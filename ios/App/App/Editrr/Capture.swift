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

/// A song's tempo from creatrr, for the count-in and the click.
struct CaptureTempo: Equatable, Sendable {
    let bpm: Double
    /// Song time of a downbeat (the click's grid lines up to it).
    let beat: Double
    /// Whether creatrr had the count-in and click on for this song.
    var countIn: Bool
    var click: Bool
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
    var speed: Speed = .normal {
        didSet {
            guard speed != oldValue else { return }
            configureFrameRate()
            // A new camera format starts back at no zoom: keep the zoom you had.
            setZoom(zoomBase * CGFloat(zoomShown))
        }
    }
    var front = false
    /// The lenses to pick from (0.5, 1, 3...), for the camera in use.
    var lenses: [Lens] = []
    /// The zoom you see, where 1 is the main camera.
    var zoomShown: Double = 1
    /// The camera's own zoom factor for 1 (the ultra wide counts as 1 on cameras that have it).
    @ObservationIgnored private var zoomBase: CGFloat = 1
    var recording = false
    /// Song time now, while recording (for the readout).
    var songNow: Double = 0
    var takes: [CapturedTake] = []
    var problem: String?
    var ready = false
    /// The song's tempo, when creatrr knows it (the count-in and click need it).
    let tempo: CaptureTempo?
    /// One bar of clicks before the song starts at your spot (no lead-in of the song then).
    var countIn = false
    /// A click on every beat while you film (the accent on each bar's first beat).
    var click = false
    /// 4, 3, 2, 1 during the count-in.
    var countBeat: Int?
    /// Plays the count-in and the click, timed to the song.
    @ObservationIgnored private let clickEngine = AVAudioEngine()
    @ObservationIgnored private let clicker = AVAudioPlayerNode()
    @ObservationIgnored private var clickReady = false
    @ObservationIgnored private var countTimers: [DispatchWorkItem] = []

    /// The part of the song this take is for (where the song starts playing from, before the lead-in).
    @ObservationIgnored private var playFrom: Double = 0
    /// Host time the song starts playing at.
    @ObservationIgnored private var songStartHost: CMTime = .invalid
    /// Host time recording actually started (from the movie output's first callback).
    @ObservationIgnored private var recordStartHost: CMTime = .invalid
    @ObservationIgnored private var pendingURL: URL?

    init(song asset: AVAsset, length: Double, tempo: CaptureTempo? = nil) {
        self.tempo = tempo.flatMap { $0.bpm >= 30 && $0.bpm <= 300 ? $0 : nil }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        songItem = item
        song = player
        songLength = length
        super.init()
        countIn = self.tempo?.countIn ?? false
        click = self.tempo?.click ?? false
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
        setUpLenses()
        let running = session
        await Task.detached { running.startRunning() }.value
        ready = cameraInput != nil
        if !ready { problem = "Couldn't open the camera." }
    }

    func stop() {
        if recording { output.stopRecording() }
        song.pause()
        stopClicks()
        if clickReady { clickEngine.stop() }
        let running = session
        Task.detached { running.stopRunning() }
        // Back to playing out loud for editing, like the app starts.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.playback, mode: .moviePlayback)
    }

    /// One of the back camera's lenses, as the zoom it gives (0.5, 1, 2, 3, 5...).
    struct Lens: Identifiable, Equatable {
        let id: Int
        let shown: Double
        let factor: CGFloat
    }

    /// The front camera, or the back one with all its lenses joined (so zoom moves across them).
    private static func camera(front: Bool) -> AVCaptureDevice? {
        if front { return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) }
        for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                     .builtInWideAngleCamera] {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return nil
    }

    /// Works out the lens buttons for the camera in use, and starts at 1.
    private func setUpLenses() {
        guard let device = cameraInput?.device else { lenses = []; return }
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let ultraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        zoomBase = ultraWide ? (switches.first ?? 2) : 1
        var factors: [CGFloat] = [1] + switches
        // No zoom lens: offer 2 (a closer crop of the main camera).
        if !front && switches.count == (ultraWide ? 1 : 0) { factors.append(zoomBase * 2) }
        factors = factors.filter { $0 >= device.minAvailableVideoZoomFactor && $0 <= device.maxAvailableVideoZoomFactor }
        lenses = factors.enumerated().map { Lens(id: $0.offset, shown: Double($0.element / zoomBase), factor: $0.element) }
        setZoom(zoomBase, smooth: false)
    }

    /// The camera's zoom factor right now (for pinching from).
    var zoomFactor: CGFloat { cameraInput?.device.videoZoomFactor ?? 1 }

    /// Zooms to a lens, gliding there.
    func pick(_ lens: Lens) { setZoom(lens.factor, smooth: true) }

    /// Sets the zoom (pinching sets it straight; a lens button glides).
    func setZoom(_ factor: CGFloat, smooth: Bool = false) {
        guard let device = cameraInput?.device else { return }
        let most = min(device.maxAvailableVideoZoomFactor, zoomBase * 15)
        let zoom = min(max(factor, device.minAvailableVideoZoomFactor), most)
        do {
            try device.lockForConfiguration()
            if smooth {
                device.ramp(toVideoZoomFactor: zoom, withRate: 8)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = zoom
            }
            device.unlockForConfiguration()
        } catch {}
        zoomShown = Double(zoom / zoomBase)
    }

    /// The zoom you can reach, as shown (.5 to 15 on a three-lens phone), for the zoom wheel.
    var zoomRange: ClosedRange<Double> {
        guard let device = cameraInput?.device else { return 1...1 }
        let least = Double(device.minAvailableVideoZoomFactor / zoomBase)
        let most = Double(min(device.maxAvailableVideoZoomFactor, zoomBase * 15) / zoomBase)
        return least...max(least, most)
    }

    /// Zooms to a zoom as shown (1 is the main camera).
    func setZoomShown(_ shown: Double) { setZoom(CGFloat(shown) * zoomBase) }

    /// The lens the zoom is on: the biggest one at or below it.
    var currentLens: Lens? {
        lenses.last { $0.shown <= zoomShown + 0.01 } ?? lenses.first
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
        setUpLenses()
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
            // Say so when this camera can't film slow-mo faster than normal.
            if rate < want {
                problem = Self.slowMoNote
            } else if problem == Self.slowMoNote {
                problem = nil
            }
        } catch {}
    }

    private static let slowMoNote = "This camera can only film 30 frames a second, so slow-mo will look choppy. Try the back camera."

    // MARK: Recording

    func record() {
        guard ready, !recording, Disk.hasRoom(for: 500 * Disk.megabyte) else {
            if !Disk.hasRoom(for: 500 * Disk.megabyte) { problem = Disk.fullMessage }
            return
        }
        problem = nil
        // With the count-in, the song starts right at your spot after a bar of clicks.
        playFrom = counting ? start : max(0, start - Self.leadIn * speed.songRate)
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
        // A bar of clicks first with the count-in (at the speed the song will play).
        let wait = 0.25 + (counting ? 4 * beatLength / speed.songRate : 0)
        let at = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: wait, preferredTimescale: 600))
        songStartHost = at
        scheduleClicks(songStart: at)
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
        stopClicks()
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

    // MARK: Count-in and click

    /// The count-in only works with a tempo.
    private var counting: Bool { countIn && tempo != nil }
    /// One beat, in song seconds.
    private var beatLength: Double { 60 / (tempo?.bpm ?? 120) }

    /// Queues the count-in's four clicks just before the song, and with Click on, one on every
    /// beat of the song from where it starts to where the take will stop.
    private func scheduleClicks(songStart: CMTime) {
        guard let tempo, counting || click, startClicks() else { return }
        let rate = speed.songRate
        let beat = beatLength
        let wallBeat = beat / rate
        var times: [(at: Double, accent: Bool)] = []
        let songAt = songStart.seconds
        if counting {
            for k in 0..<4 { times.append((songAt - Double(4 - k) * wallBeat, k == 0)) }
            // 4, 3, 2, 1 on screen with the clicks.
            for k in 0..<4 {
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.countBeat = 4 - k }
                }
                countTimers.append(item)
                let delay = max(0, songAt - Double(4 - k) * wallBeat - CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
            let clear = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.countBeat = nil }
            }
            countTimers.append(clear)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, songAt - CMClockGetTime(CMClockGetHostTimeClock()).seconds),
                                          execute: clear)
        }
        if click {
            // Beats on creatrr's grid, from where the song starts to where the take stops.
            let end = min(songLength, (partEnd ?? songLength) + 1)
            var k = Int(((playFrom - tempo.beat) / beat).rounded(.up))
            while times.count < 2000 {
                let songTime = tempo.beat + Double(k) * beat
                if songTime > end { break }
                let bar = ((k % 4) + 4) % 4
                times.append((songAt + (songTime - playFrom) / rate, bar == 0))
                k += 1
            }
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for time in times where time.at > now + 0.01 {
            let host = CMClockConvertHostTimeToSystemUnits(CMTime(seconds: time.at, preferredTimescale: 1_000_000_000))
            clicker.scheduleBuffer(Self.clickSound(accent: time.accent), at: AVAudioTime(hostTime: host),
                                   options: [], completionHandler: nil)
        }
    }

    /// Starts the click player (once), ready to queue clicks.
    private func startClicks() -> Bool {
        if !clickReady {
            clickEngine.attach(clicker)
            clickEngine.connect(clicker, to: clickEngine.mainMixerNode, format: Self.clickFormat)
            clickReady = true
        }
        if !clickEngine.isRunning {
            do { try clickEngine.start() } catch { return false }
        }
        clicker.stop()
        clicker.play()
        return true
    }

    private func stopClicks() {
        countTimers.forEach { $0.cancel() }
        countTimers = []
        countBeat = nil
        if clickReady { clicker.stop() }
    }

    private static let clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private static let accentClick = makeClick(accent: true)
    private static let plainClick = makeClick(accent: false)
    private static func clickSound(accent: Bool) -> AVAudioPCMBuffer { accent ? accentClick : plainClick }

    /// A short, bright tick (higher on a bar's first beat), the same as creatrr's click.
    private static func makeClick(accent: Bool) -> AVAudioPCMBuffer {
        let rate = clickFormat.sampleRate
        let count = AVAudioFrameCount(0.07 * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: count)!
        buffer.frameLength = count
        let amp = accent ? 0.55 : 0.32
        let pitch = accent ? 1600.0 : 1050.0
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(count) {
            let t = Double(i) / rate
            var level = amp * (t / 0.004)
            if t >= 0.004 { level = amp * pow(0.0001 / amp, min(1, (t - 0.004) / 0.056)) }
            samples[i] = Float(level * (sin(2 * Double.pi * pitch * t) >= 0 ? 1 : -1))
        }
        return buffer
    }

    func dropLastTake() {
        guard let last = takes.popLast() else { return }
        try? FileManager.default.removeItem(at: last.url)
    }

    /// Throws every take away (the copies in Photos stay).
    func dropAllTakes() {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
        takes = []
    }

    /// Throws the last take away and films it again.
    func retake() {
        guard ready, !recording, !takes.isEmpty else { return }
        dropLastTake()
        record()
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
    /// The section being filmed (Verse, Chorus...), shown under the song's name.
    let partName: String?
    /// The most takes this time (10 videos in a project, minus any already picked).
    let maxTakes: Int
    let done: ([CapturedTake]) -> Void
    /// Shoot: keep the takes as a draft project instead of editing now (the X asks).
    let draft: (([CapturedTake]) -> Void)?
    @State private var capture: CaptureModel
    /// The X asked "Draft shoot?".
    @State private var asking = false
    /// The options pop-up (speed, camera, delete a take).
    @State private var menuOpen = false
    /// A short note over the record button (the count-in and click need a tempo).
    @State private var note: String?
    /// The zoom when a pinch began.
    @State private var pinchFrom: CGFloat?
    /// Holding or sliding a lens button shows the zoom wheel.
    @State private var wheelOn = false
    /// The press on a lens button right now.
    @State private var pressId: UUID?
    /// Where the wheel's drag began: the finger's x and the zoom then.
    @State private var wheelFrom: (x: CGFloat, spot: Double)?
    /// Bumped on each press, so an old "hide the wheel" timer does nothing.
    @State private var hideToken = 0
    /// The phone is held sideways while filming vertical: say so, big.
    @State private var sideways = false
    @Environment(\.dismiss) private var dismiss

    /// `part` starts it at one of the song's parts (Shoot, or a section's record button in creatrr).
    /// Every take starts in the same place: there's no picking another spot here.
    init(song: AVAsset, length: Double, songName: String, parts: [CreatrrPart] = [],
         part: CreatrrPart.ID? = nil, start: Double? = nil, end: Double? = nil,
         partName: String? = nil, tempo: CaptureTempo? = nil, maxTakes: Int = 10,
         draft: (([CapturedTake]) -> Void)? = nil, done: @escaping ([CapturedTake]) -> Void) {
        self.songName = songName
        self.partName = partName
        self.draft = draft
        let usable = parts.filter { $0.time < length }
        self.maxTakes = max(1, maxTakes)
        self.done = done
        let model = CaptureModel(song: song, length: length, tempo: tempo)
        if let part, let index = usable.firstIndex(where: { $0.id == part }) {
            model.start = usable[index].time
            model.partEnd = index + 1 < usable.count ? usable[index + 1].time : nil
        }
        // Shoot says exactly where to start and stop.
        if let start, start < length {
            model.start = max(0, start)
            model.partEnd = end.flatMap { $0 > start ? $0 : nil }
        }
        _capture = State(initialValue: model)
    }

    private var full: Bool { capture.takes.count >= maxTakes }

    /// Steps of the zoom along the wheel's scale, one every 10 points, for the haptic ticks.
    private var zoomTick: Int {
        Int((ZoomScale(range: capture.zoomRange).spot(capture.zoomShown) / 10).rounded())
    }

    private var recordLabel: String {
        if capture.recording { return "Stop" }
        return full ? "That's \(maxTakes) takes" : "Record to the song"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: capture.session)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
                .contentShape(Rectangle())
                .gesture(
                    // Pinch to zoom, even while filming.
                    MagnifyGesture()
                        .onChanged { value in
                            let from = pinchFrom ?? capture.zoomFactor
                            pinchFrom = from
                            capture.setZoom(from * value.magnification)
                        }
                        .onEnded { _ in pinchFrom = nil }
                )

            VStack(spacing: 0) {
                topBar
                takeBar
                Spacer(minLength: 0)
                if let message = capture.problem ?? note {
                    Text(message)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(capture.problem != nil ? Tint.bad.opacity(0.85) : Color.black.opacity(0.55))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
                if !capture.recording {
                    ZStack(alignment: .bottom) {
                        // Stays in place under the wheel, so the press that opened it keeps going.
                        lensRow.opacity(wheelOn ? 0.05 : 1)
                        if wheelOn { zoomWheel.transition(.opacity) }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: wheelOn)
                }
                controls
            }
            .foregroundStyle(.white)

            // The count-in: 4, 3, 2, 1 big in the middle.
            if let beat = capture.countBeat {
                Text("\(beat)")
                    .font(.system(size: 120, weight: .heavy).monospacedDigit())
                    .foregroundStyle(beat == 4 ? Tint.accent : .white)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if menuOpen {
                // Tap anywhere else to close the pop-up.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { menuOpen = false } }
                    .accessibilityHidden(true)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        optionsMenu
                    }
                }
                .padding(.bottom, 104)
                .padding(.horizontal, 12)
                .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }

            if asking {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { asking = false } }
                    .accessibilityHidden(true)
                draftAsk
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        // Zooming clicks like the iPhone camera: a light tick as the scale passes each mark
        // (wheel or pinch), a firmer one at each lens.
        .sensoryFeedback(.selection, trigger: zoomTick)
        .sensoryFeedback(.impact(weight: .medium), trigger: capture.currentLens?.id)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await capture.prepare() }
        .onAppear {
            CameraLock.hold(true)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            sideways = UIDevice.current.orientation.isLandscape
        }
        .onDisappear {
            capture.stop()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            CameraLock.hold(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let now = UIDevice.current.orientation
            // Flat on a table says nothing either way: keep what it was.
            if now.isLandscape || now.isPortrait {
                withAnimation(.snappy) { sideways = now.isLandscape }
            }
        }
        .overlay {
            if sideways {
                // Takes are always filmed upright: make it impossible to miss.
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 40, weight: .semibold))
                    Text("Filming vertical")
                        .font(.title3.weight(.bold))
                    Text("Hold your phone upright")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26).padding(.vertical, 20)
                .frostedPopup()
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: capture.recording) { _, recording in
            if recording { menuOpen = false; note = nil; wheelOn = false }
        }
    }

    private func finish() {
        capture.stop()
        done(capture.takes)
        dismiss()
    }

    /// The X: with takes, Shoot asks whether to keep them as a draft or delete them.
    private func close() {
        guard draft != nil, !capture.takes.isEmpty else {
            finish()
            return
        }
        withAnimation(.snappy) { menuOpen = false; asking = true }
    }

    /// "Draft shoot?": Draft keeps the takes as a project in Edits, Delete throws them away.
    private var draftAsk: some View {
        let count = capture.takes.count
        let takes = count == 1 ? "1 take" : "\(count) takes"
        return VStack(spacing: 0) {
            Text("Draft shoot?")
                .font(.title3.weight(.bold))
                .padding(.top, 22)
            Text("Save your \(takes) as a draft in Edits to finish later, or delete them.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 18)
            VStack(spacing: 10) {
                Button {
                    capture.stop()
                    draft?(capture.takes)
                    dismiss()
                } label: {
                    Text("Draft")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(Tint.accent))
                }
                .buttonStyle(.plain)
                Button {
                    capture.dropAllTakes()
                    finish()
                } label: {
                    Text("Delete")
                        .font(.headline)
                        .foregroundStyle(Tint.bad)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(takes)")
                Button { withAnimation(.snappy) { asking = false } } label: {
                    Text("Keep filming")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .frame(width: 300)
        .frostedPopup()
    }

    /// Close, the song and section you're filming, and the options.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .disabled(capture.recording)
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Text(songName)
                    .font(.headline)
                    .lineLimit(1)
                if let partName, !partName.isEmpty {
                    Text(partName)
                        .font(.headline.weight(.regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            // Balances the X so the title sits in the middle.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    /// Under the title: the time while filming, or Retake and Use once there are takes.
    @ViewBuilder private var takeBar: some View {
        if capture.recording {
            HStack(spacing: 6) {
                Circle().fill(Tint.bad).frame(width: 9, height: 9)
                Text(clock(capture.songNow)).monospacedDigit()
            }
            .font(.headline)
            .frame(height: 38)
            .shadow(color: .black.opacity(0.5), radius: 4)
        } else if !capture.takes.isEmpty {
            HStack(spacing: 10) {
                // Film the last take again.
                Button { capture.retake() } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        .background(Capsule().fill(.black.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .disabled(!capture.ready)
                .accessibilityLabel("Retake the last take")
                // Done filming: use the takes.
                Button { finish() } label: {
                    Text("Use \(capture.takes.count) of \(maxTakes)")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(Capsule().fill(Tint.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(capture.takes.count) \(capture.takes.count == 1 ? "take" : "takes")")
            }
        }
    }

    /// Count-in and click on the left, record in the middle, the menu on the right. That's all.
    private var controls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                tempoButton("Count-in", icon: "metronome", on: capture.countIn) { capture.countIn.toggle() }
                tempoButton("Click", icon: "waveform.path", on: capture.click) { capture.click.toggle() }
            }
            .frame(maxWidth: .infinity)
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
            .disabled(!capture.ready || (full && !capture.recording))
            .opacity(capture.ready && (!full || capture.recording) ? 1 : 0.4)
            .accessibilityLabel(recordLabel)
            .sensoryFeedback(.impact, trigger: capture.recording)
            menuButton
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    /// Count-in or Click: an icon with its name under it, yellow when on. Needs the song's tempo.
    private func tempoButton(_ name: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        let known = capture.tempo != nil
        let lit = on && known
        return Button {
            guard known else {
                withAnimation(.snappy) { note = "Set the song's tempo in creatrr to use the count-in and click." }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.snappy) { note = nil }
                }
                return
            }
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .symbolVariant(lit ? .fill : .none)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(.white.opacity(lit ? 0 : 0.18), lineWidth: 1))
                    .overlay(Circle().strokeBorder(Tint.accent.opacity(lit ? 0.9 : 0), lineWidth: 1.5))
                Text(name).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(lit ? Tint.accent : .white.opacity(known ? 0.9 : 0.4))
            .frame(width: 56, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(capture.recording ? 0 : 1)
        .disabled(capture.recording)
        .accessibilityLabel(name)
        .accessibilityValue(lit ? "On" : "Off")
    }

    /// The menu, like the iPhone camera's: six dots on a frosted glass circle.
    private var menuButton: some View {
        Button { withAnimation(.snappy) { menuOpen.toggle() } } label: {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<2, id: \.self) { _ in
                    GridRow {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().frame(width: 4.5, height: 4.5)
                        }
                    }
                }
            }
            .foregroundStyle(menuOpen ? Tint.accent : .white)
            .frame(width: 48, height: 48)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Options")
        .opacity(capture.recording ? 0 : 1)
        .disabled(capture.recording)
    }

    /// The options pop-up, in creatrr's rounded frosted glass.
    private var optionsMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Speed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.top, 14)
            HStack(spacing: 6) {
                ForEach(CaptureModel.Speed.allCases) { speed in
                    let picked = capture.speed == speed
                    Button { capture.speed = speed } label: {
                        Text(speed.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(picked ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background {
                                if picked {
                                    Capsule().fill(Tint.accent)
                                } else {
                                    Capsule().fill(.white.opacity(0.1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(speed.detail)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)

            menuDivider
            menuRow("Delete the last take", icon: "arrow.uturn.backward", danger: true) {
                capture.dropLastTake()
                withAnimation(.snappy) { menuOpen = false }
            }
            .disabled(capture.takes.isEmpty)
            .opacity(capture.takes.isEmpty ? 0.4 : 1)
            if let tempo = capture.tempo {
                menuDivider
                Text("\(songName) · \(Int(tempo.bpm.rounded())) BPM")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 270, alignment: .leading)
        .frostedPopup()
    }

    /// The lenses (0.5, 1, 3...) and the front/back switch, like the iPhone camera.
    private var lensRow: some View {
        HStack(spacing: 10) {
            if capture.lenses.count > 1 {
                HStack(spacing: 4) {
                    ForEach(capture.lenses) { lens in
                        let on = capture.currentLens == lens
                        Text(on ? zoomLabel(capture.zoomShown) + "\u{00D7}" : zoomLabel(lens.shown))
                            .font(.system(size: on ? 13 : 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(on ? Tint.accent : .white)
                            .frame(width: on ? 40 : 32, height: on ? 40 : 32)
                            .background(Circle().fill(.black.opacity(0.45)))
                            .contentShape(Circle())
                            // Tap for the lens; hold or slide for the zoom wheel.
                            .gesture(lensGesture(lens))
                            .accessibilityLabel("Zoom \(zoomLabel(lens.shown))")
                            .accessibilityHint("Hold and slide to zoom")
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { withAnimation(.snappy) { capture.pick(lens) } }
                    }
                }
                .padding(4)
                .background(Capsule().fill(.black.opacity(0.25)))
            }
            Button { capture.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(capture.front ? "Use the back camera" : "Use the front camera")
        }
        .padding(.bottom, 14)
    }

    /// A lens button: a tap goes to that lens. Holding it, or sliding off it, brings up the zoom
    /// wheel, and sliding left or right zooms in or out, like the iPhone camera.
    private func lensGesture(_ lens: CaptureModel.Lens) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressId == nil {
                    let id = UUID()
                    pressId = id
                    hideToken += 1
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if pressId == id && !wheelOn { withAnimation(.snappy) { wheelOn = true } }
                    }
                }
                let dx = value.translation.width
                if !wheelOn && abs(dx) > 10 { withAnimation(.snappy) { wheelOn = true } }
                guard wheelOn else { return }
                let scale = ZoomScale(range: capture.zoomRange)
                let from = wheelFrom ?? (x: dx, spot: scale.spot(capture.zoomShown))
                wheelFrom = from
                capture.setZoomShown(scale.zoom(at: from.spot - Double(dx - from.x)))
            }
            .onEnded { _ in
                let wheel = wheelOn
                pressId = nil
                wheelFrom = nil
                guard wheel else {
                    withAnimation(.snappy) { capture.pick(lens) }
                    return
                }
                // The wheel stays a moment, then the lens buttons come back.
                hideToken += 1
                let token = hideToken
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if token == hideToken && pressId == nil {
                        withAnimation(.easeOut(duration: 0.25)) { wheelOn = false }
                    }
                }
            }
    }

    /// The zoom wheel: a dark dome whose scale slides under a yellow mark as you drag.
    private var zoomWheel: some View {
        let shown = capture.zoomShown
        let range = capture.zoomRange
        let lenses = capture.lenses.map(\.shown)
        return VStack(spacing: 2) {
            Text(zoomLabel(shown) + "\u{00D7}")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(Tint.accent)
                .shadow(color: .black.opacity(0.6), radius: 3)
            Canvas { context, size in
                Self.drawWheel(context, size: size, shown: shown, range: range, lenses: lenses, label: zoomLabel)
            }
            .frame(height: 124)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func drawWheel(_ context: GraphicsContext, size: CGSize, shown: Double,
                                  range: ClosedRange<Double>, lenses: [Double],
                                  label: (Double) -> String) {
        let radius = size.width * 0.85
        let center = CGPoint(x: size.width / 2, y: radius + 8)
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)),
                     with: .color(.black.opacity(0.55)))
        // Uneven like the iPhone's: wide at .5 to 2, tighter and tighter toward the top zoom.
        // The scale moves exactly as far as the finger.
        let scale = ZoomScale(range: range)
        let now = scale.spot(shown)
        func angle(_ value: Double) -> Double { (scale.spot(value) - now) / Double(radius) }
        func point(_ angle: Double, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: center.x + distance * CGFloat(sin(angle)), y: center.y - distance * CGFloat(cos(angle)))
        }
        func tick(_ value: Double, length: CGFloat, width: CGFloat, opacity: Double) {
            let a = angle(value)
            guard abs(a) < 1.2 else { return }
            var path = Path()
            path.move(to: point(a, radius - 8))
            path.addLine(to: point(a, radius - 8 - length))
            context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: width)
        }
        guard range.lowerBound > 0 else { return }
        // Small ticks every tenth of a doubling, thinned out where the scale gets tight.
        let low = Int((log2(range.lowerBound) * 10).rounded(.up))
        let high = Int((log2(range.upperBound) * 10).rounded(.down))
        if low <= high {
            var lastSpot = -Double.infinity
            for step in low...high {
                let value = pow(2, Double(step) / 10)
                let spot = scale.spot(value)
                guard spot - lastSpot >= 5 else { continue }
                lastSpot = spot
                if step % 10 != 0 { tick(value, length: 8, width: 1, opacity: 0.45) }
            }
        }
        // Big ticks and numbers at each lens and each doubling (.5, 1, 2, 4, 8), never crowded.
        var marks = lenses.filter { range.contains($0) }
        let first = Int(log2(range.lowerBound).rounded(.up))
        let last = Int(log2(range.upperBound).rounded(.down))
        if first <= last {
            for power in first...last {
                let value = pow(2, Double(power))
                if !marks.contains(where: { abs(scale.spot($0) - scale.spot(value)) < 24 }) { marks.append(value) }
            }
        }
        for value in marks {
            tick(value, length: 15, width: 2, opacity: 0.95)
            let a = angle(value)
            guard abs(a) < 1.1 else { continue }
            context.draw(Text(label(value))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white),
                         at: point(a, radius - 38))
        }
        // The yellow mark at the top: where the zoom is now.
        var mark = Path()
        mark.move(to: CGPoint(x: center.x - 5, y: 0))
        mark.addLine(to: CGPoint(x: center.x + 5, y: 0))
        mark.addLine(to: CGPoint(x: center.x, y: 7))
        mark.closeSubpath()
        context.fill(mark, with: .color(Tint.accent))
        var line = Path()
        line.move(to: point(0, radius - 2))
        line.addLine(to: point(0, radius - 26))
        context.stroke(line, with: .color(Tint.accent), lineWidth: 2)
    }

    /// 0.5 shows as .5, whole numbers without a decimal, the rest to one place.
    private func zoomLabel(_ value: Double) -> String {
        let tenth = (value * 10).rounded() / 10
        if tenth < 1 { return String(format: ".%d", Int((tenth * 10).rounded())) }
        if tenth == tenth.rounded() { return String(Int(tenth)) }
        return String(format: "%.1f", tenth)
    }

    private var menuDivider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
    }

    private func menuRow(_ name: String, icon: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .frame(width: 22)
                Text(name).font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(danger ? Tint.bad : .white)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

extension View {
    /// creatrr's pop-up look: rounded, frosted glass with a thin light edge.
    func frostedPopup(corner: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Tint.surface.opacity(0.5))
                }
            }
            .overlay {
                ZStack {
                    shape.strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center),
                                       lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.38), radius: 20, y: 14)
    }
}

/// Where each zoom sits along the zoom wheel, in points. Like the iPhone camera's dial it isn't
/// even: each doubling takes less room than the one before, so .5 to 2 is roomy and the top zoom
/// is one short slide away.
struct ZoomScale {
    let low: Double
    let high: Double
    /// Room for the first doubling, and how fast later doublings shrink.
    private static let first = 125.0
    private static let shrink = 0.3

    init(range: ClosedRange<Double>) {
        low = max(range.lowerBound, 0.01)
        high = max(range.upperBound, low)
    }

    /// Points from the lowest zoom.
    func spot(_ zoom: Double) -> Double {
        let doublings = log2(min(max(zoom, low), high) / low)
        return Self.first * (1 - exp(-Self.shrink * doublings)) / Self.shrink
    }

    /// The zoom at a point along the wheel (clamped to the ends).
    func zoom(at spot: Double) -> Double {
        let end = self.spot(high)
        let clamped = min(max(spot, 0), end)
        let doublings = -log(1 - clamped * Self.shrink / Self.first) / Self.shrink
        return min(high, low * pow(2, doublings))
    }
}

/// While the Shoot camera is open the screen stays upright (the app delegate reads this).
enum CameraLock {
    @MainActor static var upright = false

    @MainActor static func hold(_ on: Bool) {
        upright = on
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        if on { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
    }
}
