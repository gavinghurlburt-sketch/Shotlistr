import Foundation
import FoundationModels
import CoreGraphics

/// Typed requests for Auto edit ("faster cuts, more close-ups, less of video 3"), read by Apple's
/// on-device language model. Nothing leaves the phone. Needs a phone with Apple Intelligence on.
enum EditRequestReader {
    /// True when the on-device model is ready on this phone.
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why typed requests can't be used right now, in plain words (nil when they can).
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "Typed requests need a phone with Apple Intelligence (iPhone 15 Pro or newer)."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to type requests."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Typed requests work once it's ready."
        case .unavailable:
            return "Typed requests aren't available on this phone right now."
        }
    }

    @Generable
    enum PaceChoice {
        case slow, normal, fast
    }

    @Generable
    enum ShotChoice {
        case closeUps, balanced, wideShots
    }

    @Generable
    enum TransitionChoice {
        case none, crossfade, blur, zoomPunch, whip, dipToBlack, flash, mixed
    }

    @Generable
    enum LengthChoice {
        case quick, normal, slow
    }

    @Generable
    enum LookChoice {
        case none, blackAndWhite, noir, warm, cool, faded, punchy, vintage, dreamGlow
    }

    @Generable
    enum AmountChoice {
        case none, light, strong
    }

    @Generable
    enum PlaceChoice {
        case everyCut, loudParts, quietParts
    }

    @Generable
    struct Reading {
        @Guide(description: "False when the request only asks for transitions, effects or a color look and says nothing about cutting, pace, shots or which videos to show. True otherwise.")
        var recut: Bool
        @Guide(description: "How often to cut. slow: about every 2 bars. normal: every bar. fast: every 2 beats.")
        var pace: PaceChoice
        @Guide(description: "True to cut twice as often in the loud parts like the chorus. False for an even pace all the way through.")
        var fasterInLoudParts: Bool
        @Guide(description: "Which shots to show more of. closeUps: faces up close. wideShots: the whole scene or band. balanced: no preference.")
        var shots: ShotChoice
        @Guide(description: "Video numbers (starting at 1) the request asks to show more of, named by number or described by their color, lighting or look. Empty when none are meant.")
        var moreOf: [Int]
        @Guide(description: "Video numbers (starting at 1) the request asks to show less of or leave out, named by number or described by their color, lighting or look. Empty when none are meant.")
        var lessOf: [Int]
        @Guide(description: "Video numbers (starting at 1) the request asks to use only, like \"only take 6\" or \"just video 2\". Empty unless the request says only or just.")
        var onlyOf: [Int]
        @Guide(description: "True when the request asks to use all the videos or takes equally, evenly or the same amount. False otherwise.")
        var evenly: Bool
        @Guide(description: "True only when the request asks to cut between videos or takes that look alike or are the same angle anyway. False otherwise, including when it asks not to.")
        var allowAlike: Bool
        @Guide(description: "A transition between cuts the request asks for. crossfade: a dissolve or fade between shots. blur: a blur between shots. zoomPunch: a quick zoom into the next shot. whip: a whip pan or swipe. dipToBlack: fade through black. flash: a white flash. mixed: a variety of transitions. none when no transition is asked for.")
        var transition: TransitionChoice
        @Guide(description: "How long each transition takes. quick, normal or slow. normal when not mentioned.")
        var transitionLength: LengthChoice
        @Guide(description: "A color look for the whole edit. blackAndWhite, noir (dark black and white), warm, cool, faded, punchy (bold colors), vintage, dreamGlow (soft glow). none when no color look is asked for.")
        var look: LookChoice
        @Guide(description: "Camera shake the request asks for. none when not asked for.")
        var shake: AmountChoice
        @Guide(description: "An RGB split or glitch effect the request asks for. none when not asked for.")
        var glitch: AmountChoice
        @Guide(description: "True when the request asks for slow zooms or a Ken Burns move on the shots. False otherwise.")
        var slowZoom: Bool
        @Guide(description: "Where the transitions and effects go. loudParts: the chorus, drops or loud parts. quietParts: the verses or quiet parts. everyCut when the request doesn't say.")
        var effectsWhere: PlaceChoice
    }

    /// What a typed request asked for.
    struct Understood: Sendable {
        var style: AutoStyle
        var fx: FXPlan
        /// False when it only asked for effects, so the cuts stay as they are.
        var recut: Bool
    }

    /// `looks` describes each video's color and light, in order ("red light, dark").
    static func read(_ request: String, pace: AutoPace, videoCount: Int, looks: [String]) async throws -> Understood {
        let described = looks.enumerated().map { "Video \($0.offset + 1): \($0.element)." }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You turn a request for a music video edit into settings. The edit cuts between \(videoCount) \
            videos, numbered 1 to \(videoCount), all filmed to the same song. \
            When the request doesn't mention how often to cut, use \(pace.rawValue). \
            When it doesn't mention loud parts or the chorus, cut faster in the loud parts. \
            The request may name videos by number or describe them by color or lighting, like \
            "the red shots" or "the dark ones". Use this list to find which videos it means:
            \(described)
            Videos are also called takes or clips: take 6 is video 6. "Use take 6" means more of \
            video 6; "only take 6" or "just take 6" means only video 6. \
            Only list videos the request names or describes. \
            The request may also ask for transitions, effects or a color look. Leave each of those \
            at none (or false) unless the request asks for it.
            """)
        let reading = try await session.respond(to: request, generating: Reading.self).content
        var style = AutoStyle()
        switch reading.pace {
        case .slow: style.pace = .slow
        case .normal: style.pace = .normal
        case .fast: style.pace = .fast
        }
        style.fasterInLoudParts = reading.fasterInLoudParts
        switch reading.shots {
        case .closeUps: style.shots = .closeUps
        case .balanced: style.shots = .balanced
        case .wideShots: style.shots = .wide
        }
        let valid = 1...max(videoCount, 1)
        style.moreOf = Set(reading.moreOf.filter { valid.contains($0) }.map { $0 - 1 })
        style.lessOf = Set(reading.lessOf.filter { valid.contains($0) }.map { $0 - 1 }).subtracting(style.moreOf)
        style.onlyOf = Set(reading.onlyOf.filter { valid.contains($0) }.map { $0 - 1 })
        style.evenly = reading.evenly && style.onlyOf.isEmpty
        if reading.allowAlike { style.avoidAlike = false }
        // Only some takes: none of them is also left out.
        style.lessOf.subtract(style.onlyOf)

        var fx = FXPlan()
        switch reading.transition {
        case .none: break
        case .crossfade: fx.transition = .crossfade
        case .blur: fx.transition = .blur
        case .zoomPunch: fx.transition = .zoomPunch
        case .whip: fx.transition = .whip
        case .dipToBlack: fx.transition = .dipBlack
        case .flash: fx.transition = .flash
        case .mixed: fx.mixed = true
        }
        switch reading.transitionLength {
        case .quick: fx.length = 0.25
        case .normal: fx.length = 0.5
        case .slow: fx.length = 1.0
        }
        switch reading.look {
        case .none: fx.look = .none
        case .blackAndWhite: fx.look = .blackWhite
        case .noir: fx.look = .noir
        case .warm: fx.look = .warm
        case .cool: fx.look = .cool
        case .faded: fx.look = .faded
        case .punchy: fx.look = .punchy
        case .vintage: fx.look = .vintage
        case .dreamGlow: fx.look = .dream
        }
        fx.shake = amount(reading.shake, light: 0.25, strong: 0.6)
        fx.glitch = amount(reading.glitch, light: 0.3, strong: 0.75)
        fx.slowZoom = reading.slowZoom
        switch reading.effectsWhere {
        case .everyCut: fx.place = .everyCut
        case .loudParts: fx.place = .loudParts
        case .quietParts: fx.place = .quietParts
        }
        // Asked for nothing but effects: keep the cuts. (Asked for nothing at all: recut.)
        return Understood(style: style, fx: fx, recut: reading.recut || fx.isEmpty)
    }

    private static func amount(_ choice: AmountChoice, light: Double, strong: Double) -> Double {
        switch choice {
        case .none: 0
        case .light: light
        case .strong: strong
        }
    }

    /// The effects part, in a few words ("crossfades on every cut, black & white").
    static func describe(_ fx: FXPlan) -> String? {
        guard !fx.isEmpty else { return nil }
        var moves: [String] = []
        if fx.mixed {
            moves.append("mixed transitions")
        } else if let kind = fx.transition {
            let plural: String
            switch kind {
            case .none: plural = "cuts"
            case .crossfade: plural = "crossfades"
            case .blur: plural = "blur transitions"
            case .zoomPunch: plural = "zoom punches"
            case .whip: plural = "whips"
            case .dipBlack: plural = "dips to black"
            case .flash: plural = "flashes"
            }
            moves.append(plural)
        }
        if fx.shake >= 0.01 { moves.append(fx.shake > 0.4 ? "strong shake" : "light shake") }
        if fx.glitch >= 0.01 { moves.append(fx.glitch > 0.5 ? "strong RGB split" : "light RGB split") }
        if fx.slowZoom { moves.append("slow zooms") }
        var parts: [String] = []
        if !moves.isEmpty {
            let place: String
            switch fx.place {
            case .everyCut: place = "on every cut"
            case .loudParts: place = "in the loud parts"
            case .quietParts: place = "in the quiet parts"
            }
            parts.append(moves.joined(separator: " and ") + " " + place)
        }
        if fx.look != .none { parts.append(fx.look.name.lowercased() + " look") }
        return parts.joined(separator: ", ")
    }

    /// What was understood, in a few words, so a wrong reading is easy to spot.
    static func describe(_ style: AutoStyle) -> String {
        var parts = ["\(style.pace.name.lowercased()) cuts"]
        parts.append(style.fasterInLoudParts ? "faster in the loud parts" : "an even pace")
        if style.shots != .balanced { parts.append(style.shots.name) }
        if !style.moreOf.isEmpty {
            parts.append("more of " + style.moreOf.sorted().map { "video \($0 + 1)" }.joined(separator: " and "))
        }
        if !style.lessOf.isEmpty {
            parts.append("less of " + style.lessOf.sorted().map { "video \($0 + 1)" }.joined(separator: " and "))
        }
        if !style.onlyOf.isEmpty {
            parts.append("only " + style.onlyOf.sorted().map { "video \($0 + 1)" }.joined(separator: " and "))
        }
        if style.evenly { parts.append("every video about equally") }
        if !style.avoidAlike { parts.append("cuts between look-alike takes too") }
        return parts.joined(separator: ", ")
    }
}

/// Names a picture's overall color and light in plain words ("red light, dark"), so a typed request
/// like "more of the blue shots" can find the right videos.
enum ColorNamer {
    static func describe(_ image: CGImage?) -> String {
        guard let image else { return "unknown look" }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return "unknown look" }
        var r = 0.0, g = 0.0, b = 0.0
        let count = Double(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[i]) / 255
            g += Double(pixels[i + 1]) / 255
            b += Double(pixels[i + 2]) / 255
        }
        r /= count; g /= count; b /= count
        let high = max(r, g, b), low = min(r, g, b)
        let saturation = high > 0 ? (high - low) / high : 0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        var parts: [String] = []
        if saturation >= 0.28 {
            parts.append("\(hueName(r, g, b, high: high, low: low)) light")
        } else if saturation >= 0.15 {
            parts.append("natural colors with a \(hueName(r, g, b, high: high, low: low)) tint")
        } else {
            parts.append("natural colors")
        }
        if luminance < 0.22 { parts.append("dark") } else if luminance > 0.6 { parts.append("bright") }
        return parts.joined(separator: ", ")
    }

    private static func hueName(_ r: Double, _ g: Double, _ b: Double, high: Double, low: Double) -> String {
        let span = max(high - low, 1e-6)
        var hue: Double
        if high == r { hue = 60 * ((g - b) / span) } else if high == g { hue = 60 * ((b - r) / span + 2) } else { hue = 60 * ((r - g) / span + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15, 335...: return "red"
        case ..<45: return "orange"
        case ..<70: return "yellow"
        case ..<160: return "green"
        case ..<200: return "teal"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }
}
