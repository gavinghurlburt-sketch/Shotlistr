import Foundation
import AVFoundation
import Speech

// Lyrics, brought over from Gavin's Lyric Sync web tool (lyric-sync-web): the same words-with-times
// model, the same look settings and presets, the same timing rules (lead, tail, pop, stack), and the
// same clean-up and "re-time my words" logic. Only the listening part is new: on the phone it uses
// Apple's on-device speech model instead of Whisper in the browser.

/// One sung word, in timeline seconds. `br` ends its line.
struct LyricWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var br: Bool = false
    /// This word's own color ("#ff3b8d"); nil uses the look's color.
    var color: String? = nil
}

enum LyricMode: String, Codable, CaseIterable, Sendable {
    case single, stack, line
    var name: String {
        switch self {
        case .single: return "One word"
        case .stack: return "Build the line"
        case .line: return "Line by line"
        }
    }
}

enum LyricEntry: String, Codable, CaseIterable, Sendable {
    case pop, slam, fade, blur, rise, cut
    var name: String {
        switch self {
        case .pop: return "Pop"
        case .slam: return "Slam"
        case .fade: return "Fade"
        case .blur: return "Blur in"
        case .rise: return "Rise"
        case .cut: return "Cut"
        }
    }
}

enum LyricCase: String, Codable, CaseIterable, Sendable {
    case upper, lower, title, asIs
    var name: String {
        switch self {
        case .upper: return "ABC"
        case .lower: return "abc"
        case .title: return "Abc"
        case .asIs: return "As typed"
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.lowercased().capitalized
        case .asIs: return text
        }
    }
}

/// Fonts that come with every iPhone.
enum LyricFont: String, Codable, CaseIterable, Sendable {
    case heavy, condensed, futura, avenir, didot, script, typewriter, marker, mono
    // Shipped with the app (editrr/Fonts), registered at launch by FontLibrary.
    case arimo, lora, openSans, outfit, playfair, roboto, robotoSlab, shantell, sniglet

    var name: String {
        switch self {
        case .heavy: return "Heavy"
        case .condensed: return "Tall"
        case .futura: return "Futura"
        case .avenir: return "Avenir"
        case .didot: return "Didot"
        case .script: return "Script"
        case .typewriter: return "Typewriter"
        case .marker: return "Marker"
        case .mono: return "Mono"
        case .arimo: return "Arimo"
        case .lora: return "Lora"
        case .openSans: return "Open Sans"
        case .outfit: return "Outfit"
        case .playfair: return "Playfair"
        case .roboto: return "Roboto"
        case .robotoSlab: return "Roboto Slab"
        case .shantell: return "Shantell"
        case .sniglet: return "Sniglet"
        }
    }

    /// The font's PostScript name (nil: the system font, black weight).
    var postScript: String? {
        switch self {
        case .heavy: return nil
        case .condensed: return "HelveticaNeue-CondensedBlack"
        case .futura: return "Futura-CondensedExtraBold"
        case .avenir: return "AvenirNext-Heavy"
        case .didot: return "Didot-Bold"
        case .script: return "SnellRoundhand-Black"
        case .typewriter: return "AmericanTypewriter-Bold"
        case .marker: return "MarkerFelt-Wide"
        case .mono: return "Menlo-Bold"
        case .arimo: return "Arimo-Bold"
        case .lora: return "Lora-Bold"
        case .openSans: return "OpenSans-ExtraBold"
        case .outfit: return "Outfit-Black"
        case .playfair: return "PlayfairDisplay-Black"
        case .roboto: return "Roboto-Black"
        case .robotoSlab: return "RobotoSlab-Black"
        case .shantell: return "ShantellSans-ExtraBold"
        case .sniglet: return "Sniglet-ExtraBold"
        }
    }
}

/// The look, as in Lyric Sync. Sizes are in pixels on a 1080-wide frame.
struct LyricStyle: Codable, Equatable, Sendable {
    var show = true
    var mode = LyricMode.single
    var font = LyricFont.heavy
    /// One of your own fonts (its PostScript name). Empty: the built-in `font` is used.
    var customFont = ""
    var size: Double = 170
    var textCase = LyricCase.upper
    var tracking: Double = 0
    var color = "#ffffff"
    var posX: Double = 50
    var posY: Double = 50
    var maxWidth: Double = 86
    var lineGap: Double = 1.05
    var rotate: Double = 0
    var stroke: Double = 0
    var strokeColor = "#000000"
    var entry = LyricEntry.pop
    var entryDur: Double = 0.14
    var popScale: Double = 1.35
    var exitFade = false
    var exitDur: Double = 0.12
    /// Show words this many seconds before they're sung.
    var lead: Double = 0.03
    /// Hold after a word ends (until the next word comes in).
    var tail: Double = 0.45
    var stackDim: Double = 0.5
    var activeColor = ""
    var glow: Double = 0.7
    var glowRadius: Double = 22
    var glowColor = "#ff3b8d"
    var bloom: Double = 0.5
    var chroma: Double = 2
    var chromaAngle: Double = 0
    var hitChroma: Double = 10
    var hitGlow: Double = 0.9
    var shake: Double = 5
    var hitDecay: Double = 0.22
    /// Rainbow: every letter takes the next color of `palette`, running on across all the words.
    var rainbow = false
    var palette: [String] = LyricStyle.palettes[0].colors

    /// Ready-made rainbow palettes.
    static let palettes: [(name: String, colors: [String])] = [
        ("Rainbow", ["#ff3b3b", "#ff9f1a", "#ffe14d", "#3ddc6b", "#2fb8ff", "#a06bff"]),
        ("Neon", ["#ff3b8d", "#00e5ff", "#fff36b", "#7dff9a"]),
        ("Pastel", ["#ffb3c7", "#ffd9a8", "#fff3b0", "#b8f2c8", "#b3dcff", "#d6c2ff"]),
        ("Fire", ["#ff2d2d", "#ff7a1a", "#ffc21a", "#fff36b"]),
        ("Ocean", ["#00e5ff", "#2fb8ff", "#4d7cff", "#7dffe0"])
    ]

    init() {}

    /// The font to draw with: your own if one is picked, else the built-in one (nil: system Heavy).
    var postScript: String? { customFont.isEmpty ? font.postScript : customFont }

    /// Any setting missing from an older save keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = LyricStyle()
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let found = try? c.decodeIfPresent(T.self, forKey: key) { value = found }
        }
        read(.show, &s.show); read(.mode, &s.mode); read(.font, &s.font); read(.size, &s.size)
        read(.customFont, &s.customFont)
        read(.textCase, &s.textCase); read(.tracking, &s.tracking); read(.color, &s.color)
        read(.posX, &s.posX); read(.posY, &s.posY); read(.maxWidth, &s.maxWidth); read(.lineGap, &s.lineGap)
        read(.rotate, &s.rotate); read(.stroke, &s.stroke); read(.strokeColor, &s.strokeColor)
        read(.entry, &s.entry); read(.entryDur, &s.entryDur); read(.popScale, &s.popScale)
        read(.exitFade, &s.exitFade); read(.exitDur, &s.exitDur); read(.lead, &s.lead); read(.tail, &s.tail)
        read(.stackDim, &s.stackDim); read(.activeColor, &s.activeColor); read(.glow, &s.glow)
        read(.glowRadius, &s.glowRadius); read(.glowColor, &s.glowColor); read(.bloom, &s.bloom)
        read(.chroma, &s.chroma); read(.chromaAngle, &s.chromaAngle); read(.hitChroma, &s.hitChroma)
        read(.hitGlow, &s.hitGlow); read(.shake, &s.shake); read(.hitDecay, &s.hitDecay)
        read(.rainbow, &s.rainbow); read(.palette, &s.palette)
        self = s
    }

    /// Lyric Sync's ready-made looks. Each starts from the default, keeping where the words sit,
    /// the font and whether they show.
    static let presets: [(name: String, apply: (inout LyricStyle) -> Void)] = [
        ("Neon Pop", { _ in }),
        ("Hard Slam", { s in
            s.entry = .slam; s.entryDur = 0.1; s.popScale = 1.4; s.glow = 0.35; s.glowColor = "#ffffff"
            s.glowRadius = 16; s.bloom = 0.3; s.chroma = 4; s.hitChroma = 22; s.shake = 12; s.hitDecay = 0.18; s.tail = 0.3
        }),
        ("Glitch Stack", { s in
            s.mode = .stack; s.size = 120; s.entry = .pop; s.popScale = 1.6; s.entryDur = 0.1; s.glow = 0.4
            s.glowColor = "#00e5ff"; s.chroma = 6; s.hitChroma = 18; s.shake = 8; s.stackDim = 0.45; s.activeColor = "#fff36b"
        }),
        ("Dreamy Fade", { s in
            s.entry = .blur; s.entryDur = 0.35; s.exitFade = true; s.exitDur = 0.3; s.glow = 1.1; s.glowRadius = 40
            s.glowColor = "#a98bff"; s.bloom = 0.9; s.chroma = 1; s.hitChroma = 3; s.shake = 0; s.textCase = .asIs; s.tail = 0.8
        }),
        ("Clean Subtle", { s in
            s.entry = .rise; s.entryDur = 0.18; s.glow = 0.15; s.glowColor = "#ffffff"; s.bloom = 0
            s.chroma = 0; s.hitChroma = 0; s.shake = 0; s.size = 140
        })
    ]

    func withPreset(_ index: Int) -> LyricStyle {
        guard Self.presets.indices.contains(index) else { return self }
        var next = LyricStyle()
        next.show = show
        next.font = font
        next.customFont = customFont
        next.posX = posX
        next.posY = posY
        Self.presets[index].apply(&next)
        return next
    }
}

// MARK: - What shows when (Lyric Sync's frameState)

enum LyricTiming {
    struct WordState {
        var index: Int
        var hidden = false
        var scale: Double = 1
        var alpha: Double = 1
        var blur: Double = 0
        var dy: Double = 0
        var active = false
    }

    struct Item {
        var line: [Int]
        var words: [WordState]
    }

    struct Frame {
        var items: [Item] = []
        /// How hard the latest word just landed (1 right on it, fading out): drives shake and the flash.
        var hit: Double = 0
    }

    static func lines(_ words: [LyricWord]) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        for (index, word) in words.enumerated() {
            current.append(index)
            if word.br || index == words.count - 1 {
                lines.append(current)
                current = []
            }
        }
        return lines
    }

    private static func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
    private static func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    private static func easeOutBack(_ p: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
    private static func easeOutExpo(_ p: Double) -> Double { p >= 1 ? 1 : 1 - pow(2, -10 * p) }

    static func frame(_ words: [LyricWord], style: LyricStyle, at t: Double) -> Frame {
        var frame = Frame()
        guard !words.isEmpty else { return frame }
        let lead = style.lead, tail = style.tail
        func hitOf(_ start: Double) -> Double {
            let dt = t - (start - lead)
            return dt >= 0 ? exp(-dt / max(0.01, style.hitDecay)) : 0
        }
        func entry(_ w: LyricWord, _ index: Int) -> WordState {
            let p = clamp((t - (w.start - lead)) / max(0.001, style.entryDur), 0, 1)
            var s = WordState(index: index)
            switch style.entry {
            case .pop:
                s.scale = style.popScale + (1 - style.popScale) * easeOutBack(p)
                s.alpha = clamp(p * 3, 0, 1)
            case .slam:
                s.scale = 1 + (style.popScale * 1.6 - 1) * (1 - easeOutExpo(p))
                s.alpha = clamp(p * 2.5, 0, 1)
            case .fade:
                s.alpha = easeOutCubic(p)
            case .blur:
                s.blur = (1 - easeOutCubic(p)) * 24
                s.alpha = easeOutCubic(p)
                s.scale = 1 + 0.08 * (1 - p)
            case .rise:
                s.dy = (1 - easeOutCubic(p)) * 0.4
                s.alpha = easeOutCubic(p)
            case .cut:
                break
            }
            return s
        }

        if style.mode == .line {
            // The whole line shows at once while it's sung, with no word by word build.
            let all = lines(words)
            for (li, idx) in all.enumerated() {
                let first = words[idx[0]], last = words[idx[idx.count - 1]]
                let show = first.start - lead
                var hide = last.end + tail
                var cut = false
                if li + 1 < all.count, words[all[li + 1][0]].start - lead < hide {
                    hide = words[all[li + 1][0]].start - lead
                    cut = true
                }
                if t < show || t >= hide { continue }
                var lineAlpha = 1.0
                if !cut && style.exitFade { lineAlpha = clamp((hide - t) / max(0.01, style.exitDur), 0, 1) }
                // The line comes in as one, with the first word's entry.
                let came = entry(first, idx[0])
                frame.hit = hitOf(first.start)
                let states = idx.map { i -> WordState in
                    var s = came
                    s.index = i
                    s.alpha *= lineAlpha
                    return s
                }
                frame.items.append(Item(line: idx, words: states))
                break // one line at a time
            }
        } else if style.mode == .stack {
            let all = lines(words)
            for (li, idx) in all.enumerated() {
                let first = words[idx[0]], last = words[idx[idx.count - 1]]
                let show = first.start - lead
                var hide = last.end + tail
                var cut = false
                if li + 1 < all.count, words[all[li + 1][0]].start - lead < hide {
                    hide = words[all[li + 1][0]].start - lead
                    cut = true
                }
                if t < show || t >= hide { continue }
                var lineAlpha = 1.0
                if !cut && style.exitFade { lineAlpha = clamp((hide - t) / max(0.01, style.exitDur), 0, 1) }
                var active = -1
                for i in idx where t >= words[i].start - lead { active = i }
                var states: [WordState] = []
                for i in idx {
                    let w = words[i]
                    if t < w.start - lead {
                        states.append(WordState(index: i, hidden: true))
                        continue
                    }
                    var s = entry(w, i)
                    frame.hit = max(frame.hit, hitOf(w.start))
                    s.active = i == active
                    s.alpha *= lineAlpha * (s.active ? 1 : style.stackDim)
                    states.append(s)
                }
                frame.items.append(Item(line: idx, words: states))
                break // one line at a time
            }
        } else {
            for i in stride(from: words.count - 1, through: 0, by: -1) {
                let w = words[i]
                if t < w.start - lead { continue }
                var hide = w.end + tail
                var cut = false
                if i + 1 < words.count, words[i + 1].start - lead < hide {
                    hide = words[i + 1].start - lead
                    cut = true
                }
                if t < hide {
                    var s = entry(w, i)
                    if !cut && style.exitFade { s.alpha *= clamp((hide - t) / max(0.01, style.exitDur), 0, 1) }
                    s.active = true
                    frame.items.append(Item(line: [i], words: [s]))
                    frame.hit = hitOf(w.start)
                }
                break
            }
        }
        if frame.hit < 0.003 { frame.hit = 0 }
        return frame
    }
}

// MARK: - Cleaning up what was heard, lines, and "Re-time my words" (Lyric Sync's local.js)

enum LyricText {
    /// Lower case letters, numbers and apostrophes only, for matching words.
    static func norm(_ word: String) -> String {
        let folded = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars
        where CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "'" {
            kept.append(scalar)
        }
        return String(kept)
    }

    /// Lyric Sync's tidy: drops "words" held over 6 s (the model filling a gap), overlapping
    /// repeats, and loops (a 1 to 4 word phrase repeated 4 or more times in a row keeps one copy).
    static func tidy(_ list: [LyricWord]) -> [LyricWord] {
        let real = list.sorted { $0.start < $1.start }.filter { $0.end - $0.start <= 6 && !norm($0.text).isEmpty }
        var kept: [LyricWord] = []
        for word in real {
            if let previous = kept.last, word.start < previous.end - 0.1 { continue }
            kept.append(word)
        }
        var out: [LyricWord] = []
        var i = 0
        while i < kept.count {
            var skipped = false
            var n = 1
            while n <= 4 && !skipped {
                if i + n <= kept.count {
                    let phrase = kept[i..<(i + n)].map { norm($0.text) }
                    var reps = 1
                    while i + (reps + 1) * n <= kept.count,
                          kept[(i + reps * n)..<(i + (reps + 1) * n)].map({ norm($0.text) }) == phrase {
                        reps += 1
                    }
                    if reps >= 4 {
                        out.append(contentsOf: kept[i..<(i + n)])
                        i += reps * n
                        skipped = true
                    }
                }
                n += 1
            }
            if !skipped {
                out.append(kept[i])
                i += 1
            }
        }
        return out
    }

    /// Lyric Sync's toWords: strips punctuation, breaks lines at sentence ends and pauses, and
    /// splits long lines at their biggest gap.
    static func lines(from heard: [LyricWord], maxWords: Int = 7, gap: Double = 0.6) -> [LyricWord] {
        struct Piece { var text: String; var start: Double; var end: Double; var segment: Int }
        let strip = CharacterSet(charactersIn: ".,;:!?\"\u{201C}\u{201D}\u{2026}")
        var pieces: [Piece] = []
        var segment = 0
        for word in heard {
            let raw = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var keptScalars = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars where !strip.contains(scalar) { keptScalars.append(scalar) }
            let text = String(keptScalars).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !norm(text).isEmpty {
                pieces.append(Piece(text: text, start: word.start, end: max(word.end, word.start + 0.06), segment: segment))
            }
            if let last = raw.last, ".!?".contains(last) { segment += 1 }
        }
        var lines: [[Piece]] = []
        var current: [Piece] = []
        for piece in pieces {
            if let last = current.last, piece.start - last.end > gap || piece.segment != last.segment {
                lines.append(current)
                current = []
            }
            current.append(piece)
        }
        if !current.isEmpty { lines.append(current) }

        var finished: [[Piece]] = []
        var stack = Array(lines.reversed())
        while let line = stack.popLast() {
            if line.count <= maxWords {
                finished.append(line)
                continue
            }
            let lo = max(2, line.count / 3), hi = min(line.count - 2, 2 * line.count / 3 + 1)
            var split = lo
            var best = -Double.infinity
            if lo <= hi {
                for j in lo...hi {
                    let g = line[j].start - line[j - 1].end - abs(Double(j) - Double(line.count) / 2) * 0.01
                    if g > best { best = g; split = j }
                }
            }
            stack.append(Array(line[split...]))
            stack.append(Array(line[..<split]))
        }

        var words: [LyricWord] = []
        for line in finished {
            for (i, piece) in line.enumerated() {
                words.append(LyricWord(text: piece.text, start: piece.start, end: piece.end, br: i == line.count - 1))
            }
        }
        for i in words.indices {
            if i > 0, words[i].start < words[i - 1].start { words[i].start = words[i - 1].start + 0.01 }
            words[i].end = (max(words[i].end, words[i].start + 0.06) * 1000).rounded() / 1000
            words[i].start = (words[i].start * 1000).rounded() / 1000
        }
        return words
    }

    /// "Re-time my words": keeps the words as typed, takes the times from `heard` wherever the
    /// words match (in order), and spreads the rest between their neighbors.
    static func retime(_ mine: [LyricWord], to heard: [LyricWord]) -> (words: [LyricWord], missing: Int) {
        let a = mine.map { norm($0.text) }, b = heard.map { norm($0.text) }
        let n = a.count, m = b.count
        guard n > 0 else { return ([], 0) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var map = [Int](repeating: -1, count: n)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                map[i] = j
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var out = mine
        var unmatched = [Bool](repeating: false, count: n)
        for k in 0..<n {
            if map[k] >= 0 {
                out[k].start = heard[map[k]].start
                out[k].end = heard[map[k]].end
            } else {
                unmatched[k] = true
            }
        }
        var k = 0
        while k < n {
            guard unmatched[k] else { k += 1; continue }
            var e = k
            while e < n && unmatched[e] { e += 1 }
            let count = Double(e - k)
            let previous = k > 0 ? out[k - 1].end : max(0, (e < n ? out[e].start : 0) - 0.4 * count)
            let next = e < n ? out[e].start : previous + 0.4 * count
            let step = max(0.06, (next - previous) / count)
            for q in k..<e {
                out[q].start = previous + step * Double(q - k)
                out[q].end = out[q].start + step * 0.85
            }
            k = e
        }
        return (out, unmatched.filter { $0 }.count)
    }

    /// Typed lyrics (one line per line) as words, spread evenly from `start`. Re-timing then lines
    /// them up with the singing.
    static func words(fromTyped text: String, start: Double, perWord: Double = 0.4) -> [LyricWord] {
        var words: [LyricWord] = []
        var at = start
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (i, part) in parts.enumerated() {
                words.append(LyricWord(text: part, start: at, end: at + perWord * 0.85, br: i == parts.count - 1))
                at += perWord
            }
        }
        return words
    }

    /// The words, one line per lyric line, for editing as text.
    static func typed(_ words: [LyricWord]) -> String {
        LyricTiming.lines(words).map { line in line.map { words[$0].text }.joined(separator: " ") }
            .joined(separator: "\n")
    }
}

// MARK: - Listening (Apple's on-device speech model in place of Whisper)

enum LyricListenError: LocalizedError {
    case unavailable, noLanguage, nothingHeard, noSound

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This phone can't listen for words. You can type or paste them instead."
        case .noLanguage: return "This phone's language isn't one the speech model knows yet."
        case .nothingHeard: return "Didn't hear any words. Is there singing in the song?"
        case .noSound: return "There's no sound to listen to. Pick a song first."
        }
    }
}

enum LyricListener {
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Listens to the whole soundtrack and writes down every word with its time (timeline seconds).
    /// `update` gets short progress lines for the screen.
    static func listen(to asset: AVAsset, update: @escaping @Sendable (String) -> Void) async throws -> [LyricWord] {
        guard SpeechTranscriber.isAvailable else { throw LyricListenError.unavailable }
        update("Getting the song ready…")
        let url = try await writeAudio(of: asset)
        defer { try? FileManager.default.removeItem(at: url) }

        var found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if found == nil {
            found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale = found else { throw LyricListenError.noLanguage }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            update("Downloading Apple's speech model (only the first time)…")
            try await request.downloadAndInstall()
        }

        update("Listening to the song…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collector = Task { () async throws -> [LyricWord] in
            var heard: [LyricWord] = []
            for try await result in transcriber.results {
                heard.append(contentsOf: pieces(of: result.text))
                if let last = heard.last {
                    update("Listening… \(heard.count) words so far, up to \(clock(last.end)).")
                }
            }
            return heard
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let heard = try await collector.value
        let words = LyricText.lines(from: LyricText.tidy(heard))
        guard !words.isEmpty else { throw LyricListenError.nothingHeard }
        return words
    }

    /// The words in one result, each with its time. A piece with no space in front of it carries on
    /// the word before it; a piece holding several words shares its time out by length.
    private static func pieces(of text: AttributedString) -> [LyricWord] {
        var out: [LyricWord] = []
        var lastEndedInSpace = true
        for run in text.runs {
            let piece = String(text[run.range].characters)
            defer { lastEndedInSpace = piece.last?.isWhitespace ?? lastEndedInSpace }
            guard let range = run.audioTimeRange else { continue }
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            let parts = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !parts.isEmpty else { continue }
            let joins = !(piece.first?.isWhitespace ?? true) && !lastEndedInSpace && !out.isEmpty
            let total = parts.reduce(0) { $0 + max(1, $1.count) }
            var at = start
            for (i, part) in parts.enumerated() {
                let length = (end - start) * Double(max(1, part.count)) / Double(total)
                if i == 0 && joins {
                    out[out.count - 1].text += part
                    out[out.count - 1].end = at + length
                } else {
                    out.append(LyricWord(text: part, start: at, end: at + length))
                }
                at += length
            }
        }
        return out
    }

    /// The soundtrack as a small mono file the speech model can read (16 kHz).
    private static func writeAudio(of asset: AVAsset) async throws -> URL {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw LyricListenError.noSound }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LyricListenError.noSound }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LyricListenError.noSound }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false) else { throw LyricListenError.noSound }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editrr-lyrics-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                                    dataLength: count * MemoryLayout<Float>.size,
                                                    destination: channel)
            guard status == kCMBlockBufferNoErr else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
        if reader.status == .failed { throw reader.error ?? LyricListenError.noSound }
        return url
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
