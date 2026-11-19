import SwiftUI
import AVFoundation
import Photos

/// Where the song was when a take recorded in editrr started, and how fast the song played,
/// so the take lines up without searching the whole song.
struct TakeHint: Sendable, Equatable {
    /// Song time (seconds) at the take's first frame.
    let songTime: Double
    /// How many times longer the take plays than it was shot (2: shot to the song at double
    /// speed, for slow-mo). Same meaning as Layer.speed.
    let speed: Double
}

/// A take recorded to the song.
struct CapturedTake: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let hint: TakeHint
}

/// Where recorded takes wait until a project adopts them (a project keeps its own link).
enum TakeStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func newURL() -> URL { folder.appendingPathComponent(UUID().uuidString + ".mov") }

    static func clear() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("Takes", isDirectory: true))
    }
}

/// Performance capture: the camera records while the song plays from the part you pick,
/// so every take knows where it sits in the song.
@MainActor @Observable
final class CaptureModel: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Speed: CaseIterable, Identifiable {
        case normal, slowMo, spedUp
        var id: Self { self }
        /// How fast the song plays while filming (also how much longer the take plays after).
        var songRate: Double {
            switch self {
            case .normal: 1
            case .slowMo: 2
            case .spedUp: 0.5
            }
        }
        var label: String {
            switch self {
            case .normal: "Normal"
            case .slowMo: "Slow-mo"
            case .spedUp: "Sped up"
            }
        }
        var detail: String {
            switch self {
            case .normal: "The song plays as is."
            case .slowMo: "The song plays twice as fast. Your take plays back slowed down."
            case .spedUp: "The song plays at half speed. Your take plays back sped up."
            }
        }
    }

    /// How much of the song plays before the part you picked, to get into it.
    static let leadIn: Double = 2

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private var cameraInput: AVCaptureDeviceInput?
    private let song: AVPlayer
    @ObservationIgnored private var songItem: AVPlayerItem?
    @ObservationIgnored private var endWatch: Any?

    let songLength: Double
    var start: Double = 0
    /// Song time where the picked creatrr part ends; the take stops a second after it.
    var partEnd: Double?
    var speed: Speed = .normal { didSet { if speed != oldValue { configureFrameRate() } } }
    var front = false
    var recording = false
    /// Song time now, while recording (for the readout).
    var songNow: Double = 0
    var takes: [CapturedTake] = []
    var problem: String?
    var ready = false

    /// The part of the song this take is for (where the song starts playing from, before the lead-in).
    @ObservationIgnored private var playFrom: Double = 0
    /// Host time the song starts playing at.
    @ObservationIgnored private var songStartHost: CMTime = .invalid
    /// Host time recording actually started (from the movie output's first callback).
    @ObservationIgnored private var recordStartHost: CMTime = .invalid
    @ObservationIgnored private var pendingURL: URL?

    init(song asset: AVAsset, length: Double) {
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        songItem = item
        song = player
        songLength = length
        super.init()
    }

    // MARK: Setup

    func prepare() async {
        guard !ready else { return }
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard camera else {
            problem = "editrr needs the camera to record. Turn it on in Settings > editrr."
            return
        }
        if !mic {
            problem = "No microphone, so takes have no sound. They still line up to the song."
        }
        // The song plays out loud while the camera records, so the take hears it.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .videoRecording,
                               options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? audio.setActive(true)

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        if let device = Self.camera(front: front), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
        }
        if mic, let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configureFrameRate()
        orientOutput()
        let running = session
        await Task.detached { running.startRunning() }.value
        ready = cameraInput != nil
        if !ready { problem = "Couldn't open the camera." }
    }

    func stop() {
        if recording { output.stopRecording() }
        song.pause()
        let running = session
        Task.detached { running.stopRunning() }
        // Back to playing out loud for editing, like the app starts.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.playback, mode: .moviePlayback)
    }

    private static func camera(front: Bool) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
    }

    func flip() {
        guard !recording, let device = Self.camera(front: !front),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if let cameraInput { session.removeInput(cameraInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            cameraInput = input
            front.toggle()
        } else if let cameraInput {
            session.addInput(cameraInput)
        }
        session.commitConfiguration()
        configureFrameRate()
        orientOutput()
    }

    /// Upright video; the front camera is mirrored like a mirror.
    private func orientOutput() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = front
        }
    }

    /// Slow-mo takes are filmed at 60 frames a second where the camera can, so they stay smooth
    /// when slowed down.
    private func configureFrameRate() {
        guard let device = cameraInput?.device else { return }
        let want: Double = speed == .slowMo ? 60 : 30
        let fits = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == 1920 && size.height == 1080 &&
                format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= want }
        }
        do {
            try device.lockForConfiguration()
            if want > 30, let format = fits.first {
                device.activeFormat = format
            }
            let rate = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= want } ? want : 30
            let frame = CMTime(value: 1, timescale: CMTimeScale(rate))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: Recording

    func record() {
        guard ready, !recording, Disk.hasRoom(for: 500 * Disk.megabyte) else {
            if !Disk.hasRoom(for: 500 * Disk.megabyte) { problem = Disk.fullMessage }
            return
        }
        problem = nil
        playFrom = max(0, start - Self.leadIn * speed.songRate)
        recordStartHost = .invalid
        songStartHost = .invalid
        let url = TakeStore.newURL()
        pendingURL = url
        orientOutput()
        // Get the song ready to start the moment recording does.
        song.pause()
        song.seek(to: CMTime(seconds: playFrom, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        recording = true
        songNow = playFrom
        output.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        guard recording else { return }
        output.stopRecording()
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        Task { @MainActor in self.beginSong(recordingStarted: now) }
    }

    /// Starts the song a moment after recording starts, at a known host time.
    private func beginSong(recordingStarted: CMTime) {
        recordStartHost = recordingStarted
        let at = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.25, preferredTimescale: 600))
        songStartHost = at
        song.setRate(Float(speed.songRate), time: CMTime(seconds: playFrom, preferredTimescale: 600), atHostTime: at)
        if let endWatch { song.removeTimeObserver(endWatch) }
        endWatch = song.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, self.recording else { return }
                self.songNow = now.seconds
                // The song (or the picked part) ended: so does the take.
                if now.seconds >= self.songLength - 0.05 { self.stopRecording() }
                if let end = self.partEnd, now.seconds >= end + 1 { self.stopRecording() }
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // A take cut short (the phone ran out of space, a call came in) is often still fine.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        Task { @MainActor in self.finishTake(outputFileURL, ok: finished) }
    }

    private func finishTake(_ url: URL, ok: Bool) {
        recording = false
        song.pause()
        if let endWatch { song.removeTimeObserver(endWatch); self.endWatch = nil }
        guard ok, recordStartHost.isValid, songStartHost.isValid else {
            try? FileManager.default.removeItem(at: url)
            problem = "That take didn't save. Try again."
            return
        }
        // The song was at playFrom when it started, which was this long after recording started.
        let delay = CMTimeSubtract(songStartHost, recordStartHost).seconds
        let rate = speed.songRate
        let hint = TakeHint(songTime: playFrom - delay * rate, speed: rate)
        takes.append(CapturedTake(url: url, hint: hint))
        Self.keepInPhotos(url)
    }

    /// A copy goes to Photos too, so the take is safe even if the project is deleted.
    private static func keepInPhotos(_ url: URL) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let save = {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: nil)
        }
        if status == .authorized || status == .limited {
            save()
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
                if granted == .authorized || granted == .limited { save() }
            }
        }
    }

    func dropLastTake() {
        guard let last = takes.popLast() else { return }
        try? FileManager.default.removeItem(at: last.url)
    }
}

/// The camera picture, filling its space.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

/// Performance capture: pick where in the song to start, hit record, perform. Every take
/// lines up to the song on its own.
struct CaptureView: View {
    let songName: String
    /// The song's parts from creatrr (empty for other songs).
    let parts: [CreatrrPart]
    let done: ([CapturedTake]) -> Void
    @State private var capture: CaptureModel
    @State private var pickedPart: CreatrrPart.ID?
    @Environment(\.dismiss) private var dismiss

    init(song: AVAsset, length: Double, songName: String, parts: [CreatrrPart] = [],
         done: @escaping ([CapturedTake]) -> Void) {
        self.songName = songName
        self.parts = parts.filter { $0.time < length }
        self.done = done
        _capture = State(initialValue: CaptureModel(song: song, length: length))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: capture.session)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let problem = capture.problem {
                    Text(problem)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Tint.bad.opacity(0.85))
                        .padding(.bottom, 10)
                }
                controls
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await capture.prepare() }
        .onDisappear { capture.stop() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                capture.stop()
                done(capture.takes)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(capture.takes.isEmpty ? "Close" : "Close and keep the takes")
            .disabled(capture.recording)
            Spacer()
            if capture.recording {
                HStack(spacing: 6) {
                    Circle().fill(Tint.bad).frame(width: 9, height: 9)
                    Text(clock(capture.songNow)).monospacedDigit()
                }
                .font(.headline)
            } else if !capture.takes.isEmpty {
                Text(capture.takes.count == 1 ? "1 take" : "\(capture.takes.count) takes")
                    .font(.headline)
            }
            Spacer()
            Button { capture.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Switch camera")
            .disabled(capture.recording)
            .opacity(capture.recording ? 0.3 : 1)
        }
        .padding(.horizontal, 8)
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if !capture.recording {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(songName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text("Starts at \(clock(capture.start))")
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if !parts.isEmpty { partChips }
                    Slider(value: $capture.start, in: 0...max(1, capture.songLength - 1), step: 0.5, onEditingChanged: { editing in
                        // Dragging picks your own spot instead of a part.
                        if editing {
                            pickedPart = nil
                            capture.partEnd = nil
                        }
                    })
                    .tint(Tint.accent)
                    .accessibilityLabel("Where in the song to start")
                }
                HStack(spacing: 6) {
                    ForEach(CaptureModel.Speed.allCases) { speed in
                        Button(speed.label) { capture.speed = speed }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(capture.speed == speed ? Tint.accent : Color.white.opacity(0.12))
                            .foregroundStyle(capture.speed == speed ? Color.black : Color.white)
                            .accessibilityHint(speed.detail)
                    }
                }
            }

            HStack {
                // Take the last one back.
                Button { capture.dropLastTake() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .accessibilityLabel("Delete the last take")
                .opacity(capture.takes.isEmpty || capture.recording ? 0 : 1)
                .disabled(capture.takes.isEmpty || capture.recording)

                Spacer()
                Button {
                    if capture.recording { capture.stopRecording() } else { capture.record() }
                } label: {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                        if capture.recording {
                            Corner.small.fill(Tint.bad).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(Tint.bad).frame(width: 62, height: 62)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!capture.ready)
                .opacity(capture.ready ? 1 : 0.4)
                .accessibilityLabel(capture.recording ? "Stop" : "Record to the song")
                .sensoryFeedback(.impact, trigger: capture.recording)
                Spacer()

                Button {
                    capture.stop()
                    done(capture.takes)
                    dismiss()
                } label: {
                    Text("Use")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Tint.accent))
                }
                .accessibilityLabel("Use these takes")
                .opacity(capture.takes.isEmpty || capture.recording ? 0 : 1)
                .disabled(capture.takes.isEmpty || capture.recording)
            }

            if !capture.recording {
                Text(capture.takes.isEmpty
                     ? "The song starts a moment before your spot. Each take lines up on its own."
                     : "Record more takes, or tap Use.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    /// creatrr's parts: tap one to start there; the take stops when the part ends.
    private var partChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    let picked = pickedPart == part.id
                    Button {
                        pickedPart = part.id
                        capture.start = part.time
                        capture.partEnd = index + 1 < parts.count ? parts[index + 1].time : nil
                    } label: {
                        HStack(spacing: 6) {
                            Rectangle().fill(part.tint).frame(width: 4, height: 16)
                            Text(part.name).lineLimit(1)
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(picked ? part.tint.opacity(0.45) : Tint.surface2, in: Capsule())
                        .overlay(Capsule().strokeBorder(picked ? part.tint : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(part.name), starts at \(clock(part.time))")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
