import AVFoundation
import CoreImage
import Metal
import QuartzCore
import ImageIO

/// One video layer in the stack: which composition track it reads, how its frames are turned,
/// and how it's framed over time.
struct LayerInfo {
    let trackID: CMPersistentTrackID
    let orientation: CGImagePropertyOrientation
    var motion = LayerMotion.still
    /// The effects of the cut this stretch is in, and which layer this is (for face follow).
    var fx: CutFX?
    var layer: Int = -1
}

/// Keyframes and auto zoom for one stretch, all in timeline seconds.
struct LayerMotion: Sendable {
    var keyframes: [Keyframe]
    var zoom: AutoZoom
    var sectionStart: Double
    var sectionEnd: Double
    var zoomStart: ZoomBox = .full
    var zoomEnd: ZoomBox = .full

    static let still = LayerMotion(keyframes: [], zoom: .off, sectionStart: 0, sectionEnd: 0)

    func framing(at time: Double) -> Framing {
        let framing = Keyframes.framing(keyframes, at: time)
        guard zoom != .off, sectionEnd - sectionStart > 0.05 else { return framing }
        let p = Ease.smooth.apply(min(max((time - sectionStart) / (sectionEnd - sectionStart), 0), 1))
        return ZoomBox.between(zoomStart, zoomEnd, p).apply(to: framing)
    }
}

/// Tells the compositor which tracks to stack, bottom first.
final class LayerInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [LayerInfo]
    /// During a transition: layers[0] comes in, layers[1] goes out.
    let transition: TransitionWindow?
    /// The lyrics drawn over the top (the same object for the whole video).
    let lyrics: LyricsOverlay?
    /// Pictures and videos on top of the main video, bottom first, and where each sits.
    let overlays: [OverlayRef]
    let board: OverlayBoard?
    /// The whole video's filter (over the video and overlays, under the words).
    let filter: ColorLook
    /// How much of the filter shows over the original (0: none, 1: all of it).
    let filterAmount: Double
    /// The whole video's brightness, contrast, saturation and hue (after the filter).
    let adjust: ColorAdjust

    init(timeRange: CMTimeRange, layers: [LayerInfo], transition: TransitionWindow? = nil,
         lyrics: LyricsOverlay? = nil, overlays: [OverlayRef] = [], board: OverlayBoard? = nil,
         filter: ColorLook = .none, filterAmount: Double = 1, adjust: ColorAdjust = ColorAdjust()) {
        self.timeRange = timeRange
        self.filter = filter
        self.filterAmount = filterAmount
        self.adjust = adjust
        self.layers = layers
        self.transition = transition
        self.lyrics = lyrics
        self.overlays = board == nil ? [] : overlays
        self.board = board
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
            + self.overlays.compactMap { $0.trackID.map { NSNumber(value: $0) } }
        super.init()
    }
}

/// The frame renderer: draws the layer that shows at each moment, on the GPU (Core Image on Metal). The real editor will use this same renderer for preview and export.
final class LayerCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "editrr.compositor", qos: .userInteractive)
    private let ciContext: CIContext
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var generation = 0

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    /// Ask the decoder for its own native formats (no extra conversion), BGRA as a last resort.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let ticket = currentGeneration()
        renderQueue.async { [self] in
            if ticket != currentGeneration() {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                render(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = CACurrentMediaTime()
        guard let instruction = request.videoCompositionInstruction as? LayerInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "editrr", code: 1))
            return
        }

        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)

        // Normally one layer per stretch (the one that shows); drawn bottom first if there are more.
        var picture = CIImage(color: CIColor.black).cropped(to: canvas)
        let seconds = request.compositionTime.seconds
        if instruction.lyrics?.videoHidden == true {
            // The edit page's video eye is off: black under the words.
        } else if let window = instruction.transition, instruction.layers.count == 2,
           let incoming = request.sourceFrame(byTrackID: instruction.layers[0].trackID),
           let outgoing = request.sourceFrame(byTrackID: instruction.layers[1].trackID) {
            let to = Effects.picture(of: instruction.layers[0], frame: incoming, at: seconds, canvas: size)
            let from = Effects.picture(of: instruction.layers[1], frame: outgoing, at: seconds, canvas: size)
            let span = window.end - window.start
            let progress = span > 0 ? (seconds - window.start) / span : 1
            picture = Transitions.blend(from: from, to: to, progress: progress, kind: window.kind, canvas: size)
                .composited(over: picture)
        } else {
            for layer in instruction.layers.reversed() {
                guard let frame = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                picture = Effects.picture(of: layer, frame: frame, at: seconds, canvas: size).composited(over: picture)
            }
        }

        // The whole performance track's own zoom and move, over every video but under the overlays.
        if instruction.lyrics?.videoHidden != true, let framing = instruction.board?.trackFraming(at: seconds) {
            picture = Layout.reframe(picture, canvas: size, framing: framing)
        }

        // Overlays on top of the main video, under the words.
        if let board = instruction.board {
            for overlay in instruction.overlays {
                guard let look = board.look(overlay.id), !look.hidden else { continue }
                // A clip on the main track hides with the video track's eye.
                if look.isCutaway, instruction.lyrics?.videoHidden == true { continue }
                var source: CIImage?
                if let trackID = overlay.trackID {
                    if let frame = request.sourceFrame(byTrackID: trackID) {
                        source = CIImage(cvPixelBuffer: frame).oriented(overlay.orientation)
                    }
                } else {
                    source = board.image(overlay.id)
                }
                if let source {
                    let posed = look.posed(at: seconds)
                    if look.isCutaway {
                        // On the main track: fills the frame over the performance.
                        picture = Layout.fill(source, canvas: size, framing: posed.fillFraming()).composited(over: picture)
                    } else {
                        picture = OverlayRender.draw(source, look: posed, over: picture, canvas: size)
                    }
                }
            }
        }

        if instruction.filter != .none && instruction.filterAmount >= 0.01 {
            let plain = picture.cropped(to: canvas)
            let looked = Effects.color(instruction.filter, plain, rect: canvas)
            if instruction.filterAmount >= 0.999 {
                picture = looked
            } else {
                // Mixed with the original: 0 is the original, 1 the full look.
                picture = plain.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: looked,
                    kCIInputTimeKey: min(1, instruction.filterAmount),
                ]).cropped(to: canvas)
            }
        }

        if !instruction.adjust.isOff {
            picture = instruction.adjust.apply(picture.cropped(to: canvas), rect: canvas)
        }

        if let words = instruction.lyrics?.image(at: seconds, canvas: size) {
            picture = words.composited(over: picture)
        }

        ciContext.render(picture.cropped(to: canvas), to: output, bounds: canvas, colorSpace: outputColorSpace)
        RenderStats.shared.record(milliseconds: (CACurrentMediaTime() - started) * 1000)
        request.finish(withComposedVideoFrame: output)
    }
}

/// Where a layer sits: filling the 9:16 frame, then zoomed and shifted by its framing, the
/// overflow cropped.
enum Layout {
    /// A point to keep centered (a fraction of the upright picture, 0,0 top left), zoomed in a bit.
    struct Focus {
        var x: Double
        var y: Double
        var zoom: Double
    }

    /// Zooms and moves a whole frame (already the canvas size) the same way `fill` frames one video.
    static func reframe(_ picture: CIImage, canvas: CGSize, framing: Framing) -> CIImage {
        let zoom = CGFloat(framing.scale)
        return picture
            .transformed(by: CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .transformed(by: CGAffineTransform(translationX: canvas.width / 2 + CGFloat(framing.x) * canvas.width,
                                               y: canvas.height / 2 - CGFloat(framing.y) * canvas.height))
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    static func fill(_ source: CIImage, canvas: CGSize, framing: Framing = .identity, focus: Focus? = nil) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage.empty() }
        let fit = max(canvas.width / extent.width, canvas.height / extent.height)
        var zoom = CGFloat(framing.scale)
        // Core Image's y goes up, the framing's y goes down.
        var shiftX = CGFloat(framing.x) * canvas.width
        var shiftY = -CGFloat(framing.y) * canvas.height
        if let focus {
            // Move the point to the middle, but never so far that an edge shows.
            zoom *= CGFloat(focus.zoom)
            let scale = fit * zoom
            let pointX = (CGFloat(focus.x) - 0.5) * extent.width * scale
            let pointY = (0.5 - CGFloat(focus.y)) * extent.height * scale
            let roomX = max(0, (extent.width * scale - canvas.width) / 2)
            let roomY = max(0, (extent.height * scale - canvas.height) / 2)
            shiftX = min(max(shiftX - pointX, -roomX), roomX)
            shiftY = min(max(shiftY - pointY, -roomY), roomY)
        }
        return source
            .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
            .transformed(by: CGAffineTransform(scaleX: fit * zoom, y: fit * zoom))
            .transformed(by: CGAffineTransform(translationX: canvas.width / 2 + shiftX, y: canvas.height / 2 + shiftY))
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }
}

/// Counts frames as they're drawn, so the screen can show frames per second and draw time.
final class RenderStats: @unchecked Sendable {
    static let shared = RenderStats()

    private let lock = NSLock()
    private var frames: [(at: CFTimeInterval, ms: Double)] = []

    func record(milliseconds: Double) {
        let now = CACurrentMediaTime()
        lock.lock()
        frames.append((at: now, ms: milliseconds))
        frames.removeAll { now - $0.at > 2 }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    /// Frames drawn in the last second, and their average draw time.
    func snapshot() -> (fps: Double, ms: Double) {
        let now = CACurrentMediaTime()
        lock.lock()
        let recent = frames.filter { now - $0.at <= 1 }
        lock.unlock()
        guard !recent.isEmpty else { return (0, 0) }
        let average = recent.map { $0.ms }.reduce(0, +) / Double(recent.count)
        return (Double(recent.count), average)
    }
}
