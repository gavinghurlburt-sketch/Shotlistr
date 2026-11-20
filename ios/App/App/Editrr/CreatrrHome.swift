import UIKit
import SwiftUI
import WebKit
import AVFoundation
import Capacitor

/// creatrr on iPhone: the web app (Projects, Artists) with editrr (Edits) beside it.
/// On Edits home, creatrr's own header and tabs stay at the top (the web app keeps drawing them) and
/// editrr's home slides in underneath, like a third tab. Opening an edit takes the whole screen.
/// Tap Edits, or swipe in from the right edge (anywhere on creatrr Artist, from the Artists tab on
/// Plus and Pro), to open it. Tap Projects or Artists, or swipe in from the left edge, to go back.
final class CreatrrHome: UIViewController, UIGestureRecognizerDelegate {
    static let tierKey = "creatrr.tier"
    static weak var current: CreatrrHome?

    /// The web app (header, tabs, artist pages, songs, parts).
    let artist = ViewController()
    /// editrr, made the first time you open it and kept so it remembers where you were.
    private var editor: UIViewController?
    private(set) var showingEditor = false
    private var artistTier = UserDefaults.standard.string(forKey: CreatrrHome.tierKey) == "artist"
    private var panning = false
    /// 0: editrr is off to the right. 1: editrr is in place.
    private var reveal: CGFloat = 0
    private let messages = WebMessages()
    /// Where the web app is: "projects" or "artists" on home, "away" inside a project or artist page.
    private var webHome = "away"
    /// The bottom of creatrr's header and tabs (with the page scrolled to the top). editrr's home starts here.
    private var headerBottom: CGFloat = 170
    /// What editrr's back button says.
    let nav = CreatrrNav()
    /// editrr opened from inside a page (a song's sections, a project), where creatrr's tabs aren't
    /// on screen: it takes the whole screen and shows its own Back.
    private var bare = false

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
        addChild(artist)
        view.addSubview(artist.view)
        artist.didMove(toParent: self)
        // The web app tells us its plan, where you are, and when you tap Edits.
        messages.home = self
        let content = artist.webView?.configuration.userContentController
        content?.add(messages, name: "creatrrTier")
        content?.add(messages, name: "creatrrEditrr")
        content?.add(messages, name: "creatrrHome")
        content?.add(messages, name: "creatrrShoot")
        content?.add(messages, name: "creatrrLyrics")
        nav.backTitle = artistTier ? "Projects" : "Artists"
        view.addGestureRecognizer(toEditor)
        view.addGestureRecognizer(toArtist)
        NotificationCenter.default.addObserver(self, selector: #selector(stageChanged), name: .editrrStage, object: nil)
        refreshSwipes()
    }

    /// Only the swipe that can go somewhere is on, so taps near the screen edges are never held up.
    private func refreshSwipes() {
        toEditor.isEnabled = canSwipeToEditor
        toArtist.isEnabled = showingEditor
    }

    /// From the home tab just before Edits: Projects on creatrr Artist (Songs, Projects, Edits),
    /// Artists on Plus and Pro (Projects, Artists, Edits). Inside a project the edges belong to
    /// Draft, Plan, Shoot and Cut.
    private var canSwipeToEditor: Bool {
        !showingEditor && webHome == (artistTier ? "projects" : "artists")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        artist.view.frame = view.bounds
        if !panning { reveal = showingEditor ? 1 : 0 }
        layoutEditor()
    }

    /// editrr's home sits under creatrr's header and tabs; the editor itself takes the whole screen.
    private func layoutEditor() {
        guard let editor else { return }
        let size = view.bounds.size
        let top = EditrrStage.editing || bare ? 0 : min(max(0, headerBottom), size.height * 0.5)
        editor.view.frame = CGRect(x: (1 - reveal) * size.width, y: top, width: size.width, height: size.height - top)
    }

    // MARK: What the web app tells us

    func setTier(_ tier: String) {
        UserDefaults.standard.set(tier, forKey: Self.tierKey)
        artistTier = tier == "artist"
        nav.backTitle = artistTier ? "Projects" : "Artists"
        refreshSwipes()
    }

    func setWebHome(_ place: String, headerBottom bottom: CGFloat?) {
        webHome = place
        if let bottom, bottom > 0, bottom != headerBottom {
            headerBottom = bottom
            if !panning { layoutEditor() }
        }
        refreshSwipes()
    }

    /// Edits was tapped (or swiped to) in the web app.
    func openFromWeb() {
        guard !panning else { return }   // a swipe in from the edge is already opening it
        show(editor: true)
    }

    /// A section's red record button: editrr opens and films takes to that part of the song.
    func shootFromWeb(key: String, time: Double?, end: Double?, name: String?) {
        guard !panning, !key.isEmpty else { return }
        EditrrShoot.pending = EditrrShoot.Request(key: key, time: time, end: end, name: name)
        if showingEditor {
            EditrrShare.run(webView, now: true)
        } else {
            show(editor: true)
        }
    }

    /// A song's Lyrics button: the song's lyrics page opens over everything, to time the words to
    /// the whole song. Every edit that uses the song then gets them.
    func lyricsFromWeb(key: String, name: String) {
        guard !key.isEmpty, presentedViewController == nil, !panning else { return }
        pauseArtistSong()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        // The song (and its audio) goes to the shared folder first; the page waits for it.
        EditrrShare.run(webView, now: true)
        _ = FontLibrary.shared
        let model = SongLyricsModel(key: key, name: name)
        model.saved = { [weak self] count in self?.tellLyrics(key: key, count: count) }
        let page = SongLyricsView(model: model, done: { [weak self] in self?.dismiss(animated: true) })
        let host = UIHostingController(rootView: page)
        host.overrideUserInterfaceStyle = .dark
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
        present(host, animated: true)
    }

    /// Tells the song's page how many timed words the song has (0: none yet).
    func tellLyrics(key: String, count: Int) {
        guard let data = try? JSONEncoder().encode(key), let quoted = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("try { window.creatrrSongLyrics && window.creatrrSongLyrics(\(quoted), \(count)); } catch (e) {}")
    }

    /// Projects, Artists, the bell or your account was tapped in the header while Edits was open.
    func closeFromWeb() {
        guard !panning else { return }
        show(editor: false)
    }

    // MARK: Moving between them

    private func place(_ progress: CGFloat) {
        reveal = max(0, min(1, progress))
        layoutEditor()
    }

    private func prepareEditor() {
        if !showingEditor {
            // Opening from inside a page: no tabs above, so editrr fills the screen with its own Back.
            bare = webHome == "away"
            nav.bare = bare
        }
        if editor == nil {
            _ = FontLibrary.shared   // your lyric fonts, ready before a project draws its words
            let host = UIHostingController(rootView: EditrrRoot(nav: nav, back: { [weak self] in self?.show(editor: false) }))
            host.overrideUserInterfaceStyle = .dark
            host.view.backgroundColor = UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            editor = host
            layoutEditor()
        }
        editor?.view.isHidden = false
        // The header only lines up with editrr's home when the page is at the top.
        if !bare, let scroll = webView?.scrollView {
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        }
    }

    func show(editor on: Bool, animated: Bool = true) {
        guard on != showingEditor || panning else { return }
        if on {
            prepareEditor()
            pauseArtistSong()
        } else {
            NotificationCenter.default.post(name: .editrrPause, object: nil)
        }
        tellWeb(editsShown: on)
        // While Edits shows, the header stays put (no scrolling the page behind it).
        if on { webView?.scrollView.isScrollEnabled = false }
        let done = { [weak self] in
            guard let self else { return }
            self.showingEditor = on
            self.panning = false
            self.place(on ? 1 : 0)
            self.editor?.view.isHidden = !on
            self.webView?.scrollView.isScrollEnabled = !on
            self.refreshSwipes()
            if on { self.enteredEditor() }
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        guard animated else { done(); return }
        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.place(on ? 1 : 0)
        } completion: { _ in done() }
    }

    /// The Edits tab lights up while editrr shows.
    private func tellWeb(editsShown: Bool) {
        webView?.evaluateJavaScript("try { window.creatrrEditsShown && window.creatrrEditsShown(\(editsShown)); } catch (e) {}")
    }

    @objc private func stageChanged() {
        // Opening an edit: editrr grows over the header to the whole screen. Back on its home: the header returns.
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.layoutEditor()
            self.editor?.view.layoutIfNeeded()
        }
        refreshSwipes()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
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
                    self.webView?.scrollView.isScrollEnabled = !self.showingEditor
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
        if g === toEditor { return canSwipeToEditor }
        if g === toArtist { return showingEditor && !EditrrStage.editing }
        return true
    }

    /// The edge swipes win over scrolling that starts at the very edge.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === toEditor || g === toArtist
    }

    // MARK: Status bar, rotation

    /// The status bar sits over creatrr's header unless editrr has the whole screen.
    private var statusOwner: UIViewController? { showingEditor && (EditrrStage.editing || bare) ? editor : artist }
    override var childForStatusBarStyle: UIViewController? { statusOwner }
    override var childForStatusBarHidden: UIViewController? { statusOwner }
    override var childForHomeIndicatorAutoHidden: UIViewController? { showingEditor ? editor : artist }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if showingEditor { return .portrait }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
}

/// What the web app sends: its plan, where you are, and taps on Edits.
private final class WebMessages: NSObject, WKScriptMessageHandler {
    weak var home: CreatrrHome?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit calls this on the main thread.
        MainActor.assumeIsolated {
            switch message.name {
            case "creatrrTier":
                if let tier = message.body as? String { home?.setTier(tier) }
            case "creatrrEditrr":
                if (message.body as? String) == "close" { home?.closeFromWeb() } else { home?.openFromWeb() }
            case "creatrrShoot":
                if let info = message.body as? [String: Any], let key = info["key"] as? String {
                    home?.shootFromWeb(key: key, time: (info["time"] as? NSNumber).map { $0.doubleValue },
                                       end: (info["end"] as? NSNumber).map { $0.doubleValue },
                                       name: info["name"] as? String)
                }
            case "creatrrLyrics":
                if let info = message.body as? [String: Any], let key = info["key"] as? String {
                    if (info["ask"] as? Bool) == true {
                        home?.tellLyrics(key: key, count: SongLyricsStore.load(key)?.words.count ?? 0)
                    } else {
                        home?.lyricsFromWeb(key: key, name: info["name"] as? String ?? "Song")
                    }
                }
            case "creatrrHome":
                if let info = message.body as? [String: Any], let place = info["place"] as? String {
                    let bottom = (info["top"] as? NSNumber).map { CGFloat(truncating: $0) }
                    home?.setWebHome(place, headerBottom: bottom)
                } else if let place = message.body as? String {
                    home?.setWebHome(place, headerBottom: nil)
                }
            default:
                break
            }
        }
    }
}
