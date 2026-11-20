import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - What a cut can have

/// How a cut comes in from the one before it.
enum TransitionKind: String, Codable, CaseIterable, Sendable {
    case none, crossfade, blur, zoomPunch, whip, dipBlack, flash

    var name: String {
        switch self {
        case .none: "Cut"
        case .crossfade: "Crossfade"
        case .blur: "Blur"
        case .zoomPunch: "Zoom punch"
        case .whip: "Whip"
        case .dipBlack: "Dip to black"
        case .flash: "Flash"
        }
    }
}

struct Transition: Codable, Equatable, Sendable {
    var kind: TransitionKind = .none
    /// Seconds, centered on the cut.
    var length: Double = 0.5

    static let lengths: [(name: String, seconds: Double)] = [("Quick", 0.25), ("Normal", 0.5), ("Slow", 1.0)]
}

/// A color look for a whole cut.
enum ColorLook: String, Codable, CaseIterable, Sendable {
    case none, blackWhite, noir, warm, cool, faded, punchy, vintage, dream

    var name: String {
        switch self {
        case .none: "None"
        case .blackWhite: "Black & white"
        case .noir: "Noir"
        case .warm: "Warm"
        case .cool: "Cool"
        case .faded: "Faded"
        case .punchy: "Punchy"
        case .vintage: "Vintage"
        case .dream: "Dream glow"
        }
    }
}

/// Glow on a cut's highlights: Glimmer adds X stars and a glow, Fog glow a soft haze, Cross glow
/// stars that go up, down and sideways.
enum GlowStyle: String, Codable, CaseIterable, Sendable {
    case glimmer, fog, cross

    var name: String {
        switch self {
        case .glimmer: "Glimmer"
        case .fog: "Fog glow"
        case .cross: "Cross glow"
        }
    }
}

/// One effect in the Fx page's picker: each cut can have any of these, one card each.
enum FXKind: String, CaseIterable, Identifiable, Sendable {
    case transition, zoom, color, blur, tilt, shake, mirror, face, glow, rgbSplit, fisheye

    /// The effects the Fx page offers (Mirror is its own button on the toolbar: on or off).
    static let onFxPage = allCases.filter { $0 != .mirror }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .transition: "Transition"
        case .zoom: "Zoom"
        case .color: "Color"
        case .blur: "Blur"
        case .tilt: "Tilt"
        case .shake: "Shake"
        case .mirror: "Mirror"
        case .face: "Follow face"
        case .glow: "Glow"
        case .rgbSplit: "RGB split"
        case .fisheye: "Fisheye"
        }
    }

    var icon: String {
        switch self {
        case .transition: "arrow.left.arrow.right.square"
        case .zoom: "plus.magnifyingglass"
        case .color: "camera.filters"
        case .blur: "drop.halffull"
        case .tilt: "rotate.right"
        case .shake: "waveform.path"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .face: "face.smiling"
        case .glow: "sparkles"
        case .rgbSplit: "rectangle.split.3x1"
        case .fisheye: "camera.aperture"
        }
    }

    /// The shader id, for the custom ones (only one custom effect at a time).
    var customID: String? {
        switch self {
        case .rgbSplit: "rgbSplit"
        case .fisheye: CustomFX.fisheye
        default: nil
        }
    }
}

/// Where a face is in one frame: timeline seconds, and its center as a fraction of the upright
/// picture (0,0 top left).
struct FacePoint: Codable, Equatable, Sendable {
    var t: Double
    var x: Double
    var y: Double
}

/// Everything layered on one cut. Older projects without some of these fields still open.
struct CutFX: Codable, Equatable, Sendable {
    var color: ColorLook = .none
    /// How much of the color look shows over the original (0: none, 1: all of it).
    var colorAmount: Double = 1
    /// 0 (none) to 1 (very soft).
    var blur: Double = 0
    /// Degrees, -30...30.
    var rotate: Double = 0
    var mirror = false
    /// 0 (none) to 1 (strong camera shake).
    var shake: Double = 0
    /// Keep the face centered, zoomed in a little.
    var followFace = false
    /// The face found in this cut, and which layer it was found on.
    var faces: [FacePoint] = []
    var facesLayer: Int?
    /// A custom shader (its id in CustomFX) and how strong.
    var custom: String?
    var customAmount: Double = 0.5
    /// Fisheye: where the circle sits, as fractions of the frame (0,0 top left). With keyframes,
    /// the circle moves between them instead (each at a timeline time).
    var fishX: Double = 0.5
    var fishY: Double = 0.5
    var fishKeys: [FishKey]?
    /// Glow on the highlights (nil: none), and how bright.
    var glow: GlowStyle?
    var glowAmount: Double = 0.5
    /// Sliders that are keyframed: each one's keyframes (timeline times). A keyframed slider
    /// moves between them instead of holding its one value.
    /// Keyed by FXParam raw value.
    var keys: [String: [FXValueKey]]?

    init() {}

    /// This cut's effects at a timeline time, with every keyframed slider at its value then.
    func resolved(at time: Double) -> CutFX {
        guard let keys, !keys.isEmpty else { return self }
        var fx = self
        for (name, list) in keys {
            if let param = FXParam(rawValue: name), let value = FXValueKey.value(list, at: time) { fx[param] = value }
        }
        return fx
    }

    /// A slider's own value (the one it holds when it isn't keyframed).
    subscript(param: FXParam) -> Double {
        get {
            switch param {
            case .blur: blur
            case .tilt: rotate
            case .shake: shake
            case .amount: customAmount
            case .colorMix: colorAmount
            case .glow: glowAmount
            }
        }
        set {
            switch param {
            case .blur: blur = newValue
            case .tilt: rotate = newValue
            case .shake: shake = newValue
            case .amount: customAmount = newValue
            case .colorMix: colorAmount = newValue
            case .glow: glowAmount = newValue
            }
        }
    }

    /// Where the fisheye circle sits at a timeline time, as fractions of the frame (0,0 top left).
    /// Between two keyframes it moves with the first one's ease; before the first and after the last it holds.
    func fishSpot(at time: Double) -> CGPoint {
        guard let keys = fishKeys, let first = keys.first, let last = keys.last else {
            return CGPoint(x: fishX, y: fishY)
        }
        if time <= first.time { return CGPoint(x: first.x, y: first.y) }
        if time >= last.time { return CGPoint(x: last.x, y: last.y) }
        for i in 1..<keys.count where keys[i].time >= time {
            let a = keys[i - 1], b = keys[i]
            let span = b.time - a.time
            let t = a.ease.apply(span > 1e-6 ? (time - a.time) / span : 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return CGPoint(x: last.x, y: last.y)
    }

    var isEmpty: Bool {
        color == .none && blur < 0.01 && abs(rotate) < 0.1 && !mirror && shake < 0.01 && !followFace && custom == nil
            && glow == nil
            && !(keys?.values.contains { list in list.contains { abs($0.value) > 0.01 } } ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case color, colorAmount, blur, rotate, mirror, shake, followFace, faces, facesLayer, custom, customAmount
        case fishX, fishY, fishKeys, keys, glow, glowAmount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = (try? c.decodeIfPresent(ColorLook.self, forKey: .color)) ?? .none
        colorAmount = (try? c.decodeIfPresent(Double.self, forKey: .colorAmount)) ?? 1
        blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0
        rotate = (try? c.decodeIfPresent(Double.self, forKey: .rotate)) ?? 0
        mirror = (try? c.decodeIfPresent(Bool.self, forKey: .mirror)) ?? false
        shake = (try? c.decodeIfPresent(Double.self, forKey: .shake)) ?? 0
        followFace = (try? c.decodeIfPresent(Bool.self, forKey: .followFace)) ?? false
        faces = (try? c.decodeIfPresent([FacePoint].self, forKey: .faces)) ?? []
        facesLayer = try? c.decodeIfPresent(Int.self, forKey: .facesLayer)
        custom = try? c.decodeIfPresent(String.self, forKey: .custom)
        customAmount = (try? c.decodeIfPresent(Double.self, forKey: .customAmount)) ?? 0.5
        fishX = (try? c.decodeIfPresent(Double.self, forKey: .fishX)) ?? 0.5
        fishY = (try? c.decodeIfPresent(Double.self, forKey: .fishY)) ?? 0.5
        fishKeys = try? c.decodeIfPresent([FishKey].self, forKey: .fishKeys)
        keys = try? c.decodeIfPresent([String: [FXValueKey]].self, forKey: .keys)
        glow = try? c.decodeIfPresent(GlowStyle.self, forKey: .glow)
        glowAmount = (try? c.decodeIfPresent(Double.self, forKey: .glowAmount)) ?? 0.5
    }
}

/// The Fx page's sliders that can be keyframed.
enum FXParam: String, Codable, Sendable, CaseIterable {
    case blur, tilt, shake, amount, colorMix, glow
}

/// One keyframe of a slider: a timeline time and its value then.
struct FXValueKey: Codable, Equatable, Sendable {
    var time: Double
    var value: Double
    var ease: Ease = .smooth

    /// The value at a time: between two keyframes it moves with the first one's ease; before the
    /// first and after the last it holds. Nil when there are none.
    static func value(_ keys: [FXValueKey], at time: Double) -> Double? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for i in 1..<keys.count where keys[i].time >= time {
            let a = keys[i - 1], b = keys[i]
            let span = b.time - a.time
            let t = a.ease.apply(span > 1e-6 ? (time - a.time) / span : 1)
            return a.value + (b.value - a.value) * t
        }
        return last.value
    }
}

/// One spot the fisheye circle passes through: a timeline time and where it sits then
/// (fractions of the frame, 0,0 top left).
struct FishKey: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    /// How it moves on to the next one.
    var ease: Ease = .smooth
}

// MARK: - Drawing a layer with its effects

enum Effects {
    /// One layer's frame: filled into the canvas with its framing (and face follow), then its effects.
    static func picture(of layer: LayerInfo, frame: CVPixelBuffer, at seconds: Double, canvas: CGSize) -> CIImage {
        let source = CIImage(cvPixelBuffer: frame).oriented(layer.orientation)
        let framing = layer.motion.framing(at: seconds)
        var focus: Layout.Focus?
        if let fx = layer.fx, fx.followFace, fx.facesLayer == layer.layer {
            focus = FaceFollow.focus(fx.faces, at: seconds)
        }
        let filled = Layout.fill(source, canvas: canvas, framing: framing, focus: focus)
        guard let fx = layer.fx, !fx.isEmpty else { return filled }
        return apply(fx, to: filled, canvas: canvas, time: seconds)
    }

    static func apply(_ fx: CutFX, to input: CIImage, canvas: CGSize, time: Double) -> CIImage {
        let fx = fx.resolved(at: time)
        let rect = CGRect(origin: .zero, size: canvas)
        var image = input

        // Move: rotate, mirror, shake. Zoomed in just enough that no edge shows.
        if abs(fx.rotate) >= 0.1 || fx.mirror || fx.shake >= 0.01 {
            let angle = fx.rotate * .pi / 180
            let c = abs(cos(angle)), s = abs(sin(angle))
            let w = Double(canvas.width), h = Double(canvas.height)
            var cover = max((w * c + h * s) / w, (w * s + h * c) / h)
            var dx = 0.0, dy = 0.0
            if fx.shake >= 0.01 {
                cover *= 1 + 0.08 * fx.shake
                let amount = 0.03 * fx.shake
                dx = amount * w * (sin(time * 23.1) + sin(time * 37.7 + 1.3)) / 2
                dy = amount * h * (sin(time * 29.3 + 0.7) + sin(time * 41.9 + 2.1)) / 2
            }
            var t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            t = t.concatenating(CGAffineTransform(scaleX: (fx.mirror ? -1 : 1) * cover, y: cover))
            t = t.concatenating(CGAffineTransform(rotationAngle: angle))
            t = t.concatenating(CGAffineTransform(translationX: w / 2 + dx, y: h / 2 + dy))
            image = image.clampedToExtent().transformed(by: t).cropped(to: rect)
        }

        if fx.blur >= 0.01 {
            image = image.clampedToExtent().applyingGaussianBlur(sigma: fx.blur * 30).cropped(to: rect)
        }

        let looked = color(fx.color, image, rect: rect)
        if fx.color == .none || fx.colorAmount >= 0.999 {
            image = looked
        } else {
            // Mixed with the original: 0 is the original, 1 the full look.
            image = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: looked,
                kCIInputTimeKey: max(0, min(1, fx.colorAmount)),
            ]).cropped(to: rect)
        }

        if let style = fx.glow, fx.glowAmount >= 0.01 {
            image = Glow.apply(style, amount: fx.glowAmount, to: image, rect: rect)
        }

        if let id = fx.custom {
            image = CustomFX.apply(id, to: image, fx: fx, time: time, canvas: canvas)
        }
        return image.cropped(to: rect)
    }

    static func color(_ look: ColorLook, _ image: CIImage, rect: CGRect) -> CIImage {
        switch look {
        case .none:
            return image
        case .blackWhite:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .vintage:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .warm:
            return channels(image, r: 1.08, g: 1.0, b: 0.86, lift: 0.01)
        case .cool:
            return channels(image, r: 0.88, g: 0.98, b: 1.1, lift: 0.0)
        case .faded:
            let soft = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.7, kCIInputContrastKey: 0.85])
            return channels(soft, r: 0.92, g: 0.92, b: 0.92, lift: 0.07)
        case .punchy:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.12])
        case .dream:
            let glow = image.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: 24, kCIInputIntensityKey: 0.9]).cropped(to: rect)
            return glow.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
        }
    }

    /// Scales red, green and blue, and lifts the blacks.
    private static func channels(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat, lift: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
        ])
    }
}

// MARK: - Glow

/// Glow on the brightest parts of the picture, made from Core Image's own filters (no shader).
enum Glow {
    static func apply(_ style: GlowStyle, amount: Double, to image: CIImage, rect: CGRect) -> CIImage {
        let a: Double = min(max(amount, 0), 1)
        let size = Double(min(rect.width, rect.height))
        // The highlights only, kept in their own colors. The curve runs on ordinary (sRGB) values.
        let plain = image.applyingFilter("CILinearToSRGBToneCurve")
        let bright = highlights(plain, from: 0.62 - 0.12 * a).applyingFilter("CISRGBToneCurveToLinear")
        var light = CIImage(color: .clear).cropped(to: rect)

        // A glow around them: soft and wide for Fog glow, closer for the stars.
        let fog = style == .fog
        let haze: Double = fog ? size * (0.02 + 0.05 * a) : size * (0.008 + 0.015 * a)
        let hazeGain: Double = fog ? 0.4 + 0.8 * a : 0.25 + 0.45 * a
        light = add(gain(blurred(bright, sigma: haze, rect: rect), hazeGain), over: light)
        if fog {
            // A second, wider veil, so it reads as fog and not only a halo.
            let veil = blurred(bright, sigma: size * (0.06 + 0.08 * a), rect: rect)
            light = add(gain(veil, 0.25 + 0.45 * a), over: light)
        } else {
            // Stars: only small, very bright points throw them (a glint, a light), not a whole
            // bright sky: what's left after taking away the area around each point.
            let hot = highlights(plain, from: 0.82 - 0.1 * a).applyingFilter("CISRGBToneCurveToLinear")
            let around = blurred(hot, sigma: max(3, size * 0.006), rect: rect)
            let points = around.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: hot])
                .applyingFilter("CIColorClamp")
                .cropped(to: rect)
            let angles: [Double] = style == .glimmer ? [Double.pi / 4, 3 * Double.pi / 4] : [0, Double.pi / 2]
            let reach: Double = size * (0.04 + 0.1 * a)
            let strength: Double = 0.8 + 2.2 * a
            for angle in angles {
                light = add(streak(points, angle: angle, reach: reach, strength: strength, rect: rect), over: light)
            }
        }
        return add(light, over: image).cropped(to: rect)
    }

    /// Keeps what's brighter than `from` (0...1), fading in above it, in its own colors.
    private static func highlights(_ image: CIImage, from: Double) -> CIImage {
        let f = CGFloat(min(max(from, 0.3), 0.95))
        let mid: CGFloat = f + (1 - f) * 0.5
        let top: CGFloat = 1 - (1 - f) * 0.15
        return image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: f, y: 0),
            "inputPoint2": CIVector(x: mid, y: 0.25),
            "inputPoint3": CIVector(x: top, y: 0.8),
            "inputPoint4": CIVector(x: 1, y: 1),
        ])
    }

    /// One star line through each bright point (both ways along `angle`), bright in the middle and
    /// fading to its tips. Made at half size, which is quicker and softer.
    private static func streak(_ points: CIImage, angle: Double, reach: Double, strength: Double, rect: CGRect) -> CIImage {
        let half = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let small = points.transformed(by: half)
        let smallRect = rect.applying(half)
        var line = CIImage(color: .clear).cropped(to: smallRect)
        // Long and faint plus short and bright: together the line tapers.
        let parts: [(radius: Double, weight: Double)] = [(reach * 0.5, 1.0), (reach * 0.2, 0.9), (reach * 0.08, 0.7)]
        for part in parts {
            let smeared = small.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: part.radius, kCIInputAngleKey: angle])
                .cropped(to: smallRect)
            // A motion blur spreads a point thin; the gain brings the line back up.
            let g: Double = part.weight * strength * max(1, part.radius / 12)
            line = add(gain(smeared, g), over: line)
        }
        return line.transformed(by: CGAffineTransform(scaleX: 2, y: 2)).cropped(to: rect)
    }

    private static func blurred(_ image: CIImage, sigma: Double, rect: CGRect) -> CIImage {
        image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
    }

    private static func gain(_ image: CIImage, _ g: Double) -> CIImage {
        let v = CGFloat(g)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    private static func add(_ image: CIImage, over base: CIImage) -> CIImage {
        image.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: base])
    }
}

// MARK: - Transitions

/// A transition's place on the timeline (timeline seconds).
struct TransitionWindow: Sendable {
    let cut: Int
    let kind: TransitionKind
    let start: Double
    let end: Double
}

enum Transitions {
    /// Where each transition runs: centered on its cut, shortened so it never runs into the cut
    /// before or after.
    static func windows(cuts: [Cut], duration: Double) -> [TransitionWindow] {
        var result: [TransitionWindow] = []
        for index in cuts.indices where index > 0 {
            guard let transition = cuts[index].transition, transition.kind != .none else { continue }
            let time = cuts[index].time
            let before = time - cuts[index - 1].time
            let after = (index + 1 < cuts.count ? cuts[index + 1].time : duration) - time
            let half = min(transition.length / 2, before * 0.45, after * 0.45)
            guard half > 0.02 else { continue }
            result.append(TransitionWindow(cut: index, kind: transition.kind, start: time - half, end: time + half))
        }
        return result
    }

    /// The picture part way (0...1) from one layer to the next.
    static func blend(from: CIImage, to: CIImage, progress p: Double, kind: TransitionKind, canvas: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let p = min(max(p, 0), 1)
        let peak = 1 - abs(2 * p - 1)          // 0 at the ends, 1 at the cut
        switch kind {
        case .none:
            return p < 0.5 ? from : to
        case .crossfade:
            return dissolve(from, to, smooth(p))
        case .blur:
            let sigma = 28 * peak
            let a = from.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
            let b = to.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
            return dissolve(a, b, smooth(min(max((p - 0.3) / 0.4, 0), 1)))
        case .zoomPunch:
            // The old shot zooms in fast, the new one lands zoomed in and settles back.
            let scale = 1 + 0.6 * peak
            let center = CIVector(x: canvas.width / 2, y: canvas.height / 2)
            func punch(_ image: CIImage) -> CIImage {
                let t = CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
                return image.clampedToExtent().transformed(by: t)
                    .applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: center, "inputAmount": 40 * peak])
                    .cropped(to: rect)
            }
            return dissolve(punch(from), punch(to), smooth(min(max((p - 0.4) / 0.2, 0), 1)))
        case .whip:
            // Both slide left, smeared sideways.
            let e = smooth(p)
            let radius = 60 * peak
            func slide(_ image: CIImage, by x: Double) -> CIImage {
                var moved = image.transformed(by: CGAffineTransform(translationX: x, y: 0))
                if radius > 0.5 {
                    moved = moved.clampedToExtent()
                        .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: 0])
                        .cropped(to: image.extent.offsetBy(dx: x, dy: 0))
                }
                return moved
            }
            let a = slide(from, by: -canvas.width * e)
            let b = slide(to, by: canvas.width * (1 - e))
            return b.composited(over: a).cropped(to: rect)
        case .dipBlack:
            let black = CIImage(color: .black).cropped(to: rect)
            return p < 0.5 ? dissolve(from, black, smooth(p * 2)) : dissolve(black, to, smooth(p * 2 - 1))
        case .flash:
            let white = CIImage(color: .white).cropped(to: rect)
            let base = p < 0.5 ? from : to
            return dissolve(base, white, pow(peak, 2.2))
        }
    }

    private static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        if t <= 0.001 { return a }
        if t >= 0.999 { return b }
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = a
        filter.targetImage = b
        filter.time = Float(t)
        return filter.outputImage ?? b
    }

    private static func smooth(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

// MARK: - Face tracking

enum FaceFollow {
    /// How much it zooms in while following a face.
    static let zoom = 1.25

    /// The face's place at a time, between the found points.
    static func focus(_ points: [FacePoint], at time: Double) -> Layout.Focus? {
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.t { return Layout.Focus(x: first.x, y: first.y, zoom: zoom) }
        if time >= last.t { return Layout.Focus(x: last.x, y: last.y, zoom: zoom) }
        // Points are sorted and evenly spaced, so a binary search is quick.
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].t <= time { low = mid } else { high = mid }
        }
        let a = points[low], b = points[high]
        let f = b.t - a.t > 1e-6 ? (time - a.t) / (b.t - a.t) : 0
        return Layout.Focus(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, zoom: zoom)
    }
}

struct FaceJob: @unchecked Sendable {
    let asset: AVAsset
    let trackStart: Double
    let offset: Double
    let from: Double
    let to: Double
}

enum FaceTracker {
    /// Finds the biggest face 8 times a second between two timeline times, fills the gaps and
    /// smooths the path so the framing glides. Empty when no face shows.
    static func track(_ job: FaceJob) async -> [FacePoint] {
        let step = 1.0 / 8
        var stamps: [Double] = []
        var t = job.from
        while t <= job.to + 1e-6 {
            stamps.append(t)
            t += step
        }
        guard !stamps.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: job.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let slack = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        let times = stamps.map { CMTime(seconds: job.trackStart + ($0 - job.offset), preferredTimescale: 600) }
        var found: [Double: (Double, Double)] = [:]
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            let timeline = result.requestedTime.seconds - job.trackStart + job.offset
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let biggest = request.results?.max(by: {
                      $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
                  }) else { continue }
            // Vision's y goes up from the bottom; ours goes down from the top.
            found[timeline] = (Double(biggest.boundingBox.midX), Double(1 - biggest.boundingBox.midY))
        }
        guard !found.isEmpty else { return [] }

        // One point per stamp: the nearest found frame (holds through short gaps).
        let keys = found.keys.sorted()
        var raw: [FacePoint] = stamps.map { stamp in
            let nearest = keys.min(by: { abs($0 - stamp) < abs($1 - stamp) }) ?? stamp
            let place = found[nearest] ?? (0.5, 0.5)
            return FacePoint(t: stamp, x: place.0, y: place.1)
        }

        // Smooth over about half a second each way.
        let reach = 4
        var smoothed = raw
        for i in raw.indices {
            let low = max(0, i - reach), high = min(raw.count - 1, i + reach)
            var x = 0.0, y = 0.0
            for j in low...high {
                x += raw[j].x
                y += raw[j].y
            }
            let n = Double(high - low + 1)
            smoothed[i].x = x / n
            smoothed[i].y = y / n
        }
        raw = smoothed
        return raw
    }
}

// MARK: - Custom shaders

/// Custom effects written as Core Image shaders in CustomFX.metal. To add one: write the shader
/// there, then add an entry here with its name and what it's given.
enum CustomFX {
    struct Entry: Sendable {
        let id: String
        let name: String
        /// Builds the picture from the shader, the frame, the cut's effects (its amount, 0...1, is
        /// `customAmount`), the timeline time and the canvas.
        let run: @Sendable (CIKernel, CIImage, CutFX, Double, CGSize) -> CIImage?
    }

    /// The fisheye's id (it has its own circle to move and keyframe in the effects sheet).
    static let fisheye = "fisheye"

    static let all: [Entry] = [
        Entry(id: "rgbSplit", name: "RGB split") { kernel, image, fx, _, canvas in
            let shift = 4 + 36 * fx.customAmount
            let rect = CGRect(origin: .zero, size: canvas)
            return kernel.apply(extent: rect,
                                roiCallback: { _, area in area.insetBy(dx: -CGFloat(shift) - 1, dy: -1) },
                                arguments: [image.clampedToExtent(), Float(shift)])
        },
        // A round fisheye lens: the picture bulges inside a circle with a blue, out of focus rim,
        // and a dark matte around it. The circle can be moved (and keyframed).
        Entry(id: CustomFX.fisheye, name: "Fisheye") { kernel, image, fx, time, canvas in
            let rect = CGRect(origin: .zero, size: canvas)
            let spot = fx.fishSpot(at: time)
            // Core Image counts up from the bottom; the spot counts down from the top.
            let center = CIVector(x: spot.x * canvas.width, y: (1 - spot.y) * canvas.height)
            let radius = min(canvas.width, canvas.height) * 0.49
            // The look was tuned on ordinary (sRGB) colors, so the math runs on those.
            let plain = image.clampedToExtent().applyingFilter("CILinearToSRGBToneCurve")
            let output = kernel.apply(extent: rect,
                                      roiCallback: { _, _ in rect.insetBy(dx: -radius * 0.2, dy: -radius * 0.2) },
                                      arguments: [plain, center, Float(radius), Float(fx.customAmount)])
            return output?.applyingFilter("CISRGBToneCurveToLinear").cropped(to: rect)
        }
    ]

    static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// The shaders, loaded once from the app's compiled Metal library.
    private static let kernels: [String: CIKernel] = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return [:] }
        var loaded: [String: CIKernel] = [:]
        for entry in all {
            if let kernel = try? CIKernel(functionName: entry.id, fromMetalLibraryData: data) {
                loaded[entry.id] = kernel
            }
        }
        return loaded
    }()

    /// True when the shaders loaded (shown in the effects sheet if not).
    static var isReady: Bool { !kernels.isEmpty }

    static func apply(_ id: String, to image: CIImage, fx: CutFX, time: Double, canvas: CGSize) -> CIImage {
        guard let entry = entry(id), let kernel = kernels[id],
              let output = entry.run(kernel, image, fx, time, canvas) else { return image }
        return output
    }
}
