import SwiftUI
import AVFoundation

/// Inside creatrr, editrr sits beside your artist page: creatrr hands it a way back, and asks it
/// to pause when you swipe away. On its own, editrr has neither.
extension Notification.Name {
    /// creatrr is leaving editrr: stop playback and save.
    static let editrrPause = Notification.Name("editrr.pause")
    /// creatrr is going to the background: write any change that's still waiting.
    static let editrrSave = Notification.Name("editrr.save")
    /// editrr moved between its home and the editor.
    static let editrrStage = Notification.Name("editrr.stage")
    /// creatrr asked to shoot a song part (a section's red record button).
    static let editrrShoot = Notification.Name("editrr.shoot")
}

/// A song part creatrr asked to shoot, waiting for editrr to pick it up.
enum EditrrShoot {
    struct Request: Equatable, Sendable {
        /// creatrr's song key (the same as in the shared songs).
        let key: String
        /// Song time of the part (nil: from the top).
        let time: Double?
        /// Where the part ends (the next section's start), when creatrr knows it.
        var end: Double? = nil
        /// The section's name in creatrr.
        var name: String? = nil
    }

    @MainActor static var pending: Request? {
        didSet { if pending != nil { NotificationCenter.default.post(name: .editrrShoot, object: nil) } }
    }
}

/// Whether editrr is in the editor (not its home), for creatrr's swipe.
enum EditrrStage {
    /// creatrr shows its header and tabs over editrr's home, and goes full screen for the editor.
    @MainActor static var editing = false {
        didSet { if editing != oldValue { NotificationCenter.default.post(name: .editrrStage, object: nil) } }
    }
}

extension EnvironmentValues {
    /// Back to your artist page, when editrr is part of creatrr.
    @Entry var creatrrBack: (() -> Void)? = nil
    /// What the way back is called: Artist, or Artists on Plus and Pro.
    @Entry var creatrrBackTitle: String = "Artist"
    /// creatrr's header isn't above editrr's home (it opened from inside a page), so editrr shows
    /// its own way back.
    @Entry var creatrrBare: Bool = false
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
    /// Its tempo in creatrr, when set: beats a minute and the song time of a downbeat.
    var bpm: Double? = nil
    var beat: Double? = nil
    /// Whether creatrr's count-in and click are on for it.
    var countIn: Bool? = nil
    var click: Bool? = nil
    var id: String { key }

    /// The tempo for the count-in and click (nil when creatrr doesn't know it).
    var tempo: CaptureTempo? {
        guard let bpm, bpm > 0, let beat else { return nil }
        return CaptureTempo(bpm: bpm, beat: beat, countIn: countIn ?? false, click: click ?? false)
    }

    /// Where a part ends: where the next one starts (nil for the last part).
    func partEnd(_ index: Int) -> Double? {
        index + 1 < parts.count ? parts[index + 1].time : nil
    }
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

/// Shoot: pick a creatrr song, then the part to film. The camera opens at that part.
struct ShootSongSheet: View {
    let pick: (CreatrrSong, CreatrrPart?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [CreatrrSong] = []
    @State private var open: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shoot")
                    .font(.title2.weight(.bold))
                    .padding(.top, 22)
                Text("Pick a song, then the part to film. Up to 10 takes, each lined up to the song.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                if songs.isEmpty {
                    Text("Nothing here yet. Songs in creatrr that have a track show up here with their parts.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 12)
                }
                ForEach(songs) { song in
                    songRow(song)
                    if open == song.key { partRows(song) }
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.leading, 42)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            songs = CreatrrLibrary.songs()
            if songs.count == 1 { open = songs[0].key }
        }
    }

    private func songRow(_ song: CreatrrSong) -> some View {
        Button {
            withAnimation(.snappy) { open = open == song.key ? nil : song.key }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Tint.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name).font(.headline).lineLimit(1)
                    Text(song.project.isEmpty ? partsCount(song) : "\(song.project) · \(partsCount(song))")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: open == song.key ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The song's parts (and the whole song), each starting the camera there.
    private func partRows(_ song: CreatrrSong) -> some View {
        VStack(spacing: 6) {
            partButton(song, nil, name: "Whole song", detail: "From the top", tint: .white.opacity(0.5))
            ForEach(song.parts) { part in
                partButton(song, part, name: part.name, detail: "Starts at \(clock(part.time))", tint: part.tint)
            }
        }
        .padding(.leading, 42)
        .padding(.bottom, 12)
    }

    private func partButton(_ song: CreatrrSong, _ part: CreatrrPart?, name: String, detail: String,
                            tint: Color) -> some View {
        Button {
            pick(song, part)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(tint).frame(width: 5, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "record.circle")
                    .font(.title3)
                    .foregroundStyle(Tint.bad)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shoot \(name)")
    }

    private func partsCount(_ song: CreatrrSong) -> String {
        song.parts.count == 1 ? "1 part" : "\(song.parts.count) parts"
    }

    private func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

/// Shoot's camera: the song, where to start, and its tempo.
struct ShootPlan: Identifiable {
    let id = UUID()
    let song: AVAsset
    let length: Double
    let songName: String
    /// The part filmed (nil: the whole song).
    let partName: String?
    let parts: [CreatrrPart]
    let part: CreatrrPart.ID?
    /// Song time every take starts at (the part's start, or 0 for the whole song).
    let start: Double
    /// Where the part ends (takes stop a second after), nil for the whole song or the last part.
    let end: Double?
    let tempo: CaptureTempo?
    /// Started from a section's red record button in creatrr: closing with no takes goes back there.
    var fromCreatrr = false
}
