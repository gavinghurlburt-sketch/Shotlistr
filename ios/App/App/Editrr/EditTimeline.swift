import SwiftUI

/// Sizes for the edit page's timeline.
enum EditMetrics {
    /// The icon spot on the left of each track.
    static let sideWidth: CGFloat = 40
    static let videoHeight: CGFloat = 58
    static let audioHeight: CGFloat = 38
    static let gap: CGFloat = 6
    /// The lyrics row (only when the project has lyrics).
    static let lyricsHeight: CGFloat = 26
    /// Each overlay's row, above the video track.
    static let overlayHeight: CGFloat = 32
    static func height(lyrics: Bool, overlays: Int = 0, texts: Int = 0) -> CGFloat {
        LaneMetrics.rulerHeight + videoHeight + gap + audioHeight + 6 + LaneMetrics.chrome
            + (lyrics ? gap + lyricsHeight : 0)
            + CGFloat(overlays + texts) * (overlayHeight + gap)
    }
}

/// The edit page, styled after Edits: one video track and the sound under it, each with a dark
/// stripe on the left with its icon. It shows only the clip: a performance's In to Out as one clip
/// (its ends move In and Out), or, editing a video, the videos back to back (their ends trim them,
/// and the ones after close up). The ruler counts from the clip's start.
struct EditTimeline: View {
    let model: EditorModel
    /// The + at the end of the video track: adds a photo or video on the same track, after everything.
    var onAdd: (() -> Void)?

    @State private var dragStartTime: Double = 0
    @State private var zoomStart: Double?
    @State private var rulerHeld = false
    /// When the performance clip was last tapped, to catch a double tap.
    @State private var lastClipTap = Date.distantPast

    /// Which row a touch is on.
    private enum Row: Equatable {
        case video, sound, lyrics
        case overlay(UUID)
        /// A text lane (T1 is 0).
        case text(Int)

        var overlayID: UUID? {
            if case .overlay(let id) = self { return id }
            return nil
        }

        var textLane: Int? {
            if case .text(let lane) = self { return lane }
            return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let laneWidth = max(geo.size.width - EditMetrics.sideWidth, 1)
            VStack(spacing: 0) {
                Color.clear.frame(height: LaneMetrics.topSpace)
                HStack(spacing: 0) {
                    Color.clear.frame(width: EditMetrics.sideWidth)
                    Ruler(time: model.time, pixelsPerSecond: model.pixelsPerSecond, duration: model.loopEnd,
                          origin: model.loopStart)
                        .frame(width: laneWidth)
                        .contentShape(Rectangle())
                        .gesture(rulerGesture)
                }
                .frame(height: LaneMetrics.rulerHeight)

                // Text, a row for each text lane (T1 on top), above everything: it's drawn on top.
                ForEach(0..<model.textLaneCount, id: \.self) { lane in
                    HStack(spacing: 0) {
                        textSide(lane)
                        textRow(lane)
                            .frame(width: laneWidth, height: EditMetrics.overlayHeight)
                            .clipped()
                            .overlay { touches(width: laneWidth, row: .text(lane)) }
                    }
                    .frame(height: EditMetrics.overlayHeight)
                    .background(LaneMetrics.row)
                    Color.clear.frame(height: EditMetrics.gap)
                }

                // Overlays, the newest on top, each on its own row above the video.
                ForEach(model.onTop.reversed()) { overlay in
                    HStack(spacing: 0) {
                        side(icon: overlay.isVideo ? "video" : "photo", name: "Overlay", hidden: overlay.hidden) {
                            model.toggleOverlayHidden(overlay.id)
                        }
                        overlayRow(overlay)
                            .frame(width: laneWidth, height: EditMetrics.overlayHeight)
                            .clipped()
                            .opacity(overlay.hidden ? 0.35 : 1)
                            .overlay { touches(width: laneWidth, row: .overlay(overlay.id)) }
                    }
                    .frame(height: EditMetrics.overlayHeight)
                    .background(LaneMetrics.row)
                    Color.clear.frame(height: EditMetrics.gap)
                }

                HStack(spacing: 0) {
                    side(icon: "film", name: "Video", hidden: model.videoHidden) { model.videoHidden.toggle() }
                    pieces
                        .frame(width: laneWidth, height: EditMetrics.videoHeight)
                        .clipped()
                        .opacity(model.videoHidden ? 0.35 : 1)
                        .overlay { touches(width: laneWidth, row: .video) }
                        .overlay(alignment: .leading) { addButton(laneWidth: laneWidth) }
                }
                .frame(height: EditMetrics.videoHeight)
                .background(LaneMetrics.row)

                Color.clear.frame(height: EditMetrics.gap)

                HStack(spacing: 0) {
                    side(icon: "waveform", name: model.kind == .video ? "Sound" : "Song",
                         hidden: model.soundMuted) { model.soundMuted.toggle() }
                    songTrack
                        .frame(width: laneWidth, height: EditMetrics.audioHeight)
                        .clipped()
                        .opacity(model.soundMuted ? 0.35 : 1)
                        .overlay { touches(width: laneWidth, row: .sound) }
                }
                .frame(height: EditMetrics.audioHeight)
                .background(LaneMetrics.row)

                if model.hasLyrics {
                    Color.clear.frame(height: EditMetrics.gap)
                    HStack(spacing: 0) {
                        side(icon: "quote.opening", name: "Lyrics", hidden: !model.lyricStyle.show) {
                            model.toggleLyricsShown()
                        }
                        lyricsTrack
                            .frame(width: laneWidth, height: EditMetrics.lyricsHeight)
                            .clipped()
                            .overlay { touches(width: laneWidth, row: .lyrics) }
                    }
                    .frame(height: EditMetrics.lyricsHeight)
                    .background(LaneMetrics.row)
                }

                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) {
                // The playhead.
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: EditMetrics.sideWidth + laneWidth / 2 - 1)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(Corner.chip)
        .padding(.vertical, LaneMetrics.inset)
        .background(LaneMetrics.backdrop)
        .clipShape(Corner.card)
        // Frames for the pieces (made once per video, in the background).
        .task(id: model.layers.count) { model.makeFilmstrips() }
    }

    /// A track's left edge: its icon on the row's grey. A tap shows or hides the track; hidden, the
    /// icon is dimmed with a line through it.
    private func side(icon: String, name: String, hidden: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(hidden ? 0.3 : 0.75))
                .overlay {
                    if hidden {
                        Rectangle()
                            .fill(Tint.warn)
                            .frame(width: 24, height: 2)
                            .rotationEffect(.degrees(-45))
                    }
                }
                .frame(width: EditMetrics.sideWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hidden ? "Show \(name.lowercased())" : "Hide \(name.lowercased())")
    }

    /// A white + square at the end of the video track (held inside the track when the end is off
    /// screen), like Edits: it adds a photo or video on the same track, after everything.
    @ViewBuilder private func addButton(laneWidth: CGFloat) -> some View {
        if let onAdd, model.canAddToEnd {
            let end = model.loopEnd
            let side: CGFloat = 30
            let endX = laneWidth / 2 + CGFloat((end - model.time) * model.pixelsPerSecond)
            let x = min(max(endX - side / 2, 4), laneWidth - side - 4)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: side, height: side)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: x)
            .accessibilityLabel("Add a photo or video at the end")
        }
    }

    /// A text row's left edge: the T and its lane number, in the text color.
    private func textSide(_ lane: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "textformat").font(.system(size: 13, weight: .semibold))
            Text("\(lane + 1)").font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(TitleTint.color)
        .frame(width: EditMetrics.sideWidth)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text \(lane + 1)")
    }

    // MARK: Drawing

    /// The clips on the video track: the performance (In to Out) as one, or each video.
    private struct Clip {
        let id: Int
        let start: Double
        let end: Double
    }

    private var clips: [Clip] {
        if model.kind == .performance {
            return [Clip(id: 0, start: model.loopStart, end: model.performanceEnd)]
        }
        return model.playOrder.map { index in
            Clip(id: index, start: model.layers[index].clipStart, end: model.layers[index].clipEnd)
        }
    }

    /// The video track: each clip shows its frames (a performance shows whichever video is on
    /// screen at each moment). The picked clip gets a yellow outline, yellow ends and its length.
    private var pieces: some View {
        let time = model.time
        let pps = model.pixelsPerSecond
        let layers = model.layers
        let segments = model.segments
        let performance = model.kind == .performance
        let clips = self.clips
        let picked = model.editPick
        let draggingEnd: EditorModel.Grip? = performance ? model.draggingRange
            : (model.dragging != nil && model.dragging == picked ? model.grip : nil)
        let filmstrips = model.filmstrips
        let trackKeys = performance ? model.trackKeys : []
        // Clips added before or after a split, where the splits are, and the picked piece.
        let cutaways = performance ? model.cutaways.filter { !$0.hidden } : []
        let thumbs = model.overlayThumbs
        let overlayPick = model.overlayPick
        let cutawayDragged = model.draggingOverlay != nil && model.draggingOverlay == overlayPick
        let splitTimes = performance ? model.performancePieces.dropFirst().map { $0.start } : []
        let pickedPiece = model.pickedPiece
        let loopStart = model.loopStart, performanceEnd = model.performanceEnd

        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }
            let top: CGFloat = 2
            let height = size.height - 4

            /// One video's frames across a stretch of the timeline.
            func frames(of layer: Layer, in rect: CGRect, into context: inout GraphicsContext) {
                let strip = filmstrips[ObjectIdentifier(layer.asset)]
                let still = layer.thumbnail?.cgImage
                guard strip != nil || still != nil else {
                    context.fill(Path(rect), with: .color(LayerTint.color(layer).opacity(0.35)))
                    return
                }
                let aspect = min(1.8, max(0.4, layer.displaySize.width / max(layer.displaySize.height, 1)))
                let tile = max(8, height * aspect)
                let skip = max(0, floor(-rect.minX / tile) - 1)
                var tileX = rect.minX + skip * tile
                let stop = min(rect.maxX, size.width)
                while tileX < stop {
                    let at = time + Double(tileX + tile / 2 - middle) / pps
                    if let image = strip?.frame(at: at - layer.offset) ?? still {
                        context.draw(Image(decorative: image, scale: 1),
                                     in: CGRect(x: tileX, y: top, width: tile, height: height))
                    }
                    tileX += tile
                }
            }

            for clip in clips {
                let left = x(clip.start), right = x(clip.end)
                guard right > -2, left < size.width + 2, right - left > 0.5 else { continue }
                // A hair of space between clips, as in Edits.
                let rect = CGRect(x: left + (performance ? 0 : 1), y: top,
                                  width: max(0.5, right - left - (performance ? 0 : 2)), height: height)
                // creatrr's soft corners on each clip.
                let shape = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 2, rect.height / 2), style: .continuous)
                context.drawLayer { inside in
                    inside.clip(to: shape)
                    inside.fill(shape, with: .color(Tint.surface3))
                    if performance {
                        // Whichever video shows at each moment, as it plays.
                        for segment in segments {
                            guard let index = segment.layer, layers.indices.contains(index) else { continue }
                            let from = max(x(segment.start), rect.minX), to = min(x(segment.end), rect.maxX)
                            guard to > from else { continue }
                            var piece = inside
                            let stretch = CGRect(x: from, y: top, width: to - from, height: height)
                            piece.clip(to: Path(stretch))
                            frames(of: layers[index], in: stretch, into: &piece)
                        }
                    } else if layers.indices.contains(clip.id) {
                        frames(of: layers[clip.id], in: rect, into: &inside)
                    }
                }
                if performance {
                    // A small label, so it reads as the performance.
                    let label = context.resolve(Text("\(Image(systemName: "music.note.list")) Performance")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white))
                    let textSize = label.measure(in: CGSize(width: 200, height: 40))
                    let spot = CGRect(x: max(rect.minX, 0) + (picked == clip.id ? 17 : 4), y: rect.maxY - textSize.height - 6,
                                      width: textSize.width + 8, height: textSize.height + 2)
                    if spot.maxX < rect.maxX - 4 {
                        context.fill(Path(spot), with: .color(.black.opacity(0.6)))
                        context.draw(label, at: CGPoint(x: spot.midX, y: spot.midY))
                    }
                }
            }

            // Splits: a dark gap through the performance.
            for split in splitTimes {
                let splitX = x(split)
                guard splitX > -2, splitX < size.width + 2 else { continue }
                context.fill(Path(CGRect(x: splitX - 1, y: top, width: 2, height: height)), with: .color(.black))
            }

            // Clips added before or after a split: on the track, over the performance.
            for clip in cutaways {
                let left = x(clip.start), right = x(clip.end)
                guard right > -2, left < size.width + 2, right - left > 0.5 else { continue }
                let rect = CGRect(x: left + 1, y: top, width: max(1, right - left - 2), height: height)
                context.fill(Path(CGRect(x: left - 1, y: top, width: right - left + 2, height: height)),
                             with: .color(.black))
                context.drawLayer { inside in
                    inside.clip(to: Path(rect))
                    inside.fill(Path(rect), with: .color(Color(white: 0.2)))
                    if let thumb = thumbs[clip.id]?.cgImage {
                        let aspect = min(1.8, max(0.4, CGFloat(thumb.width) / max(CGFloat(thumb.height), 1)))
                        let tile = max(8, rect.height * aspect)
                        var tileX = rect.minX + max(0, floor(-rect.minX / tile) - 1) * tile
                        while tileX < min(rect.maxX, size.width) {
                            inside.draw(Image(decorative: thumb, scale: 1),
                                        in: CGRect(x: tileX, y: rect.minY, width: tile, height: rect.height))
                            tileX += tile
                        }
                    }
                }
            }

            // The whole performance's keyframes (and its added clips'): white diamonds along the top.
            let clipKeys = cutaways.flatMap { clip in (clip.keys ?? []).map { clip.keyOrigin + $0.time } }
            for keyTime in trackKeys.map(\.time) + clipKeys {
                let keyX = x(keyTime)
                guard keyX > -6, keyX < size.width + 6 else { continue }
                let side: CGFloat = 9
                let mid = top + 9
                var diamond = Path()
                diamond.move(to: CGPoint(x: keyX, y: mid - side / 2))
                diamond.addLine(to: CGPoint(x: keyX + side / 2, y: mid))
                diamond.addLine(to: CGPoint(x: keyX, y: mid + side / 2))
                diamond.addLine(to: CGPoint(x: keyX - side / 2, y: mid))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(.white))
                context.stroke(diamond, with: .color(.black.opacity(0.6)), lineWidth: 1)
            }

            // The picked clip: a yellow outline, yellow ends and its length. A piece of the split
            // performance has ends only where they're In and Out.
            var outline: (start: Double, end: Double, grips: [EditorModel.Grip])?
            if let pick = overlayPick, let clip = cutaways.first(where: { $0.id == pick }) {
                outline = (clip.start, clip.end, [.trimStart, .trimEnd])
            } else if performance {
                if let piece = pickedPiece {
                    var grips: [EditorModel.Grip] = []
                    if abs(piece.start - loopStart) < 0.001 { grips.append(.trimStart) }
                    if abs(piece.end - performanceEnd) < 0.001 { grips.append(.trimEnd) }
                    outline = (piece.start, piece.end, grips)
                }
            } else if let picked, let clip = clips.first(where: { $0.id == picked }) {
                outline = (clip.start, clip.end, [.trimStart, .trimEnd])
            }
            if let clip = outline {
                let rect = CGRect(x: x(clip.start), y: top, width: max(2, x(clip.end) - x(clip.start)), height: height)
                context.stroke(Path(rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Tint.accent), lineWidth: 3)
                for which in clip.grips {
                    let width: CGFloat = draggingEnd == which || cutawayDragged ? 16 : 13
                    let handle = CGRect(x: which == .trimStart ? rect.minX : rect.maxX - width, y: rect.minY,
                                        width: width, height: rect.height)
                    context.fill(Path(handle), with: .color(Tint.accent))
                    context.draw(Text(Image(systemName: which == .trimStart ? "chevron.compact.left" : "chevron.compact.right"))
                                    .font(.system(size: 15, weight: .heavy)).foregroundStyle(.black.opacity(0.8)),
                                 at: CGPoint(x: handle.midX, y: handle.midY))
                }
                if rect.width > 70 {
                    let length = context.resolve(Text(String(format: "%.1fs", clip.end - clip.start))
                        .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white))
                    let textSize = length.measure(in: CGSize(width: 200, height: 40))
                    let badge = CGRect(x: max(rect.minX + 17, 4), y: rect.minY + 4,
                                       width: textSize.width + 8, height: textSize.height + 2)
                    if badge.maxX < rect.maxX - 14 {
                        context.fill(Path(badge), with: .color(.black.opacity(0.65)))
                        context.draw(length, at: CGPoint(x: badge.midX, y: badge.midY))
                    }
                }
            }
        }
    }

    /// The sound: a performance's song from In to Out, or each video's own sound under it. Grey
    /// bars with their waveforms.
    private var songTrack: some View {
        let time = model.time
        let pps = model.pixelsPerSecond
        let performance = model.kind == .performance
        let soundtrack = model.soundtrack
        let layers = model.layers
        // The song stops at its own end, even when clips after the performance run past it.
        let start = model.loopStart, end = min(model.loopEnd, model.duration)

        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }

            func bar(from: Double, to: Double, sound: SoundPrint?, shift: Double, name: String?, gap: CGFloat) {
                let band = CGRect(x: x(from) + gap, y: 2, width: max(0.5, x(to) - x(from) - gap * 2),
                                  height: size.height - 4)
                guard band.maxX > 0, band.minX < size.width else { return }
                context.fill(Path(band), with: .color(SongTint.color))
                if let sound {
                    var path = Path()
                    var px = max(band.minX, 0)
                    let stop = min(band.maxX, size.width)
                    while px < stop {
                        let at = time + Double(px - middle) / pps
                        let frame = Int(((at - shift) - sound.start) * SoundPrint.rate)
                        if frame >= 0, frame < sound.loudness.count {
                            let height = max(1, CGFloat(sound.loudness[frame]) * (band.height - 6))
                            path.addRect(CGRect(x: px, y: band.midY - height / 2, width: 2, height: height))
                        }
                        px += 3
                    }
                    context.fill(path, with: .color(SongTint.wave))
                }
                if let name {
                    var inside = context
                    inside.clip(to: Path(band.insetBy(dx: 6, dy: 0)))
                    // Centered top to bottom, with a soft shadow so it reads over the wave.
                    inside.addFilter(.shadow(color: .black.opacity(0.6), radius: 2))
                    inside.draw(Text("\(Image(systemName: "music.note")) \(name)")
                                    .font(.caption2.weight(.bold)).foregroundStyle(.white),
                                at: CGPoint(x: max(band.minX, 0) + 8, y: band.midY), anchor: .leading)
                }
            }

            if performance {
                if let soundtrack {
                    bar(from: start, to: end, sound: soundtrack.sound, shift: soundtrack.shift,
                        name: soundtrack.name, gap: 0)
                } else {
                    let band = CGRect(x: x(start), y: 2, width: max(0.5, x(end) - x(start)), height: size.height - 4)
                    context.fill(Path(band), with: .color(.white.opacity(0.06)))
                }
            } else {
                for layer in layers {
                    bar(from: layer.clipStart, to: layer.clipEnd, sound: layer.sound,
                        shift: layer.offset - layer.trackStart, name: nil, gap: 1)
                }
            }
        }
    }

    /// The lyrics as one plain block (the words are edited on the lyrics page). Tap it for its
    /// tools; picked, it gets the yellow outline. Faded while they're hidden.
    private var lyricsTrack: some View {
        let time = model.time
        let pps = model.pixelsPerSecond
        let shown = model.lyricStyle.show
        let picked = model.lyricsPicked
        // From the first word to the last, inside the clip (In to Out).
        let first = max(model.loopStart, model.lyrics.map(\.start).min() ?? model.loopStart)
        let last = min(model.loopEnd, model.lyrics.map(\.end).max() ?? model.loopEnd)

        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }
            let left = x(first), right = x(last)
            guard right > left, right > 0, left < size.width else { return }
            let band = CGRect(x: left + 1, y: 2, width: max(2, right - left - 2), height: size.height - 4)
            var lane = context
            lane.opacity = shown ? 1 : 0.35
            lane.fill(Path(band), with: .color(Color(white: 0.22)))
            lane.fill(Path(CGRect(x: band.minX, y: band.minY, width: 2, height: band.height)),
                      with: .color(Tint.accent))
            var inside = lane
            inside.clip(to: Path(band.insetBy(dx: 5, dy: 0)))
            inside.draw(Text("\(Image(systemName: "quote.opening")) Lyrics")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white),
                        at: CGPoint(x: max(band.minX, 0) + 8, y: band.midY), anchor: .leading)
            if picked {
                context.stroke(Path(band.insetBy(dx: -1.5, dy: -1.5)), with: .color(Tint.accent), lineWidth: 3)
            }
        }
    }

    /// One overlay's row: its clip with its picture repeated along it. Picked, it gets the yellow
    /// outline and ends like a video clip.
    private func overlayRow(_ overlay: SavedOverlay) -> some View {
        let time = model.time
        let pps = model.pixelsPerSecond
        let thumb = model.overlayThumbs[overlay.id]?.cgImage
        let picked = model.overlayPick == overlay.id
        let dragging = model.draggingOverlay == overlay.id

        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }
            let left = x(overlay.start), right = x(overlay.end)
            guard right > -2, left < size.width + 2 else { return }
            let rect = CGRect(x: left + 1, y: 2, width: max(2, right - left - 2), height: size.height - 4)
            context.drawLayer { inside in
                inside.clip(to: Path(rect))
                inside.fill(Path(rect), with: .color(Color(white: 0.2)))
                if let thumb {
                    let aspect = min(1.8, max(0.4, CGFloat(thumb.width) / max(CGFloat(thumb.height), 1)))
                    let tile = max(8, rect.height * aspect)
                    var tileX = rect.minX + max(0, floor(-rect.minX / tile) - 1) * tile
                    while tileX < min(rect.maxX, size.width) {
                        inside.draw(Image(decorative: thumb, scale: 1),
                                    in: CGRect(x: tileX, y: rect.minY, width: tile, height: rect.height))
                        tileX += tile
                    }
                }
            }
            // Keyframes: white diamonds for its place and size, yellow for its mask.
            for (list, color) in [(overlay.keys, Color.white), (overlay.maskKeys, Tint.accent)] {
                for key in list ?? [] {
                    let keyX = x(overlay.keyOrigin + key.time)
                    guard keyX > rect.minX - 6, keyX < rect.maxX + 6 else { continue }
                    let side: CGFloat = 8
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: keyX, y: rect.midY - side / 2))
                    diamond.addLine(to: CGPoint(x: keyX + side / 2, y: rect.midY))
                    diamond.addLine(to: CGPoint(x: keyX, y: rect.midY + side / 2))
                    diamond.addLine(to: CGPoint(x: keyX - side / 2, y: rect.midY))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(color))
                    context.stroke(diamond, with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
            if picked {
                context.stroke(Path(rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Tint.accent), lineWidth: 3)
                for start in [true, false] {
                    let width: CGFloat = dragging ? 14 : 11
                    let handle = CGRect(x: start ? rect.minX : rect.maxX - width, y: rect.minY,
                                        width: width, height: rect.height)
                    context.fill(Path(handle), with: .color(Tint.accent))
                    context.draw(Text(Image(systemName: start ? "chevron.compact.left" : "chevron.compact.right"))
                                    .font(.system(size: 12, weight: .heavy)).foregroundStyle(.black.opacity(0.8)),
                                 at: CGPoint(x: handle.midX, y: handle.midY))
                }
            }
        }
    }

    /// One text lane's row: each text as a clip with its words. The open one (or one held) gets the
    /// yellow outline and grips on its ends.
    private func textRow(_ lane: Int) -> some View {
        let time = model.time
        let pps = model.pixelsPerSecond
        let titles = model.titles.filter { $0.lane == lane }
        let editing = model.titleEditing
        let drag = model.titleDrag
        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }
            let tint = TitleTint.color
            for title in titles {
                let left = x(title.start), right = x(title.end)
                guard right > -2, left < size.width + 2 else { continue }
                let rect = CGRect(x: left + 1, y: 2, width: max(2, right - left - 2), height: size.height - 4)
                let held = drag?.id == title.id
                context.fill(Path(rect), with: .color(tint.opacity(held && drag?.grip == .move ? 0.65 : 0.85)))
                var inside = context
                inside.clip(to: Path(rect.insetBy(dx: 6, dy: 0)))
                inside.draw(Text("\(Image(systemName: "textformat")) \(title.label)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white),
                            at: CGPoint(x: max(rect.minX, 0) + 8, y: rect.midY), anchor: .leading)
                if editing == title.id || held {
                    context.stroke(Path(rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Tint.accent), lineWidth: 3)
                    let grips: [(CGFloat, EditorModel.Grip)] = [(rect.minX + 3, .trimStart), (rect.maxX - 7, .trimEnd)]
                    for (edgeX, which) in grips {
                        let active = held && drag?.grip == which
                        let handle = CGRect(x: edgeX, y: rect.midY - (active ? 11 : 8), width: 4, height: active ? 22 : 16)
                        context.fill(Path(handle), with: .color(.white.opacity(active ? 1 : 0.7)))
                    }
                }
            }
        }
    }

    /// The text on a lane under a finger, and which end when the finger is near one (nil: the middle).
    private func textGrip(lane: Int, at point: CGPoint, width: CGFloat) -> (id: UUID, grip: EditorModel.Grip?)? {
        let middle = width / 2
        var best: (id: UUID, grip: EditorModel.Grip, distance: CGFloat)?
        for clip in model.titles where clip.lane == lane {
            let start = middle + CGFloat((clip.start - model.time) * model.pixelsPerSecond)
            let end = middle + CGFloat((clip.end - model.time) * model.pixelsPerSecond)
            let toStart = abs(point.x - start), toEnd = abs(point.x - end)
            let distance = min(toStart, toEnd)
            if distance <= 22 {
                if distance < (best?.distance ?? .infinity) {
                    best = (clip.id, toStart <= toEnd ? .trimStart : .trimEnd, distance)
                }
            } else if point.x > start, point.x < end {
                return (clip.id, nil)
            }
        }
        return best.map { (id: $0.id, grip: Optional($0.grip)) }
    }

    // MARK: Touches

    /// The picked clip's end under a finger (within a finger's width), for trimming it.
    private func pickedEnd(at point: CGPoint, width: CGFloat) -> EditorModel.Grip? {
        // A piece of the split performance: only its In or Out end.
        let span: (start: Double, end: Double, startEnd: Bool, endEnd: Bool)
        if model.kind == .performance {
            guard let piece = model.pickedPiece else { return nil }
            span = (piece.start, piece.end, abs(piece.start - model.loopStart) < 0.001,
                    abs(piece.end - model.performanceEnd) < 0.001)
        } else {
            guard let picked = model.editPick, let clip = clips.first(where: { $0.id == picked }) else { return nil }
            span = (clip.start, clip.end, true, true)
        }
        let middle = width / 2
        let startX = middle + CGFloat((span.start - model.time) * model.pixelsPerSecond)
        let endX = middle + CGFloat((span.end - model.time) * model.pixelsPerSecond)
        let toStart = span.startEnd ? abs(point.x - startX) : .infinity
        let toEnd = span.endEnd ? abs(point.x - endX) : .infinity
        guard min(toStart, toEnd) <= 26 else { return nil }
        return toStart <= toEnd ? .trimStart : .trimEnd
    }

    /// Takes hold of the picked clip's end: In or Out for a performance, a trim for a video.
    private func grabEnd(at point: CGPoint, width: CGFloat) -> Bool {
        guard let end = pickedEnd(at: point, width: width), let picked = model.editPick else { return false }
        if model.kind == .performance {
            model.beginRangeDrag(end)
            return model.draggingRange != nil
        }
        model.beginDrag(on: picked, grip: end)
        return model.dragging == picked
    }

    /// The overlay under a finger on its row, and which part: an end (when it's picked) or the middle.
    private func overlayGrip(_ id: UUID, at point: CGPoint, width: CGFloat, ends: Bool) -> EditorModel.Grip? {
        guard let overlay = model.overlay(id) else { return nil }
        let middle = width / 2
        let startX = middle + CGFloat((overlay.start - model.time) * model.pixelsPerSecond)
        let endX = middle + CGFloat((overlay.end - model.time) * model.pixelsPerSecond)
        if ends, model.overlayPick == id {
            let toStart = abs(point.x - startX), toEnd = abs(point.x - endX)
            if min(toStart, toEnd) <= 22 { return toStart <= toEnd ? .trimStart : .trimEnd }
        }
        return point.x >= startX && point.x <= endX ? .move : nil
    }

    /// A clip on the main track (added before or after a split) under a finger on the video row,
    /// and which part: an end of the picked one, or the middle.
    private func cutawayGrip(at point: CGPoint, width: CGFloat, ends: Bool) -> (id: UUID, grip: EditorModel.Grip)? {
        guard model.kind == .performance else { return nil }
        let middle = width / 2
        func spanX(_ clip: SavedOverlay) -> (CGFloat, CGFloat) {
            (middle + CGFloat((clip.start - model.time) * model.pixelsPerSecond),
             middle + CGFloat((clip.end - model.time) * model.pixelsPerSecond))
        }
        if ends, let id = model.overlayPick, let clip = model.overlay(id), clip.isCutaway {
            let (startX, endX) = spanX(clip)
            let toStart = abs(point.x - startX), toEnd = abs(point.x - endX)
            if min(toStart, toEnd) <= 22 { return (id, toStart <= toEnd ? .trimStart : .trimEnd) }
        }
        for clip in model.cutaways.reversed() where !clip.hidden {
            let (startX, endX) = spanX(clip)
            if point.x >= startX && point.x <= endX { return (clip.id, .move) }
        }
        return nil
    }

    /// The keyframe (timeline second, and its place in `times`) whose diamond is in reach of a tap.
    private func keyNear(_ times: [Double], x: CGFloat, width: CGFloat) -> (time: Double, index: Int)? {
        let reach: CGFloat = 16
        var best: (time: Double, index: Int, gap: CGFloat)?
        for (index, time) in times.enumerated() {
            let keyX = width / 2 + CGFloat((time - model.time) * model.pixelsPerSecond)
            let gap = abs(keyX - x)
            if gap <= reach, gap < (best?.gap ?? .infinity) { best = (time, index, gap) }
        }
        return best.map { ($0.time, $0.index) }
    }

    private func touches(width: CGFloat, row: Row) -> some View {
        let video = row == .video
        let overlayID = row.overlayID
        let textLane = row.textLane
        return LaneTouches(
            lift: { point in
                if let textLane {
                    // Hold a text to move it (or near an end, to stretch it).
                    guard let hit = textGrip(lane: textLane, at: point, width: width) else { return false }
                    model.beginTitleDrag(hit.id, grip: hit.grip ?? .move)
                    return model.titleDrag?.id == hit.id
                }
                if let overlayID {
                    // Hold an overlay to move it along the timeline (or its end, to trim).
                    guard let grip = overlayGrip(overlayID, at: point, width: width, ends: true) else { return false }
                    model.beginOverlayDrag(overlayID, grip: grip)
                    return model.draggingOverlay == overlayID
                }
                guard video else { return false }
                // The picked added clip's ends, then the performance's ends, then hold an added clip to move it.
                if let hit = cutawayGrip(at: point, width: width, ends: true), hit.grip != .move {
                    model.beginOverlayDrag(hit.id, grip: hit.grip)
                    return model.draggingOverlay == hit.id
                }
                if grabEnd(at: point, width: width) { return true }
                if let hit = cutawayGrip(at: point, width: width, ends: false) {
                    model.beginOverlayDrag(hit.id, grip: .move)
                    return model.draggingOverlay == hit.id
                }
                return false
            },
            liftMoved: { travel in
                if model.titleDrag != nil {
                    model.dragTitle(by: Double(travel) / model.pixelsPerSecond)
                } else {
                    model.drag(by: Double(travel) / model.pixelsPerSecond)
                }
            },
            trimBegan: { point in
                if let textLane {
                    guard let hit = textGrip(lane: textLane, at: point, width: width), let grip = hit.grip
                    else { return false }
                    model.beginTitleDrag(hit.id, grip: grip)
                    return model.titleDrag?.id == hit.id
                }
                if let overlayID {
                    guard let grip = overlayGrip(overlayID, at: point, width: width, ends: true),
                          grip != .move else { return false }
                    model.beginOverlayDrag(overlayID, grip: grip)
                    return model.draggingOverlay == overlayID
                }
                guard video else { return false }
                if let hit = cutawayGrip(at: point, width: width, ends: true), hit.grip != .move {
                    model.beginOverlayDrag(hit.id, grip: hit.grip)
                    return model.draggingOverlay == hit.id
                }
                return grabEnd(at: point, width: width)
            },
            dropped: {
                if model.titleDrag != nil { model.endTitleDrag() } else { model.endDrag() }
            },
            swipeBegan: {
                dragStartTime = model.time
                model.beginScrub()
            },
            swipeMoved: { travel in
                // The playhead stays on the clip.
                let to = dragStartTime - Double(travel) / model.pixelsPerSecond
                model.scrub(to: min(max(to, model.loopStart), model.loopEnd))
            },
            swipeEnded: { model.endScrub() },
            tapped: { point in
                if let textLane {
                    // A tap on a text opens it to edit.
                    if let hit = textGrip(lane: textLane, at: point, width: width) {
                        model.openTitle(hit.id)
                    } else {
                        model.pickOnEdit(nil)
                        model.pickOverlay(nil)
                    }
                    return
                }
                if let overlayID, let overlay = model.overlay(overlayID) {
                    // A tap near one of its diamonds picks that keyframe.
                    let place = (overlay.keys ?? []).map { overlay.keyOrigin + $0.time }
                    let mask = (overlay.maskKeys ?? []).map { overlay.keyOrigin + $0.time }
                    if let near = keyNear(place + mask, x: point.x, width: width) {
                        model.pickKeyframe(overlay: overlayID, at: near.time, mask: near.index >= place.count)
                        return
                    }
                }
                if let overlayID {
                    // A tap on an overlay picks it; again, or beside it, lets go.
                    let hit = overlayGrip(overlayID, at: point, width: width, ends: false) != nil
                    model.pickOverlay(hit && model.overlayPick != overlayID ? overlayID : nil)
                    return
                }
                // A tap on the lyrics row picks the lyrics: their tools (show/hide, look, lyric editor).
                if row == .lyrics {
                    model.pickLyrics(!model.lyricsPicked)
                    return
                }
                // A tap on a clip picks it; again, or anywhere else, lets go.
                guard video else {
                    model.pickOnEdit(nil)
                    model.pickOverlay(nil)
                    return
                }
                // A tap near one of an added clip's diamonds picks that keyframe.
                for clip in model.cutaways where !clip.hidden && model.kind == .performance {
                    let times = (clip.keys ?? []).map { clip.keyOrigin + $0.time }
                    if let near = keyNear(times, x: point.x, width: width) {
                        model.pickKeyframe(overlay: clip.id, at: near.time)
                        return
                    }
                }
                // A tap near one of the performance's diamonds picks that keyframe.
                if model.kind == .performance,
                   let near = keyNear(model.trackKeys.map(\.time), x: point.x, width: width) {
                    model.pickKeyframe(overlay: nil, at: near.time)
                    return
                }
                // A tap on an added clip picks it; again lets go.
                if let hit = cutawayGrip(at: point, width: width, ends: false) {
                    model.pickOverlay(model.overlayPick == hit.id ? nil : hit.id)
                    return
                }
                let at = model.time + Double(point.x - width / 2) / model.pixelsPerSecond
                let hit = clips.first { at >= $0.start && at <= $0.end }?.id
                if model.kind == .performance, hit != nil {
                    // A double tap on the performance opens it: it grows into the performance page.
                    let now = Date()
                    if now.timeIntervalSince(lastClipTap) < 0.35 {
                        lastClipTap = .distantPast
                        withAnimation(.spring(duration: 0.35)) { model.showPerformancePage() }
                        return
                    }
                    lastClipTap = now
                }
                if model.kind == .performance, hit != nil {
                    // A split performance: the piece under the finger.
                    model.pickPiece(at: at)
                } else {
                    model.pickOnEdit(hit == model.editPick ? nil : hit)
                }
                if hit == nil { model.pickOverlay(nil) }
            },
            pinchBegan: { zoomStart = model.pixelsPerSecond },
            pinched: { scale in
                let start = zoomStart ?? model.pixelsPerSecond
                model.pixelsPerSecond = min(240, max(6, start * Double(scale)))
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
                let to = dragStartTime - Double(value.translation.width) / model.pixelsPerSecond
                model.scrub(to: min(max(to, model.loopStart), model.loopEnd))
            }
            .onEnded { _ in
                rulerHeld = false
                model.endScrub()
            }
    }
}
