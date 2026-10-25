import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// NOTE: ShootActivityAttributes and the three intents are defined identically in the App target
// (AppDelegate.swift). Keep both copies in step.
struct ShootActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var song: String
        var section: String
        var playing: Bool
        var position: Int
        var total: Int
        var color: String = ""
        var colors: [String] = []
    }
    var shoot: String
}

enum ShootBridge {
    static let note = Notification.Name("creatrr.shoot.command")
    static func send(_ name: String) { NotificationCenter.default.post(name: note, object: nil, userInfo: ["name": name]) }
}

struct ShootToggleIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or stop"
    func perform() async throws -> some IntentResult { ShootBridge.send("toggle"); return .result() }
}
struct ShootNextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next section"
    func perform() async throws -> some IntentResult { ShootBridge.send("next"); return .result() }
}
struct ShootPreviousIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous section"
    func perform() async throws -> some IntentResult { ShootBridge.send("previous"); return .result() }
}
struct ShootNextSongIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next song"
    func perform() async throws -> some IntentResult { ShootBridge.send("nextSong"); return .result() }
}
struct ShootPreviousSongIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous song"
    func perform() async throws -> some IntentResult { ShootBridge.send("previousSong"); return .result() }
}

private let accent = Color(red: 0.96, green: 0.82, blue: 0.26)
private let ink = Color(red: 0.07, green: 0.07, blue: 0.07)
private let pill = Color(red: 0.22, green: 0.22, blue: 0.23)   // solid, so the wallpaper never shows through the buttons

private func rgb(_ hex: String) -> (Double, Double, Double)? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
    return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
}
private func tintColor(_ hex: String) -> Color {
    if let c = rgb(hex) { return Color(red: c.0, green: c.1, blue: c.2) }
    return accent
}
/// dark glyph on light tints, white glyph on dark ones
private func glyphColor(_ hex: String) -> Color {
    guard let c = rgb(hex) else { return ink }
    return (0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2) > 0.6 ? ink : .white
}

private struct Dots: View {
    let position: Int, colors: [String]
    var body: some View {
        if colors.count > 1 && colors.count <= 20 {
            HStack(spacing: 4) {
                ForEach(0..<colors.count, id: \.self) { i in
                    let on = i + 1 == position
                    Capsule().fill(tintColor(colors[i])).opacity(on ? 1 : 0.32).frame(height: on ? 6 : 4)
                }
            }
            .frame(height: 6)
        }
    }
}

private struct Controls: View {
    let playing: Bool
    let hex: String
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Button(intent: ShootPreviousIntent()) {
                Text("‹ Section").font(.system(size: compact ? 12 : 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 32 : 38).background(pill, in: Capsule())
            }.buttonStyle(.plain)
            Button(intent: ShootToggleIntent()) {
                // play triangle and stop square are one shape; the right-hand points slide apart so it morphs
                ZStack {
                    Circle().fill(accent)
                    PlayStopShape(t: playing ? 1 : 0)
                        .fill(ink)
                        .overlay(PlayStopShape(t: playing ? 1 : 0).stroke(ink, style: StrokeStyle(lineWidth: 4, lineJoin: .round)))
                        .frame(width: compact ? 13 : 16, height: compact ? 13 : 16)
                        .offset(x: playing ? 0 : 1.5)
                        .animation(.timingCurve(0.2, 0.0, 0.1, 1.0, duration: 0.42), value: playing)
                }
                .frame(width: compact ? 40 : 46, height: compact ? 40 : 46)
            }.buttonStyle(.plain)
            Button(intent: ShootNextIntent()) {
                Text("Section ›").font(.system(size: compact ? 12 : 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 32 : 38).background(pill, in: Capsule())
            }.buttonStyle(.plain)
        }
    }
}

private struct PlayStopShape: Shape {
    var t: CGFloat   // 0 = play triangle, 1 = stop square
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let m = r.midY, k = r.height * 0.5 * (1 - t)   // right points converge on the middle when t = 0
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + k))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        _ = m
        return p
    }
}

private struct LockScreenView: View {
    let state: ShootActivityAttributes.ContentState
    let shoot: String
    var body: some View {
        let tint = tintColor(state.color)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.song).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(state.section).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                        if state.total > 0 { Text("\(state.position) of \(state.total)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)) }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button(intent: ShootNextSongIntent()) {
                        Text("Next song ›").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10).frame(height: 26).background(pill, in: Capsule())
                    }.buttonStyle(.plain)
                    Button(intent: ShootPreviousSongIntent()) {
                        Text("‹ Prev song").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10).frame(height: 26).background(pill, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            Controls(playing: state.playing, hex: state.color).frame(maxWidth: .infinity)
            Dots(position: state.position, colors: state.colors)
        }
        .padding(14)
    }
}

struct ShootLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShootActivityAttributes.self) { context in
            LockScreenView(state: context.state, shoot: context.attributes.shoot)
                .activityBackgroundTint(ink)
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.song).font(.system(size: 16, weight: .bold)).lineLimit(1)
                        Text(context.state.section).font(.system(size: 14, weight: .semibold)).foregroundStyle(tintColor(context.state.color)).lineLimit(1)
                    }.padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.position) of \(context.state.total)").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Controls(playing: context.state.playing, hex: context.state.color, compact: true).frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill").foregroundStyle(tintColor(context.state.color))
            } compactTrailing: {
                Text(context.state.section).font(.system(size: 12, weight: .semibold)).foregroundStyle(tintColor(context.state.color)).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill").foregroundStyle(tintColor(context.state.color))
            }
            .keylineTint(tintColor(context.state.color))
        }
    }
}
