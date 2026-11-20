import SwiftUI
import AVFoundation
import UIKit

/// Tap to cut, as a rhythm game. The video is hidden: the song's waveform streams past a
/// playhead (like Voice Memos), your cuts build in a lane under it, and the whole screen is the
/// tap pad. Scoring is lenient: a tap near a beat or half beat snaps onto it. At the end, stars
/// for pacing (what keeps people watching), then Watch it, Keep edit or Try again. Which take
/// each cut goes to is Auto edit's pick, the same as before.
@MainActor @Observable
final class TapGame {
    enum Phase { case ready, counting, playing, done, applying, watching }
    enum Kind { case perfect, nice, artistic }
    struct Tap { let time: Double; let kind: Kind }
    struct Pop: Identifiable {
        let id = UUID()
        let word: String
        let color: Color
    }
    struct Rating {
        let stars: Int
        let title: String
        let facts: String
    }

    let model: EditorModel
    var phase: Phase = .ready
    /// The count before the song starts (3, 2, 1).
    var count = 3
    var taps: [Tap] = []
    var pops: [Pop] = []
    /// The song's beats (timeline seconds), when one was found.
    private(set) var beats: [Double] = []
    private(set) var barPhase = 0
    /// The waveform: one value a hundredth of a second, 0 to 1, shaped to read well.
    private(set) var peaks: [Float] = []
    private(set) var peaksZero: Double = 0
    /// The cuts are on the timeline now (after Watch it or Keep edit): Try again takes them off.
    private(set) var applied = false
    /// Where the waveform stopped when the round ended.
    private(set) var frozen: Double = 0

    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var lastSeen: Double = 0
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// Seconds the waveform moves per second (points).
    static let speed: CGFloat = 130
    /// How long the eye and finger take to answer the sound, on average (a tap is a hair late).
    private static let lateness = 0.03

    init(model: EditorModel) {
        self.model = model
        if let found = model.songLoudness {
            peaksZero = found.zero
            let top = max(found.values.max() ?? 1, 0.0001)
            peaks = found.values.map { pow($0 / top, 0.7) }
        }
    }

    /// Finds the song's beats (once), for judging the taps and drawing the dots.
    func loadBeats() async {
        guard beats.isEmpty else { return }
        let found = await model.songBeats()
        beats = found.times
        barPhase = found.barPhase
    }

    var start: Double { model.loopStart }
    var end: Double { max(model.loopStart + 0.5, model.loopEnd) }
    var length: Double { end - start }

    /// The moment the screen shows (timeline seconds).
    func shownTime() -> Double {
        switch phase {
        case .ready: return start - 1.2
        case .counting: return start - Double(count) * 0.4
        case .playing, .watching:
            let now = model.player.currentTime().seconds
            return now.isFinite ? now : start
        case .done, .applying: return frozen
        }
    }

    // MARK: Playing

    func begin() {
        runner?.cancel()
        taps = []
        pops = []
        model.rewindForTapGame()
        phase = .counting
        count = 3
        haptic.prepare()
        runner = Task {
            for left in [3, 2, 1] {
                count = left
                haptic.impactOccurred(intensity: 0.6)
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
            }
            lastSeen = start
            model.play()
            phase = .playing
            await watchForEnd()
            if Task.isCancelled { return }
            finishRound()
        }
    }

    /// Waits until the song gets to the end (or loops back round to the start).
    private func watchForEnd() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let now = model.player.currentTime().seconds
            guard now.isFinite else { continue }
            if now >= end - 0.06 || now < lastSeen - 0.5 || !model.isPlaying { return }
            lastSeen = now
        }
    }

    private func finishRound() {
        frozen = min(end, max(lastSeen, start))
        model.pause()
        phase = .done
    }

    /// Stop mid-round: back to the start, taps cleared.
    func stopRound() {
        runner?.cancel()
        model.rewindForTapGame()
        taps = []
        pops = []
        phase = .ready
    }

    /// One tap: a cut here, judged leniently.
    func tap() {
        guard phase == .playing else { return }
        let now = model.player.currentTime().seconds - Self.lateness
        guard now.isFinite, now > start + 0.15, now < end - 0.1 else { return }
        let (at, kind) = judge(now)
        if let last = taps.last, abs(last.time - at) < 0.05 { return }
        taps.append(Tap(time: at, kind: kind))
        taps.sort { $0.time < $1.time }
        haptic.impactOccurred()
        let pop: Pop
        switch kind {
        case .perfect: pop = Pop(word: "Perfect cut!", color: Tint.accent)
        case .nice: pop = Pop(word: "Nice edit!", color: Tint.good)
        case .artistic: pop = Pop(word: "Artistic!", color: TapGameView.artColor)
        }
        pops.append(pop)
        let id = pop.id
        Task {
            try? await Task.sleep(for: .milliseconds(950))
            pops.removeAll { $0.id == id }
        }
    }

    /// Close to a beat: onto it (Perfect). Close to a beat or half beat: onto that (Nice).
    /// Anything else stays where you tapped (Artistic). No beat found: every cut is Nice.
    private func judge(_ time: Double) -> (Double, Kind) {
        guard beats.count >= 2 else { return (time, .nice) }
        var low = 0, high = beats.count - 1
        while low < high {
            let middle = (low + high) / 2
            if beats[middle] < time { low = middle + 1 } else { high = middle }
        }
        var index = low
        if index > 0, abs(beats[index - 1] - time) < abs(beats[index] - time) { index -= 1 }
        let beat = beats[index]
        if abs(beat - time) <= 0.07 { return (frame(beat), .perfect) }
        var spots = [beat]
        if index + 1 < beats.count { spots.append((beat + beats[index + 1]) / 2) }
        if index > 0 { spots.append((beats[index - 1] + beat) / 2) }
        let nearest = spots.min { abs($0 - time) < abs($1 - time) } ?? beat
        if abs(nearest - time) <= 0.15 { return (frame(nearest), .nice) }
        return (frame(time), .artistic)
    }

    private func frame(_ time: Double) -> Double { (time * 30).rounded() / 30 }

    // MARK: The score

    var rating: Rating {
        let cuts = taps.count
        let shot = length / Double(cuts + 1)
        let withBeat = taps.filter { $0.kind != .artistic }.count
        let facts = cuts == 0
            ? "One shot the whole way through"
            : "\(cuts) cut\(cuts == 1 ? "" : "s") · a new shot every \(String(format: "%.1f", shot))s · \(withBeat) with the music"
        if cuts == 0 { return Rating(stars: 1, title: "No cuts at all", facts: facts) }
        if shot < 1.2 { return Rating(stars: 2, title: "Too many cuts", facts: facts) }
        if shot > 6 { return Rating(stars: 2, title: "A little slow. Try a few more cuts", facts: facts) }
        return Rating(stars: 3, title: withBeat * 2 >= cuts ? "Good pacing, on the rhythm!" : "Good pacing!", facts: facts)
    }

    // MARK: After a round

    /// Puts the cuts on the timeline (once). Says whether they're on.
    private func apply() async -> Bool {
        if applied { return true }
        phase = .applying
        applied = await model.applyTapGame(taps.map(\.time))
        phase = .done
        return applied
    }

    /// Plays the edit, with the real takes, from the start.
    func watch() {
        Task {
            guard await apply() else { return }
            runner?.cancel()
            model.rewindForTapGame()
            lastSeen = start
            phase = .watching
            model.play()
            runner = Task {
                await watchForEnd()
                if Task.isCancelled { return }
                stopWatching()
            }
        }
    }

    func stopWatching() {
        runner?.cancel()
        model.pause()
        phase = .done
    }

    /// Keeps the cuts and goes back to the editor.
    func keep() {
        Task {
            runner?.cancel()
            model.pause()
            guard await apply() else { return }
            model.tapBeatOn = false
        }
    }

    /// Takes the cuts back off (if they went on) and starts a new round.
    func tryAgain() {
        runner?.cancel()
        model.pause()
        if applied {
            model.undo()
            applied = false
        }
        begin()
    }

    /// Leaves the game: nothing changes on the timeline.
    func close() {
        runner?.cancel()
        model.pause()
        if applied {
            model.undo()
            applied = false
        }
        model.rewindForTapGame()
        model.tapBeatOn = false
    }
}

struct TapGameView: View {
    let model: EditorModel
    @State private var game: TapGame
    /// A finger is down on the pad (one cut per touch, on the touch down, for timing).
    @State private var down = false

    static let artColor = Color(red: 1.0, green: 0.37, blue: 0.64)    // #ff5fa2
    private static let lane = Color(red: 0.11, green: 0.11, blue: 0.12)
    private static let waveBack = Color(red: 0.137, green: 0.137, blue: 0.153)
    private static let line = Color(red: 0.184, green: 0.184, blue: 0.204)

    init(model: EditorModel) {
        self.model = model
        _game = State(initialValue: TapGame(model: model))
    }

    var body: some View {
        ZStack {
            // The tap pad: the whole screen while the song plays.
            Tint.backdrop
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        game.tap()
                    }
                    .onEnded { _ in down = false })
                .accessibilityElement()
                .accessibilityLabel(game.phase == .playing ? "Tap to cut" : "Tap to cut game")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { game.tap() }

            VStack(spacing: 14) {
                header
                    .allowsHitTesting(game.phase != .playing && game.phase != .counting)
                if game.phase == .watching {
                    PlayerView(player: model.player)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .frame(maxHeight: .infinity)
                        .allowsHitTesting(false)
                } else {
                    track
                        .allowsHitTesting(false)
                }
                middle
                Spacer(minLength: 0)
                buttons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .foregroundStyle(Tint.text)
        .statusBarHidden(game.phase == .playing)
        .task { await game.loadBeats() }
        .onDisappear { if game.phase == .playing || game.phase == .watching { model.pause() } }
    }

    private var header: some View {
        HStack {
            Button {
                game.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close, without changing your cuts")
            .disabled(game.phase == .applying)
            .opacity(game.phase == .playing || game.phase == .counting ? 0 : 1)
            Spacer()
            VStack(spacing: 2) {
                Text("Tap to cut").font(.headline)
                Text(subtitle)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Tint.calm)
                    .lineLimit(1)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var subtitle: String {
        let name = model.soundtrack?.name ?? "Your song"
        return "\(name) · \(TapGameView.clock(game.length, hundredths: false))"
    }

    /// The waveform, the cut lane under it, and the cheers.
    private var track: some View {
        TimelineView(.animation(paused: game.phase != .playing)) { _ in
            let now = game.shownTime()
            VStack(spacing: 0) {
                Canvas { context, size in drawWave(context, size: size, now: now) }
                    .frame(maxHeight: 280)
                    .frame(minHeight: 170)
                Canvas { context, size in drawLane(context, size: size, now: now) }
                    .frame(height: 56)
            }
            .overlay { cheers }
        }
        .padding(.horizontal, -16)
    }

    private var cheers: some View {
        ZStack {
            ForEach(game.pops) { pop in
                Cheer(word: pop.word, color: pop.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var middle: some View {
        switch game.phase {
        case .ready:
            Text("Tap anywhere to cut. Cut with the music.")
                .font(.subheadline)
                .foregroundStyle(Tint.calm)
                .multilineTextAlignment(.center)
        case .counting:
            Text("Get ready… \(game.count)")
                .font(.title2.weight(.bold).monospacedDigit())
        case .playing:
            TimelineView(.animation) { _ in
                Text(TapGameView.clock(max(0, game.shownTime() - game.start), hundredths: true))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
            }
            .allowsHitTesting(false)
        case .done, .applying:
            results
        case .watching:
            EmptyView()
        }
    }

    private var results: some View {
        let rating = game.rating
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { star in
                    Image(systemName: "star.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(star <= rating.stars ? Tint.accent : TapGameView.line)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(rating.stars) of 3 stars")
            Text(rating.title)
                .font(.title3.weight(.heavy))
                .multilineTextAlignment(.center)
            Text(rating.facts)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Tint.calm)
                .multilineTextAlignment(.center)
            Text("Short videos tend to hold people best with a new shot every 2 to 4 seconds, cut with the music.")
                .font(.caption)
                .foregroundStyle(Tint.calm)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let problem = model.problem, game.phase == .done, !game.applied {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Tint.bad)
                    .multilineTextAlignment(.center)
            }
            if game.phase == .applying {
                HStack(spacing: 8) {
                    ProgressView().tint(Tint.text)
                    Text(model.busy ?? "Putting your cuts together…")
                        .font(.subheadline)
                        .foregroundStyle(Tint.calm)
                }
                .padding(.top, 6)
            } else {
                Button {
                    game.watch()
                } label: {
                    Label("Watch it", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(Rectangle().stroke(TapGameView.line, lineWidth: 1))
                }
                .padding(.top, 4)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var buttons: some View {
        switch game.phase {
        case .ready:
            wide("Start", filled: true) { game.begin() }
        case .counting, .playing:
            wide("Stop", filled: false) { game.stopRound() }
        case .done, .applying:
            HStack(spacing: 8) {
                wide("Try again", filled: false) { game.tryAgain() }
                wide("Keep edit", filled: true) { game.keep() }
            }
            .disabled(game.phase == .applying)
            .opacity(game.phase == .applying ? 0.5 : 1)
        case .watching:
            wide("Stop watching", filled: false) { game.stopWatching() }
        }
    }

    private func wide(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(filled ? Tint.accent : TapGameView.lane)
                .foregroundStyle(filled ? Tint.ink : Tint.text)
                .overlay(Rectangle().stroke(filled ? Color.clear : TapGameView.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Drawing

    private func drawWave(_ context: GraphicsContext, size: CGSize, now: Double) {
        let speed = TapGame.speed
        let middle = size.width / 2
        let ruler: CGFloat = 26, top: CGFloat = 10
        let body = size.height - ruler - top
        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: body)), with: .color(Self.waveBack))
        let x = { (at: Double) -> CGFloat in middle + CGFloat(at - now) * speed }

        // Bars, Voice Memos style: done in white, still to come dimmer.
        let peaks = game.peaks
        if !peaks.isEmpty {
            let gap: CGFloat = 5
            let step = Double(gap / speed)
            let first = Int(((now - Double(middle / speed)) / step).rounded(.down)) - 1
            let last = Int(((now + Double(middle / speed)) / step).rounded(.up)) + 1
            if first <= last {
                for k in first...last {
                    let at = Double(k) * step
                    guard at >= game.start - 0.01, at <= game.end + 1.4 else { continue }
                    let i0 = Int((at - game.peaksZero) * SoundPrint.rate)
                    let i1 = Int((at + step - game.peaksZero) * SoundPrint.rate)
                    var loudest: Float = 0
                    if i1 >= 0, i0 < peaks.count {
                        for i in max(0, i0)...min(peaks.count - 1, max(i0, i1)) where peaks[i] > loudest { loudest = peaks[i] }
                    }
                    let height = max(2, CGFloat(loudest) * body * 0.9)
                    let bar = CGRect(x: x(at), y: top + (body - height) / 2, width: 2, height: height)
                    context.fill(Path(bar), with: .color(Tint.text.opacity(at <= now ? 1 : 0.55)))
                }
            }
        }

        // Ruler: seconds from Start.
        let from = Int((now - game.start - Double(middle / speed)).rounded(.down)) - 1
        let to = Int((now - game.start + Double(middle / speed)).rounded(.up)) + 1
        let tick = Color(red: 0.353, green: 0.353, blue: 0.376)
        if from <= to {
            for second in from...to {
                for quarter in 0..<4 {
                    let at = Double(second) + Double(quarter) / 4
                    guard at >= 0 else { continue }
                    let tickRect = CGRect(x: x(game.start + at), y: top + body, width: 1, height: quarter == 0 ? 8 : 4)
                    context.fill(Path(tickRect), with: .color(tick))
                }
                guard second >= 0 else { continue }
                let label = Text(TapGameView.clock(Double(second), hundredths: false))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tick)
                context.draw(label, at: CGPoint(x: x(game.start + Double(second)) + 3, y: size.height - 4), anchor: .bottomLeading)
            }
        }

        // The playhead.
        context.fill(Path(CGRect(x: middle - 1, y: top, width: 2, height: body)), with: .color(Tint.accent))
        for y in [top, top + body] {
            context.fill(Path(ellipseIn: CGRect(x: middle - 5, y: y - 5, width: 10, height: 10)), with: .color(Tint.accent))
        }
    }

    private func drawLane(_ context: GraphicsContext, size: CGSize, now: Double) {
        let speed = TapGame.speed
        let middle = size.width / 2
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.lane))
        let x = { (at: Double) -> CGFloat in middle + CGFloat(at - now) * speed }

        // The shots so far: a color block each, up to the playhead. (Which take each one shows is
        // picked when the cuts go on, so the colors here just tell the shots apart.)
        let end = min(now, game.end)
        if end > game.start {
            let starts = [game.start] + game.taps.map(\.time).filter { $0 <= end }
            let layers = model.layers
            for (index, from) in starts.enumerated() {
                let until = index + 1 < starts.count ? starts[index + 1] : end
                let color = layers.isEmpty ? Tint.accent : LayerTint.color(layers[index % layers.count])
                let block = CGRect(x: x(from), y: 8, width: max(0, x(until) - x(from)), height: size.height - 16)
                context.fill(Path(block), with: .color(color.opacity(0.85)))
                if index > 0 {
                    context.fill(Path(CGRect(x: x(from) - 1, y: 2, width: 2, height: size.height - 4)), with: .color(.white))
                }
            }
        }

        // Beats coming up: dots riding in toward the playhead, bigger on the one.
        let beats = game.beats
        let ahead = now + Double(middle / speed)
        for (index, beat) in beats.enumerated() where beat >= now - 0.02 && beat <= min(ahead, game.end) && beat >= game.start {
            let one = (index - game.barPhase) % 4 == 0
            let radius: CGFloat = one ? 5 : 3
            let dot = CGRect(x: x(beat) - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(one ? Tint.accent.opacity(0.9) : Tint.text.opacity(0.45)))
        }

        context.fill(Path(CGRect(x: middle - 1, y: 0, width: 2, height: size.height)), with: .color(Tint.accent))
    }

    static func clock(_ seconds: Double, hundredths: Bool) -> String {
        let total = max(0, seconds)
        let minutes = Int(total / 60)
        let rest = total - Double(minutes) * 60
        return hundredths
            ? String(format: "%02d:%05.2f", minutes, rest)
            : String(format: "%d:%02d", minutes, Int(rest))
    }
}

/// "Perfect cut!" and friends: pops up over the waveform, rises and fades.
private struct Cheer: View {
    let word: String
    let color: Color
    @State private var popped = false
    @State private var risen = false
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(word)
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.7), radius: 5, y: 2)
            .fixedSize()
            .scaleEffect(popped || reduceMotion ? 1 : 0.8)
            .offset(y: risen && !reduceMotion ? -60 : 0)
            .opacity(faded ? 0 : 1)
            .onAppear {
                withAnimation(.spring(duration: 0.25, bounce: 0.5)) { popped = true }
                withAnimation(.easeOut(duration: 0.9)) { risen = true }
                withAnimation(.easeIn(duration: 0.55).delay(0.3)) { faded = true }
            }
            .accessibilityLabel(word)
    }
}
