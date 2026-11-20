import Foundation
import UIKit

/// Where a project's video or song comes from.
enum MediaSource: Codable, Equatable, Sendable {
    /// In the Photos library (its local identifier). Nothing is copied, so it opens instantly.
    case library(String)
    /// A file. Right after picking: a full path in the app's cache. Once saved: a file name
    /// inside the project's own folder.
    case file(String)
}

/// One layer as saved: which video it shows and everything done to it.
struct SavedLayer: Codable, Equatable {
    var video: Int
    var offset: Double
    var trimStart: Double
    var trimEnd: Double
    var sync: SyncState
    var alternatives: [Double]
    var keyframes: [Keyframe]
    /// The track color you picked (nil in older projects, or never changed).
    var color: Int? = nil
    /// How many times longer it plays than it was shot (nil: normal speed). See Layer.speed.
    var speed: Double? = nil
    /// Its own sound is off (nil: on).
    var muted: Bool? = nil
}

/// A named project: the song, the videos, where each sits, and every cut, keyframe and In/Out.
struct SavedProject: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var created: Date
    var updated: Date
    var song: MediaSource?
    var songName: String?
    var videos: [MediaSource]
    var layers: [SavedLayer]
    var cuts: [Cut]
    var duration: Double
    var inPoint: Double
    var outPoint: Double
    /// No song: which video's sound plays, and timeline time = its asset time + soundShift.
    var soundVideo: Int?
    var soundShift: Double?
    var soundName: String?
    /// The lyrics, their look, and what the speech model last heard (nil in older projects).
    var lyrics: [LyricWord]?
    var lyricStyle: LyricStyle?
    var lyricsHeard: [LyricWord]?
    /// Titles and other text (nil in older projects).
    var titles: [TitleClip]?
    /// "video" (videos back to back) or "performance" (videos synced to a song); nil in older
    /// projects, which are performances.
    var kind: String?
    /// Pictures and videos on top of the main video (nil in older projects).
    var overlays: [SavedOverlay]?
    /// Keyframes on the whole performance track (zoom and move over everything), in timeline
    /// seconds (nil when there are none, and in older projects).
    var trackKeys: [Keyframe]?
    /// Where the performance is split on the edit page, in timeline seconds (nil when it isn't).
    var splits: [Double]?
    /// Editing a video: the order the videos play in, as places in `layers` (nil: as listed).
    var order: [Int]?
    /// A horizontal (16:9, 1920 x 1080) project, shot sideways. nil: vertical, like every older one.
    var wide: Bool?
    /// Music added on the edit page by the first build of it (one piece at most). Read only to
    /// bring it into `sounds`; new saves leave it out.
    var music: SavedMusic?
    /// Music and sound effects added with the + under the tracks (nil: none).
    var sounds: [SavedMusic]?
}

/// Music or a sound effect added on the edit page (a file from Files, or a creatrr song or section).
/// It plays under everything else, from where it was added, on its own audio row.
struct SavedMusic: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The file, kept in the project's folder.
    var source: MediaSource
    var name: String
    /// Where in the file it starts playing (a creatrr section's start), in seconds.
    var from: Double
    /// Timeline time it starts at.
    var at: Double
    /// How long it plays (a section's length, or the rest of the file).
    var length: Double
    /// Which audio row it sits on (0 is the first, under the song).
    var lane = 0
    /// A sound effect rather than music (only its icon differs).
    var effect = false

    init(source: MediaSource, name: String, from: Double, at: Double, length: Double, lane: Int = 0, effect: Bool = false) {
        self.source = source
        self.name = name
        self.from = from
        self.at = at
        self.length = length
        self.lane = lane
        self.effect = effect
    }

    /// Anything missing from an older save keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(MediaSource.self, forKey: .source)
        name = try c.decode(String.self, forKey: .name)
        from = try c.decode(Double.self, forKey: .from)
        at = try c.decode(Double.self, forKey: .at)
        length = try c.decode(Double.self, forKey: .length)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        lane = (try? c.decodeIfPresent(Int.self, forKey: .lane)) ?? 0
        effect = (try? c.decodeIfPresent(Bool.self, forKey: .effect)) ?? false
    }
}

/// Saved projects live in Application Support/Projects/<id>/, each with project.json, a small
/// thumbnail, and any files that aren't in Photos (a song from Files, a copied video).
enum ProjectStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func folder(for id: UUID) -> URL {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Every saved project, last edited first. A project that can't be read is skipped.
    static func list() -> [SavedProject] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let projects = folders.compactMap { folder -> SavedProject? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")) else { return nil }
            return try? decoder.decode(SavedProject.self, from: data)
        }
        return projects.sorted { $0.updated > $1.updated }
    }

    static func save(_ project: SavedProject) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: folder(for: project.id).appendingPathComponent("project.json"), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func saveThumbnail(_ image: UIImage, for id: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: folder(for: id).appendingPathComponent("thumb.jpg"), options: .atomic)
    }

    static func thumbnail(for id: UUID) -> UIImage? {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("thumb.jpg")
        return UIImage(contentsOfFile: url.path)
    }

    /// Where a file source sits on disk (nil for Photos sources).
    static func url(of source: MediaSource, in id: UUID) -> URL? {
        guard case .file(let path) = source else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(path)
    }

    /// Brings a picked file into the project's folder so a later pick can't delete it. A hard
    /// link when it can (instant, no extra space), a copy otherwise. Photos sources stay as they are.
    static func adopt(_ source: MediaSource, into id: UUID) -> MediaSource {
        guard case .file(let path) = source, path.hasPrefix("/") else { return source }
        let from = URL(fileURLWithPath: path)
        let ext = from.pathExtension.isEmpty ? "mov" : from.pathExtension
        let name = UUID().uuidString + "." + ext
        let to = folder(for: id).appendingPathComponent(name)
        do {
            try FileManager.default.linkItem(at: from, to: to)
        } catch {
            try? FileManager.default.copyItem(at: from, to: to)
        }
        return .file(name)
    }
}
