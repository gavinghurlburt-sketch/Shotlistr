import SwiftUI

/// Where each app's buttons, captions and names sit on top of a 1080 x 1920 video. Keep faces and
/// text inside the line. Margins are in pixels of the 1080 x 1920 frame, from each platform's ad specs
/// (Facebook Reels uses Meta's Reels margins, the same as Instagram).
enum SafeZone: String, CaseIterable {
    case off, instagram, tiktok, facebook, youtube

    var name: String {
        switch self {
        case .off: "Off"
        case .instagram: "Instagram Reels"
        case .tiktok: "TikTok"
        case .facebook: "Facebook Reels"
        case .youtube: "YouTube Shorts"
        }
    }

    var short: String {
        switch self {
        case .off: "Safe zone"
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .facebook: "Facebook"
        case .youtube: "Shorts"
        }
    }

    /// top, bottom, left, right
    var margins: (top: Double, bottom: Double, left: Double, right: Double) {
        switch self {
        case .off: (0, 0, 0, 0)
        case .instagram, .facebook: (269, 672, 65, 65)
        case .tiktok: (240, 660, 120, 120)
        case .youtube: (288, 672, 48, 192)
        }
    }

    /// The safe area inside a frame of this size.
    func rect(in size: CGSize) -> CGRect {
        let m = margins
        let sx = size.width / 1080
        let sy = size.height / 1920
        return CGRect(x: m.left * sx, y: m.top * sy,
                      width: size.width - (m.left + m.right) * sx,
                      height: size.height - (m.top + m.bottom) * sy)
    }
}

/// Shows what each app puts on top of the video: its buttons, counts, name, caption and bars, drawn
/// as a stand-in (no real names or logos) in the spots the app uses. Only on screen, never in the export.
struct SafeZoneOverlay: View {
    let zone: SafeZone

    var body: some View {
        switch zone {
        case .off:
            EmptyView()
        case .instagram, .tiktok, .facebook, .youtube:
            AppMock(layout: MockLayout.for(zone))
        }
    }
}

/// Where one app's pieces sit, in pixels of the 1080 x 1920 frame.
struct MockLayout {
    struct Action {
        var icon: String
        var label: String?
    }

    /// Words across the top (the first is bold, the rest dimmed), centered at `titleX`.
    var titles: [String]
    var titleX: CGFloat = 540
    var titleY: CGFloat = 150
    /// Which title is the bold, picked one.
    var boldTitle = 0
    var topLeft: String?
    var topRight: [String] = []
    /// The button column on the right.
    var actions: [Action]
    var actionTop: CGFloat
    var actionGap: CGFloat
    /// A round picture with a plus at the top of the column (TikTok).
    var avatarInColumn = false
    /// The name row: a round picture before the name, and a button after it.
    var avatarBeforeName = true
    var name = "yourname"
    var nameButton: String?
    /// White button with dark words (Subscribe) instead of an outlined one.
    var solidButton = false
    var nameY: CGFloat
    var caption = "Your caption shows here and runs on…"
    var audio: String?
    /// The tab bar along the bottom (empty: none).
    var tabs: [(icon: String, label: String?)] = []
    var tabY: CGFloat = 1840
    /// A floating rounded bar instead of a solid black strip.
    var floatingTabs = false
    /// The middle tab is a big plus button.
    var plusTab = false
    /// A solid black strip under the floating bar, starting this far down (0: none).
    var blackFrom: CGFloat = 0
    /// The picked tab sits on a lighter pill.
    var pickedTab: Int?
    /// Floating bar size and corner (a capsule when the corner is nil).
    var barWidth: CGFloat = 800
    var barHeight: CGFloat = 130
    var barCorner: CGFloat?
    /// A small square picture at the bottom of the button column (the sound, on Shorts).
    var soundSquare = false
    /// Room between the icons at the top right.
    var topGap: CGFloat = 100

    static func `for`(_ zone: SafeZone) -> MockLayout {
        switch zone {
        case .tiktok:
            return MockLayout(
                // Matched to a TikTok screen template (Nov 18).
                titles: ["Following", "For You"], titleY: 90, boldTitle: 1,
                topRight: ["magnifyingglass"],
                actions: [Action(icon: "heart.fill", label: "48.2K"),
                          Action(icon: "ellipsis.bubble.fill", label: "152"),
                          Action(icon: "bookmark.fill", label: "2,950"),
                          Action(icon: "arrowshape.turn.up.right.fill", label: "326"),
                          Action(icon: "opticaldisc.fill", label: nil)],
                actionTop: 966, actionGap: 168, avatarInColumn: true,
                avatarBeforeName: false, nameY: 1477,
                audio: "original sound - yourname",
                tabs: [("house.fill", "Home"), ("person.2", "Friends"), ("plus", nil),
                       ("tray", "Inbox"), ("person", "Profile")],
                tabY: 1850, plusTab: true)
        case .youtube:
            // Matched to a Shorts screenshot (Nov 18).
            return MockLayout(
                titles: [], titleY: 187,
                topRight: ["bubble.left.and.bubble.right", "magnifyingglass", "ellipsis"],
                actions: [Action(icon: "heart", label: "4.2K"),
                          Action(icon: "text.bubble", label: "31"),
                          Action(icon: "bookmark", label: "Save"),
                          Action(icon: "arrowshape.turn.up.right", label: "Share"),
                          Action(icon: "arrow.triangle.2.circlepath", label: "Remix")],
                actionTop: 950, actionGap: 132,
                name: "@yourname", nameButton: "Subscribe", solidButton: true, nameY: 1577,
                tabs: [("house", nil), ("play.square.stack.fill", nil), ("plus.circle", nil),
                       ("person.crop.circle.fill", nil)],
                tabY: 1792, floatingTabs: true, blackFrom: 1704, pickedTab: 1,
                barWidth: 920, barHeight: 112, barCorner: 50, soundSquare: true, topGap: 120)
        case .facebook:
            return MockLayout(
                titles: ["Reels"], titleX: 150, titleY: 150, topRight: ["magnifyingglass", "camera"],
                actions: [Action(icon: "hand.thumbsup", label: "1.2K"),
                          Action(icon: "bubble.right", label: "152"),
                          Action(icon: "arrowshape.turn.up.right", label: "326"),
                          Action(icon: "ellipsis", label: nil)],
                actionTop: 1130, actionGap: 165,
                name: "Your Name", nameButton: "Follow", nameY: 1590,
                audio: "Your Name · Original audio")
        default:
            return MockLayout(
                titles: ["Reels", "Friends"], titleX: 470, titleY: 190,
                topLeft: "plus", topRight: ["slider.horizontal.3"],
                actions: [Action(icon: "heart", label: "64.2K"),
                          Action(icon: "bubble.right", label: "152"),
                          Action(icon: "arrow.2.squarepath", label: "326"),
                          Action(icon: "paperplane", label: "8,407"),
                          Action(icon: "bookmark", label: "2,950"),
                          Action(icon: "line.3.horizontal", label: nil)],
                actionTop: 830, actionGap: 158,
                nameButton: "Follow", nameY: 1550,
                tabs: [("house", nil), ("play.rectangle.fill", nil), ("paperplane", nil),
                       ("magnifyingglass", nil), ("person.crop.circle", nil)],
                tabY: 1810, floatingTabs: true, pickedTab: 1)
        }
    }
}

/// One app's screen drawn over the video, scaled to the frame.
private struct AppMock: View {
    let layout: MockLayout

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 1080
            ZStack(alignment: .topLeading) {
                // The apps shade the top and bottom so their white text reads.
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 340 * s)
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 760 * s)
                    .offset(y: geo.size.height - 760 * s)

                topBar(s)
                column(s)
                nameBlock(s)
                if layout.blackFrom > 0 {
                    Rectangle().fill(.black)
                        .frame(width: geo.size.width, height: max(0, geo.size.height - layout.blackFrom * s))
                        .offset(y: layout.blackFrom * s)
                }
                if !layout.tabs.isEmpty { tabBar(s, size: geo.size) }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 2 * s + 0.5)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func topBar(_ s: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 34 * s) {
                ForEach(Array(layout.titles.enumerated()), id: \.offset) { index, title in
                    Text(title)
                        .font(.system(size: (index == layout.boldTitle ? 58 : 54) * s, weight: .bold))
                        .opacity(index == layout.boldTitle ? 1 : 0.6)
                }
            }
            .fixedSize()
            .position(x: layout.titleX * s, y: layout.titleY * s)
            if let left = layout.topLeft {
                Image(systemName: left)
                    .font(.system(size: 58 * s, weight: .regular))
                    .position(x: 70 * s, y: layout.titleY * s)
            }
            ForEach(Array(layout.topRight.reversed().enumerated()), id: \.offset) { index, icon in
                Image(systemName: icon)
                    .font(.system(size: 54 * s, weight: .regular))
                    .position(x: (1000 - CGFloat(index) * layout.topGap) * s, y: layout.titleY * s)
            }
        }
    }

    private func column(_ s: CGFloat) -> some View {
        ZStack {
            if layout.avatarInColumn {
                ZStack(alignment: .bottom) {
                    avatar(s, size: 100)
                    Image(systemName: "plus")
                        .font(.system(size: 22 * s, weight: .heavy))
                        .frame(width: 40 * s, height: 40 * s)
                        .background(Circle().fill(Color(red: 1, green: 0.17, blue: 0.33)))
                        .offset(y: 18 * s)
                }
                .position(x: 990 * s, y: (layout.actionTop - 175) * s)
            }
            ForEach(Array(layout.actions.enumerated()), id: \.offset) { index, action in
                VStack(spacing: 10 * s) {
                    Image(systemName: action.icon)
                        .font(.system(size: 64 * s, weight: .regular))
                    if let label = action.label {
                        Text(label)
                            .font(.system(size: 30 * s, weight: .semibold))
                            .fixedSize()
                    }
                }
                .position(x: 990 * s, y: (layout.actionTop + CGFloat(index) * layout.actionGap) * s)
            }
            if layout.soundSquare {
                RoundedRectangle(cornerRadius: 14 * s)
                    .fill(Color(white: 0.4))
                    .overlay(RoundedRectangle(cornerRadius: 14 * s).strokeBorder(.white, lineWidth: 5 * s))
                    .frame(width: 80 * s, height: 80 * s)
                    .position(x: 990 * s,
                              y: (layout.actionTop + CGFloat(layout.actions.count) * layout.actionGap + 10) * s)
            }
        }
    }

    private func nameBlock(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22 * s) {
            HStack(spacing: 22 * s) {
                if layout.avatarBeforeName { avatar(s, size: 96) }
                Text(layout.name)
                    .font(.system(size: 40 * s, weight: .bold))
                if let button = layout.nameButton {
                    Text(button)
                        .font(.system(size: 34 * s, weight: .semibold))
                        .foregroundStyle(layout.solidButton ? Color.black : Color.white)
                        .padding(.horizontal, 22 * s)
                        .padding(.vertical, 10 * s)
                        .background {
                            if layout.solidButton {
                                Capsule().fill(.white)
                            } else {
                                RoundedRectangle(cornerRadius: 14 * s).strokeBorder(.white.opacity(0.85), lineWidth: 3 * s)
                            }
                        }
                }
            }
            Text(layout.caption)
                .font(.system(size: 36 * s))
                .lineLimit(1)
            if let audio = layout.audio {
                Label(audio, systemImage: "music.note")
                    .font(.system(size: 32 * s, weight: .medium))
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .frame(width: 800 * s, alignment: .leading)
        .clipped()
        .offset(x: 40 * s, y: (layout.nameY - (layout.avatarBeforeName ? 48 : 24)) * s)
    }

    private func tabBar(_ s: CGFloat, size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(layout.tabs.enumerated()), id: \.offset) { index, tab in
                VStack(spacing: 6 * s) {
                    if layout.plusTab && tab.label == nil {
                        Image(systemName: tab.icon)
                            .font(.system(size: 42 * s, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 110 * s, height: 72 * s)
                            .background(RoundedRectangle(cornerRadius: 18 * s).fill(.white))
                    } else {
                        Image(systemName: tab.icon)
                            .font(.system(size: (tab.label == nil ? 60 : 52) * s, weight: .regular))
                        if let label = tab.label {
                            Text(label).font(.system(size: 24 * s, weight: .medium)).fixedSize()
                        }
                    }
                }
                .opacity(index == 0 || layout.floatingTabs ? 1 : 0.8)
                .frame(maxWidth: .infinity)
                .frame(height: layout.barHeight * 0.8 * s)
                .background {
                    if layout.pickedTab == index {
                        Capsule().fill(Color(white: 0.2))
                    }
                }
            }
        }
        .padding(.horizontal, layout.floatingTabs ? 30 * s : 0)
        .frame(width: layout.floatingTabs ? layout.barWidth * s : size.width,
               height: (layout.floatingTabs ? layout.barHeight : 160) * s)
        .background {
            if layout.floatingTabs, let corner = layout.barCorner {
                RoundedRectangle(cornerRadius: corner * s).fill(Color(white: 0.07))
                    .overlay(RoundedRectangle(cornerRadius: corner * s).strokeBorder(.white.opacity(0.15), lineWidth: 2 * s))
            } else if layout.floatingTabs {
                Capsule().fill(Color(white: 0.16).opacity(0.85))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 2 * s))
            } else {
                Rectangle().fill(.black.opacity(0.92))
            }
        }
        .position(x: size.width / 2, y: layout.tabY * s)
    }

    private func avatar(_ s: CGFloat, size: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.5 * s))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: size * s, height: size * s)
            .background(Circle().fill(Color(white: 0.4)))
            .overlay(Circle().strokeBorder(.white, lineWidth: 3 * s))
    }
}

/// Picks which app's safe zone to show. A tap on it fans the apps' marks out from under it
/// (Instagram, Facebook, YouTube, TikTok, and off); tap one to pick it.
struct SafeZonePicker: View {
    @Binding var zone: SafeZone
    /// Drawn as a tile for the column beside the video.
    var tile = false
    /// Whether the apps are fanned out, for a screen that needs to know (it lifts the column over
    /// its neighbours so a tap anywhere off the menu closes it). Nil: kept here.
    var isOpen: Binding<Bool>? = nil
    @State private var openHere = false
    private var open: Bool { isOpen?.wrappedValue ?? openHere }
    private func setOpen(_ value: Bool) {
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
            if let isOpen { isOpen.wrappedValue = value } else { openHere = value }
        }
    }

    /// In the order they fan out.
    private static let order: [SafeZone] = [.instagram, .facebook, .youtube, .tiktok, .off]
    private static let step: CGFloat = 46

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(Self.order.enumerated()), id: \.element) { index, option in
                Button {
                    zone = option
                    setOpen(false)
                } label: {
                    SocialMark(zone: option, picked: zone == option)
                        .frame(width: 36, height: 40)
                        // Solid, so the tiles under the fanned-out marks (Lyrics' speech bubble)
                        // don't show through.
                        .background(Color.black)
                        .overlay(Rectangle().strokeBorder(zone == option ? Tint.accent : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option == .off ? "Safe zone off" : option.name)
                .offset(y: open ? CGFloat(index + 1) * Self.step : 0)
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.6)
                .animation(.spring(duration: 0.32, bounce: 0.25).delay(open ? Double(index) * 0.03 : 0), value: open)
                .allowsHitTesting(open)
            }
            Button {
                setOpen(!open)
            } label: {
                Group {
                    if zone == .off {
                        if tile {
                            SideTile(icon: "rectangle.dashed", text: "Safe zone", lit: open)
                        } else {
                            chip
                        }
                    } else {
                        SocialMark(zone: zone, picked: true)
                            .frame(width: 36, height: 44)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(zone == .off ? "Safe zone" : "Safe zone: \(zone.name)")
            .accessibilityHint("Shows the apps to pick from")
        }
        // Open: a tap anywhere off the menu closes it (a clear catcher far past the screen's edges,
        // under the apps' marks).
        .background {
            if open {
                Color.black.opacity(0.001)
                    .frame(width: 5000, height: 5000)
                    .contentShape(Rectangle())
                    .onTapGesture { setOpen(false) }
                    .accessibilityHidden(true)
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.dashed")
            Text(zone.short)
        }
        .lineLimit(1)
        .font(.caption.weight(.semibold))
        .foregroundStyle(zone == .off ? Color.white : Tint.warn)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .shadow(color: .black.opacity(0.8), radius: 3)
    }
}

/// A small mark for each app's safe zone, drawn here (no image files): Instagram's camera, the
/// Facebook f, YouTube's play button and TikTok's note. Off is a dashed frame.
struct SocialMark: View {
    let zone: SafeZone
    var picked = false

    var body: some View {
        Group {
            switch zone {
            case .instagram:
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.76, blue: 0.27),
                                                      Color(red: 0.93, green: 0.2, blue: 0.4),
                                                      Color(red: 0.55, green: 0.24, blue: 0.85)],
                                             startPoint: .bottomLeading, endPoint: .topTrailing))
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1.8)
                        .padding(3.5)
                    Circle().strokeBorder(.white, lineWidth: 1.8).frame(width: 9, height: 9)
                    Circle().fill(.white).frame(width: 2.4, height: 2.4).offset(x: 4.6, y: -4.6)
                }
                .frame(width: 22, height: 22)
            case .facebook:
                ZStack {
                    Circle().fill(Color(red: 0.09, green: 0.47, blue: 0.95))
                    Text("f")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .offset(x: 1, y: 2)
                }
                .frame(width: 22, height: 22)
            case .youtube:
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(red: 1, green: 0, blue: 0))
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 17)
            case .tiktok:
                ZStack {
                    note.foregroundStyle(Color(red: 0.15, green: 0.96, blue: 0.94)).offset(x: -1.2, y: -1.2)
                    note.foregroundStyle(Color(red: 1, green: 0.17, blue: 0.33)).offset(x: 1.2, y: 1.2)
                    note.foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            case .off:
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .overlay(Rectangle().fill(.white.opacity(0.85)).frame(width: 26, height: 1.6).rotationEffect(.degrees(-35)))
            }
        }
        .accessibilityHidden(true)
    }

    private var note: some View {
        Image(systemName: "music.note").font(.system(size: 17, weight: .black))
    }
}
