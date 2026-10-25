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
    private func safe(_ n: String) -> String { String(n.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" ? Character($0) : "_" }) }
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
            // tidy: keep only this track
            let keep = url.lastPathComponent
            for u in (try? FileManager.default.contentsOfDirectory(at: self.dir(), includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent != keep { try? FileManager.default.removeItem(at: u) }
            call.resolve(["ok": true, "duration": self.dur])
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
        let amp = (accent ? 0.55 : 0.32) * vol, f = accent ? 1600.0 : 1050.0
        let p = b.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / clickSR
            let env = t < 0.004 ? amp * (t / 0.004) : amp * pow(0.0001 / amp, min(1, (t - 0.004) / 0.056))
            p[i] = Float(env * (sin(2 * Double.pi * f * t) >= 0 ? 1 : -1))
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
        let beat = 60 / tBpm
        nextK = Int(ceil((max(songNow() + 0.02, fromT) - tOffset) / beat - 1e-6))
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
        let beat = 60 / tBpm, horizon = nowHost() + (tGame ? 0.7 : 2.5)
        while true {
            let songT = tOffset + Double(nextK) * beat
            let when = songAtHost + (songT - fromT) / rate
            if when > horizon || songT > dur { break }
            if songT >= fromT - 1e-6 && songT >= 0 {
                let down = ((nextK % 4) + 4) % 4 == 0
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
        lpf.bypass = !(call.getBool("lowpass") ?? false)
    }

    @objc func tempo(_ call: CAPPluginCall) {
        q.async {
            self.applyTempo(call)
            if self.playing { self.resetClicks() }
            call.resolve()
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        q.async {
            guard let f = self.file else { call.reject("no track loaded"); return }
            self.stopInternal()
            self.gen += 1
            let my = self.gen
            self.fromT = max(0, min(self.dur, call.getDouble("from") ?? 0))
            self.rate = max(0.25, min(4, call.getDouble("rate") ?? 1))
            self.applyTempo(call)
            let beats = call.getInt("countInBeats") ?? 0
            let countBpm = max(30, call.getDouble("countBpm") ?? 120)
            do {
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try s.setActive(true)
                if !self.attached {
                    for n in [self.song, self.pitch, self.lpf, self.clicker] as [AVAudioNode] { self.engine.attach(n) }
                    self.attached = true
                }
                let fmt = f.processingFormat
                self.engine.connect(self.song, to: self.pitch, format: fmt)
                self.engine.connect(self.pitch, to: self.lpf, format: fmt)
                self.engine.connect(self.lpf, to: self.engine.mainMixerNode, format: fmt)
                self.clickSR = self.engine.outputNode.outputFormat(forBus: 0).sampleRate
                if self.clickSR < 8000 { self.clickSR = 44100 }
                self.engine.connect(self.clicker, to: self.engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: self.clickSR, channels: 1)!)
                self.pitch.rate = Float(self.rate)
                self.pitch.pitch = 0
                let b = self.lpf.bands[0]
                b.filterType = .lowPass; b.frequency = 650; b.bandwidth = 1.0; b.bypass = false
                self.engine.prepare()
                try self.engine.start()
            } catch { call.reject("audio engine: \(error.localizedDescription)"); return }

            let now = self.nowHost()
            let t0 = now + 0.15
            let beat = 60 / (countBpm * self.rate)
            self.songAtHost = t0 + Double(beats) * beat
            self.countClicks = (0..<beats).map { (t: t0 + Double($0) * beat, accent: $0 % 4 == 0) }
            let sr = f.processingFormat.sampleRate
            let start = AVAudioFramePosition(self.fromT * sr)
            let frames = AVAudioFrameCount(max(1, f.length - start))
            self.song.scheduleSegment(f, startingFrame: start, frameCount: frames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self = self else { return }
                self.q.async {
                    guard self.gen == my, self.playing else { return }
                    self.stopInternal()
                    self.notifyListeners("ended", data: [:])
                }
            }
            // the time-stretch unit delays the song slightly; start it that much early so the song and clicks line up
            let lead = max(0, self.pitch.latency)
            self.song.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: self.songAtHost - lead)))
            self.playing = true
            self.resetClicks()

            let pt = DispatchSource.makeTimerSource(queue: self.q)
            pt.schedule(deadline: .now() + 0.5, repeating: 0.5)
            pt.setEventHandler { [weak self] in
                guard let self = self, self.playing, self.nowHost() >= self.songAtHost else { return }
                self.notifyListeners("pos", data: ["t": self.songNow(), "rate": self.rate])
            }
            pt.resume(); self.posTimer = pt
            call.resolve(["songStartIn": self.songAtHost - now, "latency": AVAudioSession.sharedInstance().outputLatency, "enginePitchLatency": lead])
        }
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
