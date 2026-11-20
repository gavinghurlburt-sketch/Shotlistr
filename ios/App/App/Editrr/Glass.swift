import SwiftUI
import UIKit

/// editrr's look is creatrr's dark theme: the same colors, system font, soft pill buttons and
/// rounded cards, so the two halves of creatrr feel like one app. Icons beside the video and under
/// the timeline stay plain (like creatrr's icon buttons), colored only when color means something.
enum Tint {
    /// Neutral, for anything that isn't color coded (creatrr's muted grey #8e8e93).
    static let calm = Color(red: 0.557, green: 0.557, blue: 0.576)
    /// The accent: the playhead, what's picked (creatrr's yellow #ffd60a).
    static let accent = Color(red: 1.00, green: 0.839, blue: 0.039)
    /// Older name for the accent, kept so every primary button picks it up.
    static let teal = accent
    static let good = Color(red: 0.19, green: 0.82, blue: 0.35)    // #30d158
    /// In, Out and keyframes (creatrr's cut orange #ffb340).
    static let warn = Color(red: 1.00, green: 0.70, blue: 0.25)
    static let bad = Color(red: 1.00, green: 0.42, blue: 0.38)     // creatrr's danger #ff6b61
    /// The screen behind everything (creatrr's dark background #121212).
    static let backdrop = Color(red: 0.071, green: 0.071, blue: 0.071)
    /// creatrr's cards (#1c1c1e), buttons (#272729) and pressed buttons (#323235).
    static let surface = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let surface2 = Color(red: 0.153, green: 0.153, blue: 0.161)
    static let surface3 = Color(red: 0.196, green: 0.196, blue: 0.208)
    /// creatrr's text (#f5f5f7); also its main buttons, which are white with dark words (#151515).
    static let text = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let ink = Color(red: 0.082, green: 0.082, blue: 0.082)
}

/// creatrr's corners: cards and panels, chips and swatches, and small pieces like track headers.
enum Corner {
    static let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
    static let chip = RoundedRectangle(cornerRadius: 10, style: .continuous)
    static let small = RoundedRectangle(cornerRadius: 6, style: .continuous)
}

/// A panel: creatrr's card color, with a faint wash of its tint when it has one.
/// (Kept the old name; it's no longer glass.)
struct GlassPlate: View {
    var tint: Color = Tint.calm
    var strength: Double = 1

    var body: some View {
        ZStack {
            Rectangle().fill(Tint.surface)
            if tint != Tint.calm {
                Rectangle().fill(tint.opacity(min(0.3, 0.12 * strength)))
            }
        }
    }
}

/// The timeline's surround: creatrr's card color.
struct TimelinePlate: View {
    var body: some View { Rectangle().fill(Tint.surface) }
}

/// creatrr's button: a soft pill. Grey with white words normally; once picked (or when it's the main
/// action) it turns white with dark words, like creatrr's main buttons, or fills with its own
/// color when that color means something (a track's color, Record's red). `big` is the roomier
/// size for a screen's main action.
/// (Kept the old name so every button in the app picks this up.)
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = Tint.calm
    var selected: Bool = false
    var big: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, selected: selected, big: big)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let selected: Bool
        let big: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.frostedPills) private var frosted

        var body: some View {
            let neutral = tint == Tint.accent || tint == Tint.calm
            let fill: Color = selected ? (neutral ? Tint.text : tint) : Tint.surface2
            configuration.label
                .font(.system(size: big ? 17 : 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected ? Tint.ink : Tint.text)
                .padding(.horizontal, big ? 22 : 12)
                .padding(.vertical, big ? 13 : 8)
                .frame(minWidth: 38, minHeight: big ? 48 : 38)
                .background {
                    if frosted && !selected {
                        // Frosted glass, like creatrr's floating pills.
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.07))
                    } else {
                        Capsule().fill(configuration.isPressed && !selected ? Tint.surface3 : fill)
                    }
                }
                .overlay {
                    if frosted && !selected { FrostEdge() }
                }
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed && selected ? 0.88 : 1) : 0.4)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// One color per video layer, so a layer's button, lane and badge match.
enum LayerTint {
    /// creatrr's section colors first, so a video and a shot section can share a color.
    static let all: [Color] = [
        Color(red: 0.98, green: 0.45, blue: 0.09),   // orange  #f97316
        Color(red: 0.23, green: 0.51, blue: 0.96),   // blue    #3b82f6
        Color(red: 0.13, green: 0.77, blue: 0.37),   // green   #22c55e
        Color(red: 0.66, green: 0.33, blue: 0.97),   // purple  #a855f7
        Color(red: 0.93, green: 0.28, blue: 0.60),   // pink    #ec4899
        Color(red: 0.08, green: 0.72, blue: 0.65),   // teal    #14b8a6
        Color(red: 0.92, green: 0.70, blue: 0.03),   // yellow  #eab308
        Color(red: 0.94, green: 0.27, blue: 0.27),   // red     #ef4444
        Color(red: 0.02, green: 0.71, blue: 0.83),   // cyan    #06b6d4
        Color(red: 0.52, green: 0.80, blue: 0.09)    // lime    #84cc16
    ]

    static let names = ["Orange", "Blue", "Green", "Purple", "Pink", "Teal", "Yellow", "Red", "Cyan", "Lime"]

    static func color(_ index: Int) -> Color { all[((index % all.count) + all.count) % all.count] }
    /// A track's color: the one you picked, else the one for its number.
    static func color(_ layer: Layer) -> Color { color(layer.color ?? layer.id) }
    /// The palette spot a track's color comes from.
    static func pick(_ layer: Layer) -> Int { ((layer.color ?? layer.id) % all.count + all.count) % all.count }
}

/// An icon beside the video: no tile behind it, just the icon, filled in its color when it's on.
struct SideTile: View {
    let icon: String
    /// Read out by VoiceOver; only the icon shows.
    let text: String
    var tint: Color = Tint.calm
    var lit = false
    /// A small number under the icon, like which video is showing.
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: lit ? Self.filled(icon) : icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(lit ? (tint == Tint.calm ? Tint.accent : tint) : Color.white.opacity(0.85))
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(lit ? (tint == Tint.calm ? Tint.accent : tint) : Color.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .frame(width: 36, height: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// The filled version of a symbol, when there is one, so "on" reads at a glance.
    static func filled(_ icon: String) -> String {
        if icon.hasSuffix(".fill") { return icon }
        let candidate = icon + ".fill"
        return UIImage(systemName: candidate) != nil ? candidate : icon
    }
}

/// A tool under the timeline: an icon over its name. White, or its color while it's on.
struct ToolItem: View {
    let icon: String
    let text: String
    var tint: Color = Tint.accent
    var on = false
    var enabled = true
    /// What VoiceOver says, when the short name isn't enough.
    var spoken: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(height: 22)
                // Full size, never squeezed: the row makes room for it.
                Text(text)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? tint : Color.white.opacity(0.9))
            .padding(.horizontal, 4)
            .frame(minWidth: 48)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(spoken ?? text)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A row of tools along the bottom. When they fit, they spread out across the width (each a bit
/// apart, never too far); when they don't, the row scrolls.
struct ToolStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                SpreadRow(minWidth: geometry.size.width) { content }
                    .frame(height: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

/// Lays the tools out left to right with the same space between each pair (never less than
/// `minGap`, at most `maxGap`), spreading them over the width when there's room.
/// (SwiftUI's Layout: the editor has its own `Layout` enum.)
struct SpreadRow: SwiftUI.Layout {
    var minWidth: CGFloat
    var minGap: CGFloat = 10
    var maxGap: CGFloat = 34

    private func widths(_ subviews: LayoutSubviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize.unspecified).width }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let total = widths(subviews).reduce(0, +) + minGap * CGFloat(subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize.unspecified).height }.max() ?? 0
        return CGSize(width: max(total, minWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let sizes = widths(subviews)
        let spare = bounds.width - sizes.reduce(0, +)
        let gap = min(maxGap, max(minGap, spare / CGFloat(subviews.count)))
        var x = bounds.minX
        for (subview, width) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: x + (width + gap) / 2, y: bounds.midY),
                          anchor: UnitPoint.center, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}

/// The performance's mark: a grid of four squares (his pick).
enum PerformanceGlyph {
    static let name = "square.grid.2x2"
}

extension EnvironmentValues {
    /// Pills turn to frosted glass inside creatrr-style glass sheets (the New pop-up).
    @Entry var frostedPills = false
}

/// The thin light edge on frosted glass: brighter along the top, like creatrr's.
struct FrostEdge: View {
    var body: some View {
        ZStack {
            Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1)
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center),
                                   lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// creatrr's glass sheet: blurred, with its dark surface showing through.
struct FrostSheet: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Tint.surface.opacity(0.5)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// A pop-up in creatrr's frosted glass, with frosted buttons.
    func frostedSheet() -> some View {
        environment(\.frostedPills, true)
            .presentationBackground { FrostSheet() }
            .presentationCornerRadius(28)
    }
}
