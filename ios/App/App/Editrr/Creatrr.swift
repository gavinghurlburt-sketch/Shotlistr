import SwiftUI

/// Inside creatrr, editrr sits beside your artist page: creatrr hands it a way back, and asks it
/// to pause when you swipe away. On its own, editrr has neither.
extension Notification.Name {
    /// creatrr is leaving editrr: stop playback and save.
    static let editrrPause = Notification.Name("editrr.pause")
    /// creatrr is going to the background: write any change that's still waiting.
    static let editrrSave = Notification.Name("editrr.save")
}

/// Whether editrr is in the editor (not its home), for creatrr's swipe.
enum EditrrStage {
    @MainActor static var editing = false
}

extension EnvironmentValues {
    /// Back to your artist page, when editrr is part of creatrr.
    @Entry var creatrrBack: (() -> Void)? = nil
}

/// A part of a creatrr song (Verse 1, Chorus...): its name, where it starts and its color.
struct CreatrrPart: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let time: Double
    let color: String
    var id: String { "\(name)@\(time)" }

    /// creatrr's color (#rrggbb), or the accent when it has none.
    var tint: Color {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return Tint.accent }
        return Color(red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
}

/// A song creatrr shares: its name, the creatrr project it's in, its parts and its audio file.
struct CreatrrSong: Codable, Identifiable, Sendable {
    let key: String
    let name: String
    let project: String
    let parts: [CreatrrPart]
    /// The audio file, inside the shared folder.
    let audio: String
    var id: String { key }
}

/// creatrr's songs, from the folder the two apps share (creatrr writes it each time you leave it).
enum CreatrrLibrary {
    static let groupId = "group.art.gavingeddes.producrr"

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId)?
            .appendingPathComponent("editrr", isDirectory: true)
    }

    static func songs() -> [CreatrrSong] {
        guard let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("songs.json")),
              let list = try? JSONDecoder().decode([CreatrrSong].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.audio).path) }
    }

    static func audioURL(_ song: CreatrrSong) -> URL? {
        folder?.appendingPathComponent(song.audio)
    }
}

/// Picks one of creatrr's songs.
struct CreatrrSongsSheet: View {
    let pick: (CreatrrSong) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [CreatrrSong] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Songs from creatrr")
                    .font(.title2.weight(.bold))
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                if songs.isEmpty {
                    Text("Nothing here yet. Songs in creatrr that have a track show up here with their parts.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 12)
                }
                ForEach(songs) { song in
                    Button {
                        pick(song)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Tint.accent)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.name).font(.headline).lineLimit(1)
                                Text(detail(song))
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: 3) {
                                ForEach(song.parts.prefix(6)) { part in
                                    Rectangle().fill(part.tint).frame(width: 6, height: 14)
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.leading, 42)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { songs = CreatrrLibrary.songs() }
    }

    private func detail(_ song: CreatrrSong) -> String {
        let parts = song.parts.count == 1 ? "1 part" : "\(song.parts.count) parts"
        return song.project.isEmpty ? parts : "\(song.project) · \(parts)"
    }
}
