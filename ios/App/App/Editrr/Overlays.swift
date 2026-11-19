import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - What an overlay is

/// The shape that cuts an overlay out: nothing, a circle, a square or your own shape made of
/// points, soft at its edge, and turned inside out with Invert.
enum MaskShape: String, Codable, CaseIterable, Sendable {
    // `rectangle` is the square (the name it was saved under before).
    case off, circle, rectangle, custom

    var name: String {
        switch self {
        case .off: "None"
        case .circle: "Circle"
        case .rectangle: "Square"
        case .custom: "Custom"
        }
    }

    var icon: String {
        switch self {
        case .off: "square.slash"
        case .circle: "circle"
        case .rectangle: "square"
        case .custom: "pentagon"
        }
    }
}

/// One of a Custom mask's points, from the shape's middle in shape units (y down). A shape unit
/// is the overlay's shorter side times the mask's size, so a Custom shape grows with a pinch.
struct MaskPoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    /// How far a point can go from the middle.
    static let reach = 2.0
}

struct OverlayMask: Codable, Equatable, Sendable {
    var shape: MaskShape = .off
    /// How big the shape is, from 0.1 to 1 of the overlay.
    var size: Double = 0.8
    /// How soft its edge is, 0 (sharp) to 1 (very soft).
    var feather: Double = 0.15
    /// Keeps the outside of the shape instead of the inside.
    var invert = false
    /// Its middle, as a fraction of the overlay from the top left (nil: the middle). Optional so
    /// projects saved before masks could move still open.
    var centerX: Double? = nil
    var centerY: Double? = nil
    /// How far a Circle or Square is stretched across and down by its side handles (nil: even).
    var wide: Double? = nil
    var tall: Double? = nil
    /// Custom's points, in order around the shape (nil until Custom is first picked).
    var points: [MaskPoint]? = nil
    /// Custom: a smooth curve through the points instead of straight lines.
    var smooth: Bool? = nil

    var middleX: Double { centerX ?? 0.5 }
    var middleY: Double { centerY ?? 0.5 }
    var across: Double { wide ?? 1 }
    var down: Double { tall ?? 1 }
    var curved: Bool { smooth ?? false }
    /// Custom's points, or the corners of the Circle or Square it starts from.
    var anchors: [MaskPoint] {
        if let points, points.count >= 3 { return points }
        return corners
    }
    var corners: [MaskPoint] {
        let x = across / 2, y = down / 2
        return [MaskPoint(x: -x, y: -y), MaskPoint(x: x, y: -y), MaskPoint(x: x, y: y), MaskPoint(x: -x, y: y)]
    }
    /// The biggest it can be made: twice the overlay, so a moved shape can still cover it.
    static let largest = 2.0
    /// How thin and how stretched a side handle can make a Circle or Square, in shape units.
    static let thinnest = 0.05
    static let widest = 6.0
}

/// A mask's outline through its points: straight lines, or a curve that passes through every point.
enum MaskOutline {
    static func path(_ points: [CGPoint], smooth: Bool) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }
        guard smooth else {
            path.addLines(between: points)
            path.closeSubpath()
            return path
        }
        let n = points.count
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}

/// Custom mask shapes drawn once into a picture (white inside, black outside) and reused on every
/// frame, so a moving or growing shape doesn't redraw.
final class MaskPictures: @unchecked Sendable {
    static let shared = MaskPictures()
    /// Pixels to one shape unit.
    static let scale: CGFloat = 600
    private let lock = NSLock()
    private var cache: [String: (image: CIImage, box: CGRect)] = [:]

    /// The picture, and the box it covers in shape units (y up, as Core Image counts).
    func picture(_ points: [MaskPoint], smooth: Bool) -> (image: CIImage, box: CGRect)? {
        let key = points.map { "\($0.x),\($0.y)" }.joined(separator: ";") + (smooth ? "~" : "")
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let path = MaskOutline.path(points.map { CGPoint(x: $0.x, y: -$0.y) }, smooth: smooth)
        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let s = Self.scale
        let width = Int((bounds.width * s).rounded(.up)) + 2
        let height = Int((bounds.height * s).rounded(.up)) + 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 1 - bounds.minX * s, y: 1 - bounds.minY * s)
        context.scaleBy(x: s, y: s)
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        guard let drawn = context.makeImage() else { return nil }
        let box = CGRect(x: bounds.minX - 1 / s, y: bounds.minY - 1 / s,
                         width: CGFloat(width) / s, height: CGFloat(height) / s)
        let made = (image: CIImage(cgImage: drawn), box: box)
        lock.lock()
        if cache.count > 40 { cache.removeAll() }
        cache[key] = made
        lock.unlock()
        return made
    }
}

/// A picture or video on top of the main video track, as saved.
struct SavedOverlay: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var source: MediaSource
    var isVideo: Bool
    /// Timeline seconds it starts at, and how long it shows.
    var start: Double
    var length: Double
    /// Seconds skipped at the start of a video overlay.
    var trimStart: Double = 0
    /// Its middle, as a fraction of the frame from the top left (0.5, 0.5 is the middle).
    var x: Double = 0.5
    var y: Double = 0.5
    /// Its width, as a fraction of the frame's width.
    var scale: Double = 0.6
    var mask = OverlayMask()
    /// Turned off with its row's icon: not drawn on the video or in the export.
    var hidden = false
    /// Its place and size over time, sorted by time. Nil or empty: it stays put. Optional so
    /// projects saved before overlay keyframes still open.
    var keys: [OverlayKey]? = nil
    /// Its mask's place, size and soft edge over time, kept apart from `keys`: placing a mask
    /// never animates it until you start keyframing the mask itself.
    var maskKeys: [OverlayKey]? = nil
    /// A clip on the main video track (added before or after a split), not on top: it fills the
    /// frame and plays over the performance while the song keeps going. Optional so projects
    /// saved before splits still open.
    var onTrack: Bool? = nil
    /// A clip on the main track after the performance (added with +, or After on its last piece):
    /// these sit back to back from the performance's End, in list order, and make the video longer.
    /// Optional so older projects still open.
    var tail: Bool? = nil

    var isCutaway: Bool { onTrack == true }
    var isTail: Bool { onTrack == true && tail == true }

    /// A clip on the main track fills the frame: its place and size become a zoom and move,
    /// never showing an edge.
    func fillFraming() -> Framing {
        Framing(scale: scale, x: x - 0.5, y: y - 0.5).clamped()
    }

    /// Which keyframes: the overlay's place and size, or its mask.
    typealias KeyList = WritableKeyPath<SavedOverlay, [OverlayKey]?>
    static let placeKeys: KeyList = \.keys
    static let maskKeyList: KeyList = \.maskKeys

    var end: Double { start + length }

    /// Keyframe times count from here, so they move with the overlay (and its video).
    var keyOrigin: Double { start - trimStart }

    /// What animates, as it is now (ignoring keyframes).
    var pose: OverlayPose {
        OverlayPose(x: x, y: y, scale: scale, maskX: mask.middleX, maskY: mask.middleY,
                    maskSize: mask.size, maskFeather: mask.feather)
    }

    /// A list of keyframes played out at `at` (seconds from the key origin). Nil with none.
    private static func play(_ keys: [OverlayKey]?, at: Double) -> OverlayPose? {
        guard let keys, let first = keys.first else { return nil }
        guard at > first.time else { return first.pose }
        for (a, b) in zip(keys, keys.dropFirst()) where at >= a.time && at < b.time {
            let span = b.time - a.time
            return a.pose.mixed(with: b.pose, a.ease.apply(span > 0 ? (at - a.time) / span : 1))
        }
        return keys.last?.pose ?? first.pose
    }

    /// The overlay as it shows at a timeline second, its keyframes played out.
    func posed(at time: Double) -> SavedOverlay {
        let at = time - keyOrigin
        var pose = self.pose
        if let place = Self.play(keys, at: at) {
            pose.x = place.x
            pose.y = place.y
            pose.scale = place.scale
        }
        if let cut = Self.play(maskKeys, at: at) {
            pose.maskX = cut.maskX
            pose.maskY = cut.maskY
            pose.maskSize = cut.maskSize
            pose.maskFeather = cut.maskFeather
        }
        return with(pose)
    }

    /// This overlay with its place, size and mask set to `pose` (shape and Invert stay).
    func with(_ pose: OverlayPose) -> SavedOverlay {
        var next = self
        next.x = pose.x
        next.y = pose.y
        next.scale = pose.scale
        next.mask.centerX = pose.maskX
        next.mask.centerY = pose.maskY
        next.mask.size = pose.maskSize
        next.mask.feather = pose.maskFeather
        return next
    }

    /// The keyframe in a list at a timeline second (within a frame), if there is one.
    func keyIndex(_ list: KeyList = SavedOverlay.placeKeys, at time: Double) -> Int? {
        let at = time - keyOrigin
        return self[keyPath: list]?.firstIndex { abs($0.time - at) < 0.5 / 30 }
    }

    /// Adds a keyframe holding `pose` at a timeline second to a list, or updates the one there.
    func addingKey(_ list: KeyList, _ pose: OverlayPose, at time: Double) -> SavedOverlay {
        var keys = self[keyPath: list] ?? []
        if let index = keyIndex(list, at: time) {
            keys[index].pose = pose
        } else {
            keys.append(OverlayKey(time: time - keyOrigin, pose: pose))
            keys.sort { $0.time < $1.time }
        }
        var next = self
        next[keyPath: list] = keys
        return next
    }

    /// Saves `pose` as it should show at a timeline second. The place and the mask each go into
    /// their keyframes when they have some, and otherwise set how it looks all the way through.
    func storing(_ pose: OverlayPose, at time: Double) -> SavedOverlay {
        var base = self.pose
        var next = self
        if keys?.isEmpty == false {
            next = next.addingKey(Self.placeKeys, pose, at: time)
        } else {
            base.x = pose.x
            base.y = pose.y
            base.scale = pose.scale
        }
        if maskKeys?.isEmpty == false {
            next = next.addingKey(Self.maskKeyList, pose, at: time)
        } else {
            base.maskX = pose.maskX
            base.maskY = pose.maskY
            base.maskSize = pose.maskSize
            base.maskFeather = pose.maskFeather
        }
        return next.with(base)
    }
}

/// Everything about an overlay that keyframes animate: its place and size, and its mask's place,
/// size and soft edge.
struct OverlayPose: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var scale: Double
    var maskX: Double
    var maskY: Double
    var maskSize: Double
    var maskFeather: Double

    func mixed(with other: OverlayPose, _ amount: Double) -> OverlayPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return OverlayPose(x: mix(x, other.x), y: mix(y, other.y), scale: mix(scale, other.scale),
                           maskX: mix(maskX, other.maskX), maskY: mix(maskY, other.maskY),
                           maskSize: mix(maskSize, other.maskSize),
                           maskFeather: mix(maskFeather, other.maskFeather))
    }
}

/// An overlay's pose at a moment (seconds from its `keyOrigin`).
struct OverlayKey: Codable, Equatable, Sendable {
    var time: Double
    var pose: OverlayPose
    var ease: Ease = .smooth
}

/// The opened picture or video behind an overlay. Kept for the whole session, so Undo can bring
/// a deleted overlay back.
struct OverlayMedia: @unchecked Sendable {
    /// A photo, already upright.
    var image: CIImage?
    var asset: AVAsset?
    var track: AVAssetTrack?
    /// Asset seconds of the first video frame, and the video's length.
    var trackStart: Double = 0
    var videoLength: Double = 0
    var orientation: CGImagePropertyOrientation = .up
    /// Upright width and height.
    var size: CGSize
    var thumbnail: UIImage?
}

// MARK: - Live looks for the renderer

/// Where each overlay sits and how it's masked, read by the renderer on every frame. Moving an
/// overlay updates this in place, so it shows without rebuilding the video.
final class OverlayBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var looks: [UUID: SavedOverlay] = [:]
    private var images: [UUID: CIImage] = [:]
    private var track: [Keyframe] = []

    func update(_ overlays: [SavedOverlay], media: [UUID: OverlayMedia], track: [Keyframe]) {
        lock.lock()
        self.track = track
        looks = Dictionary(uniqueKeysWithValues: overlays.map { ($0.id, $0) })
        var pictures: [UUID: CIImage] = [:]
        for overlay in overlays where !overlay.isVideo {
            if let image = media[overlay.id]?.image { pictures[overlay.id] = image }
        }
        images = pictures
        lock.unlock()
    }

    /// One overlay's place, while a finger moves it.
    func place(_ overlay: SavedOverlay) {
        lock.lock()
        looks[overlay.id] = overlay
        lock.unlock()
    }

    /// The whole performance track's framing at a timeline second (nil when it's never framed).
    func trackFraming(at seconds: Double) -> Framing? {
        lock.lock()
        defer { lock.unlock() }
        guard !track.isEmpty else { return nil }
        let framing = Keyframes.framing(track, at: seconds)
        return framing == .identity ? nil : framing
    }

    func look(_ id: UUID) -> SavedOverlay? {
        lock.lock()
        defer { lock.unlock() }
        return looks[id]
    }

    func image(_ id: UUID) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[id]
    }
}

/// Which overlays show in one stretch of the video, top last.
struct OverlayRef: Sendable {
    let id: UUID
    /// The composition track of a video overlay (nil for a photo).
    let trackID: CMPersistentTrackID?
    let orientation: CGImagePropertyOrientation
}

enum OverlayRender {
    /// One overlay over the picture: sized and placed, cut by its mask.
    static func draw(_ source: CIImage, look: SavedOverlay, over picture: CIImage, canvas: CGSize) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return picture }
        let width = canvas.width * look.scale
        let factor = width / extent.width
        let height = extent.height * factor
        // Core Image counts y from the bottom.
        let middle = CGPoint(x: canvas.width * look.x, y: canvas.height * (1 - look.y))
        let rect = CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
        var placed = source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        if let mask = mask(look.mask, in: rect) {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = placed
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask
            placed = blend.outputImage ?? placed
        }
        return placed.cropped(to: rect).composited(over: picture)
    }

    /// White where the overlay shows, black where it's cut away.
    private static func mask(_ mask: OverlayMask, in rect: CGRect) -> CIImage? {
        guard mask.shape != .off else { return nil }
        let size = min(OverlayMask.largest, max(0.1, mask.size))
        let feather = min(1, max(0, mask.feather))
        // Core Image counts y from the bottom.
        let middle = CGPoint(x: rect.minX + rect.width * mask.middleX, y: rect.maxY - rect.height * mask.middleY)
        // One shape unit: the overlay's shorter side times the size.
        let unit = min(rect.width, rect.height) * size
        let across = min(OverlayMask.widest, max(OverlayMask.thinnest, mask.across))
        let down = min(OverlayMask.widest, max(OverlayMask.thinnest, mask.down))
        var shape: CIImage
        switch mask.shape {
        case .off:
            return nil
        case .circle:
            // A round gradient, stretched into an oval by the side handles.
            let radius = unit / 2
            let soft = radius * feather * 0.9
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = Float(max(0, radius - soft))
            gradient.radius1 = Float(radius + 0.5)
            gradient.color0 = .white
            gradient.color1 = .black
            shape = (gradient.outputImage ?? CIImage(color: .black))
                .transformed(by: CGAffineTransform(scaleX: across, y: down))
                .transformed(by: CGAffineTransform(translationX: middle.x, y: middle.y))
        case .rectangle:
            let width = unit * across, height = unit * down
            let box = CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
            let blur = min(box.width, box.height) * feather * 0.25
            shape = CIImage(color: .white).cropped(to: box)
                .composited(over: CIImage(color: .black).cropped(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3)))
            if blur > 0.5 { shape = shape.applyingGaussianBlur(sigma: blur) }
        case .custom:
            guard let drawn = MaskPictures.shared.picture(mask.anchors, smooth: mask.curved) else { return nil }
            let factor = unit / MaskPictures.scale
            let placed = drawn.image
                .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                .transformed(by: CGAffineTransform(translationX: middle.x + drawn.box.minX * unit,
                                                   y: middle.y + drawn.box.minY * unit))
            let blur = min(drawn.box.width, drawn.box.height) * unit * feather * 0.25
            shape = placed.composited(over: CIImage(color: .black).cropped(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3)))
            if blur > 0.5 { shape = shape.applyingGaussianBlur(sigma: blur) }
        }
        shape = shape.cropped(to: rect)
        if mask.invert { shape = shape.applyingFilter("CIColorInvert") }
        return shape
    }
}

// MARK: - Opening a picked photo or video

enum OverlayLoader {
    /// A picked photo or video, opened. Photos are copied into the project's folder (so the
    /// project keeps them); videos open from Photos where they can, like the main videos.
    static func open(_ item: PhotosPickerItem, project: UUID?) async -> (SavedOverlay, OverlayMedia)? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if isVideo {
            guard let picked = await PhotosLoader.load([item]).first,
                  let media = await video(picked.asset) else { return nil }
            let source = project.map { ProjectStore.adopt(picked.source, into: $0) } ?? picked.source
            let overlay = SavedOverlay(source: source, isVideo: true, start: 0, length: media.videoLength)
            return (overlay, media)
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let media = photo(data) else { return nil }
        // Kept as a file: in the project's folder, or the cache until the project is saved.
        let name = UUID().uuidString + ".png"
        let kept = media.kept ?? data
        let source: MediaSource
        if let project {
            let url = ProjectStore.folder(for: project).appendingPathComponent(name)
            try? kept.write(to: url, options: .atomic)
            source = .file(name)
        } else {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? kept.write(to: url, options: .atomic)
            source = .file(url.path)
        }
        return (SavedOverlay(source: source, isVideo: false, start: 0, length: 3), media.media)
    }

    /// Opens a saved overlay's photo or video again. Nil when it's gone.
    static func reopen(_ overlay: SavedOverlay, project: UUID) async -> OverlayMedia? {
        if overlay.isVideo {
            guard let asset = await PhotosLoader.open(overlay.source, project: project) else { return nil }
            return await video(asset)
        }
        guard let url = ProjectStore.url(of: overlay.source, in: project),
              let data = try? Data(contentsOf: url) else { return nil }
        return photo(data)?.media
    }

    /// A photo, upright, no bigger than 2160 on its long side, with the PNG that's kept.
    private static func photo(_ data: Data) -> (media: OverlayMedia, kept: Data?)? {
        guard let original = UIImage(data: data) else { return nil }
        let longest = max(original.size.width, original.size.height) * original.scale
        let shrink = min(1, 2160 / max(longest, 1))
        let target = CGSize(width: original.size.width * original.scale * shrink,
                            height: original.size.height * original.scale * shrink)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Drawing it again turns it upright and keeps any see-through parts (a PNG).
        let upright = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cg = upright.cgImage else { return nil }
        let kept = upright.pngData()
        let thumb = upright.preparingThumbnail(of: CGSize(width: 240, height: 240 * target.height / max(target.width, 1)))
        let media = OverlayMedia(image: CIImage(cgImage: cg), size: target, thumbnail: thumb ?? upright)
        return (media, kept)
    }

    private static func video(_ asset: AVAsset) async -> OverlayMedia? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .timeRange)
        else { return nil }
        let (size, transform, range) = loaded
        let turn = await TimelineBuilder.orientation(of: transform)
        let turned = turn == .left || turn == .right
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let at = CMTime(seconds: range.start.seconds + min(0.5, range.duration.seconds / 2), preferredTimescale: 600)
        let thumbnail = (try? await generator.image(at: at)).map { UIImage(cgImage: $0.image) }
        return OverlayMedia(asset: asset, track: track, trackStart: range.start.seconds,
                            videoLength: range.duration.seconds, orientation: turn,
                            size: turned ? CGSize(width: size.height, height: size.width) : size,
                            thumbnail: thumbnail)
    }
}
