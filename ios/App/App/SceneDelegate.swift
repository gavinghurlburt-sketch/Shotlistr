import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    // Files shared to creatrr (from the Share Extension) arrive in the App Group folder.
    // Move them into the app's own Documents/Inbox so the web layer can read them.
    func sceneDidBecomeActive(_ scene: UIScene) {
        let fm = FileManager.default
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.art.gavingeddes.producrr"),
              let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let from = group.appendingPathComponent("Inbox", isDirectory: true)
        let to = docs.appendingPathComponent("Inbox", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil), !files.isEmpty else { return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for f in files {
            var dest = to.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { dest = to.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(f.lastPathComponent)") }
            try? fm.moveItem(at: f, to: dest)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
