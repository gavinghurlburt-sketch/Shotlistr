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

private let accent = Color(red: 0.96, green: 0.82, blue: 0.26)
private let ink = Color(red: 0.07, green: 0.07, blue: 0.07)

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
        HStack(spacing: compact ? 10 : 14) {
            Button(intent: ShootPreviousIntent()) {
                Image(systemName: "backward.fill").font(.system(size: compact ? 15 : 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: compact ? 34 : 40, height: compact ? 34 : 40).background(Color.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain)
            Button(intent: ShootToggleIntent()) {
                // one shape that swaps instantly (no crossfade): rounded square = stop, triangle = play
                ZStack {
                    Circle().fill(tintColor(hex))
                    if playing {
                        RoundedRectangle(cornerRadius: 3).fill(glyphColor(hex)).frame(width: compact ? 14 : 18, height: compact ? 14 : 18)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: compact ? 18 : 22, weight: .bold)).foregroundStyle(glyphColor(hex)).offset(x: 2)
                    }
                }
                .frame(width: compact ? 44 : 54, height: compact ? 44 : 54)
                .contentTransition(.identity)
                .transaction { $0.animation = nil }
            }.buttonStyle(.plain)
            Button(intent: ShootNextIntent()) {
                Image(systemName: "forward.fill").font(.system(size: compact ? 15 : 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: compact ? 34 : 40, height: compact ? 34 : 40).background(Color.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain)
        }
        .transaction { $0.animation = nil }
    }
}

private struct LockScreenView: View {
    let state: ShootActivityAttributes.ContentState
    let shoot: String
    var body: some View {
        let tint = tintColor(state.color)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("creatrr").font(.system(size: 12, weight: .heavy)).foregroundStyle(accent)
                        Text(shoot).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Text(state.song).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(state.section).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                        if state.total > 0 { Text("\(state.position) of \(state.total)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)) }
                    }
                }
                Spacer(minLength: 8)
                Controls(playing: state.playing, hex: state.color)
            }
            Dots(position: state.position, colors: state.colors)
        }
        .padding(16)
        .contentTransition(.identity)
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
