import UIKit
import SwiftUI
import WebKit
import AVFoundation
import Capacitor

/// creatrr on iPhone. With creatrr Artist it's two pages side by side: your artist page (the web
/// app) and editrr. Swipe in from the right edge (or tap Edit videos) to open editrr; swipe in from
/// the left edge on editrr's home (or tap Artist) to come back. Plus and Pro show just the web app
/// for now.
final class CreatrrHome: UIViewController, UIGestureRecognizerDelegate {
    static let tierKey = "creatrr.tier"
    static weak var current: CreatrrHome?

    /// The web app (artist page, songs, parts).
    let artist = ViewController()
    /// editrr, made the first time you open it and kept so it remembers where you were.
    private var editor: UIViewController?
    private(set) var showingEditor = false
    private var artistTier = UserDefaults.standard.string(forKey: CreatrrHome.tierKey) == "artist"
    /// Holds both pages side by side; sliding its bounds moves between them.
    private let track = UIView()
    private var panning = false
    private let messages = WebMessages()

    private lazy var toEditor: UIScreenEdgePanGestureRecognizer = {
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pan(_:)))
        g.edges = .right
        g.delegate = self
        return g
    }()
    private lazy var toArtist: UIScreenEdgePanGestureRecognizer = {
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pan(_:)))
        g.edges = .left
        g.delegate = self
        return g
    }()

    var webView: WKWebView? { artist.webView }

    override func viewDidLoad() {
        super.viewDidLoad()
        CreatrrHome.current = self
        view.backgroundColor = UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
        track.clipsToBounds = false
        view.addSubview(track)
        addChild(artist)
        track.addSubview(artist.view)
        artist.didMove(toParent: self)
        // The web app tells us its plan (Artist, Plus, Pro) and when you tap Edit videos.
        messages.home = self
        let content = artist.webView?.configuration.userContentController
        content?.add(messages, name: "creatrrTier")
        content?.add(messages, name: "creatrrEditrr")
        view.addGestureRecognizer(toEditor)
        view.addGestureRecognizer(toArtist)
        refreshSwipes()
    }

    /// Only the swipe that can go somewhere is on, so taps near the screen edges are never held up.
    private func refreshSwipes() {
        toEditor.isEnabled = artistTier && !showingEditor
        toArtist.isEnabled = showingEditor
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        track.center = CGPoint(x: size.width / 2, y: size.height / 2)
        let origin = panning ? track.bounds.origin.x : (showingEditor ? size.width : 0)
        track.bounds = CGRect(x: origin, y: 0, width: size.width, height: size.height)
        artist.view.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        editor?.view.frame = CGRect(x: size.width, y: 0, width: size.width, height: size.height)
    }

    // MARK: Plan

    func setTier(_ tier: String) {
        UserDefaults.standard.set(tier, forKey: Self.tierKey)
        artistTier = tier == "artist"
        if !artistTier && showingEditor { show(editor: false, animated: false) }
        refreshSwipes()
    }

    // MARK: Moving between the pages

    /// 0 shows the artist page, 1 shows editrr.
    private func place(_ progress: CGFloat) {
        track.bounds.origin.x = max(0, min(1, progress)) * view.bounds.width
    }

    private func prepareEditor() {
        if editor == nil {
            _ = FontLibrary.shared   // your lyric fonts, ready before a project draws its words
            let host = UIHostingController(rootView: EditrrRoot(back: { [weak self] in self?.show(editor: false) }))
            host.overrideUserInterfaceStyle = .dark
            host.view.backgroundColor = UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
            addChild(host)
            host.view.frame = CGRect(x: view.bounds.width, y: 0, width: view.bounds.width, height: view.bounds.height)
            track.addSubview(host.view)
            host.didMove(toParent: self)
            editor = host
        }
        editor?.view.isHidden = false
    }

    func show(editor on: Bool, animated: Bool = true) {
        guard on != showingEditor || panning else { return }
        if on {
            guard artistTier else { return }
            prepareEditor()
            pauseArtistSong()
        } else {
            NotificationCenter.default.post(name: .editrrPause, object: nil)
        }
        let done = { [weak self] in
            guard let self else { return }
            self.showingEditor = on
            self.panning = false
            self.place(on ? 1 : 0)
            self.editor?.view.isHidden = !on
            self.refreshSwipes()
            if on { self.enteredEditor() }
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        guard animated else { done(); return }
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.place(on ? 1 : 0)
        } completion: { _ in done() }
    }

    private func enteredEditor() {
        // editrr plays the song even with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Fresh songs and parts for Record.
        EditrrShare.run(webView, now: true)
    }

    /// A song playing on the artist page stops when you go to editrr.
    private func pauseArtistSong() {
        webView?.evaluateJavaScript("try { if (typeof isPlaying === 'function' && isPlaying()) stopAndReturn(); } catch (e) {}")
    }

    @objc private func pan(_ g: UIScreenEdgePanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        let opening = g === toEditor
        let dx = g.translation(in: view).x
        let progress = opening ? -dx / width : 1 - dx / width
        switch g.state {
        case .began:
            panning = true
            if opening { prepareEditor() }
        case .changed:
            place(progress)
        case .ended, .cancelled, .failed:
            let speed = g.velocity(in: view).x
            let go = g.state == .ended && (opening ? (progress > 0.3 || speed < -500) : (progress < 0.7 || speed > 500))
            let target = opening ? go : !go
            if target == showingEditor {
                // Not far enough: slide back to where it was.
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.place(self.showingEditor ? 1 : 0)
                } completion: { _ in
                    self.panning = false
                    self.editor?.view.isHidden = !self.showingEditor
                }
            } else {
                show(editor: target)
            }
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard presentedViewController == nil else { return false }
        if g === toEditor { return artistTier && !showingEditor }
        if g === toArtist { return showingEditor && !EditrrStage.editing }
        return true
    }

    /// The edge swipes win over scrolling that starts at the very edge.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === toEditor || g === toArtist
    }

    // MARK: Status bar, rotation

    override var childForStatusBarStyle: UIViewController? { showingEditor ? editor : artist }
    override var childForStatusBarHidden: UIViewController? { showingEditor ? editor : artist }
    override var childForHomeIndicatorAutoHidden: UIViewController? { showingEditor ? editor : artist }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if showingEditor { return .portrait }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
}

/// What the web app sends: its plan, and taps on Edit videos.
private final class WebMessages: NSObject, WKScriptMessageHandler {
    weak var home: CreatrrHome?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit calls this on the main thread.
        MainActor.assumeIsolated {
            switch message.name {
            case "creatrrTier":
                if let tier = message.body as? String { home?.setTier(tier) }
            case "creatrrEditrr":
                home?.show(editor: true)
            default:
                break
            }
        }
    }
}

/// editrr inside creatrr: dark, creatrr's yellow, with a way back to the artist page.
struct EditrrRoot: View {
    let back: () -> Void

    var body: some View {
        EditorView()
            .environment(\.creatrrBack, back)
            .environment(\.colorScheme, .dark)
            .tint(Tint.accent)
    }
}
