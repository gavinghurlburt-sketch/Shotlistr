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
    /// Filmed horizontal (16:9), with the phone sideways.
    var wide = false
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
/// Turns a take upright when the camera saved it on its side. Only the note in the file that
/// says which way is up changes: the picture and sound are copied as they are (fast, no quality lost).
enum TakeUpright {
    static func fix(_ url: URL, wide: Bool) async {
        // Horizontal takes are left alone (shooting is vertical only now).
        guard !wide else { return }
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await video.load(.naturalSize, .preferredTransform) else { return }
        let size = loaded.0, transform = loaded.1
        let shown = CGRect(origin: .zero, size: size).applying(transform).size
        // Taller than wide, as a vertical take should be: nothing to do.
        guard abs(shown.width) > abs(shown.height) + 1 else { return }
        // A picture lying on its side (top to the left) is turned a quarter right; a tall picture that
        // was turned sideways is just put back.
        let upright = size.width > size.height
            ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
            : .identity
        let composition = AVMutableComposition()
        do {
            let tracks = try await asset.load(.tracks)
            for track in tracks where track.mediaType == .video || track.mediaType == .audio {
                guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let range = try await track.load(.timeRange)
                // At the same time it was, so the take stays lined up to the song.
                try copy.insertTimeRange(range, of: track, at: range.start)
                if track.trackID == video.trackID { copy.preferredTransform = upright }
            }
        } catch { return }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { return }
        let turned = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try await session.export(to: turned, as: .mov)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: turned)
        } catch {
            try? FileManager.default.removeItem(at: turned)
        }
    }
}

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
            applyExposure()
        }
    }
    var front = false
    /// Films horizontal (16:9, the phone sideways) instead of vertical. Picked before the first
    /// take: every take in a shoot is the same way, since they all go in one project.
    var wide = false
    /// How the phone is held (upright or sideways), from the view; flat keeps the last one.
    @ObservationIgnored var tilt: UIDeviceOrientation = .portrait
    /// Knows which way is up for the camera in use, so a sideways take is never upside down.
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    /// Whether the take being filmed is horizontal (fixed when it starts).
    @ObservationIgnored private var takeWide = false
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
    /// A take looked a lot like an earlier one in this shoot: a nudge to try another angle.
    var lookAlike: String?
    /// What each take looks like, to compare the next one against.
    @ObservationIgnored private var looks: [UUID: TakeLook.Look] = [:]
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
        watchRotation()
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

    // MARK: Exposure

    /// Brighter or darker than the camera would pick, in stops (0 is the camera's own).
    var brightness: Float = 0
    /// The exposure holds still, so a take doesn't brighten or darken when the light changes.
    var exposureLocked = false

    /// How far Brightness goes on the camera in use (at most 2 stops each way).
    var brightnessRange: ClosedRange<Float> {
        guard let device = cameraInput?.device else { return -2...2 }
        let least = max(-2, device.minExposureTargetBias)
        return least...max(least, min(2, device.maxExposureTargetBias))
    }

    /// Whether anything is set by hand (Brightness, the lock, or a spot to measure).
    var exposureChanged: Bool { brightness != 0 || exposureLocked || metered }
    private var metered = false

    func setBrightness(_ value: Float) {
        let range = brightnessRange
        brightness = min(max(value, range.lowerBound), range.upperBound)
        guard let device = cameraInput?.device else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(brightness, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {}
    }

    func setExposureLocked(_ on: Bool) {
        guard let device = cameraInput?.device else { exposureLocked = false; return }
        let mode: AVCaptureDevice.ExposureMode = on ? .locked : .continuousAutoExposure
        guard device.isExposureModeSupported(mode) else { exposureLocked = false; return }
        do {
            try device.lockForConfiguration()
            device.exposureMode = mode
            device.unlockForConfiguration()
            exposureLocked = on
        } catch {}
    }

    /// Measures the light (and focuses) at a spot of the camera's own picture (0 to 1 each way).
    func meter(at point: CGPoint) {
        guard let device = cameraInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                // Locked: it measures once at the new spot, then holds again.
                let mode: AVCaptureDevice.ExposureMode = exposureLocked ? .autoExpose : .continuousAutoExposure
                if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            }
            device.unlockForConfiguration()
        } catch {}
        metered = point != CGPoint(x: 0.5, y: 0.5)
    }

    /// Back to the camera's own exposure: no Brightness, no lock, measured in the middle.
    func resetExposure() {
        setExposureLocked(false)
        meter(at: CGPoint(x: 0.5, y: 0.5))
        setBrightness(0)
    }

    /// The camera in use gets the Brightness and lock you picked (after a switch or a new format).
    private func applyExposure() {
        setBrightness(brightness)
        if exposureLocked { setExposureLocked(true) }
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
        watchRotation()
        orientOutput()
        setUpLenses()
        // The other camera finds its own light (a lock was for the old one), with the same Brightness.
        exposureLocked = false
        applyExposure()
    }

    /// Vertical or horizontal, before the first take (once there are takes, it stays).
    func setWide(_ on: Bool) {
        guard !recording, takes.isEmpty, on != wide else { return }
        wide = on
        orientOutput()
    }

    private func watchRotation() {
        rotation = cameraInput.map { AVCaptureDevice.RotationCoordinator(device: $0.device, previewLayer: nil) }
    }

    /// Which way the picture is turned in the file: 90 is upright (vertical); a horizontal take is
    /// 0 or 180, whichever way the phone is turned, so it's never upside down.
    private var outputAngle: CGFloat {
        guard wide else { return 90 }
        if let angle = rotation?.videoRotationAngleForHorizonLevelCapture {
            let turn = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            if turn < 45 || turn >= 315 { return 0 }
            if turn >= 135 && turn < 225 { return 180 }
        }
        // The camera can't tell (the phone is flat, say): go by how it was last held.
        return tilt == .landscapeRight ? 180 : 0
    }

    /// Upright video (or level, horizontal); the front camera is mirrored like a mirror.
    private func orientOutput() {
        guard let connection = output.connection(with: .video) else { return }
        let angle = outputAngle
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
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
        lookAlike = nil
        // With the count-in, the song starts right at your spot after a bar of clicks.
        playFrom = counting ? start : max(0, start - Self.leadIn * speed.songRate)
        recordStartHost = .invalid
        songStartHost = .invalid
        let url = TakeStore.newURL()
        pendingURL = url
        takeWide = wide
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
        let take = CapturedTake(url: url, hint: hint, wide: takeWide)
        // Some cameras (the front one on some iPhones) save a vertical take on its side: it's turned
        // upright before it shows anywhere.
        Task {
            await TakeUpright.fix(url, wide: take.wide)
            takes.append(take)
            Self.keepInPhotos(url)
            compareLook(of: take)
        }
    }

    /// Checks the new take against the earlier ones in this shoot. If it looks a lot like one,
    /// says so (it's only a nudge: the take is kept either way).
    private func compareLook(of take: CapturedTake) {
        Task {
            guard let look = await TakeLook.look(at: take.url) else { return }
            // Thrown away (Retake, Delete) while it was being checked: nothing to say.
            guard let number = takes.firstIndex(where: { $0.id == take.id }) else { return }
            var closest: (number: Int, distance: Float)?
            for (index, earlier) in takes.enumerated() where index < number {
                guard let seen = looks[earlier.id], let distance = TakeLook.distance(look, seen) else { continue }
                print("Take \(number + 1) vs take \(index + 1): look distance \(distance)")
                if distance < (closest?.distance ?? .greatestFiniteMagnitude) { closest = (index + 1, distance) }
            }
            looks[take.id] = look
            if let closest, closest.distance < TakeLook.alike, !recording, takes.last?.id == take.id {
                lookAlike = "Hmm, that looked a lot like take \(closest.number). Maybe try a different angle or background?"
            }
        }
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
        looks[last.id] = nil
        lookAlike = nil
    }

    /// Throws one take away (its copy in Photos stays).
    func dropTake(_ id: CapturedTake.ID) {
        guard let index = takes.firstIndex(where: { $0.id == id }) else { return }
        let take = takes.remove(at: index)
        try? FileManager.default.removeItem(at: take.url)
        looks[take.id] = nil
        lookAlike = nil
    }

    /// Throws every take away (the copies in Photos stay).
    func dropAllTakes() {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
        takes = []
        looks = [:]
        lookAlike = nil
    }

    /// Throws the last take away and films it again.
    func retake() {
        guard ready, !recording, !takes.isEmpty else { return }
        dropLastTake()
        record()
    }
}

/// Lets Shoot turn a tap on the picture into a spot on the camera's own picture.
@MainActor final class PreviewHandle {
    weak var view: CameraPreview.PreviewView?

    /// A point on screen (window points) as a spot on the camera's picture, or nil off the picture.
    func cameraPoint(fromScreen point: CGPoint) -> CGPoint? {
        guard let view else { return nil }
        let local = view.convert(point, from: nil)
        guard view.bounds.contains(local) else { return nil }
        return view.preview.captureDevicePointConverted(fromLayerPoint: local)
    }
}

/// The camera picture, filling its space.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var handle: PreviewHandle?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        handle?.view = view
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
    let done: ([CapturedTake]) -> Void
    /// Shoot: keep the takes as a draft project instead of editing now (the X asks).
    let draft: (([CapturedTake]) -> Void)?
    @State private var capture: CaptureModel
    /// The X asked "Draft shoot?".
    @State private var asking = false
    /// The options pop-up (speed, camera, delete a take).
    @State private var menuOpen = false
    /// Your takes, big, before you use them (like Photos).
    @State private var reviewing = false
    /// Where the takes Polaroids sit on screen, so the takes view can grow out of them.
    @State private var stackFrame = CGRect.zero
    /// A small picture of each take, for the Polaroids.
    @State private var thumbs: [CapturedTake.ID: UIImage] = [:]
    /// The soft white flash when a take ends (1 is all white).
    @State private var flash = 0.0
    /// The newest Polaroid, developing from white to its picture (0 to 1).
    @State private var developing: CapturedTake.ID?
    @State private var develop = 1.0
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
    /// How the phone is held: upright or sideways (flat on a table keeps the last one).
    @State private var tilt: UIDeviceOrientation = .portrait
    /// The Brightness slider and lock, above the lenses.
    @State private var exposureOpen = false
    /// Where the picture was last tapped to measure light (screen points), shown as a square.
    @State private var meterSpot: CGPoint?
    @State private var meterToken = 0
    @State private var previewHandle = PreviewHandle()
    @Environment(\.dismiss) private var dismiss

    /// `part` starts it at one of the song's parts (Shoot, or a section's record button in creatrr).
    /// Every take starts in the same place: there's no picking another spot here.
    init(song: AVAsset, length: Double, songName: String, parts: [CreatrrPart] = [],
         part: CreatrrPart.ID? = nil, start: Double? = nil, end: Double? = nil,
         partName: String? = nil, tempo: CaptureTempo? = nil,
         draft: (([CapturedTake]) -> Void)? = nil, done: @escaping ([CapturedTake]) -> Void) {
        self.songName = songName
        self.partName = partName
        self.draft = draft
        let usable = parts.filter { $0.time < length }
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

    /// The phone is held the wrong way for what's being filmed: sideways while filming vertical,
    /// or upright while filming horizontal. Said big, and Record waits until it's right.
    private var heldWrong: Bool { capture.wide ? !tilt.isLandscape : tilt.isLandscape }

    /// Steps of the zoom along the wheel's scale, one every 10 points, for the haptic ticks.
    private var zoomTick: Int {
        Int((ZoomScale(range: capture.zoomRange).spot(capture.zoomShown) / 10).rounded())
    }

    private var recordLabel: String {
        if capture.recording { return "Stop" }
        if heldWrong { return capture.wide ? "Turn your phone sideways to record" : "Hold your phone upright to record" }
        return "Record to the song"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: capture.session, handle: previewHandle)
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
                // Tap the picture: it focuses and measures the light there, like the iPhone camera.
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .global)
                        .onEnded { value in meter(atScreen: value.location) }
                )

            meterSquare

            VStack(spacing: 0) {
                topBar
                takeBar
                Spacer(minLength: 0)
                if let message = capture.problem ?? capture.lookAlike ?? note {
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
                    if exposureOpen {
                        exposurePanel
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
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

            // A take just ended: the screen flashes white, like a camera, and fades back.
            Color.white
                .opacity(flash)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

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

            if reviewing {
                TakesReview(takes: capture.takes,
                            filmMore: { withAnimation(Self.cardSpring) { reviewing = false } },
                            delete: { capture.dropTake($0) },
                            use: { finish() },
                            startThumbs: thumbs)
                    .transition(.cardExpand(from: stackFrame))
                    .zIndex(2)
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
            let now = UIDevice.current.orientation
            if now.isLandscape || now.isPortrait { tilt = now }
            capture.tilt = tilt
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
                withAnimation(.snappy) { tilt = now }
                capture.tilt = now
            }
        }
        .overlay {
            if heldWrong && !reviewing {
                // Held the wrong way for what's being filmed: make it impossible to miss.
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 40, weight: .semibold))
                        .rotationEffect(.degrees(capture.wide ? 90 : 0))
                        .frame(width: 60, height: 60)
                    Text(capture.wide ? "Filming horizontal" : "Filming vertical")
                        .font(.title3.weight(.bold))
                    Text(capture.wide ? "Turn your phone sideways" : "Hold your phone upright")
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
        .onChange(of: capture.takes.map(\.id)) { old, new in
            // A new take (not one thrown away): flash, and its Polaroid develops.
            guard let newest = capture.takes.last, !old.contains(newest.id) else { return }
            tookPicture(newest)
        }
    }

    /// The flash, then the new Polaroid slowly shows its picture, white first.
    private func tookPicture(_ take: CapturedTake) {
        flash = 0.55
        developing = take.id
        develop = 0
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.easeOut(duration: 0.45)) { flash = 0 }
            await loadThumb(take)
            guard developing == take.id else { return }
            withAnimation(.easeIn(duration: 3)) { develop = 1 }
        }
    }

    private func loadThumb(_ take: CapturedTake) async {
        guard thumbs[take.id] == nil else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
            thumbs[take.id] = UIImage(cgImage: frame.image)
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
            // Film the last take again, in the middle under the title.
            Button { capture.retake() } label: {
                Label("Retake", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .environment(\.colorScheme, .dark)
            .disabled(!capture.ready || heldWrong)
            .accessibilityLabel("Retake the last take")
        }
    }

    /// Your last three takes, bottom right, as a little stack of square Polaroids with the newest
    /// on top. Tap it to see them all.
    private var takesStack: some View {
        let latest = Array(capture.takes.suffix(3))
        let count = capture.takes.count
        return Button { withAnimation(Self.cardSpring) { menuOpen = false; reviewing = true } } label: {
            ZStack {
                ForEach(Array(latest.enumerated()), id: \.element.id) { index, take in
                    // 0 is the top one; the ones under it peek out, tilted.
                    let depth = latest.count - 1 - index
                    polaroid(take, count: depth == 0 ? count : nil)
                        .rotationEffect(.degrees(depth == 0 ? 0 : (depth == 1 ? -8 : 7)))
                        .offset(x: CGFloat(depth) * -3, y: CGFloat(depth) * -2)
                        .zIndex(Double(index))
                }
            }
            .frame(width: 60, height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(capture.recording || count == 0 ? 0 : 1)
        .disabled(capture.recording || count == 0)
        .accessibilityLabel(count == 1 ? "See your take" : "See your \(count) takes")
        // A tap you can feel as the takes open.
        .sensoryFeedback(.impact(weight: .medium), trigger: reviewing) { was, now in !was && now }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stackFrame = $0 }
    }

    /// The takes view opening out of the Polaroids and folding back into them.
    private static let cardSpring = Animation.spring(duration: 0.45, bounce: 0.12)

    /// One take as a classic square Polaroid: white all round, a wider strip at the bottom (with
    /// the number of takes on the top one). A new one develops from white to its picture.
    private func polaroid(_ take: CapturedTake, count: Int?) -> some View {
        let fresh = take.id == developing
        return VStack(spacing: 0) {
            ZStack {
                Color(white: 0.93)
                if let image = thumbs[take.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .saturation(fresh ? develop : 1)
                        .opacity(fresh ? develop : 1)
                }
            }
            .frame(width: 40, height: 40)
            .clipped()
            Text(count.map { "\($0)" } ?? "")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 40, height: 13)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .background(Color.white)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        .task(id: take.id) { await loadThumb(take) }
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
            .disabled(!capture.ready || (!capture.recording && heldWrong))
            .opacity(capture.ready && (capture.recording || !heldWrong) ? 1 : 0.4)
            .accessibilityLabel(recordLabel)
            .sensoryFeedback(.impact, trigger: capture.recording)
            HStack(spacing: 16) {
                menuButton
                takesStack
            }
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

    /// The sun: opens Brightness and the exposure lock. Yellow (with the Brightness) once changed.
    private var exposureButton: some View {
        let changed = capture.exposureChanged
        return Button { withAnimation(.snappy) { exposureOpen.toggle() } } label: {
            HStack(spacing: 4) {
                Image(systemName: capture.exposureLocked ? "lock.fill" : "sun.max")
                    .font(.body.weight(.semibold))
                if capture.brightness != 0 {
                    Text(brightnessLabel(capture.brightness))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                }
            }
            .foregroundStyle(changed || exposureOpen ? Tint.accent : .white)
            .padding(.horizontal, capture.brightness != 0 ? 10 : 0)
            .frame(minWidth: 40, minHeight: 40)
            .background(Capsule().fill(.black.opacity(0.45)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exposure")
        .accessibilityValue(capture.exposureLocked ? "Locked, brightness \(brightnessLabel(capture.brightness))"
                            : "Brightness \(brightnessLabel(capture.brightness))")
    }

    /// Brightness, Lock and Auto: how light the picture is, and keeping it from changing mid-take.
    private var exposurePanel: some View {
        let range = capture.brightnessRange
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: Binding(get: { Double(capture.brightness) },
                                      set: { capture.setBrightness(Float(($0 * 10).rounded() / 10)) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .tint(Tint.accent)
                    .accessibilityLabel("Brightness")
                    .accessibilityValue(brightnessLabel(capture.brightness))
                Image(systemName: "sun.max.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(brightnessLabel(capture.brightness))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(capture.brightness != 0 ? Tint.accent : .white)
                    .frame(width: 38, alignment: .trailing)
            }
            HStack(spacing: 8) {
                exposureChoice(capture.exposureLocked ? "Locked" : "Lock",
                               icon: capture.exposureLocked ? "lock.fill" : "lock.open",
                               on: capture.exposureLocked) {
                    capture.setExposureLocked(!capture.exposureLocked)
                }
                .accessibilityHint("Keeps the light from changing while you film")
                exposureChoice("Auto", icon: "a.circle", on: false) {
                    capture.resetExposure()
                    withAnimation(.snappy) { meterSpot = nil }
                }
                .disabled(!capture.exposureChanged)
                .opacity(capture.exposureChanged ? 1 : 0.4)
                .accessibilityHint("Back to the camera's own exposure")
            }
            Text("Tap the picture to set where it measures the light.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Rectangle().fill(.black.opacity(0.6)))
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .sensoryFeedback(.selection, trigger: capture.brightness == 0)
    }

    private func exposureChoice(_ name: String, icon: String, on: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.footnote.weight(.semibold))
                Text(name).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(Rectangle().fill(on ? Tint.accent : .white.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func brightnessLabel(_ value: Float) -> String {
        abs(value) < 0.05 ? "0" : String(format: "%+.1f", value)
    }

    /// A tap on the picture: focus and measure the light there, and show the square for a moment.
    private func meter(atScreen point: CGPoint) {
        guard capture.ready, !menuOpen, let spot = previewHandle.cameraPoint(fromScreen: point) else { return }
        capture.meter(at: spot)
        meterToken += 1
        let token = meterToken
        withAnimation(.snappy) { meterSpot = point }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard meterToken == token else { return }
            withAnimation(.easeOut(duration: 0.4)) { meterSpot = nil }
        }
    }

    /// The yellow square where the picture was tapped (it says Locked when the lock is on).
    private var meterSquare: some View {
        GeometryReader { proxy in
            if let spot = meterSpot {
                let origin = proxy.frame(in: .global).origin
                VStack(spacing: 4) {
                    Rectangle()
                        .strokeBorder(Tint.accent, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                    if capture.exposureLocked {
                        Text("Locked")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Rectangle().fill(Tint.accent))
                    }
                }
                .position(x: spot.x - origin.x, y: spot.y - origin.y + (capture.exposureLocked ? 10 : 0))
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The lenses (0.5, 1, 3...) and the front/back switch, like the iPhone camera.
    private var lensRow: some View {
        HStack(spacing: 10) {
            // Exposure on the left and the camera switch on the right, in same-size spots, so the
            // lenses sit in the middle.
            exposureButton
                .frame(width: 78, alignment: .trailing)
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
            .frame(width: 78, alignment: .leading)
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
