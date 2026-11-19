import UIKit
import Capacitor
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = CreatrrHome()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    // Files shared to creatrr (from the Share Extension) arrive in the App Group folder.
    // Move them into the app's own Documents/Inbox so the web layer can read them.
    func sceneDidBecomeActive(_ scene: UIScene) {
        shareSoon()
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

    private func shareSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            EditrrShare.run(CreatrrHome.current?.webView)
        }
    }

    // editrr (same team) records takes to creatrr's songs and parts: share them on the way out,
    // and again a moment after coming back.
    func sceneWillResignActive(_ scene: UIScene) {
        EditrrShare.run(CreatrrHome.current?.webView)
        // editrr inside creatrr: save your edit on the way out.
        NotificationCenter.default.post(name: .editrrSave, object: nil)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        EditrrShare.run(CreatrrHome.current?.webView)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

/// Shares creatrr's songs (with their parts and audio) with editrr through the App Group, so
/// editrr's Record can start a take right at a part. Only reads creatrr's data; never changes it.
/// Lives here (not in the web code) so it ships with a plain Xcode build.
enum EditrrShare {
    private static let groupId = "group.art.gavingeddes.producrr"
    private static var running = false
    private static var lastRun = Date.distantPast

    private struct Part: Codable { let name: String; let time: Double; let color: String }
    private struct Song: Codable {
        let key: String
        let name: String
        let project: String
        let parts: [Part]
        let size: Int
        let type: String
        let file: String
        let bpm: Double?
        let beat: Double?
        let countIn: Bool?
        let click: Bool?
    }
    /// What editrr reads: each song's audio file (inside the shared folder) and its parts.
    private struct Shared: Codable {
        let key: String
        let name: String
        let project: String
        let parts: [Part]
        let audio: String
        /// The song's tempo (for the count-in and click when filming), when creatrr knows it.
        let bpm: Double?
        let beat: Double?
        let countIn: Bool?
        let click: Bool?
    }

    /// Opens creatrr's database the same way the app does (so it's never created differently).
    private static let openDB = """
    const db = await new Promise((res, rej) => {
      const r = indexedDB.open("shotlist-app-db", 1);
      r.onupgradeneeded = () => { const d = r.result;
        if (!d.objectStoreNames.contains("projects")) d.createObjectStore("projects", { keyPath: "id" });
        if (!d.objectStoreNames.contains("tracks")) d.createObjectStore("tracks", { keyPath: "projectId" }); };
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    """

    private static let listJS = openDB + """
    const all = s => new Promise((res, rej) => { const q = db.transaction(s, "readonly").objectStore(s).getAll();
      q.onsuccess = () => res(q.result || []); q.onerror = () => rej(q.error); });
    const projects = await all("projects"), tracks = await all("tracks");
    db.close();
    const audio = {};
    for (const t of tracks) if (t && t.blob) audio[t.projectId] = { size: t.blob.size, type: t.blob.type || "", name: t.name || "" };
    const tc = s => { const m = String(s == null ? "" : s).match(/(\\d+):(\\d{1,2}(?:\\.\\d+)?)/); return m ? parseInt(m[1], 10) * 60 + parseFloat(m[2]) : null; };
    const songs = {};
    for (const p of projects) {
      if (!p || p.deletedAt || !Array.isArray(p.songs)) continue;
      const content = p.type === "content" || p.type === "artist";
      const owner = p.type === "content" && p.artistId ? p.artistId : p.id;
      for (const sg of p.songs) {
        if (!sg) continue;
        const key = content ? owner + "::" + sg.id : p.id, a = audio[key];
        if (!a) continue;
        const parts = (Array.isArray(p.sections) ? p.sections : []).filter(x => x && x.songId === sg.id)
          .map(x => ({ name: String(x.name || "Part"), time: tc(x.time), color: String(x.color || "") }))
          .filter(x => x.time != null).sort((x, y) => x.time - y.time);
        const prev = songs[key];
        if (prev && prev.parts.length >= parts.length) continue;
        const tp = (content ? sg.tempo : p.tempo) || {}, bpm = Number(tp.bpm), beat = Number(tp.offset);
        songs[key] = { key, name: String(sg.name || "Untitled song"), project: String(p.docTitle || p.artist || ""),
                       parts, size: a.size, type: a.type, file: a.name,
                       bpm: bpm > 0 ? bpm : null, beat: tp.offset != null && isFinite(beat) ? beat : null,
                       countIn: !!tp.countIn, click: !!tp.click };
      }
    }
    return JSON.stringify(Object.values(songs));
    """

    private static let audioJS = openDB + """
    const t = await new Promise((res, rej) => { const q = db.transaction("tracks", "readonly").objectStore("tracks").get(key);
      q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error); });
    db.close();
    if (!t || !t.blob) return "";
    return await new Promise((res, rej) => { const f = new FileReader();
      f.onload = () => res(String(f.result)); f.onerror = () => rej(f.error); f.readAsDataURL(t.blob); });
    """

    /// `now` skips the 15 second wait between runs (used when you open editrr).
    @MainActor
    static func run(_ webView: WKWebView?, now: Bool = false) {
        guard let webView, !running, now || Date().timeIntervalSince(lastRun) > 15 else { return }
        running = true
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "Share songs with editrr") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        Task { @MainActor in
            await share(webView)
            running = false
            lastRun = Date()
            if task != .invalid { app.endBackgroundTask(task) }
        }
    }

    @MainActor
    private static func share(_ webView: WKWebView) async {
        let fm = FileManager.default
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return }
        let folder = group.appendingPathComponent("editrr", isDirectory: true)
        let audioFolder = folder.appendingPathComponent("audio", isDirectory: true)
        try? fm.createDirectory(at: audioFolder, withIntermediateDirectories: true)

        guard let raw = try? await webView.callAsyncJavaScript(listJS, contentWorld: .page) as? String,
              let songs = try? JSONDecoder().decode([Song].self, from: Data(raw.utf8)) else { return }

        var shared: [Shared] = []
        var keep: Set<String> = []
        for song in songs {
            let name = fileName(song)
            let url = audioFolder.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            if size != song.size {
                guard let dataURL = try? await webView.callAsyncJavaScript(audioJS, arguments: ["key": song.key],
                                                                           contentWorld: .page) as? String,
                      let comma = dataURL.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { continue }
                try? data.write(to: url, options: .atomic)
            }
            guard fm.fileExists(atPath: url.path) else { continue }
            keep.insert(name)
            shared.append(Shared(key: song.key, name: song.name, project: song.project, parts: song.parts,
                                 audio: "audio/" + name, bpm: song.bpm, beat: song.beat,
                                 countIn: song.countIn, click: song.click))
        }
        // Songs that are gone from creatrr leave editrr too.
        for old in (try? fm.contentsOfDirectory(atPath: audioFolder.path)) ?? [] where !keep.contains(old) {
            try? fm.removeItem(at: audioFolder.appendingPathComponent(old))
        }
        if let json = try? JSONEncoder().encode(shared) {
            try? json.write(to: folder.appendingPathComponent("songs.json"), options: .atomic)
        }
    }

    /// A safe file name for a song's audio, keeping its kind (mp3, m4a, wav...).
    private static func fileName(_ song: Song) -> String {
        let safe = song.key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var ext = (song.file as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 {
            ext = song.type.contains("mp4") || song.type.contains("m4a") || song.type.contains("aac") ? "m4a"
                : song.type.contains("wav") ? "wav" : "mp3"
        }
        return String(safe) + "." + ext
    }
}
