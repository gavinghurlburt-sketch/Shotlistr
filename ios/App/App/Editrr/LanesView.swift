import SwiftUI

/// Sizes for the timeline.
enum LaneMetrics {
    static let labelWidth: CGFloat = 70
    static let rulerHeight: CGFloat = 24
    static let songHeight: CGFloat = 40
    /// Grey between the timeline's edge and its white outline.
    static let inset: CGFloat = 6
    /// Extra grey above the time markers, inside the outline.
    static let topSpace: CGFloat = 8
    /// The grey frame around the lanes, all told.
    static var chrome: CGFloat { inset * 2 + topSpace }

    /// UserDefaults key for tall tracks: each video's lane grows to show its picture full size.
    static let tallKey = "tallTracks"
    static var tall: Bool { UserDefaults.standard.bool(forKey: tallKey) }
    /// A lane's height: short (40), or tall enough for a full 9:16 picture in the header.
    static var laneHeight: CGFloat { laneHeight(tall: tall) }
    static func laneHeight(tall: Bool) -> CGFloat { tall ? (labelWidth - 6) * 16 / 9 + 8 : 40 }
    /// The strip at the top of the song lane where the cut markers sit, above the song.
    static let markerStrip: CGFloat = 12
    /// The timeline's background; each lane is a lighter row on it.
    static let backdrop = Tint.surface
    static let row = Tint.surface2

    /// Shows up to 5 short lanes (or 2 tall ones) at once; more scroll up and down, with the top
    /// of the next one peeking out so you can tell there's more.
    static func height(layers: Int, tall: Bool = LaneMetrics.tall) -> CGFloat {
        let lane = laneHeight(tall: tall)
        let count = max(layers, 1)
        let shown = lane * CGFloat(min(count, tall ? 2 : 5))
        let peek = min(36, lane * CGFloat(count) - shown)
        return rulerHeight + songHeight + shown + peek + 4 + chrome
    }

    /// "0", "1s", "2.5s", then "1:05" past a minute, for the ruler.
    static func rulerLabel(_ seconds: Double) -> String {
        if seconds < 0.001 { return "0" }
        if seconds >= 60 { return short(seconds) }
        let whole = seconds.rounded()
        return abs(seconds - whole) < 0.001 ? "\(Int(whole))s" : String(format: "%.1fs", seconds)
    }

    /// "1:05" for the ruler.
    static func short(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        let tenth = max(0, seconds) - Double(whole)
        let label = String(format: "%d:%02d", whole / 60, whole % 60)
        return tenth > 0.01 ? label + String(format: ".%d", Int((tenth * 10).rounded())) : label
    }
}

/// The timeline: the song lane on top, one lane per video under it, the playhead fixed in the
/// middle. Swipe anywhere to move through time. Press and hold a clip to lift it, then drag to
/// move it (or, in Trim, to trim its nearer edge). Pinch to zoom. Tap a video's number to cut to it.
struct LanesView: View {
    let model: EditorModel

    @State private var dragStartTime: Double = 0
    @State private var zoomStart: Double?
    @State private var rulerHeld = false
    /// The track whose color picker is open (a hold on its header opens it).
    @State private var coloring: Int?
    /// Tall tracks show each video's picture full size; read here so the lanes redraw on a switch.
    @AppStorage(LaneMetrics.tallKey) private var tallTracks = false

    var body: some View {
        GeometryReader { geo in
            let laneWidth = max(geo.size.width - LaneMetrics.labelWidth, 1)
            VStack(spacing: 0) {
                Color.clear.frame(height: LaneMetrics.topSpace)
                HStack(spacing: 0) {
                    Color.clear.frame(width: LaneMetrics.labelWidth)
                    Ruler(time: model.time, pixelsPerSecond: model.pixelsPerSecond, duration: model.duration)
                        .frame(width: laneWidth)
                        .contentShape(Rectangle())
                        .gesture(rulerGesture)
                }
                .frame(height: LaneMetrics.rulerHeight)

                // The song lane stays put on top; only the video lanes under it scroll.
                HStack(spacing: 0) {
                    songHeader
                    lanes(song: true)
                        .frame(width: laneWidth, height: LaneMetrics.songHeight)
                        .clipped()
                        .overlay { touches(width: laneWidth, song: true) }
                }
                .frame(height: LaneMetrics.songHeight)

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        labels
                        lanes(song: false)
                            .frame(width: laneWidth,
                                   height: LaneMetrics.laneHeight(tall: tallTracks) * CGFloat(model.laneCount))
                            .clipped()
                            .overlay { touches(width: laneWidth, song: false) }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            .overlay(alignment: .topLeading) {
                // The playhead: where a tap on a number cuts.
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: LaneMetrics.labelWidth + laneWidth / 2 - 1)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(Corner.chip)
        .padding(LaneMetrics.inset)
        .background(LaneMetrics.backdrop)
        .clipShape(Corner.card)
    }

    // MARK: Buttons on the left

    /// The song lane's header: a note (or no-sound) icon and the tall tracks switch.
    private var songHeader: some View {
        HStack(spacing: 0) {
            Image(systemName: model.soundtrack == nil ? "speaker.slash" : "music.note")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Song")
            // Tall tracks: each video's picture full size. Off again for the compact view.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { tallTracks.toggle() }
            } label: {
                Image(systemName: tallTracks ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tallTracks ? Tint.accent : Color.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tallTracks ? "Short tracks" : "Tall tracks with full pictures")
        }
        .frame(width: LaneMetrics.labelWidth, height: LaneMetrics.songHeight)
        .background(LaneMetrics.row.padding(.vertical, 2))
    }

    /// One header per video, scrolling with the video lanes.
    private var labels: some View {
        let showing = model.showing
        return VStack(spacing: 0) {
            ForEach(model.layers) { layer in
                // Two taps cut to it; one tap previews it. (The double tap is listed first so
                // SwiftUI waits a moment to tell them apart.)
                LayerChip(layer: layer, lit: showing == layer.id, previewing: model.previewing == layer.id,
                          tall: tallTracks)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.cut(to: layer.id) }
                    .onTapGesture { model.preview(layer.id) }
                    .onLongPressGesture { coloring = layer.id }
                    .popover(isPresented: Binding(get: { coloring == layer.id },
                                                  set: { if !$0 { coloring = nil } })) {
                        TrackColorPicker(selected: LayerTint.pick(layer)) { pick in
                            model.setTrackColor(layer.id, to: pick)
                            coloring = nil
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                    .frame(width: LaneMetrics.labelWidth, height: LaneMetrics.laneHeight(tall: tallTracks))
                    .background(LaneMetrics.row.padding(.vertical, 2))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Video \(layer.id + 1)")
                    .accessibilityHint("Tap to preview, double tap to cut to it, hold to change its color")
            }
            // Text lanes under the videos.
            ForEach(0..<model.textLaneCount, id: \.self) { lane in
                TextLaneChip(number: lane + 1, lit: titleShowing(lane: lane), tall: tallTracks)
                    .frame(width: LaneMetrics.labelWidth, height: LaneMetrics.laneHeight(tall: tallTracks))
                    .background(LaneMetrics.row.padding(.vertical, 2))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Text lane \(lane + 1)")
            }
        }
    }

    /// True when a text on this lane shows at the playhead.
    private func titleShowing(lane: Int) -> Bool {
        model.titles.contains { $0.lane == lane && model.time >= $0.start && model.time < $0.end }
    }

    // MARK: The lanes

    /// The song lane (song: true) or the video lanes under it (song: false). Both draw the same
    /// picture, the video one shifted up by the song lane's height, so lines meet at the seam.
    private func lanes(song: Bool) -> some View {
        let time = model.time
        let pps = model.pixelsPerSecond
        let duration = model.duration
        let layers = model.layers
        let segments = model.segments
        let soundtrack = model.soundtrack
        let selected = model.selected
        let dragging = model.dragging
        let grip = model.grip
        let locked = model.locked
        let cuts = model.cuts
        let draggingCut = model.draggingCut
        let inPoint = model.inPoint
        let outPoint = model.outPoint > 0 ? model.outPoint : model.duration
        let songHeight = LaneMetrics.songHeight
        let laneHeight = LaneMetrics.laneHeight(tall: tallTracks)
        let titles = model.titles
        let titleEditing = model.titleEditing
        let titleDrag = model.titleDrag
        let songName = soundtrack?.name ?? "Song"
        let textLanes = model.textLaneCount

        return Canvas { context, canvasSize in
            if !song { context.translateBy(x: 0, y: -songHeight) }
            let size = CGSize(width: canvasSize.width, height: canvasSize.height + (song ? 0 : songHeight))
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }
            func width(_ seconds: Double) -> CGFloat { CGFloat(seconds * pps) }

            /// The In or Out line, with its name at the top.
            func marker(at markX: CGFloat, label: String, leading: Bool) {
                guard markX > -40, markX < size.width + 40 else { return }
                context.fill(Path(CGRect(x: markX - 1, y: 0, width: 2, height: size.height)), with: .color(Tint.warn))
                context.draw(Text(label).font(.caption2.weight(.heavy)).foregroundStyle(Tint.warn),
                             at: CGPoint(x: markX + (leading ? 4 : -4), y: 2),
                             anchor: leading ? .topLeading : .topTrailing)
            }

            /// Loudness bars for a sound whose asset time + shift = timeline time (from the bottom
            /// of the band up, or from its middle out).
            func wave(_ sound: SoundPrint?, shift: Double, in band: CGRect, color: Color, fromBottom: Bool = false) {
                guard let sound else { return }
                var path = Path()
                var px = max(band.minX, 0)
                let end = min(band.maxX, size.width)
                while px < end {
                    let timeline = time + Double(px - middle) / pps
                    let frame = Int(((timeline - shift) - sound.start) * SoundPrint.rate)
                    if frame >= 0, frame < sound.loudness.count {
                        let height = max(1, CGFloat(sound.loudness[frame]) * (band.height - (fromBottom ? 2 : 4)))
                        path.addRect(CGRect(x: px, y: fromBottom ? band.maxY - height : band.midY - height / 2,
                                            width: 2, height: height))
                    }
                    px += 3
                }
                context.fill(path, with: .color(color))
            }

            // Song lane: the cut markers along the top, then the song as a grey bar with its name
            // at the left and its sound along the bottom.
            if song {
                let barTop = LaneMetrics.markerStrip + 1
                context.fill(Path(CGRect(x: 0, y: barTop - 1, width: size.width, height: songHeight - barTop - 1)),
                             with: .color(LaneMetrics.row))
                let songBand = CGRect(x: x(0), y: barTop, width: width(duration), height: songHeight - barTop - 3)
                if soundtrack != nil {
                    context.fill(Path(songBand), with: .color(SongTint.color))
                    wave(soundtrack?.sound, shift: soundtrack?.shift ?? 0,
                         in: songBand.insetBy(dx: 0, dy: 1), color: SongTint.wave, fromBottom: true)
                    var inside = context
                    inside.clip(to: Path(songBand.insetBy(dx: 8, dy: 0)))
                    inside.draw(Text("\(Image(systemName: "music.note")) \(songName)")
                                    .font(.caption.weight(.bold)).foregroundStyle(.white),
                                at: CGPoint(x: max(songBand.minX, 0) + 10, y: songBand.midY), anchor: .leading)
                } else {
                    context.fill(Path(songBand), with: .color(.white.opacity(0.06)))
                }
            } else {
                // A lighter row behind every lane, video and text.
                for lane in 0..<(layers.count + textLanes) {
                    let top = songHeight + CGFloat(lane) * laneHeight
                    context.fill(Path(CGRect(x: 0, y: top + 2, width: size.width, height: laneHeight - 4)),
                                 with: .color(LaneMetrics.row))
                }
            }

            // One lane per video, one clip per lane. A lifted clip is drawn last, on top.
            let order: [Layer] = song ? [] : layers.filter { $0.id != dragging } + layers.filter { $0.id == dragging }
            for layer in order {
                let tint = LayerTint.color(layer)
                let lifted = dragging == layer.id && grip == .move   // trimming leaves it in place
                let top = songHeight + CGFloat(layer.id) * laneHeight
                let whole = CGRect(x: x(layer.offset), y: top + 4, width: width(layer.length), height: laneHeight - 8)
                let resting = CGRect(x: x(layer.clipStart), y: top + 4,
                                     width: width(layer.clipEnd - layer.clipStart), height: laneHeight - 8)
                // Lifted: a little bigger and raised, with a shadow, as if popped out of its lane.
                let band = lifted ? resting.insetBy(dx: -2, dy: -3).offsetBy(dx: 0, dy: -2) : resting
                let shape = Path(band)

                // Other spots its sound fits (a repeated chorus): dashed, with the song time.
                for spot in layer.alternatives {
                    let ghost = CGRect(x: x(spot + layer.trimStart), y: top + 5,
                                       width: width(layer.clipEnd - layer.clipStart), height: laneHeight - 10)
                    guard ghost.maxX > 0, ghost.minX < size.width else { continue }
                    let outline = Path(ghost)
                    context.fill(outline, with: .color(tint.opacity(0.08)))
                    context.stroke(outline, with: .color(tint.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    context.draw(Text("Tap: \(LaneMetrics.short(max(0, spot + layer.trimStart)))")
                                    .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.9)),
                                 at: CGPoint(x: max(ghost.minX, 0) + 8, y: ghost.midY), anchor: .leading)
                }

                // Trimmed-away parts, faint.
                if layer.trimStart > 0 || layer.trimEnd > 0 {
                    context.fill(Path(whole), with: .color(tint.opacity(0.06)))
                }
                if lifted {
                    context.drawLayer { raised in
                        raised.addFilter(.shadow(color: .black.opacity(0.75), radius: 8, x: 0, y: 5))
                        raised.fill(shape, with: .color(tint.opacity(0.65)))
                    }
                } else {
                    context.fill(shape, with: .color(tint.opacity(0.18)))
                    context.stroke(shape, with: .color(tint.opacity(0.55)), lineWidth: 1)

                    // Where this video is the one that shows.
                    for segment in segments where segment.layer == layer.id {
                        let lit = CGRect(x: x(segment.start), y: top + 4, width: width(segment.end - segment.start),
                                         height: laneHeight - 8)
                        // creatrr's color coding: the color fades left to right, with a solid stripe
                        // where this video starts showing (right on the cut line).
                        context.fill(Path(lit), with: .linearGradient(
                            Gradient(colors: [tint.opacity(0.85), tint.opacity(0.45)]),
                            startPoint: CGPoint(x: lit.minX, y: lit.midY),
                            endPoint: CGPoint(x: max(lit.maxX, lit.minX + 1), y: lit.midY)))
                        context.fill(Path(CGRect(x: lit.minX, y: lit.minY, width: min(4, lit.width), height: lit.height)),
                                     with: .color(tint))
                    }
                }
                wave(layer.sound, shift: layer.offset - layer.trackStart, in: band, color: .white.opacity(0.35))

                // Keyframes: small diamonds along the bottom of the clip.
                for key in layer.keyframes {
                    let keyX = x(layer.offset + key.time)
                    guard keyX > -10, keyX < size.width + 10 else { continue }
                    let y = band.maxY - 7
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: keyX, y: y - 5))
                    diamond.addLine(to: CGPoint(x: keyX + 5, y: y))
                    diamond.addLine(to: CGPoint(x: keyX, y: y + 5))
                    diamond.addLine(to: CGPoint(x: keyX - 5, y: y))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(Tint.warn))
                    context.stroke(diamond, with: .color(.white), lineWidth: 1)
                }

                // Picked: a bold outline in the accent, grips on both ends to trim it, and its length.
                let picked = selected == layer.id
                if picked || lifted {
                    context.stroke(Path(band.insetBy(dx: -1.5, dy: -1.5)), with: .color(Tint.accent), lineWidth: 3)
                }
                if (picked || dragging == layer.id) && !lifted && !locked {
                    for which in [EditorModel.Grip.trimStart, .trimEnd] {
                        let active = dragging == layer.id && grip == which
                        let gripWidth: CGFloat = active ? 16 : 13
                        let handle = CGRect(x: which == .trimStart ? band.minX : band.maxX - gripWidth,
                                            y: band.minY, width: gripWidth, height: band.height)
                        context.fill(Path(handle), with: .color(Tint.accent))
                        context.draw(Text(Image(systemName: which == .trimStart ? "chevron.compact.left" : "chevron.compact.right"))
                                        .font(.system(size: 15, weight: .heavy)).foregroundStyle(.black.opacity(0.8)),
                                     at: CGPoint(x: handle.midX, y: handle.midY))
                    }
                }
                if picked && band.width > 60 {
                    let length = Text(String(format: "%.1fs", layer.clipEnd - layer.clipStart))
                        .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    let resolved = context.resolve(length)
                    let textSize = resolved.measure(in: CGSize(width: 200, height: 40))
                    let left = max(band.minX + (locked ? 4 : 17), 4)
                    let badge = CGRect(x: left, y: band.minY + 4, width: textSize.width + 8, height: textSize.height + 2)
                    if badge.maxX < band.maxX - 14 {
                        context.fill(Path(badge), with: .color(.black.opacity(0.65)))
                        context.draw(resolved, at: CGPoint(x: badge.midX, y: badge.midY))
                    }
                }
                let note: String? = switch layer.sync {
                case .unsure: "Check sync"
                case .noSound: "No sound to match"
                default: nil
                }
                if let note, dragging != layer.id {
                    let label = context.resolve(Text(note).font(.caption2.weight(.bold)).foregroundStyle(.white))
                    let textSize = label.measure(in: CGSize(width: 300, height: 40))
                    let spot = CGPoint(x: max(band.minX, 0) + 18, y: band.midY)
                    context.fill(Path(CGRect(x: spot.x - 4, y: spot.y - textSize.height / 2 - 1,
                                             width: textSize.width + 8, height: textSize.height + 2)),
                                 with: .color(.black.opacity(0.65)))
                    context.draw(label, at: spot, anchor: .leading)
                }
            }

            // Text clips, on their lanes under the videos.
            if !song {
                let tint = TitleTint.color
                for title in titles {
                    let top = songHeight + CGFloat(layers.count + title.lane) * laneHeight
                    let held = titleDrag?.id == title.id
                    let lifted = held && titleDrag?.grip == .move
                    let resting = CGRect(x: x(title.start), y: top + 4, width: max(2, width(title.end - title.start)),
                                         height: laneHeight - 8)
                    guard resting.maxX > -20, resting.minX < size.width + 20 else { continue }
                    let band = lifted ? resting.insetBy(dx: -2, dy: -3).offsetBy(dx: 0, dy: -2) : resting
                    let shape = Path(band)
                    if lifted {
                        context.drawLayer { raised in
                            raised.addFilter(.shadow(color: .black.opacity(0.75), radius: 8, x: 0, y: 5))
                            raised.fill(shape, with: .color(tint.opacity(0.75)))
                        }
                    } else {
                        context.fill(shape, with: .color(tint.opacity(0.85)))
                    }
                    // Its words, kept inside the clip.
                    var inside = context
                    inside.clip(to: Path(band.insetBy(dx: 8, dy: 0)))
                    inside.draw(Text("\(Image(systemName: "textformat")) \(title.label)")
                                    .font(.caption2.weight(.bold)).foregroundStyle(.white),
                                at: CGPoint(x: max(band.minX, 0) + 10, y: band.midY), anchor: .leading)
                    if titleEditing == title.id || held {
                        context.stroke(Path(band.insetBy(dx: -1.5, dy: -1.5)), with: .color(Tint.accent), lineWidth: 3)
                    }
                    // Grips on both ends, as on the videos. Text isn't held by the lock.
                    if !lifted {
                        let grips: [(CGFloat, EditorModel.Grip)] = [(band.minX + 3, .trimStart), (band.maxX - 7, .trimEnd)]
                        for (edgeX, which) in grips {
                            let active = held && titleDrag?.grip == which
                            let handle = CGRect(x: edgeX, y: band.midY - (active ? 14 : 9), width: 4, height: active ? 28 : 18)
                            context.fill(Path(handle), with: .color(.white.opacity(active ? 1 : 0.55)))
                        }
                    }
                }
            }

            // Hand-offs: where one video switches to the next. A line down through the video lanes
            // and a marker on the song lane, DaVinci style: a block that tapers to a point, the tip
            // right on the line. Drag the marker to make the video before it run longer or shorter.
            for (index, cut) in cuts.enumerated() where index > 0 {
                let cutX = x(cut.time)
                guard cutX > -20, cutX < size.width + 20 else { continue }
                let active = draggingCut == index
                if song {
                    // A small marker above the song, its point on the line, and the line on down.
                    let half: CGFloat = active ? 6 : 4.5
                    let strip = LaneMetrics.markerStrip
                    let shoulder = strip * 0.55   // where the block starts to taper
                    var flag = Path()
                    flag.move(to: CGPoint(x: cutX - half, y: 1))
                    flag.addLine(to: CGPoint(x: cutX + half, y: 1))
                    flag.addLine(to: CGPoint(x: cutX + half, y: shoulder))
                    flag.addLine(to: CGPoint(x: cutX, y: strip))
                    flag.addLine(to: CGPoint(x: cutX - half, y: shoulder))
                    flag.closeSubpath()
                    context.fill(flag, with: .color(layers.indices.contains(cut.layer)
                                                    ? LayerTint.color(layers[cut.layer]) : LayerTint.color(cut.layer)))
                    context.stroke(flag, with: .color(Color(white: 0.12)),
                                   style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineJoin: .round))
                    context.fill(Path(CGRect(x: cutX - (active ? 1 : 0.5), y: strip, width: active ? 2 : 1,
                                             height: songHeight - strip)),
                                 with: .color(.white.opacity(active ? 0.9 : 0.35)))
                } else {
                    context.fill(Path(CGRect(x: cutX - (active ? 1 : 0.5), y: songHeight, width: active ? 2 : 1,
                                             height: size.height - songHeight)),
                                 with: .color(.white.opacity(active ? 0.9 : 0.35)))
                }
            }

            // Cuts with auto zoom: a label at the start, on the lane of the video they cut to.
            for cut in cuts where cut.zoom != .off && !song {
                let labelX = x(cut.time)
                guard labelX < size.width, labelX > -120 else { continue }
                let top = songHeight + CGFloat(cut.layer) * laneHeight
                let icon = cut.zoom == .zoomIn ? "plus.magnifyingglass" : "minus.magnifyingglass"
                context.draw(Text("\(Image(systemName: icon)) \(cut.zoom.name)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white),
                             at: CGPoint(x: max(labelX, 0) + 10, y: top + 12), anchor: .leading)
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

            // In and Out: outside them is dimmed (it won't be exported), with an amber marker at each.
            let dim = Color.black.opacity(0.35)
            if inPoint > 0.0005 {
                let inX = x(inPoint)
                if inX > x(0) {
                    context.fill(Path(CGRect(x: max(0, x(0)), y: 0, width: inX - max(0, x(0)), height: size.height)),
                                 with: .color(dim))
                }
                marker(at: inX, label: "Start", leading: true)
            }
            if outPoint < duration - 0.0005 {
                let outX = x(outPoint)
                let endX = min(size.width, x(duration))
                if endX > outX {
                    context.fill(Path(CGRect(x: outX, y: 0, width: endX - outX, height: size.height)), with: .color(dim))
                }
                marker(at: outX, label: "End", leading: false)
            }

        }
    }

    // MARK: Finding what's under a finger

    /// The clip under a point on the lanes.
    private func clip(at point: CGPoint, width: CGFloat, slop: CGFloat = 12) -> Int? {
        let y = point.y
        guard y >= 0 else { return nil }
        let lane = Int(y / LaneMetrics.laneHeight(tall: tallTracks))
        guard model.layers.indices.contains(lane) else { return nil }
        let layer = model.layers[lane]
        let middle = width / 2
        let start = middle + CGFloat((layer.clipStart - model.time) * model.pixelsPerSecond)
        let end = middle + CGFloat((layer.clipEnd - model.time) * model.pixelsPerSecond)
        // A little slop makes short clips and edges easier to grab.
        guard point.x >= start - slop, point.x <= end + slop else { return nil }
        return lane
    }

    /// The text clip under a point, and which end when the finger is near one (nil grip: the middle).
    private func title(at point: CGPoint, width: CGFloat) -> (id: UUID, grip: EditorModel.Grip?)? {
        guard point.y >= 0 else { return nil }
        let lane = Int(point.y / LaneMetrics.laneHeight(tall: tallTracks)) - model.layers.count
        guard lane >= 0, lane < model.textLaneCount else { return nil }
        let middle = width / 2
        var best: (id: UUID, grip: EditorModel.Grip?, distance: CGFloat)?
        for clip in model.titles where clip.lane == lane {
            let start = middle + CGFloat((clip.start - model.time) * model.pixelsPerSecond)
            let end = middle + CGFloat((clip.end - model.time) * model.pixelsPerSecond)
            let reach: CGFloat = 22
            let toStart = abs(point.x - start), toEnd = abs(point.x - end)
            if min(toStart, toEnd) <= reach {
                // Near an end: the nearer end of the nearest clip.
                let distance = min(toStart, toEnd)
                if distance < (best?.distance ?? .infinity) {
                    best = (id: clip.id, grip: toStart <= toEnd ? EditorModel.Grip.trimStart : EditorModel.Grip.trimEnd, distance: distance)
                }
            } else if point.x > start, point.x < end {
                return (clip.id, nil)
            }
        }
        return best.map { (id: $0.id, grip: $0.grip) }
    }

    /// The hand-off marker under a point on the song lane: an index into the cuts.
    private func handle(at point: CGPoint, width: CGFloat) -> Int? {
        let middle = width / 2
        var best: (index: Int, distance: CGFloat)?
        for (index, cut) in model.cuts.enumerated() where index > 0 {
            let distance = abs(point.x - (middle + CGFloat((cut.time - model.time) * model.pixelsPerSecond)))
            if distance <= 24, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    /// A clip's end under a point (within a finger's width), for trimming.
    private func edge(at point: CGPoint, width: CGFloat) -> (index: Int, grip: EditorModel.Grip)? {
        let y = point.y
        guard y >= 0 else { return nil }
        let lane = Int(y / LaneMetrics.laneHeight(tall: tallTracks))
        guard model.layers.indices.contains(lane) else { return nil }
        let layer = model.layers[lane]
        let middle = width / 2
        let start = middle + CGFloat((layer.clipStart - model.time) * model.pixelsPerSecond)
        let end = middle + CGFloat((layer.clipEnd - model.time) * model.pixelsPerSecond)
        let reach: CGFloat = 26
        let toStart = abs(point.x - start), toEnd = abs(point.x - end)
        guard min(toStart, toEnd) <= reach else { return nil }
        // On a short clip both ends are close: take the nearer one.
        return (lane, toStart <= toEnd ? .trimStart : .trimEnd)
    }

    /// The dashed spot (another place the clip fits) under a point, if any.
    private func alternative(at point: CGPoint, width: CGFloat) -> (index: Int, choice: Int)? {
        let y = point.y
        guard y >= 0 else { return nil }
        let lane = Int(y / LaneMetrics.laneHeight(tall: tallTracks))
        guard model.layers.indices.contains(lane) else { return nil }
        let layer = model.layers[lane]
        let middle = width / 2
        for (choice, spot) in layer.alternatives.enumerated() {
            let start = middle + CGFloat((spot + layer.trimStart - model.time) * model.pixelsPerSecond)
            let end = start + CGFloat((layer.clipEnd - layer.clipStart) * model.pixelsPerSecond)
            if point.x >= start - 8, point.x <= end + 8 { return (lane, choice) }
        }
        return nil
    }

    // MARK: Gestures

    private func touches(width: CGFloat, song: Bool) -> some View {
        LaneTouches(
            lift: { point in
                // On the song lane, a hold on a hand-off marker moves the switch.
                if song {
                    guard let cut = handle(at: point, width: width) else { return false }
                    model.beginCutDrag(cut)
                    return model.draggingCut == cut
                }
                // Text: a hold on an end stretches it; anywhere else moves it.
                if let hit = title(at: point, width: width) {
                    model.beginTitleDrag(hit.id, grip: hit.grip ?? .move)
                    return model.titleDrag?.id == hit.id
                }
                // A hold on a clip's end trims it; anywhere else on the clip moves it.
                if let hit = edge(at: point, width: width) {
                    model.beginDrag(on: hit.index, grip: hit.grip)
                    return model.dragging == hit.index
                }
                guard let index = clip(at: point, width: width) else { return false }
                model.beginDrag(on: index, grip: .move)
                return model.dragging == index
            },
            liftMoved: { travel in
                // The clip follows your finger.
                if model.titleDrag != nil {
                    model.dragTitle(by: Double(travel) / model.pixelsPerSecond)
                } else {
                    model.drag(by: Double(travel) / model.pixelsPerSecond)
                }
            },
            trimBegan: { point in
                // Dragging a hand-off marker moves the switch (works while locked).
                if song {
                    guard let cut = handle(at: point, width: width) else { return false }
                    model.beginCutDrag(cut)
                    return model.draggingCut == cut
                }
                // A text clip's end stretches it (works while locked too).
                if let hit = title(at: point, width: width), let grip = hit.grip {
                    model.beginTitleDrag(hit.id, grip: grip)
                    return model.titleDrag?.id == hit.id
                }
                guard let hit = edge(at: point, width: width) else { return false }
                model.beginDrag(on: hit.index, grip: hit.grip)
                return model.dragging == hit.index   // false while locked: the swipe scrolls
            },
            dropped: {
                if model.titleDrag != nil { model.endTitleDrag() } else { model.endDrag() }
            },
            swipeBegan: {
                dragStartTime = model.time
                model.beginScrub()
            },
            swipeMoved: { travel in
                model.scrub(to: dragStartTime - Double(travel) / model.pixelsPerSecond)   // the timeline follows your finger
            },
            swipeEnded: { model.endScrub() },
            tapped: { point in
                if song {
                    model.select(nil)
                } else if let hit = title(at: point, width: width) {
                    model.openTitle(hit.id)   // a tap on a text opens it
                } else if let index = clip(at: point, width: width, slop: 0) {
                    model.select(index)
                } else if let spot = alternative(at: point, width: width) {
                    model.moveToAlternative(spot.index, choice: spot.choice)
                } else {
                    model.select(clip(at: point, width: width))
                }
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
                model.scrub(to: dragStartTime - Double(value.translation.width) / model.pixelsPerSecond)
            }
            .onEnded { _ in
                rulerHeld = false
                model.endScrub()
            }
    }

}

/// The track colors to pick from: tap one and the track, its header stripe and its cut markers
/// all change.
struct TrackColorPicker: View {
    let selected: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Track color")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 5), spacing: 8) {
                ForEach(LayerTint.all.indices, id: \.self) { index in
                    Button { pick(index) } label: {
                        Corner.chip
                            .fill(LayerTint.all[index])
                            .frame(width: 36, height: 36)
                            .overlay(Corner.chip.strokeBorder(.white, lineWidth: index == selected ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LayerTint.names[index])
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .preferredColorScheme(.dark)
    }
}

/// A video's track header: its picture fills the box, with a stripe of its color down the left
/// edge and its number in the corner. Full brightness while it's the one on screen, dimmed otherwise.
struct LayerChip: View {
    let layer: Layer
    let lit: Bool
    var previewing = false
    /// Tall tracks: the whole picture shows, uncropped.
    var tall = false

    var body: some View {
        let tint = LayerTint.color(layer)
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail = layer.thumbnail {
                    Image(uiImage: thumbnail).resizable()
                        .aspectRatio(contentMode: tall ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else {
                    Color.white.opacity(0.12)
                        .overlay(Image(systemName: "video").font(.caption).foregroundStyle(.white.opacity(0.6)))
                }
            }
            .frame(width: LaneMetrics.labelWidth - 6, height: LaneMetrics.laneHeight(tall: tall) - 8)
            .clipped()
            .opacity(lit || previewing ? 1 : 0.55)

            Group {
                if previewing {
                    Image(systemName: "eye.fill").font(.caption.weight(.bold))
                } else {
                    Text("\(layer.id + 1)").font(.caption.weight(.heavy).monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2)
            .padding(.leading, 8)
            .padding(.bottom, 2)
        }
        .frame(width: LaneMetrics.labelWidth - 6, height: LaneMetrics.laneHeight(tall: tall) - 8, alignment: .bottomLeading)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 4)
        }
        .clipShape(Corner.small)
    }
}

/// Seconds along the top: a label every second or so ("1s", "2s"), with small ticks between.
struct Ruler: View {
    let time: Double
    let pixelsPerSecond: Double
    /// Where the ruler ends (timeline seconds).
    let duration: Double
    /// The timeline second that reads 0 (the edit page counts from the clip's start).
    var origin: Double = 0

    var body: some View {
        Canvas { context, size in
            let middle = size.width / 2
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60]
            let step = steps.first { $0 * pixelsPerSecond >= 56 } ?? 60
            let minor = step / 4 * pixelsPerSecond >= 10 ? step / 4 : step / 2
            let now = time - origin
            let span = duration - origin
            var mark = max(0, (floor((now - Double(middle) / pixelsPerSecond) / step)) * step)
            while mark <= span + 0.0001 {
                let x = middle + CGFloat((mark - now) * pixelsPerSecond)
                if x > size.width + 30 { break }
                let major = abs((mark / step).rounded() * step - mark) < 0.0001
                if major {
                    context.draw(Text(LaneMetrics.rulerLabel(mark)).font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.65)),
                                 at: CGPoint(x: x, y: 1), anchor: .top)
                    context.fill(Path(CGRect(x: x - 0.5, y: size.height - 7, width: 1, height: 7)),
                                 with: .color(.white.opacity(0.55)))
                } else {
                    context.fill(Path(CGRect(x: x - 0.5, y: size.height - 4, width: 1, height: 4)),
                                 with: .color(.white.opacity(0.35)))
                }
                mark += minor
            }
        }
    }
}

/// A video's small frames for the timeline, one every `step` seconds of the video.
struct Filmstrip {
    let step: Double
    let frames: [CGImage?]

    /// The frame nearest a second into the video (the nearest one that loaded).
    func frame(at second: Double) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let index = min(max(Int(second / step), 0), frames.count - 1)
        if let frame = frames[index] { return frame }
        for reach in 1..<frames.count {
            if index - reach >= 0, let frame = frames[index - reach] { return frame }
            if index + reach < frames.count, let frame = frames[index + reach] { return frame }
        }
        return nil
    }
}

/// The song's colors on the timeline: a grey bar with a lighter waveform.
enum SongTint {
    static let color = Color(white: 0.27)
    static let wave = Color.white.opacity(0.35)
}
