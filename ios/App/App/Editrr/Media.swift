import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import AVFoundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI

/// How much room is left on the phone, so a big import or export stops with a plain message
/// instead of failing halfway.
enum Disk {
    /// Bytes free for things you chose to do (what Settings counts as available). Nil if unknown.
    static var freeBytes: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return free
    }

    /// True when at least `bytes` are free (or the phone won't say: then it just tries).
    static func hasRoom(for bytes: Int64) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= bytes
    }

    static let megabyte: Int64 = 1_000_000

    /// Room an export of this many seconds needs: about 2 MB a second at 1080 x 1920, plus some to
    /// spare for the copy that goes to Photos.
    static func exportNeeds(seconds: Double) -> Int64 {
        Int64(max(0, seconds) * 2 * Double(megabyte)) * 2 + 200 * megabyte
    }

    /// "1.2 GB", "450 MB".
    static func describe(_ bytes: Int64) -> String {
        bytes >= 1_000 * megabyte ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / megabyte) MB"
    }

    static let fullMessage = "Your iPhone is almost out of space. Free some up in Settings > General > iPhone Storage, then try again."
}

/// The app's own folder for the rare fallback copy of a video, and the picked song.
enum ClipStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("LayerTestClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func reset() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("LayerTestClips", isDirectory: true))
    }

    /// Where a song picked in Files is kept (songs are small, so copying is quick).
    static var songFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Song", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies a song picked in Files into the app's folder, replacing the last one.
    static func keepSong(_ url: URL) throws -> URL {
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("Song", isDirectory: true))
        let destination = songFolder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}

/// Asks once for Photos access, so picked videos open in place instead of being copied.
enum PhotoAccess {
    static func ask() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}

/// A picked video and where it came from, so a project can open it again later.
struct PickedMedia: @unchecked Sendable {
    let asset: AVAsset
    let source: MediaSource
}

/// Opens picked videos. The fast way reads each video straight from the Photos library
/// (no copy, so it's instant for videos on the phone). Only if that isn't allowed does it
/// fall back to copying the file, which is slow for long clips.
enum PhotosLoader {
    /// Carries an opened video between tasks.
    private struct Opened: @unchecked Sendable {
        let index: Int
        let picked: PickedMedia?
    }

    static func load(_ items: [PhotosPickerItem]) async -> [PickedMedia] {
        await withTaskGroup(of: Opened.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    if let id = item.itemIdentifier, let asset = await fromLibrary(id) {
                        return Opened(index: index, picked: PickedMedia(asset: asset, source: .library(id)))
                    }
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        return Opened(index: index, picked: PickedMedia(asset: AVURLAsset(url: movie.url),
                                                                        source: .file(movie.url.path)))
                    }
                    return Opened(index: index, picked: nil)
                }
            }
            var found: [Opened] = []
            for await opened in group where opened.picked != nil {
                found.append(opened)
            }
            // Keep the order he picked them in.
            return found.sorted { $0.index < $1.index }.compactMap { $0.picked }
        }
    }

    /// Opens a saved project's video or song again. Nil when it's gone (deleted from Photos).
    static func open(_ source: MediaSource, project: UUID) async -> AVAsset? {
        switch source {
        case .library(let id):
            return await fromLibrary(id)
        case .file:
            guard let url = ProjectStore.url(of: source, in: project),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return AVURLAsset(url: url)
        }
    }

    private static func fromLibrary(_ identifier: String) async -> AVAsset? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              photo.mediaType == .video else { return nil }

        let options = PHVideoRequestOptions()
        options.version = .current            // with his trims and edits
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true // fetch from iCloud if it isn't on the phone

        let opened: Opened = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: photo, options: options) { asset, _, _ in
                continuation.resume(returning: Opened(index: 0, picked: asset.map { PickedMedia(asset: $0, source: .library(identifier)) }))
            }
        }
        return opened.picked?.asset
    }
}

/// Fallback only: a video from the Photos picker, copied into the app's folder as-is.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = ClipStore.folder
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum EditorError: LocalizedError {
    case noVideo, noSound, couldNotBuild(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "Those files have no video in them."
        case .noSound: return "That file has no sound in it."
        case .couldNotBuild(let detail): return detail
        }
    }

    /// The full story of an error (domain, code and the reason underneath), so a failure can be
    /// pasted back into chat instead of "The operation could not be completed".
    static func explain(_ error: Error) -> String {
        if let ours = error as? EditorError { return ours.errorDescription ?? "Unknown problem." }
        let ns = error as NSError
        var parts = ["\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"]
        if let reason = ns.localizedFailureReason { parts.append(reason) }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underneath: \(under.domain) \(under.code) \(under.localizedDescription)")
        }
        return parts.joined(separator: " · ")
    }
}
