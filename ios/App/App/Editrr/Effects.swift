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

    init() {}

    var isEmpty: Bool {
        color == .none && blur < 0.01 && abs(rotate) < 0.1 && !mirror && shake < 0.01 && !followFace && custom == nil
    }

    private enum CodingKeys: String, CodingKey {
        case color, blur, rotate, mirror, shake, followFace, faces, facesLayer, custom, customAmount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = (try? c.decodeIfPresent(ColorLook.self, forKey: .color)) ?? .none
        blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0
        rotate = (try? c.decodeIfPresent(Double.self, forKey: .rotate)) ?? 0
        mirror = (try? c.decodeIfPresent(Bool.self, forKey: .mirror)) ?? false
        shake = (try? c.decodeIfPresent(Double.self, forKey: .shake)) ?? 0
        followFace = (try? c.decodeIfPresent(Bool.self, forKey: .followFace)) ?? false
        faces = (try? c.decodeIfPresent([FacePoint].self, forKey: .faces)) ?? []
        facesLayer = try? c.decodeIfPresent(Int.self, forKey: .facesLayer)
        custom = try? c.decodeIfPresent(String.self, forKey: .custom)
        customAmount = (try? c.decodeIfPresent(Double.self, forKey: .customAmount)) ?? 0.5
    }
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

        image = color(fx.color, image, rect: rect)

        if let id = fx.custom {
            image = CustomFX.apply(id, to: image, amount: fx.customAmount, time: time, canvas: canvas)
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
        /// Builds the picture from the shader, the frame, the amount (0...1), the time and the canvas.
        let run: @Sendable (CIKernel, CIImage, Double, Double, CGSize) -> CIImage?
    }

    static let all: [Entry] = [
        Entry(id: "rgbSplit", name: "RGB split") { kernel, image, amount, _, canvas in
            let shift = 4 + 36 * amount
            let rect = CGRect(origin: .zero, size: canvas)
            return kernel.apply(extent: rect,
                                roiCallback: { _, area in area.insetBy(dx: -CGFloat(shift) - 1, dy: -1) },
                                arguments: [image.clampedToExtent(), Float(shift)])
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

    static func apply(_ id: String, to image: CIImage, amount: Double, time: Double, canvas: CGSize) -> CIImage {
        guard let entry = entry(id), let kernel = kernels[id],
              let output = entry.run(kernel, image, amount, time, canvas) else { return image }
        return output
    }
}
