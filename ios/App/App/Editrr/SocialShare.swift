import SwiftUI
import UIKit
import Photos

/// After an export: one row of square icons, Instagram, TikTok, YouTube, Facebook and More.
/// Each icon opens that app with the video. More opens the phone's full share sheet.
enum SocialShare {
    /// Your Meta (Facebook) developer app ID. With it, Instagram and Facebook open straight into a new
    /// Reel with the video already in it. Without it (empty), they still work: the video is saved to
    /// Photos and the app opens, where you pick it.
    static let metaAppID = ""

    enum Place: String, CaseIterable, Identifiable {
        case instagram, tiktok, youtube, facebook
        var id: String { rawValue }

        var title: String {
            switch self {
            case .instagram: "Instagram"
            case .tiktok: "TikTok"
            case .youtube: "YouTube"
            case .facebook: "Facebook"
            }
        }

        var icon: String {
            switch self {
            case .instagram: "camera"
            case .tiktok: "music.note"
            case .youtube: "play.rectangle"
            case .facebook: "hand.thumbsup"
            }
        }

        /// Opens the app (after the video is in Photos).
        var openURLs: [String] {
            switch self {
            case .instagram: ["instagram://app"]
            case .tiktok: ["snssdk1233://", "tiktok://"]
            case .youtube: ["youtube://"]
            case .facebook: ["fb://"]
            }
        }

        /// What to do once the app opens on its own (no straight-to-Reel path).
        var pickLine: String {
            switch self {
            case .instagram: "Saved to Photos. In Instagram, tap + then Reel and pick it."
            case .tiktok: "Saved to Photos. In TikTok, tap + then Upload and pick it."
            case .youtube: "Saved to Photos. In YouTube, tap + then Short and pick it."
            case .facebook: "Saved to Photos. In Facebook, tap + then Reel and pick it."
            }
        }
    }

    /// Photos keeps one copy of each export, however many icons you tap.
    @MainActor private static var savedIDs: [URL: String] = [:]

    /// Sends the video to that app. Returns a line to show under the icons (nil: nothing to say).
    @MainActor
    static func send(_ url: URL, to place: Place) async -> String? {
        let app = UIApplication.shared
        // Straight into a new Reel, Meta's own way (needs the app ID).
        if !metaAppID.isEmpty, place == .instagram || place == .facebook {
            let scheme = place == .instagram ? "instagram-reels" : "facebook-reels"
            let owner = place == .instagram ? "com.instagram" : "com.facebook"
            if let open = URL(string: "\(scheme)://share?source_application=\(metaAppID)"), app.canOpenURL(open),
               let video = try? Data(contentsOf: url, options: .mappedIfSafe) {
                UIPasteboard.general.setItems([["\(owner).sharedSticker.backgroundVideo": video,
                                                "\(owner).sharedSticker.appID": metaAppID]],
                                              options: [.expirationDate: Date().addingTimeInterval(300)])
                if await app.open(open) { return nil }
            }
        }
        // Everyone else (and Meta without the ID): into Photos, then open the app to pick it.
        let id: String
        do {
            id = try await saveOnce(url)
        } catch {
            return EditorError.explain(error)
        }
        if place == .instagram,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let library = URL(string: "instagram://library?LocalIdentifier=\(encoded)"),
           app.canOpenURL(library), await app.open(library) {
            return "Saved to Photos and opened in Instagram."
        }
        for raw in place.openURLs {
            if let open = URL(string: raw), app.canOpenURL(open), await app.open(open) {
                return place.pickLine
            }
        }
        return "Saved to Photos. \(place.title) isn't on this phone."
    }

    @MainActor
    private static func saveOnce(_ url: URL) async throws -> String {
        if let id = savedIDs[url] { return id }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw EditorError.couldNotBuild("creatrr isn't allowed to save to Photos. Turn it on in Settings > creatrr > Photos.")
        }
        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
            box.id = request.placeholderForCreatedAsset?.localIdentifier
        }
        let id = box.id ?? ""
        savedIDs[url] = id
        return id
    }
}

/// The row that shows once the video is made. Square tiles, plain icons (editrr's look).
struct SocialRow: View {
    let url: URL
    let more: () -> Void
    static let detent = PresentationDetent.height(190)
    @State private var note: String?
    @State private var busy: SocialShare.Place?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(SocialShare.Place.allCases) { place in
                    tile(place.icon, place.title, working: busy == place) { go(place) }
                }
                tile("ellipsis", "More", working: false, action: more)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ icon: String, _ title: String, working: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                    if working {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: icon)
                            .font(.title2)
                    }
                }
                .frame(width: 54, height: 54)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityLabel(title)
    }

    private func go(_ place: SocialShare.Place) {
        busy = place
        Task {
            note = await SocialShare.send(url, to: place)
            busy = nil
        }
    }
}
