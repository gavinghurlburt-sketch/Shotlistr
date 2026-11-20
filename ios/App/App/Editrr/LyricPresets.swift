import SwiftUI

/// A lyric look you saved and named: font, size, case, colors, outline, glow, color split, shake,
/// how words come in, how long they hold, and one word or build the line. Where the words sit is
/// not part of it (that changes video to video), so using a preset keeps the current spot.
struct LyricPreset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var style: LyricStyle
}

/// Your presets, kept on the phone for every project.
@MainActor
@Observable
final class LyricPresetStore {
    static let shared = LyricPresetStore()
    private static let key = "lyricPresets"

    private(set) var presets: [LyricPreset] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([LyricPreset].self, from: data) {
            presets = saved
        }
    }

    /// Saves the look under a name (a name already used gets a number on the end).
    @discardableResult
    func add(name: String, style: LyricStyle) -> LyricPreset {
        let preset = LyricPreset(name: unique(Self.clean(name)), style: style)
        presets.append(preset)
        save()
        return preset
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.clean(name)
        presets[index].name = clean == presets[index].name ? clean : unique(clean)
        save()
    }

    /// Puts the current look into a saved preset.
    func update(_ id: UUID, style: LyricStyle) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].style = style
        save()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My look" : String(trimmed.prefix(24))
    }

    private func unique(_ name: String) -> String {
        let taken = Set(presets.map(\.name)).union(LyricStyle.presets.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}

extension LyricStyle {
    /// This look with another one's settings, keeping where the words sit, how big they are and
    /// whether they show (those three change video to video, so presets leave them alone).
    func taking(_ look: LyricStyle) -> LyricStyle {
        var next = look
        next.posX = posX
        next.posY = posY
        next.size = size
        next.show = show
        next.from = from
        next.to = to
        return next
    }

    /// Whether this is that look already (ignoring where the words sit and how big).
    func wears(_ look: LyricStyle) -> Bool {
        taking(look) == self
    }
}

/// One stop on the look wheel: lyrics off, the look you have now (when it isn't a preset),
/// a ready-made look, or one you saved.
struct LyricLook: Identifiable {
    enum Kind { case off, now, builtIn(Int), saved(UUID) }
    let id: String
    let kind: Kind
    let name: String
    /// What the look is, already fitted to the current spot and size (nil for off).
    let style: LyricStyle?

    /// Off first, then the ready-made looks, then yours. `current` is where you are on it.
    @MainActor
    static func all(for style: LyricStyle) -> (looks: [LyricLook], current: Int) {
        var looks = [LyricLook(id: "off", kind: .off, name: "Off", style: nil)]
        var ready: [LyricLook] = []
        for (index, preset) in LyricStyle.presets.enumerated() {
            ready.append(LyricLook(id: "b\(index)", kind: .builtIn(index), name: preset.name,
                                   style: style.taking(style.withPreset(index))))
        }
        for preset in LyricPresetStore.shared.presets {
            ready.append(LyricLook(id: preset.id.uuidString, kind: .saved(preset.id), name: preset.name,
                                   style: style.taking(preset.style)))
        }
        if !style.show { return (looks + ready, 0) }
        if let match = ready.firstIndex(where: { $0.style == style }) { return (looks + ready, match + 1) }
        // A look you made by hand stays on the wheel so you can come back to it.
        looks.append(LyricLook(id: "now", kind: .now, name: "Yours", style: style))
        return (looks + ready, 1)
    }
}

/// A preset as a square tile: a sample in its font, color, outline and glow, its name under it.
struct LyricPresetTile: View {
    let name: String
    let style: LyricStyle
    let picked: Bool

    var body: some View {
        let sample = style.textCase.apply("Aa")
        VStack(spacing: 6) {
            ZStack {
                Corner.chip.fill(Tint.surface2)
                Text(sample)
                    .font(style.postScript.map { Font.custom($0, size: 30) } ?? .system(size: 30, weight: .black))
                    .foregroundStyle(LyricsSheet.swatch(style.color))
                    .shadow(color: style.stroke > 0.5 ? LyricsSheet.swatch(style.strokeColor) : .clear, radius: 0, x: 1.5, y: 1.5)
                    .shadow(color: LyricsSheet.swatch(style.glowColor).opacity(min(1, style.glow)),
                            radius: style.glow > 0.05 ? 8 : 0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(6)
            }
            .frame(width: 72, height: 72)
            .overlay(Corner.chip.strokeBorder(picked ? Tint.accent : .clear, lineWidth: 3))
            Text(name)
                .font(.caption2.weight(picked ? .bold : .semibold))
                .foregroundStyle(picked ? Tint.accent : Color.white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 76)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A slider that shows the change while you drag and saves it when you let go (one Undo step).
struct LiveSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let ends: (String, String)
    let changing: (Double) -> Void
    let commit: (Double) -> Void
    @State private var live: Double = 0
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text(ends.0).frame(minWidth: 34, alignment: .leading)
            Slider(value: Binding(get: { dragging ? live : value },
                                  set: { live = $0; changing($0) }),
                   in: range,
                   onEditingChanged: { editing in
                       if editing {
                           live = value
                           dragging = true
                       } else {
                           dragging = false
                           commit(live)
                       }
                   })
                .tint(Tint.accent)
            Text(ends.1).frame(minWidth: 34, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.6))
    }
}
