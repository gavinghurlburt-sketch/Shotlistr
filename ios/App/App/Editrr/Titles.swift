import SwiftUI
import CoreText

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
    var bold = false
    var italic = false
    var textCase = LyricCase.asIs
    var size: Double = 110
    var color = "#ffffff"
    var outline = false
    var shadow = true
    var posX: Double = 50
    var posY: Double = 50
    var entry = TitleEntry.fade
    /// The text's box: how wide it wraps, in percent of the frame's width (nil: 90). With a height
    /// (percent of the frame's height), the text grows or shrinks to fill the box; without one, the
    /// box is as tall as the wrapped lines at `size`.
    var boxW: Double?
    var boxH: Double?

    var postScript: String? { customFont.isEmpty ? font.postScript : customFont }
    /// The font as it's drawn: the font, with Bold and Italic.
    var drawFont: String? { StyledFont.spec(postScript, bold: bold, italic: italic) }

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
        read(.font, &t.font); read(.customFont, &t.customFont)
        read(.bold, &t.bold); read(.italic, &t.italic); read(.textCase, &t.textCase); read(.size, &t.size)
        read(.color, &t.color); read(.outline, &t.outline); read(.shadow, &t.shadow)
        read(.posX, &t.posX); read(.posY, &t.posY); read(.entry, &t.entry)
        read(.boxW, &t.boxW); read(.boxH, &t.boxH)
        self = t
    }

    /// One line for the timeline.
    var label: String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Text" : line
    }
}

/// Where a text's lines fall: wrapped to its box's width (onto new lines instead of shrinking), and
/// with a box height, sized to fill the box. The same for the preview, the export and the handles.
enum TitleLayout {
    struct Laid {
        /// The font size in pixels on this frame.
        let size: Double
        let lines: [String]
        let lineHeight: Double
        /// How wide the lines may run before wrapping, in pixels on this frame.
        let wrapWidth: Double
        /// The box on the video, in pixels on this frame. Until a side is pulled, it hugs the lines.
        let width: Double
        let height: Double
    }

    /// Line height for a font size (the renderer spaces lines the same).
    static let leading = 1.15
    /// The largest a text can grow to fill its box (pixels on a 1080-wide frame).
    static let biggest = 480.0
    static let smallest = 20.0

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Laid] = [:]
    nonisolated(unsafe) private static var widths: [String: Double] = [:]

    /// The pixels-on-a-1080-frame scale for this frame.
    static func scale(_ canvas: CGSize) -> Double { Double(min(canvas.width, canvas.height)) / 1080 }

    static func lay(_ title: TitleClip, canvas: CGSize) -> Laid {
        let W = Double(canvas.width), H = Double(canvas.height)
        let k = scale(canvas)
        let text = title.textCase.apply(title.text)
        let boxW = W * min(max(title.boxW ?? 90, 5), 100) / 100
        let key = "\(text)|\(title.drawFont ?? "")|\(title.size)|\(boxW)|\(title.boxH ?? -1)|\(W)x\(H)"
        lock.lock()
        if let found = cache[key] {
            lock.unlock()
            return found
        }
        lock.unlock()

        let font = title.drawFont
        // Words measured once at 100 px, then scaled (a font's widths grow with its size).
        let paragraphs = text.components(separatedBy: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
        let space = width(" ", font: font)
        func wrap(_ size: Double) -> [String] {
            let f = size / 100
            var lines: [String] = []
            for words in paragraphs {
                var line: [String] = []
                var used = 0.0
                for word in words {
                    let w = width(word, font: font) * f
                    if !line.isEmpty, used + space * f + w > boxW {
                        lines.append(line.joined(separator: " "))
                        line = [word]
                        used = w
                    } else {
                        used += (line.isEmpty ? 0 : space * f) + w
                        line.append(word)
                    }
                }
                lines.append(line.joined(separator: " "))
            }
            return lines
        }
        /// Its longest single word fits across the box at this size.
        func wordsFit(_ size: Double) -> Bool {
            let longest = paragraphs.joined().map { width($0, font: font) }.max() ?? 0
            return longest * size / 100 <= boxW
        }

        var size: Double
        let height: Double
        if let boxH = title.boxH {
            // Fill the box: the biggest size whose wrapped lines fit inside it.
            let tall = H * min(max(boxH, 2), 100) / 100
            var low = smallest * k, high = biggest * k
            func fits(_ s: Double) -> Bool {
                wordsFit(s) && Double(wrap(s).count) * s * leading <= tall
            }
            if fits(high) {
                low = high
            } else {
                for _ in 0..<18 where high - low > 0.5 {
                    let mid = (low + high) / 2
                    if fits(mid) { low = mid } else { high = mid }
                }
            }
            size = low
            height = tall
        } else {
            size = title.size * k
            // A single word too long for the box shrinks to fit (there's nowhere to wrap it).
            let longest = paragraphs.joined().map { width($0, font: font) }.max() ?? 0
            if longest * size / 100 > boxW, longest > 0 { size = boxW / longest * 100 }
            height = 0
        }
        size = (size * 2).rounded(.down) / 2
        let lines = wrap(size)
        let lineHeight = size * leading
        var shown = boxW
        if title.boxW == nil, title.boxH == nil {
            let widest = lines.map { width($0, font: font) * size / 100 }.max() ?? 0
            shown = min(boxW, widest + size * 0.3)
        }
        let laid = Laid(size: size, lines: lines, lineHeight: lineHeight, wrapWidth: boxW, width: shown,
                        height: title.boxH == nil ? Double(max(lines.count, 1)) * lineHeight : height)
        lock.lock()
        if cache.count > 400 { cache.removeAll() }
        cache[key] = laid
        lock.unlock()
        return laid
    }

    /// A word's width at 100 px in this font (the renderer's font rule).
    private static func width(_ word: String, font postScript: String?) -> Double {
        let key = "\(postScript ?? "")|\(word)"
        lock.lock()
        if let found = widths[key] {
            lock.unlock()
            return found
        }
        lock.unlock()
        let made = StyledFont.font(postScript, size: 100)
        let string = NSAttributedString(string: word, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): made.font
        ])
        let line = CTLineCreateWithAttributedString(string)
        let measured = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        lock.lock()
        if widths.count > 4000 { widths.removeAll() }
        widths[key] = measured
        lock.unlock()
        return measured
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

/// Over the video while a text is picked or open: its box, with handles as on a picked layer in
/// other editors. Drag anywhere to move it. Pull a side to change where its lines wrap; pull the top,
/// the bottom or a corner and the text grows or shrinks to fill the box. A tap away lets go (or
/// picks the text tapped), and a double tap on it opens its sheet.
struct TitleMover: View {
    let model: EditorModel
    let id: UUID
    private static let space = "titleMover"
    @State private var start: CGPoint?
    /// The box (fractions of the frame) when a handle was taken hold of.
    @State private var shaping: CGRect?
    @State private var lastTap = Date.distantPast

    /// Each handle: which way it pulls across (-1 left, 1 right) and down (-1 top, 1 bottom).
    private static let handles: [(x: Int, y: Int)] = [
        (0, -1), (0, 1), (-1, 0), (1, 0),
        (-1, -1), (1, -1), (-1, 1), (1, 1)
    ]

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1), h = max(geo.size.height, 1)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(move(width: w, height: h))
                    .onTapGesture(coordinateSpace: .local) { at in
                        tapped(CGPoint(x: at.x / w, y: at.y / h))
                    }
                if let box = model.titleBox(id) {
                    let frame = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
                    Rectangle()
                        .strokeBorder(Tint.accent, lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                    ForEach(0..<Self.handles.count, id: \.self) { i in
                        let pull = Self.handles[i]
                        handle(pull)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                            .gesture(shape(pull, width: w, height: h))
                            .position(x: frame.midX + CGFloat(pull.x) * frame.width / 2,
                                      y: frame.midY + CGFloat(pull.y) * frame.height / 2)
                            .accessibilityLabel(pull.y == 0 ? "Change where the text wraps" : "Make the text fill a bigger or smaller box")
                    }
                }
            }
        }
        .coordinateSpace(name: Self.space)
    }

    /// A white square at a corner, a white bar on a side.
    private func handle(_ pull: (x: Int, y: Int)) -> some View {
        let corner = pull.x != 0 && pull.y != 0
        return Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().strokeBorder(Tint.accent, lineWidth: 2))
            .frame(width: corner ? 14 : (pull.x == 0 ? 22 : 8), height: corner ? 14 : (pull.y == 0 ? 22 : 8))
    }

    /// Drag anywhere: the text follows the finger.
    private func move(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let clip = model.title(id) else { return }
                if start == nil { start = CGPoint(x: clip.posX, y: clip.posY) }
                guard let start else { return }
                let x = start.x + value.translation.width / width * 100
                let y = start.y + value.translation.height / height * 100
                model.placeTitle(id, x: Double(x), y: Double(y))
            }
            .onEnded { _ in
                start = nil
                model.placeTitleEnded()
            }
    }

    /// A handle: the side across from it stays put while the box grows or shrinks toward the finger.
    private func shape(_ pull: (x: Int, y: Int), width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if shaping == nil { shaping = model.titleBox(id) }
                guard let s = shaping else { return }
                let dx = value.translation.width / width, dy = value.translation.height / height
                var boxW = s.width, boxH = s.height, mx = s.midX, my = s.midY
                if pull.x != 0 {
                    boxW = min(max(s.width + CGFloat(pull.x) * dx, 0.12), 1)
                    mx = s.midX + CGFloat(pull.x) * (boxW - s.width) / 2
                }
                if pull.y != 0 {
                    boxH = min(max(s.height + CGFloat(pull.y) * dy, 0.03), 1)
                    my = s.midY + CGFloat(pull.y) * (boxH - s.height) / 2
                }
                model.shapeTitle(id, width: Double(boxW * 100), height: pull.y != 0 ? Double(boxH * 100) : nil,
                                 x: Double(mx * 100), y: Double(my * 100))
            }
            .onEnded { _ in
                shaping = nil
                model.placeTitleEnded()
            }
    }

    private func tapped(_ point: CGPoint) {
        let inside = model.titleBox(id)?.insetBy(dx: -0.03, dy: -0.02).contains(point) ?? false
        if inside {
            // A double tap on the text opens it.
            let now = Date()
            if now.timeIntervalSince(lastTap) < 0.35 {
                lastTap = .distantPast
                model.openTitle(id)
            } else {
                lastTap = now
            }
        } else if model.titleEditing == nil {
            model.pickTitle(model.titleAt(point))
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
                    note("Drag on the video to move it. Pull the box's sides to change where the lines wrap, or its top or bottom to make the text fill the box. On the timeline, hold the text clip to move it, or drag its ends to make it longer or shorter.")
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
            BoldItalicRow(bold: clip.bold, italic: clip.italic,
                          toggleBold: { model.editTitle(id) { $0.bold.toggle() } },
                          toggleItalic: { model.editTitle(id) { $0.italic.toggle() } })
            chips(LyricCase.allCases, selected: clip.textCase, name: { $0.name }) { textCase in
                model.editTitle(id) { $0.textCase = textCase }
            }
            // Sizing by hand lets go of filling the box (the box is as tall as the lines again).
            FXSlider(value: clip.size, range: 40...TitleLayout.biggest, ends: ("Small", "Big")) { value in
                model.editTitle(id) {
                    $0.size = value
                    $0.boxH = nil
                }
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
