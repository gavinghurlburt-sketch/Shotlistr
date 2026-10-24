import UIKit
import Capacitor

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
        if !files.isEmpty { try? fm.createDirectory(at: to, withIntermediateDirectories: true) }
        var moved = 0
        for f in files {
            var dest = to.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { dest = to.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(f.lastPathComponent)") }
            if (try? fm.moveItem(at: f, to: dest)) != nil { moved += 1 }
        }
        call.resolve(["groupOk": true, "moved": moved])
    }
    @objc func setArtists(_ call: CAPPluginCall) {
        UserDefaults(suiteName: "group.art.gavingeddes.producrr")?.set(call.getString("json") ?? "[]", forKey: "artists")
        call.resolve()
    }
}

class ViewController: CAPBridgeViewController {
    // Make sure the push and app plugins are registered even if automatic discovery missed them
    override func capacitorDidLoad() {
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
