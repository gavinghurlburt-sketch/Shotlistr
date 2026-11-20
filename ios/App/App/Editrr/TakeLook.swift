import AVFoundation
import Vision

/// Tells whether two takes look alike (same angle, same background), using Apple's on-device
/// image matching on a few frames of each. Free, offline, and nothing leaves the phone.
enum TakeLook {
    /// How close two takes have to be to count as "a lot alike". Smaller is stricter. A starting
    /// point to tune on real shoots: each check prints its distance to the Xcode console.
    static let alike: Float = 0.45

    /// What a take looks like: a print of a few frames across it (nil if it couldn't be read).
    struct Look {
        fileprivate let frames: [VNFeaturePrintObservation]
    }

    static func look(at url: URL) async -> Look? {
        await Task.detached(priority: .utility) { () -> Look? in
            let asset = AVURLAsset(url: url)
            guard let length = try? await asset.load(.duration).seconds, length > 0.2 else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            var frames: [VNFeaturePrintObservation] = []
            for spot in [0.2, 0.5, 0.8] {
                let at = CMTime(seconds: length * spot, preferredTimescale: 600)
                guard let image = try? await generator.image(at: at).image else { continue }
                let request = VNGenerateImageFeaturePrintRequest()
                request.imageCropAndScaleOption = .scaleFill
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    if let found = request.results?.first { frames.append(found) }
                } catch {
                    continue
                }
            }
            return frames.isEmpty ? nil : Look(frames: frames)
        }.value
    }

    /// How different two takes look: for each frame of one, the closest frame of the other,
    /// averaged (0 is identical).
    static func distance(_ a: Look, _ b: Look) -> Float? {
        var total: Float = 0
        var count = 0
        for frame in a.frames {
            var best = Float.greatestFiniteMagnitude
            for other in b.frames {
                var d: Float = 0
                if (try? frame.computeDistance(&d, to: other)) != nil, d < best { best = d }
            }
            if best < .greatestFiniteMagnitude {
                total += best
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : nil
    }
}
