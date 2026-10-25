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
        if !files.isEmpty { try? fm.createDirectory(at: to, withIntermediateDirectories: true) }
        var moved = 0, firstErr = ""
        for f in files {
            if !fm.fileExists(atPath: f.path) { continue }
            var dest = to.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { dest = to.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(f.lastPathComponent)") }
            do { try fm.copyItem(at: f, to: dest); try? fm.removeItem(at: f); moved += 1 }
            catch { if firstErr.isEmpty { firstErr = error.localizedDescription } }
        }
        // older leftovers with spaces/symbols in the name: make them readable (audio + its .meta.json get the same new name pattern)
        func safeName(_ n: String) -> String { String(n.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") ? $0 : "_" }) }
        for f in (try? fm.contentsOfDirectory(at: to, includingPropertiesForKeys: nil)) ?? [] {
            let n = f.lastPathComponent, s = safeName(n)
            if s != n, !fm.fileExists(atPath: to.appendingPathComponent(s).path) { try? fm.moveItem(at: f, to: to.appendingPathComponent(s)) }
        }
        let waiting = ((try? fm.contentsOfDirectory(atPath: to.path)) ?? []).filter { !$0.hasSuffix(".meta.json") }.count
        call.resolve(["groupOk": true, "moved": moved, "found": waiting, "log": log, "err": firstErr])
    }
    @objc func setArtists(_ call: CAPPluginCall) {
        UserDefaults(suiteName: "group.art.gavingeddes.producrr")?.set(call.getString("json") ?? "[]", forKey: "artists")
        call.resolve()
    }
}

class ViewController: CAPBridgeViewController {
    // Make sure the push and app plugins are registered even if automatic discovery missed them
    override func capacitorDidLoad() {
        if #available(iOS 16.2, *) { if bridge?.plugin(withName: "ShootActivity") == nil { bridge?.registerPluginInstance(ShootActivityPlugin()) } }
        if bridge?.plugin(withName: "ShareBridge") == nil { bridge?.registerPluginInstance(ShareBridgePlugin()) }
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
