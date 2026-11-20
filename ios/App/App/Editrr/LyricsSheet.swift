import SwiftUI

/// Lyrics words and look, the Lyric Sync way: listen for the words, type or fix them, re-time them
/// to the singing, and style them. Timing word by word happens on the lyrics timeline.
struct LyricsSheet: View {
    let model: EditorModel
    /// Just the look (colors, font, animation and so on), no word editing. Opened from the
    /// lyrics track's Look tool on the edit page.
    var lookOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var typing = false
    @State private var typed = ""
    @State private var addingFont = false
    @State private var naming: NameAsk?
    @State private var presetName = ""
    private var library: FontLibrary { FontLibrary.shared }

    static let colors = ["#ffffff", "#fff36b", "#ff3b8d", "#00e5ff", "#a98bff", "#7dff9a", "#000000"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let line = model.listening {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(line).font(.footnote)
                        Spacer(minLength: 0)
                        Button("Stop") { model.stopListening() }
                            .buttonStyle(GlassButtonStyle(tint: Tint.bad))
                    }
                }
                if model.hasLyrics {
                    if !lookOnly { actions }
                    look
                } else if !lookOnly {
                    start
                }
                note("Undo takes back any change.")
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .fileImporter(isPresented: $addingFont, allowedContentTypes: FontLibrary.types,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let added = library.add(urls)
            if let first = added.first {
                var next = model.lyricStyle
                next.customFont = first.postScript
                model.setLyricStyle(next)
                model.notice = added.count == 1 ? "Added \(first.name)." : "Added \(added.count) fonts."
            } else {
                model.notice = "That file isn't a font this phone can use. Try a .ttf or .otf file."
            }
        }
        .sheet(isPresented: $typing) {
            LyricsTypingSheet(text: $typed) { model.setTypedLyrics(typed) }
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lookOnly ? "Lyrics look" : "Lyrics").font(.title3.weight(.bold))
                Text(model.hasLyrics ? "\(model.lyrics.count) words" : "No words yet")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
            if model.hasLyrics {
                // Lyrics on or off on the video (they stay on the timeline either way).
                Button {
                    change { $0.show.toggle() }
                } label: {
                    Image(systemName: model.lyricStyle.show ? "eye" : "eye.slash").frame(width: 22)
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: model.lyricStyle.show))
                .accessibilityLabel(model.lyricStyle.show ? "Hide the lyrics" : "Show the lyrics")
            }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
            Button("Done") { dismiss() }
                .buttonStyle(GlassButtonStyle())
        }
    }

    // MARK: No words yet

    @ViewBuilder private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.canListen {
                LyricAudioPicker(model: model)
                Button { model.listenForLyrics(retime: false) } label: {
                    Label("Listen to the song", systemImage: "waveform")
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true, big: true))
                .disabled(model.listening != nil)
                note("Writes down every word, timed to the singing, right on your phone. Then fix any misheard word.")
            } else if model.soundtrack == nil {
                note("Lyrics follow the song. This project has no song or video sound to listen to, but you can still type the words.")
            } else {
                note("This phone can't listen for words, but you can type or paste them and line them up on the lyrics timeline.")
            }
            Button {
                typed = ""
                typing = true
            } label: {
                Label("Type or paste the words", systemImage: "text.cursor")
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    // MARK: Words here

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    typed = LyricText.typed(model.lyrics)
                    typing = true
                } label: {
                    Label("Fix words", systemImage: "text.cursor")
                }
                .buttonStyle(GlassButtonStyle())
                Button { model.retimeLyrics() } label: {
                    Label("Re-time to the singing", systemImage: "metronome")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(model.listening != nil || (model.lyricsHeard.isEmpty && !model.canListen))
                if model.canListen {
                    LyricAudioPicker(model: model)
                    Button { model.listenForLyrics(retime: false) } label: {
                        Label("Listen again", systemImage: "waveform")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(model.listening != nil)
                }
                Button { model.clearLyrics() } label: {
                    Label("Clear", systemImage: "xmark")
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.bad))
            }
        }
    }

    // MARK: The look

    /// Presets on top (tap one to use it, or save your own), then everything a look is made of,
    /// one plain section each. Where the words sit and how big: the handles on the video.
    private var look: some View {
        let style = model.lyricStyle
        return VStack(alignment: .leading, spacing: 22) {
            presets(style)

            part("Words", icon: "text.word.spacing", says: "One word at a time, the line building up word by word, or the whole line as it's sung.") {
                chips(LyricMode.allCases, selected: style.mode, name: { $0.name }) { mode in
                    change { $0.mode = mode }
                }
                chips(LyricCase.allCases, selected: style.textCase, name: { $0.name }) { textCase in
                    change { $0.textCase = textCase }
                }
                FXSlider(value: style.tail, range: 0...1.5, ends: ("Leave right away", "Hold longer")) { value in
                    change { $0.tail = value }
                }
            }

            part("Word animation", icon: "sparkles", says: "How each word comes in. Tap one to see it.") {
                chips(LyricEntry.allCases, selected: style.entry, name: { $0.name }) { entry in
                    change { $0.entry = entry }
                    model.previewLyricLook()
                }
            }

            part("Font", icon: "textformat", says: "Hold one of yours to remove it. + adds your own.") {
                fonts(style)
            }

            part("Color", icon: "paintpalette",
                 says: style.rainbow ? "Every letter the next color of the palette, across all the words."
                                     : "The words' color. A single word's own color is in the lyrics tools.") {
                chips(["One color", "Rainbow"], selected: style.rainbow ? "Rainbow" : "One color", name: { $0 }) { pick in
                    change { $0.rainbow = pick == "Rainbow" }
                }
                if style.rainbow {
                    palettes(style)
                } else {
                    swatches(style.color) { hex in change { $0.color = hex } }
                }
            }

            part("Outline", icon: "character", says: "A line around each letter.") {
                FXSlider(value: style.stroke, range: 0...14, ends: ("None", "Thick")) { value in
                    change { $0.stroke = value }
                }
                swatches(style.strokeColor) { hex in change { $0.strokeColor = hex } }
                    .opacity(style.stroke > 0.5 ? 1 : 0.4)
            }

            part("Glow", icon: "sun.max", says: "Light around the words.") {
                FXSlider(value: style.glow, range: 0...1.6, ends: ("None", "Bright")) { value in
                    change { $0.glow = value }
                }
                swatches(style.glowColor) { hex in change { $0.glowColor = hex } }
                    .opacity(style.glow > 0.05 ? 1 : 0.4)
            }

            part("Color split", icon: "circle.lefthalf.filled", says: "Red and blue edges that kick on each word.") {
                FXSlider(value: style.chroma, range: 0...12, ends: ("None", "Strong")) { value in
                    change {
                        $0.chroma = value
                        $0.hitChroma = value * 5
                    }
                }
            }

            part("Shake", icon: "waveform.path", says: "The words jolt as each one hits.") {
                FXSlider(value: style.shake, range: 0...20, ends: ("None", "Big")) { value in
                    change { $0.shake = value }
                }
            }

            note("Where the words sit and how big they are is under the lyrics timeline, since that changes video to video. Presets leave those alone.")
        }
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $presetName)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text(naming?.message ?? "")
        }
    }

    /// The preset tiles: the ready-made looks, yours, and + Save for the look you have now.
    private func presets(_ style: LyricStyle) -> some View {
        let wheel = LyricLook.all(for: style)
        let currentID = wheel.looks[wheel.current].id
        let store = LyricPresetStore.shared
        return VStack(alignment: .leading, spacing: 8) {
            heading("Presets", icon: "square.grid.2x2",
                    says: store.presets.isEmpty
                        ? "Tap one to use it. Change anything below, then Save to keep it as your own."
                        : "Tap one to use it. Hold one of yours to rename, update or delete it.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(LyricStyle.presets.indices, id: \.self) { index in
                        Button { model.useLyricPreset(index) } label: {
                            LyricPresetTile(name: LyricStyle.presets[index].name,
                                            style: style.withPreset(index),
                                            picked: currentID == "b\(index)")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(store.presets) { preset in
                        Button { model.applyLyricLook(preset.style) } label: {
                            LyricPresetTile(name: preset.name, style: preset.style,
                                            picked: currentID == preset.id.uuidString)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(5)
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                presetName = preset.name
                                naming = .rename(preset.id)
                            }
                            Button("Update with this look", systemImage: "arrow.triangle.2.circlepath") {
                                store.update(preset.id, style: model.lyricStyle)
                                model.notice = "Updated \(preset.name)."
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(preset.id)
                            }
                        }
                    }
                    Button {
                        presetName = ""
                        naming = .new
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Tint.accent)
                                .frame(width: 72, height: 72)
                                .overlay(Corner.chip.strokeBorder(Tint.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                            Text("Save look")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Tint.accent)
                                .frame(width: 76)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save this look as a preset")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func fonts(_ style: LyricStyle) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LyricFont.allCases, id: \.self) { font in
                    Button {
                        change {
                            $0.font = font
                            $0.customFont = ""
                        }
                    } label: {
                        Text(font.name)
                            .font(font.postScript.map { Font.custom($0, size: 17) } ?? .system(size: 17, weight: .black))
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.accent,
                                                  selected: style.customFont.isEmpty && style.font == font))
                }
                // Your own fonts. Hold one to remove it.
                ForEach(library.fonts) { entry in
                    Button {
                        change { $0.customFont = entry.postScript }
                    } label: {
                        Text(entry.name).font(.custom(entry.postScript, size: 17))
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: style.customFont == entry.postScript))
                    .contextMenu {
                        Button("Remove font", systemImage: "trash", role: .destructive) {
                            if style.customFont == entry.postScript {
                                change { $0.customFont = "" }
                            }
                            library.remove(entry)
                        }
                    }
                }
                Button { addingFont = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: true))
                .accessibilityLabel("Add your own font")
            }
        }
    }

    private func change(_ edit: (inout LyricStyle) -> Void) {
        var next = model.lyricStyle
        edit(&next)
        model.setLyricStyle(next)
    }

    private func saveName() {
        guard let ask = naming else { return }
        naming = nil
        let store = LyricPresetStore.shared
        switch ask {
        case .new:
            let saved = store.add(name: presetName, style: model.lyricStyle)
            model.notice = "Saved \(saved.name). It's on the look wheel too."
        case .rename(let id):
            store.rename(id, to: presetName)
        }
    }

    /// Naming a new preset, or renaming one of yours.
    enum NameAsk: Equatable {
        case new
        case rename(UUID)

        var title: String {
            switch self {
            case .new: return "Name this look"
            case .rename: return "Rename"
            }
        }

        var message: String {
            switch self {
            case .new: return "Saves the font, case, colors, outline, glow, color split, shake, word animation, hold, and one word or build the line."
            case .rename: return ""
            }
        }
    }

    /// A section of the look: an icon and a name, a line on what it does, then its controls.
    private func part<Content: View>(_ title: String, icon: String, says: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title, icon: icon, says: says)
            content()
        }
    }

    private func heading(_ title: String, icon: String, says: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Text(says)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: Pieces

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
                        .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: item == selected))
                }
            }
        }
    }

    /// Colors to build your own rainbow palette from.
    static let paletteColors = ["#ff3b3b", "#ff9f1a", "#ffe14d", "#7dff9a", "#3ddc6b", "#00e5ff", "#2fb8ff",
                                "#4d7cff", "#a06bff", "#ff3b8d", "#ffb3c7", "#ffffff", "#000000"]

    /// Rainbow palettes: the ready ones, then your own (tap colors in the order you want them).
    @ViewBuilder private func palettes(_ style: LyricStyle) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LyricStyle.palettes.indices, id: \.self) { i in
                    let ready = LyricStyle.palettes[i]
                    let on = style.palette == ready.colors
                    Button { change { $0.palette = ready.colors } } label: {
                        VStack(spacing: 4) {
                            strip(ready.colors).frame(width: 72, height: 14)
                            Text(ready.name).font(.caption2.weight(.semibold))
                        }
                        .padding(6)
                        .background(Tint.surface2, in: Corner.chip)
                        .overlay(Corner.chip.strokeBorder(on ? Tint.accent : .clear, lineWidth: 2))
                        .foregroundStyle(on ? Tint.accent : .white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your own: tap colors in order").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button("Start over") { change { $0.palette = [] } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Tint.accent)
                    .disabled(style.palette.isEmpty)
                    .opacity(style.palette.isEmpty ? 0.4 : 1)
            }
            if style.palette.isEmpty {
                Text("No colors yet: the words use their one color until you add some.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                strip(style.palette).frame(height: 14)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.paletteColors, id: \.self) { hex in
                        let at = style.palette.firstIndex(of: hex)
                        Button {
                            change { s in
                                if let at = s.palette.firstIndex(of: hex) {
                                    s.palette.remove(at: at)
                                } else if s.palette.count < 8 {
                                    s.palette.append(hex)
                                }
                            }
                        } label: {
                            Corner.chip
                                .fill(Self.swatch(hex))
                                .frame(width: 32, height: 32)
                                .overlay(Corner.chip.strokeBorder(.white.opacity(at != nil ? 0.95 : 0.3),
                                                               lineWidth: at != nil ? 3 : 1))
                                .overlay {
                                    // Its place in the palette.
                                    if let at {
                                        Text("\(at + 1)")
                                            .font(.caption2.weight(.heavy))
                                            .foregroundStyle(hex == "#000000" ? Color.white : Color.black)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(at != nil ? "Take this color out" : "Add this color")
                    }
                }
            }
        }
    }

    /// A palette's colors side by side.
    private func strip(_ colors: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { i in
                Rectangle().fill(Self.swatch(colors[i]))
            }
        }
    }

    private func swatches(_ selected: String, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(Self.colors, id: \.self) { hex in
                Button { pick(hex) } label: {
                    Corner.chip
                        .fill(Self.swatch(hex))
                        .frame(width: 32, height: 32)
                        .overlay(Corner.chip.strokeBorder(.white.opacity(selected.lowercased() == hex ? 0.95 : 0.3),
                                                       lineWidth: selected.lowercased() == hex ? 3 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func swatch(_ hex: String) -> Color {
        guard let c = LyricColor.rgb(hex) else { return .white }
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}

/// Typing or pasting the words, one lyric line per line.
struct LyricsTypingSheet: View {
    @Binding var text: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Words").font(.title3.weight(.bold))
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                Button("Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
            }
            Text("One lyric line per line. Words you don't change keep their timing.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(.body)
                .padding(10)
                .background(Tint.surface2, in: Corner.card)
        }
        .padding(20)
        .foregroundStyle(.white)
    }
}

/// Which sound Lyrics listens to for the words, when there's both a song (the performance's, or
/// one added from creatrr or Files) and the videos' own sound. Shows nothing when there's one.
struct LyricAudioPicker: View {
    let model: EditorModel

    var body: some View {
        let choices = model.lyricAudioChoices
        if choices.count > 1 {
            HStack(spacing: 6) {
                ForEach(choices, id: \.self) { choice in
                    let on = model.lyricAudio == choice
                    Button { model.lyricAudio = choice } label: {
                        Label(choice.name, systemImage: choice == .song ? "music.note" : "video")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Listen to")
        }
    }
}
