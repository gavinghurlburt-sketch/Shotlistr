import CoreImage
import Foundation

/// Basic color correction on the whole video: brightness, contrast, saturation and hue. Each
/// slider sits in the middle (0) when it's off. Goes on after the filter, under the words.
struct ColorAdjust: Codable, Equatable, Sendable {
    /// -1 (darker) to 1 (brighter).
    var brightness: Double = 0
    /// -1 (flatter) to 1 (punchier).
    var contrast: Double = 0
    /// -1 (black and white) to 1 (twice the color).
    var saturation: Double = 0
    /// Degrees around the color wheel, -180 to 180.
    var hue: Double = 0

    init() {}

    /// Anything missing from an older save stays in the middle.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness = (try? c.decodeIfPresent(Double.self, forKey: .brightness)) ?? 0
        contrast = (try? c.decodeIfPresent(Double.self, forKey: .contrast)) ?? 0
        saturation = (try? c.decodeIfPresent(Double.self, forKey: .saturation)) ?? 0
        hue = (try? c.decodeIfPresent(Double.self, forKey: .hue)) ?? 0
    }

    /// Every slider in the middle: nothing to do.
    var isOff: Bool {
        abs(brightness) < 0.005 && abs(contrast) < 0.005 && abs(saturation) < 0.005 && abs(hue) < 0.5
    }

    /// The picture with the correction on (cropped back to `rect`).
    func apply(_ image: CIImage, rect: CGRect) -> CIImage {
        guard !isOff else { return image }
        var picture = image
        if abs(brightness) >= 0.005 || abs(contrast) >= 0.005 || abs(saturation) >= 0.005 {
            picture = picture.applyingFilter("CIColorControls", parameters: [
                // Gentle ranges: the ends are strong but still look like the video.
                kCIInputBrightnessKey: brightness * 0.3,
                kCIInputContrastKey: 1 + contrast * 0.5,
                kCIInputSaturationKey: max(0, 1 + saturation),
            ])
        }
        if abs(hue) >= 0.5 {
            picture = picture.applyingFilter("CIHueAdjust", parameters: [
                kCIInputAngleKey: hue * Double.pi / 180,
            ])
        }
        return picture.cropped(to: rect)
    }
}
