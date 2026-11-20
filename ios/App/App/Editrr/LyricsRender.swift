import Foundation
import CoreImage
import CoreText
import UIKit

/// Draws the lyrics for one frame, the same three steps as Lyric Sync's render.js: the text, then
/// glow and bloom added under it, then the color split (chromatic aberration). Used by the
/// compositor for both preview and export. The words and look can change while the video plays.
final class LyricsOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [LyricWord]
    private var style: LyricStyle
    private var cache: [String: Glyph] = [:]
    /// Titles and other text, drawn over the lyrics.
    private var titles: [TitleClip]

    init(words: [LyricWord] = [], style: LyricStyle = LyricStyle(), titles: [TitleClip] = []) {
        self.words = Self.shown(words, style)
        self.style = style
        self.titles = titles
    }

    func update(titles: [TitleClip]) {
        lock.lock()
        self.titles = titles
        lock.unlock()
    }

    /// The lyrics and any text at time `t` on a clear background, or nil when nothing shows.
    func image(at t: Double, canvas: CGSize) -> CIImage? {
        let sung = lyricsImage(at: t, canvas: canvas)
        guard let text = titlesImage(at: t, canvas: canvas) else { return sung }
        guard let sung else { return text }
        return text.composited(over: sung)
    }

    /// While the edit page's video eye is off: the preview shows black under the words.
    private var hidesVideo = false
    var videoHidden: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hidesVideo
    }
    func setVideoHidden(_ hidden: Bool) {
        lock.lock()
        hidesVideo = hidden
        lock.unlock()
    }

    /// The words inside where the lyrics come in and go out (all of them when they aren't trimmed).
    static func shown(_ words: [LyricWord], _ style: LyricStyle) -> [LyricWord] {
        guard let pieces = style.pieces else { return words }
        return words.filter { word in pieces.contains { word.start >= $0.from - 0.001 && word.start < $0.to } }
    }

    func update(words: [LyricWord], style: LyricStyle) {
        lock.lock()
        self.words = Self.shown(words, style)
        self.style = style
        lock.unlock()
    }

    /// Where the lyrics show at `t`, as fractions of the frame from the top left (nil when none show).
    func lyricsBox(at t: Double, canvas: CGSize) -> CGRect? {
        guard let extent = lyricsImage(at: t, canvas: canvas)?.extent,
              !extent.isEmpty, !extent.isInfinite, canvas.width > 0, canvas.height > 0 else { return nil }
        return CGRect(x: extent.minX / canvas.width, y: 1 - extent.maxY / canvas.height,
                      width: extent.width / canvas.width, height: extent.height / canvas.height)
    }

    /// The lyrics at time `t` on a clear background, or nil when nothing shows.
    private func lyricsImage(at t: Double, canvas: CGSize) -> CIImage? {
        lock.lock()
        let words = self.words
        let style = self.style
        lock.unlock()
        guard style.show, !words.isEmpty else { return nil }
        let frame = LyricTiming.frame(words, style: style, at: t)
        guard !frame.items.isEmpty else { return nil }

        let W = Double(canvas.width), H = Double(canvas.height)
        let k = min(W, H) / 1080
        let cx = W * style.posX / 100
        let cy = H - H * style.posY / 100           // Core Image's y goes up
        let maxW = W * style.maxWidth / 100
        let color = LyricColor.cg(style.color) ?? CGColor(gray: 1, alpha: 1)
        let active = style.activeColor.isEmpty ? nil : LyricColor.cg(style.activeColor)
        let stroke = LyricColor.cg(style.strokeColor) ?? CGColor(gray: 0, alpha: 1)
        func text(_ i: Int) -> String { style.textCase.apply(words[i].text) }
        /// A word's own color, if it has one, else the look's.
        func ownColor(_ i: Int) -> CGColor? {
            guard words.indices.contains(i), let hex = words[i].color else { return nil }
            return LyricColor.cg(hex)
        }
        func fill(_ i: Int) -> CGColor { ownColor(i) ?? color }
        // Rainbow: each letter the next palette color, counted on from the words before it, so a
        // word keeps its colors as the line builds. A word with its own color stays that color.
        let palette = style.rainbow ? style.palette.compactMap { LyricColor.cg($0) } : []
        var letterStarts: [Int] = []
        if !palette.isEmpty {
            var count = 0
            for word in words {
                letterStarts.append(count)
                count += style.textCase.apply(word.text).filter { !$0.isWhitespace }.count
            }
        }
        func glyph(_ s: String, _ size: Double, _ fill: CGColor, word: Int? = nil) -> Glyph {
            var colors: [CGColor] = []
            var offset = 0
            if let word, !palette.isEmpty, letterStarts.indices.contains(word), ownColor(word) == nil {
                colors = palette
                offset = letterStarts[word] % palette.count
            }
            return self.glyph(s, size: size, postScript: style.postScript, color: fill, stroke: style.stroke,
                              strokeColor: stroke, tracking: style.tracking * k, palette: colors, offset: offset)
        }
        // Words sit centered on their spot (Lyric Sync's default).
        func alignShift(_ width: Double) -> Double { 0 }

        // 1. The text layer.
        var layer = CIImage.empty()
        for item in frame.items {
            var size = style.size * k
            if style.mode == .single, let state = item.words.first {
                let own = fill(state.index)
                var g = glyph(text(state.index), size, own, word: state.index)
                if g.width > maxW {
                    size *= maxW / g.width
                    g = glyph(text(state.index), size, own, word: state.index)
                }
                layer = place(g, state: state, x: cx + alignShift(g.width), y: cy - state.dy * size)
                    .composited(over: layer)
            } else {
                let texts = item.line.map(text)
                let fills = item.line.map(fill)
                var glyphs = texts.indices.map { glyph(texts[$0], size, fills[$0], word: item.line[$0]) }
                let longest = glyphs.map { $0.width }.max() ?? 0
                if longest > maxW {
                    size *= maxW / longest
                    glyphs = texts.indices.map { glyph(texts[$0], size, fills[$0], word: item.line[$0]) }
                }
                let space = glyph(" ", size, color).width + style.tracking * k
                // Wrap into rows with fixed spots, so words don't shift as they appear.
                var rows: [(words: [Int], width: Double)] = []
                var row: [Int] = []
                var rowWidth = 0.0
                for (j, g) in glyphs.enumerated() {
                    let add = (row.isEmpty ? 0 : space) + g.width
                    if !row.isEmpty && rowWidth + add > maxW {
                        rows.append((row, rowWidth))
                        row = []
                        rowWidth = 0
                    }
                    rowWidth += (row.isEmpty ? 0 : space) + g.width
                    row.append(j)
                }
                if !row.isEmpty { rows.append((row, rowWidth)) }
                let lineHeight = size * style.lineGap
                var y = cy + Double(rows.count - 1) * lineHeight / 2
                for r in rows {
                    var x = cx - r.width / 2 + alignShift(r.width)
                    for j in r.words {
                        let state = item.words[j]
                        if !state.hidden {
                            let g = state.active && active != nil ? glyph(texts[j], size, active!) : glyphs[j]
                            layer = place(g, state: state, x: x + glyphs[j].width / 2, y: y - state.dy * size)
                                .composited(over: layer)
                        }
                        x += glyphs[j].width + space
                    }
                    y -= lineHeight
                }
            }
        }
        guard !layer.extent.isEmpty else { return nil }

        // Turn the whole block about its spot, and shake it when a word lands.
        var move = CGAffineTransform.identity
        if style.rotate != 0 {
            move = move.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(-style.rotate * Double.pi / 180)))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
        }
        if frame.hit > 0 && style.shake > 0 {
            let f = Int((t * 60).rounded(.down))
            let sx = (Self.hash(Double(f)) - 0.5) * 2 * style.shake * k * frame.hit
            let sy = (Self.hash(Double(f + 99)) - 0.5) * 2 * style.shake * k * frame.hit
            move = move.concatenating(CGAffineTransform(translationX: sx, y: -sy))
        }
        if !move.isIdentity { layer = layer.transformed(by: move) }

        // 2. Glow: a tight glow and a wide bloom, tinted and added under the text.
        var picture = layer
        let glowAmount = style.glow * (1 + style.hitGlow * frame.hit)
        if glowAmount > 0.001, let glowColor = LyricColor.ci(style.glowColor) {
            var glow = glowPass(layer, radius: style.glowRadius * k, amount: glowAmount, color: glowColor)
            if style.bloom > 0 {
                let bloom = glowPass(layer, radius: style.glowRadius * 3.2 * k, amount: glowAmount * style.bloom,
                                     color: glowColor)
                glow = add(bloom, glow)
            }
            picture = layer.composited(over: glow)
        }

        // 3. Color split: red one way, blue the other.
        let split = (style.chroma + style.hitChroma * frame.hit) * k
        if split > 0.25, let kernel = LyricShader.split {
            let angle = style.chromaAngle * .pi / 180
            let dx = cos(angle) * split, dy = -sin(angle) * split
            let reach = CGFloat(abs(dx) + abs(dy)) + 1
            let extent = picture.extent.insetBy(dx: -reach, dy: -reach)
            if let out = kernel.apply(extent: extent,
                                      roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
                                      arguments: [picture, CIVector(x: dx, y: dy)]) {
                picture = out
            }
        }
        return picture.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    // MARK: Titles

    /// The text clips showing at `t`. Each line is centered on the clip's spot; text wider than
    /// 90% of the frame shrinks to fit.
    private func titlesImage(at t: Double, canvas: CGSize) -> CIImage? {
        lock.lock()
        let titles = self.titles
        lock.unlock()
        // Lane T1 draws on top, so later lanes go first.
        let showing = titles.filter { t >= $0.start && t < $0.end }.sorted { $0.lane > $1.lane }
        guard !showing.isEmpty else { return nil }

        let W = Double(canvas.width), H = Double(canvas.height)
        var layer = CIImage.empty()
        for title in showing {
            guard !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Wrapped to its box onto new lines (and sized to fill the box when it has a height).
            let laid = TitleLayout.lay(title, canvas: canvas)
            let lines = laid.lines
            let maxW = laid.wrapWidth
            let color = LyricColor.cg(title.color) ?? CGColor(gray: 1, alpha: 1)
            let outlineColor = title.color.lowercased() == "#000000" ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
            func glyphs(_ size: Double) -> [Glyph] {
                lines.map {
                    glyph($0.isEmpty ? " " : $0, size: size, postScript: title.postScript, color: color,
                          stroke: title.outline ? 10 : 0, strokeColor: outlineColor, tracking: 0)
                }
            }
            var size = laid.size
            var made = glyphs(size)
            // Just in case a line measures a hair wider drawn than wrapped.
            let widest = made.map { $0.width }.max() ?? 0
            if widest > maxW, widest > 0 {
                size *= maxW / widest
                made = glyphs(size)
            }

            // Coming in, and fading out over the last moment.
            let into = t - title.start, left = title.end - t
            var alpha = 1.0, scale = 1.0, rise = 0.0
            let inTime = 0.35
            if title.entry != .cut, into < inTime {
                let p = max(0, into / inTime)
                let eased = 1 - pow(1 - p, 3)
                switch title.entry {
                case .cut: break
                case .fade: alpha = eased
                case .pop:
                    // Overshoots a little, then settles.
                    let c = 1.70158
                    let back = 1 + (c + 1) * pow(p - 1, 3) + c * pow(p - 1, 2)
                    scale = 0.6 + 0.4 * back
                    alpha = min(1, p * 2.5)
                case .rise:
                    rise = (1 - eased) * size * 0.6
                    alpha = eased
                }
            }
            if title.entry != .cut, left < 0.25 { alpha *= max(0, left / 0.25) }
            guard alpha > 0.001 else { continue }

            let cx = W * title.posX / 100
            let cy = H - H * title.posY / 100      // Core Image's y goes up
            let lineHeight = size * TitleLayout.leading
            var y = cy + Double(made.count - 1) * lineHeight / 2 - rise
            var block = CIImage.empty()
            for g in made {
                let w = g.image.extent.width, h = g.image.extent.height
                let move = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                    .concatenating(CGAffineTransform(translationX: cx, y: y))
                block = g.image.transformed(by: move).composited(over: block)
                y -= lineHeight
            }
            if scale != 1 {
                block = block.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: cx, y: cy)))
            }
            if title.shadow {
                // A soft dark copy under the text, so it reads on bright footage.
                let shade = block
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6)
                    ])
                    .applyingGaussianBlur(sigma: max(1, size * 0.05))
                    .transformed(by: CGAffineTransform(translationX: 0, y: -size * 0.04))
                block = block.composited(over: shade)
            }
            if alpha < 0.999 {
                // Same fade as the lyrics' words.
                block = block.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])
            }
            layer = block.composited(over: layer)
        }
        guard !layer.extent.isEmpty else { return nil }
        return layer.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    // MARK: Pieces

    /// One word's picture, centered on (x, y), scaled, faded and blurred by its entry.
    private func place(_ g: Glyph, state: LyricTiming.WordState, x: Double, y: Double) -> CIImage {
        var image = g.image
        if state.blur > 0.1 {
            image = image.applyingGaussianBlur(sigma: state.blur * g.size / 170)
        }
        if state.alpha < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, min(1, state.alpha)))
            ])
        }
        let w = g.image.extent.width, h = g.image.extent.height
        let move = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: state.scale, y: state.scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
        return image.transformed(by: move)
    }

    private func glowPass(_ layer: CIImage, radius: Double, amount: Double, color: CIColor) -> CIImage {
        let blurred = layer.applyingGaussianBlur(sigma: max(0.5, radius))
        let tinted = CIImage(color: color).cropped(to: blurred.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: blurred])
        var total = CIImage.empty()
        var left = amount
        while left > 0.001 {
            let piece = left >= 1 ? tinted : tinted.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: left)
            ])
            total = add(piece, total)
            left -= 1
        }
        return total
    }

    private func add(_ top: CIImage, _ bottom: CIImage) -> CIImage {
        if bottom.extent.isEmpty { return top }
        return top.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: bottom])
    }

    private static func hash(_ n: Double) -> Double {
        let s = sin(n * 127.1 + 311.7) * 43758.5453
        return s - s.rounded(.down)
    }

    // MARK: Text pictures (kept, so each word is drawn once)

    struct Glyph {
        let image: CIImage
        /// The text's own width (without the padding around it).
        let width: Double
        let size: Double
    }

    private func glyph(_ text: String, size: Double, postScript: String?, color: CGColor, stroke: Double,
                       strokeColor: CGColor, tracking: Double, palette: [CGColor] = [], offset: Int = 0) -> Glyph {
        let size = (size * 2).rounded() / 2
        let rainbow = palette.isEmpty ? "" : "|\(palette.map { $0.components ?? [] })|\(offset)"
        let key = "\(text)|\(size)|\(postScript ?? "system")|\(color.components ?? [])|\(stroke)|\(strokeColor.components ?? [])|\(tracking)\(rainbow)"
        lock.lock()
        if let found = cache[key] {
            lock.unlock()
            return found
        }
        lock.unlock()

        let made = Self.draw(text, size: size, postScript: postScript, color: color, stroke: stroke,
                             strokeColor: strokeColor, tracking: tracking, palette: palette, offset: offset)
        lock.lock()
        if cache.count > 600 { cache.removeAll() }
        cache[key] = made
        lock.unlock()
        return made
    }

    private static func draw(_ text: String, size: Double, postScript: String?, color: CGColor, stroke: Double,
                             strokeColor: CGColor, tracking: Double, palette: [CGColor] = [], offset: Int = 0) -> Glyph {
        let uiFont = postScript.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size, weight: .black)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): uiFont as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking
        ]
        if stroke > 0 {
            // Negative: fill and outline, the outline as wide as `stroke` percent of the size.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -stroke
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
        }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if !palette.isEmpty {
            // Rainbow: each letter (spaces skipped) the next color, starting `offset` along the palette.
            var n = offset
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byComposedCharacterSequences) { letter, range, _, _ in
                guard let letter, !letter.allSatisfy(\.isWhitespace) else { return }
                string.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                    value: palette[n % palette.count], range: NSRange(range, in: text))
                n += 1
            }
        }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = Double(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = ceil(size * 0.15 + stroke * size / 100)
        let pixelWidth = max(1, Int(ceil(width + pad * 2)))
        let pixelHeight = max(1, Int(ceil(Double(ascent + descent) + pad * 2)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Glyph(image: CIImage.empty(), width: width, size: size)
        }
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.textPosition = CGPoint(x: pad, y: pad + Double(descent))
        CTLineDraw(line, context)
        guard let picture = context.makeImage() else {
            return Glyph(image: CIImage.empty(), width: width, size: size)
        }
        return Glyph(image: CIImage(cgImage: picture), width: width, size: size)
    }
}

/// "#ff3b8d" to colors.
enum LyricColor {
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    static func cg(_ hex: String) -> CGColor? {
        guard let c = rgb(hex) else { return nil }
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    static func ci(_ hex: String) -> CIColor? {
        guard let c = rgb(hex), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIColor(red: c.0, green: c.1, blue: c.2, alpha: 1, colorSpace: space)
    }
}

/// The color split shader (in CustomFX.metal), loaded once.
enum LyricShader {
    static let split: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "lyricSplit", fromMetalLibraryData: data)
    }()
}
