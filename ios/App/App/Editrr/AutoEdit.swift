import AVFoundation
import Vision
import CoreGraphics

/// How often Auto edit cuts.
enum AutoPace: String, CaseIterable, Sendable {
    case slow, normal, fast

    var name: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    /// Beats between cuts (it cuts twice as often in the loud parts).
    var beats: Int {
        switch self {
        case .slow: 8
        case .normal: 4
        case .fast: 2
        }
    }

    /// Seconds between cuts when there's no beat to follow.
    var seconds: Double {
        switch self {
        case .slow: 4
        case .normal: 2
        case .fast: 1
        }
    }
}

/// One-tap starting points: each sets the length, the lyrics and the cuts.
enum StarterRecipe: CaseIterable, Identifiable, Sendable {
    case performanceCut, lyricVideo, teaser

    var id: Self { self }

    var name: String {
        switch self {
        case .performanceCut: "Performance cut"
        case .lyricVideo: "Lyric video"
        case .teaser: "15s teaser"
        }
    }

    var detail: String {
        switch self {
        case .performanceCut: "The whole song, cut on the beat, leaning on close-ups."
        case .lyricVideo: "The whole song with your lyrics on, slower cuts and wider shots."
        case .teaser: "The loudest 15 seconds of the song, with fast cuts."
        }
    }

    var icon: String {
        switch self {
        case .performanceCut: "music.mic"
        case .lyricVideo: "quote.bubble"
        case .teaser: "bolt"
        }
    }

    /// How Auto edit cuts for it.
    var style: AutoStyle {
        switch self {
        case .performanceCut: AutoStyle(pace: .normal, shots: .closeUps)
        case .lyricVideo: AutoStyle(pace: .slow, shots: .wide)
        case .teaser: AutoStyle(pace: .fast)
        }
    }
}

/// Which kind of shot Auto edit leans toward.
enum ShotLean: Equatable, Sendable {
    case closeUps, balanced, wide

    var name: String {
        switch self {
        case .closeUps: "close-ups"
        case .balanced: "a mix of shots"
        case .wide: "wide shots"
        }
    }
}

/// Everything that shapes an Auto edit: the pace, plus what a typed request asked for.
struct AutoStyle: Equatable, Sendable {
    var pace: AutoPace = .normal
    var fasterInLoudParts = true
    var shots: ShotLean = .balanced
    /// Layer indexes (0-based) to show more of, or to leave out when anything else can show.
    var moreOf: Set<Int> = []
    var lessOf: Set<Int> = []
    /// Only these layers (0-based), wherever they have footage. Empty: any.
    var onlyOf: Set<Int> = []
    /// Every take gets about the same screen time.
    var evenly = false
    /// Never cut from a take to one that looks a lot like it (same angle, same background).
    /// On unless the request says to cut between them anyway.
    var avoidAlike = true
    /// Which layers look a lot like each other (filled in when `avoidAlike` is on).
    var alike: [Int: Set<Int>] = [:]
    /// Shuffle: a number that makes a different (but still good) cut each time. Nil: the best cut.
    var shuffle: UInt64? = nil
}

/// Dice that roll the same way for the same number, so one Shuffle is one fixed cut.
struct ShuffleDice: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Transitions, effects and a color look a typed request asked for.
struct FXPlan: Equatable, Sendable {
    /// Where the transitions and effects go (the color look goes on every cut).
    enum Place: Sendable { case everyCut, loudParts, quietParts }

    /// One transition on every cut it goes on, or a mix of them (nil and not mixed: none asked for).
    var transition: TransitionKind?
    var mixed = false
    var length = 0.5
    var look: ColorLook = .none
    /// 0 none ... 1 strong.
    var shake = 0.0
    var glitch = 0.0
    var slowZoom = false
    var place: Place = .everyCut

    var isEmpty: Bool {
        transition == nil && !mixed && look == .none && shake < 0.01 && glitch < 0.01 && !slowZoom
    }

    /// The transitions a mix goes round.
    static let mix: [TransitionKind] = [.crossfade, .zoomPunch, .whip, .flash, .blur]

    /// Puts the plan on the cuts that start between `from` and `stop`. Returns how many it touched.
    func apply(to cuts: inout [Cut], from: Double, until stop: Double, duration: Double, loud: (Double) -> Bool) -> Int {
        guard !isEmpty else { return 0 }
        var touched = 0
        var turn = 0
        for i in cuts.indices where cuts[i].time >= from - 1e-6 && cuts[i].time < stop - 1e-6 {
            let end = i + 1 < cuts.count ? min(cuts[i + 1].time, stop) : min(duration, stop)
            let middle = (cuts[i].time + max(end, cuts[i].time)) / 2
            let here: Bool
            switch place {
            case .everyCut: here = true
            case .loudParts: here = loud(middle)
            case .quietParts: here = !loud(middle)
            }
            var fx = cuts[i].fx ?? CutFX()
            if look != .none { fx.color = look }
            if here {
                if shake >= 0.01 { fx.shake = shake }
                if glitch >= 0.01 {
                    fx.custom = "rgbSplit"
                    fx.customAmount = glitch
                }
                if slowZoom { cuts[i].zoom = turn % 2 == 0 ? .zoomIn : .zoomOut }
                if i > 0 {
                    if mixed {
                        cuts[i].transition = Transition(kind: Self.mix[turn % Self.mix.count], length: length)
                    } else if let transition {
                        cuts[i].transition = Transition(kind: transition, length: length)
                    }
                }
                turn += 1
            }
            cuts[i].fx = fx == CutFX() ? nil : fx
            if here || look != .none { touched += 1 }
        }
        return touched
    }
}

// MARK: - The beat

/// Finds the beat in a sound: how fast it goes (from how the hits repeat), then where each beat
/// falls (a dynamic-programming beat tracker, the standard way, after Ellis 2007), and which beat
/// starts each bar.
enum Beats {
    struct Found: Sendable {
        /// Asset seconds of every beat.
        let times: [Double]
        /// Which beat (0...3) starts the bars.
        let barPhase: Int
    }

    static func find(_ sound: SoundPrint) -> Found? {
        let n = sound.fluxFrames
        let bands = SoundReader.fluxBands
        guard n > 400, sound.flux.count == n * bands else { return nil }

        // How strongly new sound starts each hundredth of a second (all bands), and in the lowest two (kick).
        var onset = [Double](repeating: 0, count: n)
        var low = [Double](repeating: 0, count: n)
        for band in 0..<bands {
            let row = band * n
            for i in 0..<n {
                let rise = Double(max(0, sound.flux[row + i]))
                onset[i] += rise
                if band < 2 { low[i] += rise }
            }
        }
        // A light smooth, then scaled so the usual spread is 1.
        var smooth = onset
        for i in 1..<(n - 1) { smooth[i] = 0.25 * onset[i - 1] + 0.5 * onset[i] + 0.25 * onset[i + 1] }
        let mean = smooth.reduce(0, +) / Double(n)
        let spread = sqrt(smooth.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n))
        guard spread > 1e-9 else { return nil }
        let strength = smooth.map { ($0 - mean) / spread }

        // Tempo: the repeat (0.3 to 1 second, 200 to 60 BPM) that lines up best, leaning toward 120 BPM.
        let minLag = 30, maxLag = 100
        guard n > maxLag * 4 else { return nil }
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var sum = 0.0
            for i in 0..<(n - lag) { sum += strength[i] * strength[i + lag] }
            let lean = exp(-0.5 * pow(log2(Double(lag) / 50) / 0.9, 2))
            scores[lag] = sum / Double(n - lag) * lean
        }
        var bestLag = minLag
        for lag in minLag...maxLag where scores[lag] > scores[bestLag] { bestLag = lag }
        // Between whole hundredths, where the peak really sits.
        let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
        let bend = a - 2 * b + c
        let period = Double(bestLag) + (abs(bend) > 1e-12 ? 0.5 * (a - c) / bend : 0)
        guard period > 10 else { return nil }

        // Beats: each one rewards a strong hit and a steady gap from the beat before it.
        let tightness = 100.0
        var total = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let farthest = Int(2 * period), nearest = max(1, Int(period / 2))
        for i in 0..<n {
            var best = -Double.infinity
            var from = -1
            let lo = max(0, i - farthest), hi = i - nearest
            if hi >= lo {
                for j in lo...hi {
                    let gap = log(Double(i - j) / period)
                    let value = total[j] - tightness * gap * gap
                    if value > best { best = value; from = j }
                }
            }
            if from >= 0, best > 0 {
                total[i] = strength[i] + best
                back[i] = from
            } else {
                total[i] = strength[i]
            }
        }
        var last = max(0, n - Int(period))
        for i in last..<n where total[i] > total[last] { last = i }
        var frames: [Int] = []
        var at = last
        while at >= 0 {
            frames.append(at)
            at = back[at]
        }
        frames.reverse()
        guard frames.count >= 8 else { return nil }

        // The bar starts on the beat (of every four) with the most kick.
        var phaseScore = [Double](repeating: 0, count: 4)
        for (index, frame) in frames.enumerated() { phaseScore[index % 4] += low[frame] }
        var phase = 0
        for p in 1..<4 where phaseScore[p] > phaseScore[phase] { phase = p }

        let hopSeconds = Double(SoundReader.hop) / Double(SoundReader.sampleRate)
        return Found(times: frames.map { sound.start + Double($0) * hopSeconds }, barPhase: phase)
    }
}

// MARK: - Watching the clips

/// What one moment of a video looks like.
struct Look: Sendable {
    /// 0: no face. 0.4 to 1: a face, bigger (closer) is higher.
    let face: Double
    /// How crisp it is (bigger is sharper; compared across all the clips).
    let sharp: Double
    /// Average brightness, 0 to 1.
    let light: Double
}

/// One batch of seconds of one video to look at.
struct WatchJob: @unchecked Sendable {
    let asset: AVAsset
    let trackStart: Double
    let video: Int
    let seconds: [Int]
}

enum ClipWatcher {
    /// Looks at one frame per listed second (seconds into the video).
    static func watch(_ job: WatchJob) async -> [Int: Look] {
        let generator = AVAssetImageGenerator(asset: job.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let slack = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        let times = job.seconds.map { CMTime(seconds: job.trackStart + Double($0) + 0.5, preferredTimescale: 600) }
        var found: [Int: Look] = [:]
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            let second = Int((result.requestedTime.seconds - job.trackStart - 0.5).rounded())
            found[second] = look(at: image)
        }
        return found
    }

    static func look(at image: CGImage) -> Look {
        var face = 0.0
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty {
            let biggest = faces.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
            face = 0.4 + 0.6 * min(1, sqrt(biggest) * 2.5)
        }
        let (sharp, light) = measure(image)
        return Look(face: face, sharp: sharp, light: light)
    }

    /// Crispness (how much the picture changes from pixel to pixel) and brightness, in gray.
    static func measure(_ image: CGImage) -> (Double, Double) {
        let width = image.width, height = image.height
        guard width > 4, height > 4 else { return (0, 0.5) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0.5) }
        var brightness = 0.0
        for value in pixels { brightness += Double(value) }
        brightness /= Double(width * height) * 255
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let center = Double(pixels[row + x]) * 4
                let edges = Double(pixels[row + x - 1]) + Double(pixels[row + x + 1])
                    + Double(pixels[row - width + x]) + Double(pixels[row + width + x])
                let value = center - edges
                sum += value
                squares += value * value
                count += 1
            }
        }
        let average = sum / count
        return (sqrt(max(0, squares / count - average * average)), brightness)
    }
}

// MARK: - Making the edit

enum AutoEditor {
    struct Clip {
        let layer: Int
        let video: Int
        let offset: Double
        let start: Double      // timeline seconds the kept part starts
        let end: Double
    }

    /// Where to cut, between `from` and `to` (timeline seconds), following the beat when there is one.
    /// `loud` says whether a moment is one of the song's louder parts (where it cuts twice as often).
    static func cutTimes(from: Double, to: Double, beats: [Double], barPhase: Int,
                         style: AutoStyle, loud base: (Double) -> Bool) -> [Double] {
        let pace = style.pace
        func loud(_ time: Double) -> Bool { style.fasterInLoudParts && base(time) }
        var dice = style.shuffle.map { ShuffleDice($0) }
        var times = [from]
        guard beats.count >= 8 else {
            var at = from + pace.seconds
            while at < to - 0.5 {
                times.append(at)
                at += loud(at) ? pace.seconds / 2 : pace.seconds
            }
            return times
        }
        // The first bar start (or beat, when cutting every 2 beats) at or after `from`.
        guard var index = beats.firstIndex(where: { $0 >= from - 0.05 }) else { return times }
        if pace.beats >= 4 {
            while index < beats.count, (index - barPhase) % 4 != 0 { index += 1 }
        }
        while index < beats.count, beats[index] < to - 0.3 {
            let time = beats[index]
            if time - (times.last ?? from) > 0.3 {
                times.append(time)
            } else if times.count == 1 {
                times[0] = from            // the start stays where it is
            }
            var step = loud(time) ? max(2, pace.beats / 2) : pace.beats
            // Shuffle: now and then a cut comes a bar sooner or later, so each version feels new.
            if var roll = dice {
                step = [step, step, step, min(8, step * 2), max(2, step / 2)].randomElement(using: &roll) ?? step
                dice = roll
            }
            index += step
        }
        return times
    }

    /// Picks the best-looking clip for each stretch, never the same one twice in a row when
    /// another has footage there, and spreads the picks around.
    static func pick(times: [Double], to: Double, clips: [Clip], looks: [Int: [Int: Look]], style: AutoStyle) -> [Int] {
        // Sharpness is compared across every clip: the top 10% counts as fully sharp.
        let allSharp = looks.values.flatMap { $0.values.map { $0.sharp } }.sorted()
        let topSharp = allSharp.isEmpty ? 1 : max(allSharp[min(allSharp.count - 1, Int(Double(allSharp.count) * 0.9))], 1e-6)

        func score(_ clip: Clip, _ a: Double, _ b: Double) -> (score: Double, cover: Double) {
            let start = max(a, clip.start), end = min(b, clip.end)
            let cover = max(0, end - start) / max(b - a, 0.001)
            guard cover > 0, let seen = looks[clip.video] else { return (0, cover) }
            var total = 0.0, count = 0.0
            var t = start + 0.25
            while t < end {
                if let look = seen[Int((t - clip.offset).rounded(.down))] {
                    let sharp = min(1, look.sharp / topSharp)
                    let light = max(0, 1 - abs(look.light - 0.45) * 2.2)
                    // look.face: 0 no face, 0.4 a small face, up to 1 a close-up.
                    let shot: Double
                    switch style.shots {
                    case .balanced: shot = 0.55 * look.face
                    case .closeUps: shot = 0.75 * (look.face > 0 ? look.face * look.face : 0)
                    case .wide: shot = 0.55 * (look.face > 0 ? 1.4 - look.face : 0.35)
                    }
                    total += shot + 0.3 * sharp + 0.15 * light
                    count += 1
                }
                t += 0.5
            }
            return (count > 0 ? total / count : 0, cover)
        }

        var picks: [Int] = []
        var uses: [Int: Int] = [:]
        var dice = style.shuffle.map { ShuffleDice($0) }
        for (index, a) in times.enumerated() {
            let b = index + 1 < times.count ? times[index + 1] : to
            let rated = clips.map { (clip: $0, rating: score($0, a, b)) }
            var choices = rated.filter { $0.rating.cover >= 0.85 }
            if choices.isEmpty {
                let most = rated.map { $0.rating.cover }.max() ?? 0
                choices = most > 0 ? rated.filter { $0.rating.cover >= most - 0.001 } : []
            }
            // "Only take 6": just those, wherever they have footage (the rest fill in where they don't).
            if !style.onlyOf.isEmpty, choices.contains(where: { style.onlyOf.contains($0.clip.layer) }) {
                choices.removeAll { !style.onlyOf.contains($0.clip.layer) }
            }
            // No cut between look-alike takes: when only look-alikes have footage, it stays on the
            // one showing (a jump between two takes of the same angle looks like a glitch).
            if style.avoidAlike, let previous = picks.last, let twins = style.alike[previous], !twins.isEmpty {
                let others = choices.filter { !twins.contains($0.clip.layer) }
                if !others.isEmpty { choices = others }
            }
            if choices.count > 1, let previous = picks.last {
                choices.removeAll { $0.clip.layer == previous }
            }
            if choices.contains(where: { !style.lessOf.contains($0.clip.layer) }) {
                choices.removeAll { style.lessOf.contains($0.clip.layer) }
            }
            let recent = Set(picks.suffix(2))
            // Shuffle: each choice gets a little luck, so close calls go another way.
            let valued = choices.map { choice -> (clip: Clip, value: Double) in
                var luck = 0.0
                if var roll = dice {
                    luck = Double.random(in: 0..<0.35, using: &roll)
                    dice = roll
                }
                var even = 0.0
                if style.evenly {
                    // All takes equally: the less a take has been on so far, the more it's wanted.
                    let fewest = choices.map { uses[$0.clip.layer, default: 0] }.min() ?? 0
                    even = -0.6 * Double(uses[choice.clip.layer, default: 0] - fewest)
                }
                return (choice.clip, value(choice.rating.score, choice.clip.layer, recent, uses, style) + luck + even)
            }
            let best = valued.max { $0.value < $1.value }
            let layer = best?.clip.layer ?? picks.last ?? clips.first?.layer ?? 0
            picks.append(layer)
            uses[layer, default: 0] += 1
        }
        return picks
    }

    private static func value(_ score: Double, _ layer: Int, _ recent: Set<Int>, _ uses: [Int: Int],
                              _ style: AutoStyle) -> Double {
        var value = score
        if style.moreOf.contains(layer) { value += 0.5 }
        if recent.contains(layer) { value -= 0.12 }
        if uses[layer, default: 0] == 0 { value += 0.05 }
        return value
    }
}
