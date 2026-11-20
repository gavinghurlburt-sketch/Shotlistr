import SwiftUI

/// The lyrics timeline, shown in place of the video timeline: the song on top and the words under
/// it as blocks, on two rows so short words next to each other stay readable. It works like the
/// video timeline: swipe to move through the song, pinch to zoom, hold a word to move it. Tap a
/// word to pick it; the picked word's ends can then be dragged to stretch it.
struct LyricsLane: View {
    let model: EditorModel

    @State private var dragStartTime: Double = 0
    @State private var zoomStart: Double?
    @State private var rulerHeld = false

    static let rowHeight: CGFloat = 38
    static let wordsTop: CGFloat = LaneMetrics.songHeight
    static var height: CGFloat { LaneMetrics.rulerHeight + LaneMetrics.songHeight + rowHeight * 2 + 8 + LaneMetrics.chrome }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            VStack(spacing: 0) {
                Color.clear.frame(height: LaneMetrics.topSpace)
                Ruler(time: model.time, pixelsPerSecond: model.lyricPixelsPerSecond, duration: model.duration)
                    .frame(width: width, height: LaneMetrics.rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(rulerGesture)
                lane
                    .frame(width: width, height: max(1, geo.size.height - LaneMetrics.rulerHeight - LaneMetrics.topSpace))
                    .overlay { touches(width: width) }
                    .overlay {
                        if model.lyrics.isEmpty {
                            Text(model.listening ?? "No words yet")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.top, LaneMetrics.songHeight)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: width / 2 - 1)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(Corner.chip)
        .padding(LaneMetrics.inset)
        .background(LaneMetrics.backdrop)   // same as the edit timeline
        .clipShape(Corner.card)
    }

    // MARK: Drawing

    private var lane: some View {
        let time = model.time
        let pps = model.lyricPixelsPerSecond
        let duration = model.duration
        let words = model.lyrics
        let soundtrack = model.soundtrack
        let picked = model.lyricSelected
        let now = model.lyricNow
        let drag = model.lyricDrag
        let rowHeight = Self.rowHeight
        let top = Self.wordsTop

        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }

            // The song, so words can be lined up with what's heard.
            let songBand = CGRect(x: x(0), y: 4, width: CGFloat(duration * pps), height: LaneMetrics.songHeight - 8)
            context.fill(Path(songBand), with: .color(soundtrack == nil ? Color.white.opacity(0.06) : SongTint.color))
            if let sound = soundtrack?.sound {
                let shift = soundtrack?.shift ?? 0
                var path = Path()
                var px = max(songBand.minX, 0)
                let end = min(songBand.maxX, size.width)
                while px < end {
                    let timeline = time + Double(px - middle) / pps
                    let frame = Int(((timeline - shift) - sound.start) * SoundPrint.rate)
                    if frame >= 0, frame < sound.loudness.count {
                        let height = max(1, CGFloat(sound.loudness[frame]) * (songBand.height - 4))
                        path.addRect(CGRect(x: px, y: songBand.midY - height / 2, width: 2, height: height))
                    }
                    px += 3
                }
                context.fill(path, with: .color(SongTint.wave))
            }

            // Where each lyric line ends: a faint line down through both rows.
            for (index, word) in words.enumerated() where word.br && index + 1 < words.count {
                let lineX = x((word.end + words[index + 1].start) / 2)
                guard lineX > -4, lineX < size.width + 4 else { continue }
                context.fill(Path(CGRect(x: lineX - 0.5, y: top + 2, width: 1, height: rowHeight * 2)),
                             with: .color(.white.opacity(0.3)))
            }

            // The words. The picked or moving one is drawn last, on top.
            let active = drag?.index ?? picked
            let order = words.indices.filter { $0 != active } + (active.map { [$0] } ?? [])
            for index in order where words.indices.contains(index) {
                let word = words[index]
                let startX = x(word.start), endX = x(word.end)
                guard endX > -60, startX < size.width + 60 else { continue }
                let row = CGFloat(index % 2)
                let lifted = drag?.index == index && drag?.grip == .move
                var block = CGRect(x: startX, y: top + 4 + row * rowHeight, width: max(4, endX - startX),
                                   height: rowHeight - 8)
                if lifted { block = block.insetBy(dx: -2, dy: -3).offsetBy(dx: 0, dy: -2) }
                let shape = Path(block)
                let isPicked = active == index
                let sung = now == index
                // Like the video clips: color fading left to right, with a solid stripe where the
                // word starts. The word being sung lights up yellow.
                let fade: [Color] = sung || lifted
                    ? [Tint.accent.opacity(0.95), Tint.accent.opacity(0.6)]
                    : [Color.white.opacity(0.20), Color.white.opacity(0.06)]
                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: fade),
                    startPoint: CGPoint(x: block.minX, y: block.midY),
                    endPoint: CGPoint(x: max(block.maxX, block.minX + 1), y: block.midY))
                if lifted {
                    context.drawLayer { raised in
                        raised.addFilter(.shadow(color: .black.opacity(0.75), radius: 8, x: 0, y: 5))
                        raised.fill(shape, with: gradient)
                    }
                } else {
                    context.fill(shape, with: gradient)
                }
                context.fill(Path(CGRect(x: block.minX, y: block.minY, width: min(3, block.width), height: block.height)),
                             with: .color(sung || lifted ? Color.black.opacity(0.35) : Tint.accent))
                if isPicked {
                    context.stroke(shape, with: .color(.white), lineWidth: 2)
                }
                // The word stays inside its box: anything past the end is cut off.
                context.drawLayer { inside in
                    inside.clip(to: Path(block.insetBy(dx: 1, dy: 0)))
                    inside.draw(Text(word.text).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(sung || lifted ? Color.black : Color.white),
                                at: CGPoint(x: block.minX + 7, y: block.midY), anchor: .leading)
                }
                if word.br {
                    context.draw(Text(Image(systemName: "return")).font(.caption2.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.7)),
                                 at: CGPoint(x: block.maxX + 3, y: block.minY + 1), anchor: .topLeading)
                }
                // Grips on the picked word: drag one to stretch the word.
                if isPicked && !lifted {
                    let grips: [(CGFloat, EditorModel.Grip)] = [(block.minX + 3, .trimStart), (block.maxX - 7, .trimEnd)]
                    for (edgeX, grip) in grips {
                        let on = drag?.grip == grip
                        let handle = CGRect(x: edgeX, y: block.midY - (on ? 13 : 9), width: 4, height: on ? 26 : 18)
                        context.fill(Path(handle), with: .color(.white.opacity(on ? 1 : 0.8)))
                    }
                }
            }

            // Shade what's before the start and after the end.
            let shade = Color.black.opacity(0.4)
            if x(0) > 0 {
                context.fill(Path(CGRect(x: 0, y: 0, width: x(0), height: size.height)), with: .color(shade))
            }
            if x(duration) < size.width {
                context.fill(Path(CGRect(x: x(duration), y: 0, width: size.width - x(duration), height: size.height)),
                             with: .color(shade))
            }
        }
    }

    // MARK: Finding the word under a finger

    private func seconds(atX px: CGFloat, width: CGFloat) -> Double {
        model.time + Double(px - width / 2) / model.lyricPixelsPerSecond
    }

    /// The word under a point (on its own row), with a little slop for short words.
    private func word(at point: CGPoint, width: CGFloat, slop: CGFloat = 8) -> Int? {
        let y = point.y - Self.wordsTop
        guard y >= 0 else { return nil }
        let row = min(1, Int(y / Self.rowHeight))
        let middle = width / 2
        let pps = model.lyricPixelsPerSecond
        var best: (index: Int, distance: CGFloat)?
        for (index, word) in model.lyrics.enumerated() where index % 2 == row {
            let start = middle + CGFloat((word.start - model.time) * pps)
            let end = middle + CGFloat((word.end - model.time) * pps)
            guard point.x >= start - slop, point.x <= end + slop else { continue }
            let distance = point.x < start ? start - point.x : (point.x > end ? point.x - end : 0)
            if distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    /// An end of the picked word under a point, for stretching it.
    private func edge(at point: CGPoint, width: CGFloat) -> EditorModel.Grip? {
        guard let index = model.lyricSelected, model.lyrics.indices.contains(index) else { return nil }
        let y = point.y - Self.wordsTop
        guard y >= 0, min(1, Int(y / Self.rowHeight)) == index % 2 else { return nil }
        let word = model.lyrics[index]
        let middle = width / 2
        let pps = model.lyricPixelsPerSecond
        let start = middle + CGFloat((word.start - model.time) * pps)
        let end = middle + CGFloat((word.end - model.time) * pps)
        let reach = min(26, max(12, (end - start) / 2))
        let toStart = abs(point.x - start), toEnd = abs(point.x - end)
        guard min(toStart, toEnd) <= reach else { return nil }
        return toStart <= toEnd ? .trimStart : .trimEnd
    }

    // MARK: Gestures (the same touch handling as the video timeline)

    private func touches(width: CGFloat) -> some View {
        LaneTouches(
            lift: { point in
                if let grip = edge(at: point, width: width), let index = model.lyricSelected {
                    model.beginLyricDrag(index, grip: grip)
                    return model.lyricDrag != nil
                }
                guard let index = word(at: point, width: width) else { return false }
                model.beginLyricDrag(index, grip: .move)
                return model.lyricDrag != nil
            },
            liftMoved: { travel in
                model.dragLyric(by: Double(travel) / model.lyricPixelsPerSecond)
            },
            trimBegan: { point in
                guard let grip = edge(at: point, width: width), let index = model.lyricSelected else { return false }
                model.beginLyricDrag(index, grip: grip)
                return model.lyricDrag != nil
            },
            dropped: { model.endLyricDrag() },
            swipeBegan: {
                dragStartTime = model.time
                model.beginScrub()
            },
            swipeMoved: { travel in
                model.scrub(to: dragStartTime - Double(travel) / model.lyricPixelsPerSecond)
            },
            swipeEnded: { model.endScrub() },
            tapped: { point in
                model.pickLyric(word(at: point, width: width, slop: 4))
            },
            pinchBegan: { zoomStart = model.lyricPixelsPerSecond },
            pinched: { scale in
                let start = zoomStart ?? model.lyricPixelsPerSecond
                model.lyricPixelsPerSecond = min(800, max(20, start * Double(scale)))
            },
            pinchEnded: { zoomStart = nil }
        )
    }

    private var rulerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !rulerHeld {
                    rulerHeld = true
                    dragStartTime = model.time
                    model.beginScrub()
                }
                model.scrub(to: dragStartTime - Double(value.translation.width) / model.lyricPixelsPerSecond)
            }
            .onEnded { _ in
                rulerHeld = false
                model.endScrub()
            }
    }
}

/// The lyrics timeline's tools, in place of the editing toolbar.
struct LyricsToolbar: View {
    let model: EditorModel
    let openLook: () -> Void
    @State private var typing: TypingTarget?
    @State private var text = ""
    /// The word whose color picker is open.
    @State private var coloring: Int?

    private enum TypingTarget: Identifiable {
        case add, change(Int)
        var id: String {
            switch self {
            case .add: return "add"
            case .change(let index): return "change\(index)"
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.lyrics.isEmpty {
                    if model.canListen {
                        LyricAudioPicker(model: model)
                        Button { model.listenForLyrics(retime: false) } label: {
                            Label("Listen to the song", systemImage: "waveform")
                        }
                        .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
                        .disabled(model.listening != nil)
                    }
                    Button(action: openLook) {
                        Label("Type the words", systemImage: "text.cursor")
                    }
                    .buttonStyle(GlassButtonStyle())
                } else if let index = model.lyricSelected, model.lyrics.indices.contains(index) {
                    picked(index)
                } else {
                    Button { begin(.add) } label: {
                        Label("Add word", systemImage: "plus")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
                    Button(action: openLook) {
                        Label("Words & look", systemImage: "textformat")
                    }
                    .buttonStyle(GlassButtonStyle())
                    wordColorButton
                }
            }
        }
        .labelStyle(.iconOnly)
        .lineLimit(1)
        .alert(alertTitle, isPresented: Binding(get: { typing != nil }, set: { if !$0 { typing = nil } })) {
            TextField("Word", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { typing = nil }
            Button("Save") { save() }
        } message: {
            Text(alertMessage)
        }
    }

    /// One word's own color: the picked word, else the one at the playhead.
    private var wordColorButton: some View {
        let target = model.lyricColorTarget
        let own = target.flatMap { model.lyrics.indices.contains($0) ? model.lyrics[$0].color : nil }
        return Button { coloring = target } label: {
            Label("Word color", systemImage: own == nil ? "paintbrush.pointed" : "paintbrush.pointed.fill")
                .foregroundStyle(own.map { LyricsSheet.swatch($0) } ?? Color.white.opacity(0.9))
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1)
        .popover(isPresented: Binding(get: { coloring != nil }, set: { if !$0 { coloring = nil } })) {
            if let index = coloring, model.lyrics.indices.contains(index) {
                wordColors(index)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// The color picker for one word: the look's colors, or back to the look's own color.
    private func wordColors(_ index: Int) -> some View {
        let current = model.lyrics[index].color
        return VStack(alignment: .leading, spacing: 12) {
            Text("Color for \u{201C}\(model.lyrics[index].text)\u{201D}")
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            HStack(spacing: 8) {
                ForEach(LyricsSheet.colors, id: \.self) { hex in
                    Button { model.setLyricColor(index, hex) } label: {
                        Corner.chip
                            .fill(LyricsSheet.swatch(hex))
                            .frame(width: 30, height: 30)
                            .overlay(Corner.chip.strokeBorder(.white.opacity(current == hex ? 0.95 : 0.3),
                                                           lineWidth: current == hex ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                model.setLyricColor(index, nil)
            } label: {
                Label("Same as the look", systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(current == nil ? Color.white.opacity(0.4) : Tint.accent)
            .disabled(current == nil)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white)
        .padding(16)
    }

    @ViewBuilder private func picked(_ index: Int) -> some View {
        Button { begin(.change(index)) } label: {
            Label("Change", systemImage: "pencil")
        }
        .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
        wordColorButton
        Button { model.setLyricEdge(index, start: true) } label: {
            Label("Start here", systemImage: "arrow.right.to.line")
        }
        .buttonStyle(GlassButtonStyle())
        Button { model.setLyricEdge(index, start: false) } label: {
            Label("End here", systemImage: "arrow.left.to.line")
        }
        .buttonStyle(GlassButtonStyle())
        if model.canSplitLyric(index) {
            Button { model.splitLyric(index) } label: {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(GlassButtonStyle())
        }
        if index + 1 < model.lyrics.count {
            Button { model.mergeLyric(index) } label: {
                Label("Join next", systemImage: "link")
            }
            .buttonStyle(GlassButtonStyle())
            Button { model.toggleLyricBreak(index) } label: {
                Label(model.lyrics[index].br ? "Join lines" : "New line", systemImage: "return")
            }
            .buttonStyle(GlassButtonStyle())
        }
        Button { model.deleteLyric(index) } label: {
            Label("Delete", systemImage: "trash")
        }
        .buttonStyle(GlassButtonStyle(tint: Tint.bad))
    }

    private var changing: Bool {
        if case .some(.change) = typing { return true }
        return false
    }

    private var alertTitle: String { changing ? "Change word" : "Add word" }

    private var alertMessage: String {
        changing ? "Spaces make more than one word." : "Goes in at the playhead. Spaces make more than one word."
    }

    private func begin(_ target: TypingTarget) {
        switch target {
        case .add: text = ""
        case .change(let index): text = model.lyrics.indices.contains(index) ? model.lyrics[index].text : ""
        }
        typing = target
    }

    private func save() {
        switch typing {
        case .some(.add): model.addLyric(text)
        case .some(.change(let index)): model.setLyricText(index, text)
        case .none: break
        }
        typing = nil
    }
}
