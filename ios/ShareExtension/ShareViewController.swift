import UIKit
import UniformTypeIdentifiers

/// Share sheet for audio files (Messages, Files, Voice Memos, Mail). Shows a small card:
/// pick the band, check the song name, tap Add. The files go into the shared App Group folder
/// with a small .meta.json next to each; creatrr files them into the right band when it opens.
class ShareViewController: UIViewController {
    private let groupId = "group.art.gavingeddes.producrr"
    private struct Artist { let id: String; let name: String }
    private struct Pending { let url: URL; let original: String; let field: UITextField }

    private var artists: [Artist] = []
    private var chosen: Artist?
    private var pending: [Pending] = []
    private let bandButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let stack = UIStackView()
    private let status = UILabel()
    private var staging: URL!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        loadArtists()
        buildUI()
        stage()
    }

    // MARK: data
    private func loadArtists() {
        let d = UserDefaults(suiteName: groupId)
        if let s = d?.string(forKey: "artists"), let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            artists = arr.compactMap { a in
                guard let id = a["id"] as? String, let n = a["name"] as? String, !n.isEmpty else { return nil }
                return Artist(id: id, name: n)
            }
        }
        let last = d?.string(forKey: "lastArtist")
        chosen = artists.first(where: { $0.id == last }) ?? artists.first
    }

    // MARK: UI
    private func buildUI() {
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        let title = UILabel(); title.text = "Add to creatrr"; title.font = .systemFont(ofSize: 17, weight: .semibold)
        addButton.setTitle("Add", for: .normal)
        addButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        addButton.isEnabled = false
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [cancel, UIView(), title, UIView(), addButton])
        header.distribution = .equalCentering

        let bandLabel = UILabel(); bandLabel.text = "BAND"; bandLabel.font = .systemFont(ofSize: 12, weight: .semibold); bandLabel.textColor = .secondaryLabel
        bandButton.contentHorizontalAlignment = .leading
        bandButton.titleLabel?.font = .systemFont(ofSize: 17)
        bandButton.backgroundColor = .secondarySystemBackground
        bandButton.layer.cornerRadius = 10
        bandButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        bandButton.showsMenuAsPrimaryAction = true
        refreshBandMenu()

        status.font = .systemFont(ofSize: 14); status.textColor = .secondaryLabel; status.numberOfLines = 0

        stack.axis = .vertical; stack.spacing = 8
        let body = UIStackView(arrangedSubviews: [bandLabel, bandButton, stack, status])
        body.axis = .vertical; body.spacing = 8
        body.setCustomSpacing(18, after: bandButton)
        body.setCustomSpacing(14, after: stack)

        for v in [header, body] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
        ])
        if artists.isEmpty { status.text = "Open creatrr once so it can list your bands here." }
    }

    private func refreshBandMenu() {
        bandButton.setTitle((chosen?.name ?? (artists.isEmpty ? "No bands yet (pick later in creatrr)" : "Choose a band")) + "   \u{25BE}", for: .normal)
        let actions = artists.map { a in
            UIAction(title: a.name, state: a.id == chosen?.id ? .on : .off) { [weak self] _ in
                self?.chosen = a; self?.refreshBandMenu()
            }
        }
        bandButton.menu = UIMenu(children: actions)
        bandButton.isEnabled = !artists.isEmpty
    }

    // MARK: receiving files
    private func stage() {
        staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup(), lock = NSLock()
        var found: [(URL, String)] = []
        for p in providers {
            let type: String
            if p.hasItemConformingToTypeIdentifier(UTType.audio.identifier) { type = UTType.audio.identifier }
            else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { type = UTType.fileURL.identifier }
            else if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) { type = UTType.data.identifier }
            else { continue }
            group.enter()
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                let ext = url.pathExtension.lowercased()
                guard ["mp3", "m4a", "wav", "aac", "aif", "aiff", "flac", "ogg", "caf", "mp4"].contains(ext) else { return }
                let dest = self.staging.appendingPathComponent(String(UUID().uuidString.prefix(6)) + "-" + url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    lock.lock(); found.append((dest, url.lastPathComponent)); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            if found.isEmpty { self.status.text = "That doesn't look like an audio file. creatrr takes MP3, M4A, WAV and similar."; return }
            for (url, original) in found.prefix(10) {
                let f = UITextField()
                f.text = Self.songName(from: original)
                f.placeholder = "Song name"
                f.borderStyle = .roundedRect
                f.font = .systemFont(ofSize: 17)
                f.clearButtonMode = .whileEditing
                f.autocapitalizationType = .words
                let cap = UILabel(); cap.text = original; cap.font = .systemFont(ofSize: 12); cap.textColor = .secondaryLabel; cap.lineBreakMode = .byTruncatingMiddle
                let lbl = UILabel(); lbl.text = found.count > 1 ? "SONG NAME" : "SONG NAME (CHECK THIS)"; lbl.font = .systemFont(ofSize: 12, weight: .semibold); lbl.textColor = .secondaryLabel
                self.stack.addArrangedSubview(lbl); self.stack.addArrangedSubview(f); self.stack.addArrangedSubview(cap)
                self.pending.append(Pending(url: url, original: original, field: f))
            }
            self.addButton.isEnabled = true
            self.pending.first?.field.becomeFirstResponder()
        }
    }

    // MARK: actions
    @objc private func cancelTapped() {
        try? FileManager.default.removeItem(at: staging)
        extensionContext?.cancelRequest(withError: NSError(domain: "creatrr", code: 0))
    }

    @objc private func addTapped() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            status.text = "creatrr isn't set up to receive files yet. Open creatrr once and try again."; return
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var saved = 0
        for p in pending {
            let name = p.original
            var dest = inbox.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) { dest = inbox.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(name)") }
            do {
                try FileManager.default.copyItem(at: p.url, to: dest)
                var meta: [String: Any] = ["songName": (p.field.text ?? "").trimmingCharacters(in: .whitespaces)]
                if let a = chosen { meta["artistId"] = a.id; meta["artistName"] = a.name }
                if let data = try? JSONSerialization.data(withJSONObject: meta) {
                    try? data.write(to: dest.appendingPathExtension("meta.json"))   // "<file>.meta.json"
                }
                saved += 1
            } catch {}
        }
        if let a = chosen { UserDefaults(suiteName: groupId)?.set(a.id, forKey: "lastArtist") }
        try? FileManager.default.removeItem(at: staging)
        view.endEditing(true)
        addButton.isEnabled = false
        status.text = saved > 0 ? "Added. It will be in \(chosen?.name ?? "your inbox") next time you open creatrr." : "Couldn't save that file."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil) }
    }

    // Same idea as the app: "Hotel_Lobby_MosesMaster_44.1_16.wav" -> "Hotel Lobby"
    static func songName(from file: String) -> String {
        var base = (file as NSString).deletingPathExtension
        base = base.replacingOccurrences(of: "\\(\\d+\\)$", with: "", options: .regularExpression)
        let noise = try! NSRegularExpression(pattern: "master|mstr|mix|final|demo|bounce|print|stems?|rough|\\bref\\b|^v\\d+$|^\\d+(\\.\\d+)?(k|khz|bit|b)?$|^(wav|mp3|flac|aiff|m4a|hq|lossless)$", options: .caseInsensitive)
        var toks = base.replacingOccurrences(of: "\\s*-\\s*", with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: "_ ")).filter { !$0.isEmpty }
        while toks.count > 1, toks[0].range(of: "^\\d{1,2}$", options: .regularExpression) != nil { toks.removeFirst() }
        var keep: [String] = []
        for t in toks {
            if !keep.isEmpty, noise.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { break }
            keep.append(t)
        }
        var name = keep.joined(separator: " ").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled song" : name
    }
}
