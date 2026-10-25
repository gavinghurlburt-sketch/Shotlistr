import UIKit
import AVFoundation
import ActivityKit
import AppIntents
import Capacitor
import MediaPlayer

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    // Push notifications: hand the device token (or the failure) to Capacitor's push plugin
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// ---- Lock-screen Live Activity for shoot playback (the widget itself lives in the CreatrrWidget target) ----
/// Identical copies of these types live in the widget target (ios/CreatrrWidget/ShootLiveActivity.swift).
@available(iOS 16.2, *)
struct ShootActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var song: String
        var section: String
        var playing: Bool
        var position: Int
        var total: Int
        var color: String = ""
        var colors: [String] = []
    }
    var shoot: String
}

enum ShootBridge {
    static let note = Notification.Name("creatrr.shoot.command")
    static func send(_ name: String) { NotificationCenter.default.post(name: note, object: nil, userInfo: ["name": name]) }
}

@available(iOS 17.0, *)
struct ShootToggleIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or stop"
    func perform() async throws -> some IntentResult { ShootBridge.send("toggle"); return .result() }
}
@available(iOS 17.0, *)
struct ShootNextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next section"
    func perform() async throws -> some IntentResult { ShootBridge.send("next"); return .result() }
}
@available(iOS 17.0, *)
struct ShootPreviousIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous section"
    func perform() async throws -> some IntentResult { ShootBridge.send("previous"); return .result() }
}
@available(iOS 17.0, *)
struct ShootNextSongIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next song"
    func perform() async throws -> some IntentResult { ShootBridge.send("nextSong"); return .result() }
}
@available(iOS 17.0, *)
struct ShootPreviousSongIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous song"
    func perform() async throws -> some IntentResult { ShootBridge.send("previousSong"); return .result() }
}

@available(iOS 16.2, *)
@objc(ShootActivityPlugin)
public class ShootActivityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ShootActivityPlugin"
    public let jsName = "ShootActivity"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "end", returnType: CAPPluginReturnPromise),
    ]
    private var activity: Activity<ShootActivityAttributes>?
    private var sessionReady = false
    private var nowTimer: Timer?

    override public func load() {
        NotificationCenter.default.addObserver(forName: ShootBridge.note, object: nil, queue: .main) { [weak self] n in
            self?.notifyListeners("command", data: ["name": (n.userInfo?["name"] as? String) ?? ""])
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        if !sessionReady {   // keeps the song playing with the screen locked
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])  // mixWithOthers keeps it out of the system Now Playing
            try? AVAudioSession.sharedInstance().setActive(true)
            sessionReady = true
        }
        if nowTimer == nil {   // the web page's audio also posts a generic lock-screen player; keep clearing it so only the creatrr card shows
            nowTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                let c = MPRemoteCommandCenter.shared()
                let cmds: [MPRemoteCommand] = [c.playCommand, c.pauseCommand, c.stopCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand, c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand, c.changePlaybackPositionCommand]
                for m in cmds { m.isEnabled = false }
            }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { call.resolve(["enabled": false]); return }
        let state = ShootActivityAttributes.ContentState(
            song: call.getString("song") ?? "creatrr", section: call.getString("section") ?? "",
            playing: call.getBool("playing") ?? false, position: call.getInt("position") ?? 1, total: call.getInt("total") ?? 1,
            color: call.getString("color") ?? "", colors: (call.getArray("colors") as? [String]) ?? [])
        let content = ActivityContent(state: state, staleDate: nil)
        if let a = activity ?? Activity<ShootActivityAttributes>.activities.first {
            activity = a
            Task { await a.update(content) }
            call.resolve(["enabled": true])
        } else {
            do {
                activity = try Activity.request(attributes: ShootActivityAttributes(shoot: call.getString("shoot") ?? ""), content: content, pushType: nil)
                call.resolve(["enabled": true])
            } catch { call.resolve(["enabled": false, "error": "\(error)"]) }
        }
    }

    @objc func end(_ call: CAPPluginCall) {
        Task {
            for a in Activity<ShootActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            nowTimer?.invalidate(); nowTimer = nil
            call.resolve()
        }
    }
}

/// Lets the web layer hand the list of bands to the share extension (via the App Group).
@objc(ShareBridgePlugin)
public class ShareBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ShareBridgePlugin"
    public let jsName = "ShareBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setArtists", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "drain", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "discard", returnType: CAPPluginReturnPromise),
    ]
    /// Move files the share extension left in the App Group folder into Documents/Inbox. Reports whether the shared folder is reachable at all.
    @objc func drain(_ call: CAPPluginCall) {
        let fm = FileManager.default
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.art.gavingeddes.producrr"),
              let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { call.resolve(["groupOk": false, "moved": 0]); return }
        let from = group.appendingPathComponent("Inbox", isDirectory: true)
        let to = docs.appendingPathComponent("Inbox", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
        let ud = UserDefaults(suiteName: "group.art.gavingeddes.producrr")
        let log = ud?.string(forKey: "shareLog") ?? ""
        if !log.isEmpty { ud?.removeObject(forKey: "shareLog") }
        var list: [[String: String]] = []
        for f in files where !f.lastPathComponent.hasSuffix(".meta.json") {
            let metaURL = URL(fileURLWithPath: f.path + ".meta.json")
            let meta = (try? String(contentsOf: metaURL, encoding: .utf8)) ?? ""
            list.append(["name": f.lastPathComponent, "path": f.absoluteString, "meta": meta])
        }
        call.resolve(["groupOk": true, "files": list, "found": list.count, "log": log])
    }
    /// Delete shared files (and their .meta.json) once the web side has stored them.
    @objc func discard(_ call: CAPPluginCall) {
        let fm = FileManager.default
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.art.gavingeddes.producrr") else { call.resolve(); return }
        let dir = group.appendingPathComponent("Inbox", isDirectory: true)
        for n in call.getArray("names", String.self) ?? [] {
            let f = dir.appendingPathComponent(n)
            try? fm.removeItem(at: f)
            try? fm.removeItem(atPath: f.path + ".meta.json")
        }
        call.resolve()
    }
    @objc func setArtists(_ call: CAPPluginCall) {
        UserDefaults(suiteName: "group.art.gavingeddes.producrr")?.set(call.getString("json") ?? "[]", forKey: "artists")
        call.resolve()
    }
}

/// Plays the shoot track natively (AVAudioEngine) so iOS never sees the web view as a media player:
/// no duplicate lock-screen "Now Playing" card, and it keeps playing with the silent switch on or the phone locked.
/// The web side still decodes the file for the waveform and tempo; this only plays it, with the count-in and click.
public class NativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativeAudioPlugin"
    public let jsName = "NativeAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openTrack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "check", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "write", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tempo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
    ]
    private let q = DispatchQueue(label: "creatrr.nativeaudio")
    private let engine = AVAudioEngine()
    private let song = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let lpf = AVAudioUnitEQ(numberOfBands: 1)
    private let clicker = AVAudioPlayerNode()
    private var attached = false
    private var file: AVAudioFile?
    private var gen = 0
    private var playing = false
    private var songAtHost = 0.0          // host seconds when the song is heard
    private var fromT = 0.0, rate = 1.0, dur = 0.0
    private var clickSR = 44100.0
    private var countClicks: [(t: Double, accent: Bool)] = []
    private var tClick = false, tGame = false, tDown = false, tBpm = 0.0, tOffset = -1e9
    private var nextK = 0
    private var pump: DispatchSourceTimer?
    private var posTimer: DispatchSourceTimer?
    private var bufCache: [String: AVAudioPCMBuffer] = [:]

    override public func load() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: v) == .began else { return }
            self.q.async { if self.playing { self.stopInternal(); self.notifyListeners("interrupted", data: [:]) } }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.q.async { if self.playing { self.stopInternal(); self.notifyListeners("interrupted", data: [:]) } }
        }
    }

    private func dir() -> URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func safe(_ n: String) -> String {
        var out = ""
        for u in n.unicodeScalars {
            let ok: Bool = CharacterSet.alphanumerics.contains(u) || u == "." || u == "-" || u == "_"
            out.append(ok ? Character(u) : Character("_"))
        }
        return out
    }
    private func nowHost() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    /// Open a previously written track. `ok` is false when the file isn't there (or is the wrong size) so the web side writes it first.
    @objc func openTrack(_ call: CAPPluginCall) {
        q.async {
            guard let name = call.getString("name") else { call.reject("no name"); return }
            let url = self.dir().appendingPathComponent(self.safe(name))
            let want = call.getInt("size") ?? -1
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let have = (attrs?[.size] as? NSNumber)?.intValue
            guard let h = have, want < 0 || h == want, let f = try? AVAudioFile(forReading: url) else { call.resolve(["ok": false]); return }
            self.file = f
            self.dur = Double(f.length) / f.processingFormat.sampleRate
            // tidy: drop copies not used for two weeks (every song of a shoot stays while the shoot is in use)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let all: [URL] = (try? FileManager.default.contentsOfDirectory(at: self.dir(), includingPropertiesForKeys: keys)) ?? []
            let cutoff: Date = Date().addingTimeInterval(-14 * 24 * 3600)
            for u in all {
                let d: Date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if d < cutoff { try? FileManager.default.removeItem(at: u) }
            }
            call.resolve(["ok": true, "duration": self.dur])
        }
    }
    /// Is this track already copied (right size)? Doesn't open it, so it's safe while something is playing.
    @objc func check(_ call: CAPPluginCall) {
        q.async {
            guard let name = call.getString("name") else { call.reject("no name"); return }
            let url = self.dir().appendingPathComponent(self.safe(name))
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let have: Int? = (attrs?[.size] as? NSNumber)?.intValue
            let want: Int = call.getInt("size") ?? -1
            let ok: Bool = have != nil && (want < 0 || have == want)
            if ok { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
            call.resolve(["ok": ok])
        }
    }
    @objc func write(_ call: CAPPluginCall) {
        q.async {
            guard let name = call.getString("name"), let b64 = call.getString("data"), let data = Data(base64Encoded: b64) else { call.reject("bad data"); return }
            let url = self.dir().appendingPathComponent(self.safe(name))
            do {
                if (call.getBool("append") ?? false), let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                } else { try data.write(to: url) }
                call.resolve()
            } catch { call.reject("write failed: \(error.localizedDescription)") }
        }
    }

    private func clickBuffer(_ accent: Bool, _ vol: Double) -> AVAudioPCMBuffer {
        let key = "\(accent ? 1 : 0)-\(Int(vol * 100))-\(Int(clickSR))"
        if let b = bufCache[key] { return b }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: clickSR, channels: 1)!
        let n = AVAudioFrameCount(0.07 * clickSR)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        let base: Double = accent ? 0.55 : 0.32
        let amp: Double = base * vol
        let f: Double = accent ? 1600.0 : 1050.0
        let p = b.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / clickSR
            var env: Double = amp * (t / 0.004)
            if t >= 0.004 {
                let k: Double = min(1.0, (t - 0.004) / 0.056)
                env = amp * pow(0.0001 / amp, k)
            }
            let sq: Double = sin(2.0 * Double.pi * f * t) >= 0 ? 1.0 : -1.0
            p[i] = Float(env * sq)
        }
        bufCache[key] = b
        return b
    }
    private func clickAt(_ host: Double, _ accent: Bool, _ vol: Double) {
        if host < nowHost() { return }
        clicker.scheduleBuffer(clickBuffer(accent, vol), at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host)), options: [], completionHandler: nil)
    }
    private func songNow() -> Double { fromT + (nowHost() - songAtHost) * rate }

    /// (Re)schedule the clicks that follow the song's beat grid; used at play and whenever the tempo changes.
    private func resetClicks() {
        clicker.stop()
        clicker.play()
        let now = nowHost()
        for c in countClicks where c.t > now + 0.005 { clickAt(c.t, c.accent, 1) }
        guard (tClick || tGame), tBpm > 0, tOffset > -1e8 else { pump?.cancel(); pump = nil; return }
        let beat: Double = 60.0 / tBpm
        let startT: Double = max(songNow() + 0.02, fromT)
        nextK = Int(ceil((startT - tOffset) / beat - 1e-6))
        if pump == nil {
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: 0.25)
            t.setEventHandler { [weak self] in self?.pumpClicks() }
            t.resume(); pump = t
        }
        pumpClicks()
    }
    private func pumpClicks() {
        guard playing, (tClick || tGame), tBpm > 0, tOffset > -1e8 else { return }
        let beat: Double = 60.0 / tBpm
        let ahead: Double = tGame ? 0.7 : 2.5
        let horizon: Double = nowHost() + ahead
        while true {
            let songT: Double = tOffset + Double(nextK) * beat
            let when: Double = songAtHost + (songT - fromT) / rate
            if when > horizon || songT > dur { break }
            if songT >= fromT - 1e-6 && songT >= 0 {
                let down: Bool = ((nextK % 4) + 4) % 4 == 0
                if tGame { clickAt(when, tDown && down, 0.9) } else { clickAt(when, down, 0.55) }
            }
            nextK += 1
        }
    }
    private func applyTempo(_ call: CAPPluginCall) {
        tClick = call.getBool("click") ?? false
        tGame = call.getBool("game") ?? false
        tDown = call.getBool("downbeat") ?? false
        tBpm = call.getDouble("bpm") ?? 0
        tOffset = call.getDouble("offset") ?? -1e9
        song.volume = (call.getBool("duck") ?? false) ? 0.7 : 1.0   // while tapping the tempo the song is 30% quieter so the click cuts through
    }

    @objc func tempo(_ call: CAPPluginCall) {
        q.async {
            self.applyTempo(call)
            if self.playing { self.resetClicks() }
            call.resolve()
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        q.async { self.doPlay(call) }
    }

    private func buildGraph(_ f: AVAudioFile) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try s.setActive(true)
        if !attached {
            engine.attach(song)
            engine.attach(pitch)
            engine.attach(lpf)
            engine.attach(clicker)
            attached = true
        }
        let fmt: AVAudioFormat = f.processingFormat
        engine.connect(song, to: pitch, format: fmt)
        engine.connect(pitch, to: lpf, format: fmt)
        engine.connect(lpf, to: engine.mainMixerNode, format: fmt)
        var sr: Double = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sr < 8000 { sr = 44100 }
        clickSR = sr
        let cf: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        engine.connect(clicker, to: engine.mainMixerNode, format: cf)
        pitch.rate = Float(rate)
        pitch.pitch = 0
        let band: AVAudioUnitEQFilterParameters = lpf.bands[0]
        band.filterType = .lowPass
        band.frequency = 650
        band.bandwidth = 1.0
        band.bypass = true
        engine.prepare()
        try engine.start()
    }

    private func doPlay(_ call: CAPPluginCall) {
        guard let f = file else { call.reject("no track loaded"); return }
        stopInternal()
        gen += 1
        let my: Int = gen
        let reqFrom: Double = call.getDouble("from") ?? 0
        let reqRate: Double = call.getDouble("rate") ?? 1
        fromT = max(0.0, min(dur, reqFrom))
        rate = max(0.25, min(4.0, reqRate))
        applyTempo(call)
        let beats: Int = call.getInt("countInBeats") ?? 0
        let countBpm: Double = max(30.0, call.getDouble("countBpm") ?? 120.0)
        do { try buildGraph(f) } catch { call.reject("audio engine: \(error.localizedDescription)"); return }

        let now: Double = nowHost()
        let t0: Double = now + 0.15
        let beat: Double = 60.0 / (countBpm * rate)
        songAtHost = t0 + Double(beats) * beat
        var cc: [(t: Double, accent: Bool)] = []
        for i in 0..<beats { cc.append((t: t0 + Double(i) * beat, accent: i % 4 == 0)) }
        countClicks = cc

        let sr: Double = f.processingFormat.sampleRate
        let start: AVAudioFramePosition = AVAudioFramePosition(fromT * sr)
        let remaining: AVAudioFramePosition = max(1, f.length - start)
        let frames: AVAudioFrameCount = AVAudioFrameCount(remaining)
        // The time-stretch unit pulls its input `rate` times faster than real time, so a player timeline "start at host time X" drifts
        // (late when slowed, early when sped up). Instead start the player now and queue silence for the count-in, measured in song time.
        let lead: Double = max(0.0, pitch.latency)
        let playAt: Double = nowHost() + 0.01
        let silenceSec: Double = max(0.0, songAtHost - playAt - lead) * rate
        let silenceFrames: AVAudioFrameCount = AVAudioFrameCount(silenceSec * sr)
        if silenceFrames > 0 {
            let fmt: AVAudioFormat = f.processingFormat
            if let sb = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: silenceFrames) {
                sb.frameLength = silenceFrames
                if let ch = sb.floatChannelData {
                    for c in 0..<Int(fmt.channelCount) { memset(ch[c], 0, Int(silenceFrames) * MemoryLayout<Float>.size) }
                }
                song.scheduleBuffer(sb, completionHandler: nil)
            }
        }
        song.scheduleSegment(f, startingFrame: start, frameCount: frames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.songFinished(my)
        }
        song.play()
        playing = true
        resetClicks()
        startPosTimer()
        let outLat: Double = AVAudioSession.sharedInstance().outputLatency
        call.resolve(["songStartIn": songAtHost - now, "latency": outLat, "enginePitchLatency": lead])
    }

    private func songFinished(_ my: Int) {
        q.async {
            guard self.gen == my, self.playing else { return }
            self.stopInternal()
            self.notifyListeners("ended", data: [:])
        }
    }

    private func startPosTimer() {
        let pt = DispatchSource.makeTimerSource(queue: q)
        pt.schedule(deadline: .now() + 0.5, repeating: 0.5)
        pt.setEventHandler { [weak self] in
            guard let self = self, self.playing else { return }
            if self.nowHost() < self.songAtHost { return }
            let data: [String: Any] = ["t": self.songNow(), "rate": self.rate]
            self.notifyListeners("pos", data: data)
        }
        pt.resume()
        posTimer = pt
    }

    private func stopInternal() {
        playing = false
        pump?.cancel(); pump = nil
        posTimer?.cancel(); posTimer = nil
        if attached { song.stop(); clicker.stop() }
        if engine.isRunning { engine.stop() }
    }
    @objc func stop(_ call: CAPPluginCall) {
        q.async {
            self.gen += 1
            self.stopInternal()
            call.resolve()
        }
    }
}

class ViewController: CAPBridgeViewController {
    // Make sure the push and app plugins are registered even if automatic discovery missed them
    override func capacitorDidLoad() {
        if #available(iOS 16.2, *) { if bridge?.plugin(withName: "ShootActivity") == nil { bridge?.registerPluginInstance(ShootActivityPlugin()) } }
        if bridge?.plugin(withName: "ShareBridge") == nil { bridge?.registerPluginInstance(ShareBridgePlugin()) }
        if bridge?.plugin(withName: "NativeAudio") == nil { bridge?.registerPluginInstance(NativeAudioPlugin()) }
        let wanted: [(js: String, cls: String)] = [("PushNotifications", "PushNotificationsPlugin"), ("App", "AppPlugin")]
        for w in wanted where bridge?.plugin(withName: w.js) == nil {
            if let t = NSClassFromString(w.cls) as? CAPPlugin.Type { bridge?.registerPluginInstance(t.init()) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView?.scrollView.bounces = true
        webView?.scrollView.alwaysBounceVertical = true
        let bg = UIColor { t in t.userInterfaceStyle == .dark
            ? UIColor(red: 0x12/255.0, green: 0x12/255.0, blue: 0x12/255.0, alpha: 1)
            : UIColor(red: 0xF5/255.0, green: 0xF3/255.0, blue: 0xEF/255.0, alpha: 1) }
        view.backgroundColor = bg
        webView?.isOpaque = false
        webView?.backgroundColor = bg
        webView?.scrollView.backgroundColor = bg
    }
}
