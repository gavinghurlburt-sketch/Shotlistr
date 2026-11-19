import SwiftUI

/// How a piece of text comes in. It goes out the same way, faded.
enum TitleEntry: String, Codable, CaseIterable, Sendable {
    case cut, fade, pop, rise

    var name: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .rise: return "Rise"
        }
    }
}

/// A title or any text, on its own lane under the videos. Times are timeline seconds; the size is
/// in pixels on a 1080-wide frame; the spot is percent across and percent down from the top (like the lyrics).
struct TitleClip: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text = "Your text"
    var start: Double
    var end: Double
    /// Which text lane it sits on (0 is the first one under the videos).
    var lane = 0
    var font = LyricFont.heavy
    var customFont = ""
    var textCase = LyricCase.asIs
    var size: Double = 110
    var color = "#ffffff"
    var outline = false
    var shadow = true
    var posX: Double = 50
    var posY: Double = 50
    var entry = TitleEntry.fade

    var postScript: String? { customFont.isEmpty ? font.postScript : customFont }

    init(start: Double, end: Double, lane: Int) {
        self.start = start
        self.end = end
        self.lane = lane
    }

    /// Anything missing from an older save keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var t = TitleClip(start: 0, end: 1, lane: 0)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let found = try? c.decodeIfPresent(T.self, forKey: key) { value = found }
        }
        read(.id, &t.id); read(.text, &t.text); read(.start, &t.start); read(.end, &t.end); read(.lane, &t.lane)
        read(.font, &t.font); read(.customFont, &t.customFont); read(.textCase, &t.textCase); read(.size, &t.size)
        read(.color, &t.color); read(.outline, &t.outline); read(.shadow, &t.shadow)
        read(.posX, &t.posX); read(.posY, &t.posY); read(.entry, &t.entry)
        self = t
    }

    /// One line for the timeline.
    var label: String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Text" : line
    }
}

/// The text lanes' color on the timeline.
enum TitleTint {
    static let color = Color(red: 0.66, green: 0.55, blue: 1.0)
}

/// A text lane's header: a T, in the lane color.
struct TextLaneChip: View {
    let number: Int
    let lit: Bool
    var tall = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Tint.surface2)
            Image(systemName: "textformat")
                .font(.body.weight(.semibold))
                .foregroundStyle(lit ? TitleTint.color : Color.white.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("T\(number)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .padding(.leading, 8)
                .padding(.bottom, 2)
        }
        .frame(width: LaneMetrics.labelWidth - 6, height: LaneMetrics.laneHeight(tall: tall) - 8, alignment: .bottomLeading)
        .overlay(alignment: .leading) {
            Rectangle().fill(TitleTint.color).frame(width: 4)
        }
        .clipShape(Corner.small)
    }
}

/// Over the video while a text is open: drag anywhere to move it. A crosshair marks its middle.
struct TitleMover: View {
    let model: EditorModel
    let id: UUID
    @State private var start: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let clip = model.title(id)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let clip {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 3)
                        .position(x: geo.size.width * clip.posX / 100,
                                  y: geo.size.height * clip.posY / 100)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard let clip = model.title(id) else { return }
                        if start == nil { start = CGPoint(x: clip.posX, y: clip.posY) }
                        guard let start else { return }
                        let x = start.x + value.translation.width / max(geo.size.width, 1) * 100
                        let y = start.y + value.translation.height / max(geo.size.height, 1) * 100
                        model.placeTitle(id, x: Double(x), y: Double(y))
                    }
                    .onEnded { _ in
                        start = nil
                        model.placeTitleEnded()
                    }
            )
        }
    }
}

/// One text's words and look. Opens from the Text button or a tap on a text clip.
struct TitleSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    private var library: FontLibrary { FontLibrary.shared }

    private static let colors = ["#ffffff", "#fff36b", "#ff3b8d", "#00e5ff", "#a98bff", "#7dff9a", "#000000"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let id = model.titleEditing, let clip = model.title(id) {
                    header(clip)
                    words(id)
                    look(id, clip)
                    note("Drag on the video to move it. On the timeline, hold the text clip to move it, or drag its ends to make it longer or shorter.")
                } else {
                    note("This text is gone.")
                }
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .onAppear {
            // A brand new one: start typing right away.
            if let id = model.titleEditing, model.title(id)?.text == "Your text" { typing = true }
        }
    }

    private func header(_ clip: TitleClip) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Text").font(.title3.weight(.bold))
                Text("\(EditorModel.clockWhole(clip.start)) to \(EditorModel.clockWhole(clip.end)), lane T\(clip.lane + 1)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
            // Another text at the playhead, on the next lane (for a second line that comes in on its own).
            Button { model.addTitle() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(GlassButtonStyle())
            .accessibilityLabel("Add another text here")
            Button(role: .destructive) { model.deleteTitle(clip.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassButtonStyle(tint: Tint.bad))
            .accessibilityLabel("Delete this text")
            Button("Done") { dismiss() }
                .buttonStyle(GlassButtonStyle())
        }
    }

    private func words(_ id: UUID) -> some View {
        TextField("Type your text", text: Binding(
            get: { model.title(id)?.text ?? "" },
            set: { new in model.editTitle(id) { $0.text = new } }
        ), axis: .vertical)
        .font(.body.weight(.semibold))
        .lineLimit(1...4)
        .focused($typing)
        .padding(12)
        .background(Tint.surface2, in: Corner.chip)
    }

    @ViewBuilder
    private func look(_ id: UUID, _ clip: TitleClip) -> some View {
        section("Font") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LyricFont.allCases, id: \.self) { font in
                        Button {
                            model.editTitle(id) { $0.font = font; $0.customFont = "" }
                        } label: {
                            Text(font.name)
                                .font(font.postScript.map { Font.custom($0, size: 17) } ?? .system(size: 17, weight: .black))
                        }
                        .buttonStyle(GlassButtonStyle(tint: Tint.accent,
                                                      selected: clip.customFont.isEmpty && clip.font == font))
                    }
                    // Fonts you added (in Lyrics) show here too.
                    ForEach(library.fonts) { entry in
                        Button {
                            model.editTitle(id) { $0.customFont = entry.postScript }
                        } label: {
                            Text(entry.name).font(.custom(entry.postScript, size: 17))
                        }
                        .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: clip.customFont == entry.postScript))
                    }
                }
            }
            chips(LyricCase.allCases, selected: clip.textCase, name: { $0.name }) { textCase in
                model.editTitle(id) { $0.textCase = textCase }
            }
            FXSlider(value: clip.size, range: 40...320, ends: ("Small", "Big")) { value in
                model.editTitle(id) { $0.size = value }
            }
        }

        section("Color") {
            HStack(spacing: 10) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button { model.editTitle(id) { $0.color = hex } } label: {
                        Corner.chip
                            .fill(LyricsSheet.swatch(hex))
                            .frame(width: 32, height: 32)
                            .overlay(Corner.chip.strokeBorder(.white.opacity(clip.color.lowercased() == hex ? 0.95 : 0.3),
                                                           lineWidth: clip.color.lowercased() == hex ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Button { model.editTitle(id) { $0.outline.toggle() } } label: {
                    Label("Outline", systemImage: "character")
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: clip.outline))
                Button { model.editTitle(id) { $0.shadow.toggle() } } label: {
                    Label("Shadow", systemImage: "shadow")
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: clip.shadow))
            }
        }

        section("Place") {
            HStack(spacing: 8) {
                ForEach([("Top", 20.0), ("Middle", 50.0), ("Bottom", 78.0)], id: \.0) { spot in
                    Button(spot.0) { model.editTitle(id) { $0.posX = 50; $0.posY = spot.1 } }
                        .buttonStyle(GlassButtonStyle(tint: Tint.calm,
                                                      selected: abs(clip.posX - 50) < 0.5 && abs(clip.posY - spot.1) < 0.5))
                }
            }
        }

        section("Comes in") {
            chips(TitleEntry.allCases, selected: clip.entry, name: { $0.name }) { entry in
                model.editTitle(id) { $0.entry = entry }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
    }

    private func chips<Item: Hashable>(_ items: [Item], selected: Item, name: @escaping (Item) -> String,
                                       pick: @escaping (Item) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button(name(item)) { pick(item) }
                        .buttonStyle(GlassButtonStyle(tint: Tint.calm, selected: item == selected))
                }
            }
        }
    }
}
