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

private struct Dots: View {
    let position: Int, total: Int
    var body: some View {
        if total > 1 && total <= 16 {
            HStack(spacing: 3) {
                ForEach(1...total, id: \.self) { i in
                    Capsule().fill(i == position ? accent : Color.white.opacity(i < position ? 0.45 : 0.18)).frame(height: 4)
                }
            }
        }
    }
}

private struct Controls: View {
    let playing: Bool
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            Button(intent: ShootPreviousIntent()) {
                Image(systemName: "backward.fill").font(.system(size: compact ? 15 : 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: compact ? 34 : 40, height: compact ? 34 : 40).background(Color.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain)
            Button(intent: ShootToggleIntent()) {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: compact ? 18 : 22, weight: .bold)).foregroundStyle(ink)
                    .frame(width: compact ? 44 : 54, height: compact ? 44 : 54).background(accent, in: Circle())
            }.buttonStyle(.plain)
            Button(intent: ShootNextIntent()) {
                Image(systemName: "forward.fill").font(.system(size: compact ? 15 : 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: compact ? 34 : 40, height: compact ? 34 : 40).background(Color.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain)
        }
    }
}

private struct LockScreenView: View {
    let state: ShootActivityAttributes.ContentState
    let shoot: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("creatrr").font(.system(size: 12, weight: .heavy)).foregroundStyle(accent)
                        Text(shoot).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Text(state.song).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(state.section).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent).lineLimit(1)
                        if state.total > 0 { Text("\(state.position) of \(state.total)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)) }
                    }
                }
                Spacer(minLength: 8)
                Controls(playing: state.playing)
            }
            Dots(position: state.position, total: state.total)
        }
        .padding(16)
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
                        Text(context.state.section).font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).lineLimit(1)
                    }.padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.position) of \(context.state.total)").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Controls(playing: context.state.playing, compact: true).frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill").foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.section).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill").foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}
