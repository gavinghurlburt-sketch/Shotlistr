import Foundation
import CoreText
import UniformTypeIdentifiers

/// Your own fonts for the lyrics. Picked font files (.ttf, .otf) are copied into
/// Application Support/Fonts and registered for the app each launch, so a project that uses
/// one keeps it. Lyrics fall back to the built-in Heavy font if a font file is removed.
@MainActor
@Observable
final class FontLibrary {
    static let shared = FontLibrary()

    struct Entry: Identifiable, Hashable {
        /// What the renderer asks for.
        let postScript: String
        /// What the button shows.
        let name: String
        let file: String
        var id: String { postScript }
    }

    private(set) var fonts: [Entry] = []

    static let types: [UTType] = [.font]

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private init() {
        Self.registerBundled()
        loadAll()
    }

    /// Registers the fonts shipped inside the app (editrr/Fonts), used by the built-in `LyricFont` cases.
    private static func registerBundled() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Registers every saved font file (called once, when the app starts).
    func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var found: [Entry] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            found += Self.entries(in: url)
        }
        fonts = found
    }

    /// Copies picked font files in and registers them. Returns the fonts that were added.
    func add(_ urls: [URL]) -> [Entry] {
        var added: [Entry] = []
        for url in urls {
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            let inside = Self.entries(in: url)
            guard !inside.isEmpty else { continue }
            // Already have it: just use it.
            if let same = inside.first(where: { entry in fonts.contains { $0.postScript == entry.postScript } }) {
                added.append(same)
                continue
            }
            var target = Self.folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                target = Self.folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            }
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { continue }
            CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
            let entries = Self.entries(in: target)
            fonts += entries
            added += entries
        }
        return added
    }

    /// Takes a font out of the app (its whole file, if the file held several).
    func remove(_ entry: Entry) {
        let url = Self.folder.appendingPathComponent(entry.file)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: url)
        fonts.removeAll { $0.file == entry.file }
    }

    private static func entries(in url: URL) -> [Entry] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap { descriptor in
            guard let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
                return nil
            }
            let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? postScript
            return Entry(postScript: postScript, name: name, file: url.lastPathComponent)
        }
    }
}
