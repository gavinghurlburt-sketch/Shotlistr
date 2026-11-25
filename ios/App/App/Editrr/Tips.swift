import SwiftUI

/// The editor's short tips. Each one shows by itself only the first time its feature is used
/// (Fx opened, a first keyframe, Tap beat picked, Tap the timing picked). The ? beside the
/// feature's title shows it again any time. Export, Mirror, Cut, Add sound and the rest have none:
/// they work like every other editor.
enum EditorTip: String {
    case fx, keyframes, tapBeat, lyricTap

    var icon: String {
        switch self {
        case .fx: "sparkles"
        case .keyframes: "diamond"
        case .tapBeat: "hand.tap"
        case .lyricTap: "music.mic"
        }
    }

    var title: String {
        switch self {
        case .fx: "Fx"
        case .keyframes: "Keyframes"
        case .tapBeat: "Tap beat"
        case .lyricTap: "Tap the timing"
        }
    }

    var lines: [String] {
        switch self {
        case .fx:
            ["Each effect goes on this cut only. Its sliders set how much: drag one, then play to see it.",
             "The diamond beside a slider animates it. Tap it, move the playhead, then move the slider again. Each change makes a keyframe."]
        case .keyframes:
            ["A keyframe keeps how something looks at that moment.",
             "Move the playhead and change it again: it glides from one keyframe to the next.",
             "Tap a diamond on the timeline to go to it. The diamond button then takes it off."]
        case .tapBeat:
            ["Tap Play, then tap either pad on the beat. Each tap is a cut.",
             "Done picks a take for each cut. Cancel leaves your edit as it was."]
        case .lyricTap:
            ["Tap Play, then tap either pad as each word is sung. A word with more than one syllable takes a tap for each.",
             "Mess up? Tap Stop, then Previous to go back a word at a time, and tap on from there. Play back checks it with the music. Done keeps it."]
        }
    }

    /// Set once the tip has shown by itself, so it never pops up on its own again.
    var seenKey: String { "tipSeen." + rawValue }

    /// True the first time only (and marks it shown).
    func firstTime() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seenKey) else { return false }
        defaults.set(true, forKey: seenKey)
        return true
    }
}

/// A tip over the screen: its icon, title and a few short lines, and Got it. A tap anywhere
/// outside the card puts it away too.
struct TipCard: View {
    let tip: EditorTip
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: tip.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Tint.accent)
                    Text(tip.title).font(.title3.weight(.bold))
                }
                ForEach(tip.lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Got it", action: close)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .background(Tint.surface)
            .padding(24)
            .accessibilityElement(children: .contain)
        }
        .transition(.opacity)
    }
}

/// The ? beside a feature's title: shows its tip again.
struct TipButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How this works")
    }
}
