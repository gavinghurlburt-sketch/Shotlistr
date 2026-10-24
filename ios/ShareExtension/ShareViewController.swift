import UIKit
import UniformTypeIdentifiers

/// Receives audio files shared from Messages, Files, Voice Memos, Mail and so on,
/// copies them into the shared App Group folder, creatrr picks them up the next time it opens.
/// creatrr itself moves the files into its own storage the next time it becomes active.
class ShareViewController: UIViewController {
    private let groupId = "group.art.gavingeddes.producrr"
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Adding to creatrr…"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical; stack.spacing = 14; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        spinner.startAnimating()
        receive()
    }

    private func receive() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            finish("creatrr isn't set up to receive files yet. Open creatrr once and try again.", delay: 2.2); return
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var saved = 0

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
                // only keep audio files; the activation rule lets other files through too
                let ext = url.pathExtension.lowercased()
                guard ["mp3", "m4a", "wav", "aac", "aif", "aiff", "flac", "ogg", "caf", "mp4"].contains(ext) else { return }
                var dest = inbox.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    dest = inbox.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(url.lastPathComponent)")
                }
                do { try FileManager.default.copyItem(at: url, to: dest); lock.lock(); saved += 1; lock.unlock() } catch {}
            }
        }

        group.notify(queue: .main) {
            if saved == 0 { self.finish("That doesn't look like an audio file. creatrr takes MP3, M4A, WAV and similar.", delay: 2.4); return }
            self.spinner.stopAnimating()
            self.label.text = (saved == 1 ? "Added to creatrr" : "Added \(saved) files to creatrr") + ".\nOpen creatrr to put it in a song."
            self.finish(nil, delay: 1.6)
        }
    }

    private func finish(_ message: String?, delay: TimeInterval) {
        if let m = message { spinner.stopAnimating(); label.text = m }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
