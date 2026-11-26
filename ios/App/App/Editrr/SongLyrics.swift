import SwiftUI
import AVFoundation

// A creatrr song's lyrics, timed once to the whole song from the song's page in creatrr. They're
// kept with the song (in the folder creatrr and editrr share), and every edit that uses the song
// brings them in already timed: the whole song, or just the words of the section that was added.

/// The words of a song, in song seconds (the song file's own time), and the look they had.
struct SongLyricsFile: Codable {
    var words: [LyricWord]
    var style: LyricStyle?
}

enum SongLyricsStore {
    private static func url(_ key: String) -> URL? {
        guard let folder = CreatrrLibrary.folder, !key.isEmpty else { return nil }
        let safe = String(key.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return folder.appendingPathComponent("lyrics", isDirectory: true).appendingPathComponent(safe + ".json")
    }

    static func load(_ key: String) -> SongLyricsFile? {
        guard let url = url(key), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SongLyricsFile.self, from: data),
              !file.words.isEmpty else { return nil }
        return file
    }

    /// Saves the song's words (no words: the song has none any more).
    static func save(_ key: String, words: [LyricWord], style: LyricStyle?) {
        guard let url = url(key) else { return }
        if words.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(SongLyricsFile(words: words, style: style)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The song's words between song times `from` and `to`, moved so `from` lands at timeline time
    /// `at`. Words that start outside the stretch are left out; one running past its end is cut there.
    static func words(_ key: String, from: Double = 0, to: Double = .infinity, at: Double) -> [LyricWord] {
        guard let file = load(key) else { return [] }
        let shift = at - from
        let last = to.isFinite ? to + shift : Double.infinity
        var placed: [LyricWord] = []
        for word in file.words where word.start >= from - 0.01 && word.start < to {
            var moved = word
            moved.start = max(0, word.start + shift)
            moved.end = min(word.end + shift, last)
            if moved.end <= moved.start { moved.end = moved.start + 0.1 }
            placed.append(moved)
        }
        if var final = placed.last {
            final.br = true
            placed[placed.count - 1] = final
        }
        return placed
    }
}

// MARK: - The song's lyrics page

/// Times a creatrr song's words to the whole song: type or paste them, let the phone listen for
/// them, then tap out the timing. Every change is kept with the song right away.
@Observable @MainActor
final class SongLyricsModel: LyricTapping {
    let key: String
    var name: String
    /// Getting the song ready (nil once it's ready).
    var loading: String? = "Getting the song from creatrr…"
    var problem: String?
    var notice: String?
    var lyrics: [LyricWord] = []
    var time: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var sound: SoundPrint?
    /// Progress while listening for the words (nil when not listening).
    var listening: String?
    var tapTiming = false
    var tapNext = 0
    /// Taps on the word being recorded (the one before `tapNext`): one a syllable.
    var tapSyllable = 0
    /// Playing back what was tapped to check it (taps don't record meanwhile).
    var tapChecking = false
    var canUndo: Bool { !history.isEmpty }
    /// After each save: how many words the song now has (for creatrr's song page).
    @ObservationIgnored var saved: ((Int) -> Void)?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var asset: AVURLAsset?
    @ObservationIgnored private var style: LyricStyle?
    @ObservationIgnored private var heard: [LyricWord] = []
    @ObservationIgnored private var history: [[LyricWord]] = []
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var tapBefore: [LyricWord]?
    @ObservationIgnored private var tapFirst = 0
    @ObservationIgnored private var tapFrom: Double = 0
    /// The playhead was dragged since the last tap: Play back plays from there, not the start.
    @ObservationIgnored private var tapPlayFromHere = false
    /// Something was changed by hand this go (a word's taps, a word moved): kept and saved even
    /// with no taps.
    @ObservationIgnored private var tapByHand = false
    @ObservationIgnored private var tapLastAt: Double = -1
    /// When the last pad tap landed (phone clock), to drop a bounce right after it.
    @ObservationIgnored private var tapLastPress: Double = 0
    /// Clean up has nudged the taps toward the singing (its button then takes it back).
    var tapCleaned = false
    /// Clean up is waiting on the AI to finish listening.
    var tapCleanBusy = false
    /// What Clean up did, or why it couldn't (shown on the tap screen).
    var tapCleanNote: String?
    @ObservationIgnored private var tapRaw: [LyricWord]?
    @ObservationIgnored private var cleanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanTried = false

    /// The longest a tapped word stays up before the next tap.
    static let tapLongest = 3.0

    init(key: String, name: String) {
        self.key = key
        self.name = name
        player.actionAtItemEnd = .pause
        _ = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing, self.isPlaying else { return }
                let seconds = now.seconds
                if seconds.isFinite { self.time = min(max(0, seconds), self.duration) }
                // It stopped at the end of the song.
                if self.player.rate == 0 && self.time >= self.duration - 0.05 { self.isPlaying = false }
            }
        }
    }

    /// Finds the song (creatrr shares its songs as this opens, so give it a moment), then its
    /// words and its waveform.
    func load() async {
        var found: CreatrrSong?
        for attempt in 0..<120 {
            if let song = CreatrrLibrary.songs().first(where: { $0.key == key }) {
                found = song
                break
            }
            if attempt == 20 { loading = "Still getting the song from creatrr…" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let song = found, let url = CreatrrLibrary.audioURL(song) else {
            loading = nil
            problem = "Couldn't get this song from creatrr. Check it has a track, then try again."
            return
        }
        name = song.name
        let asset = AVURLAsset(url: url)
        self.asset = asset
        duration = (try? await asset.load(.duration).seconds) ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if let file = SongLyricsStore.load(key) {
            lyrics = file.words
            style = file.style
        }
        loading = nil
        // The waveform, read off the main thread.
        sound = await Task.detached(priority: .userInitiated) { try? await SoundReader.read(asset) }.value
    }

    // MARK: Playing

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        if time >= duration - 0.05 { seek(0) }
        isPlaying = true
        player.play()
    }

    func pause() {
        player.pause()
        isPlaying = false
        let now = player.currentTime().seconds
        if now.isFinite, player.currentItem != nil { time = min(max(0, now), duration) }
    }

    func seek(_ seconds: Double) {
        let at = min(max(0, seconds), max(0, duration))
        time = at
        player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginScrub() {
        if tapTiming && !tapChecking { tapPlayFromHere = true }
        if isPlaying { pause() }
        scrubbing = true
    }

    func scrub(to seconds: Double) { seek(seconds) }

    func endScrub() {
        scrubbing = false
        if tapTiming && !tapChecking { tapFromPlayhead() }
    }

    /// The playhead was dragged while tapping: the next tap times the first word at or after it.
    /// Words before it keep their taps; it and the ones after get tapped again as you go.
    private func tapFromPlayhead() {
        guard let i = lyrics.firstIndex(where: { $0.start >= time - 0.05 }) else { return }
        tapNext = i
        if i < tapFirst {
            tapFirst = i
            tapFrom = min(tapFrom, time)
        }
        tapSyllable = LyricTapGuard.wordDone
        tapLastAt = -1
    }

    func close() {
        if tapTiming { finishTapTiming(keep: true) }
        listenTask?.cancel()
        listenTask = nil
        cleanTask?.cancel()
        cleanTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Changing the words

    /// The word being sung at the playhead.
    var nowIndex: Int? {
        guard let index = lyrics.lastIndex(where: { $0.start <= time + 0.01 }) else { return nil }
        return time <= lyrics[index].end + 0.4 ? index : nil
    }

    private func change(_ words: [LyricWord]) {
        guard words != lyrics else { return }
        history.append(lyrics)
        if history.count > 30 { history.removeFirst() }
        lyrics = words
        save()
    }

    private func save() {
        SongLyricsStore.save(key, words: lyrics, style: style)
        saved?(lyrics.count)
    }

    func undo() {
        guard let last = history.popLast() else { return }
        pause()
        lyrics = last
        save()
        notice = "Took back the last change."
    }

    /// The words as text, one lyric line per line.
    var typedText: String { LyricText.typed(lyrics) }

    /// Typed or pasted words. Words that didn't change keep their times; new ones go between them.
    func setTyped(_ text: String) {
        let start = lyrics.first?.start ?? heard.first?.start ?? 0
        let typed = LyricText.words(fromTyped: text, start: start)
        var next: [LyricWord] = typed
        if typed.isEmpty {
            next = []
        } else if !lyrics.isEmpty {
            next = LyricText.retime(typed, to: lyrics).words
        } else if !heard.isEmpty {
            next = LyricText.retime(typed, to: heard).words
        }
        change(next)
        problem = nil
        if lyrics.isEmpty {
            notice = nil
        } else {
            notice = "Words saved. Listen lines them up with the singing, or tap out the timing."
        }
    }

    var canListen: Bool { asset != nil && LyricListener.isAvailable }

    /// Listens to the song for the words. Words already here keep their text and only take the
    /// times from what was heard.
    func listen() {
        guard listening == nil, let asset else { return }
        pause()
        problem = nil
        notice = nil
        listening = "Getting the song ready…"
        let report: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                guard let self, self.listening != nil else { return }
                self.listening = line
            }
        }
        listenTask = Task { [weak self] in
            do {
                let found = try await LyricListener.listen(to: asset, update: report)
                guard let self, !Task.isCancelled else { return }
                self.listening = nil
                self.listenTask = nil
                self.heard = found
                if self.lyrics.isEmpty {
                    self.change(found)
                    self.notice = "Heard \(self.lyrics.count) words. Fix any with Words, or tap out the timing."
                } else {
                    let result = LyricText.retime(self.lyrics, to: found)
                    self.change(result.words)
                    let total = result.words.count
                    self.notice = result.missing == 0
                        ? "Lined up all \(total) words with the singing."
                        : "Lined up \(total - result.missing) of \(total) words. Tap out the timing to fix the rest."
                }
            } catch {
                guard let self else { return }
                self.listening = nil
                self.listenTask = nil
                if !(error is CancellationError) && !Task.isCancelled {
                    self.problem = (error as? LocalizedError)?.errorDescription ?? "Couldn't listen to the song."
                }
            }
        }
    }

    func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        listening = nil
    }

    // MARK: Tapping out the timing (the same as in an edit)

    var lyricTapCount: Int { tapTiming ? max(0, tapNext - tapFirst) : 0 }

    /// Starts tapping from the word at the playhead (from the top when nothing's timed past it).
    func startTapping() {
        guard !lyrics.isEmpty, !tapTiming, listening == nil else { return }
        pause()
        tapBefore = lyrics
        let from = lyrics.firstIndex(where: { $0.start >= time - 0.05 }) ?? 0
        tapNext = min(max(0, from), lyrics.count - 1)
        tapFirst = tapNext
        tapSyllable = 0
        tapLastAt = -1
        tapChecking = false
        tapPlayFromHere = false
        tapByHand = false
        tapTiming = true
        forgetCleanUp()
        let at: Double = tapNext == 0 ? max(0, min(time, lyrics[0].start - 3)) : max(0, lyrics[tapNext].start - 3)
        tapFrom = at
        seek(at)
        notice = nil
        // The AI listens quietly meanwhile, so Clean up is ready when the tapping's done.
        hearForCleanUp()
    }

    func lyricTap() {
        guard tapTiming, !lyrics.isEmpty else { return }
        // A double tap by accident (even on Play) counts once.
        if LyricTapGuard.tooSoon(after: &tapLastPress) { return }
        if tapChecking {
            lyricTapCheck(false)
            return
        }
        guard isPlaying else {
            play()
            return
        }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        let at = min(max(0, now), duration)
        // Two taps closer than a couple of frames are one tap (both thumbs at once).
        if tapLastAt >= 0, abs(at - tapLastAt) < 0.06 { return }
        forgetCleanUp()
        tapPlayFromHere = false
        // A word of more than one syllable takes a tap for each: these stay on the same word.
        let current = tapNext - 1
        if current >= tapFirst, lyrics.indices.contains(current), tapSyllable < LyricSyllables.count(lyrics[current]) {
            tapSyllable += 1
            tapLastAt = at
            lyrics[current].end = max(lyrics[current].end, at + 0.25)
            return
        }
        guard lyrics.indices.contains(tapNext) else { return }
        let i = tapNext
        tapLastAt = at
        tapSyllable = 1
        let length = lyrics[i].end - lyrics[i].start
        lyrics[i].start = at
        lyrics[i].end = at + min(max(0.3, length), Self.tapLongest)
        if i > 0 {
            if i > tapFirst {
                lyrics[i - 1].end = max(lyrics[i - 1].start + 0.04, min(at, lyrics[i - 1].start + Self.tapLongest))
            } else if lyrics[i - 1].end > at {
                lyrics[i - 1].end = max(lyrics[i - 1].start + 0.04, at)
            }
        }
        tapNext = i + 1
    }

    func lyricTapBack() {
        guard tapTiming, tapNext > tapFirst, let before = tapBefore else { return }
        pause()
        tapChecking = false
        forgetCleanUp()
        tapNext -= 1
        let i = tapNext
        if before.indices.contains(i), lyrics.indices.contains(i) { lyrics[i] = before[i] }
        let from = i > tapFirst ? lyrics[i - 1].start : lyrics[i].start - 2
        seek(max(0, from - 1))
        tapSyllable = LyricTapGuard.wordDone
        tapLastAt = -1
    }

    /// Stop: the song stops where it is, every tap so far kept.
    func lyricTapStop() {
        guard tapTiming, !tapChecking else { return }
        pause()
        tapLastAt = -1
    }

    func lyricTapRestart() {
        guard tapTiming, let before = tapBefore else { return }
        pause()
        lyrics = before
        tapNext = tapFirst
        tapSyllable = 0
        tapLastAt = -1
        tapChecking = false
        tapPlayFromHere = false
        forgetCleanUp()
        seek(tapFrom)
    }

    /// Play back: plays from where this go of tapping started, to check the words before Done.
    /// Off stops and goes back to just before the last tapped word, ready to tap on.
    func lyricTapCheck(_ on: Bool) {
        guard tapTiming else { return }
        pause()
        if on {
            tapChecking = true
            // From the start of this go, or from where the playhead was dragged to.
            seek(tapPlayFromHere ? time : tapFrom)
            tapPlayFromHere = false
            play()
            return
        }
        tapChecking = false
        let last = tapNext - 1
        let from = last >= tapFirst && lyrics.indices.contains(last) ? lyrics[last].start - 1 : tapFrom
        seek(max(0, from))
        tapSyllable = LyricTapGuard.wordDone
        tapLastAt = -1
    }

    /// How many taps a word takes (one a syllable): changed on the tap screen, kept with the word.
    func setSyllables(_ index: Int, _ count: Int) {
        guard lyrics.indices.contains(index) else { return }
        let value = min(6, max(1, count))
        lyrics[index].syl = value == LyricSyllables.guess(lyrics[index].text) ? nil : value
        if tapTiming { keepByHand(index, times: false) } else { save() }
    }

    /// A change made by hand while tapping (a word's taps, a word moved) stays whatever happens to
    /// this go's taps after it: Previous, Start over, Undo clean up and Cancel don't take it back.
    private func keepByHand(_ i: Int, times: Bool) {
        guard lyrics.indices.contains(i) else { return }
        let word = lyrics[i]
        func apply(_ words: inout [LyricWord]?) {
            guard words?.indices.contains(i) == true else { return }
            words?[i].syl = word.syl
            if times {
                words?[i].start = word.start
                words?[i].end = word.end
            }
        }
        apply(&tapBefore)
        apply(&tapRaw)
        tapByHand = true
    }

    // MARK: Moving a word by hand

    /// The word being moved, as it was when the hold began, and all the words then (for Undo).
    @ObservationIgnored private var wordDrag: (index: Int, word: LyricWord, before: [LyricWord])?
    /// The word lifted to move it (drawn outlined).
    var movingWord: Int?

    /// Hold a word to lift it, then drag to move it. The song stops while it's moved.
    func beginWordDrag(_ index: Int) {
        guard lyrics.indices.contains(index), wordDrag == nil, !tapChecking else { return }
        pause()
        wordDrag = (index: index, word: lyrics[index], before: lyrics)
        movingWord = index
    }

    /// The finger has moved this many seconds since the hold. Words keep their order.
    func dragWord(by seconds: Double) {
        guard let drag = wordDrag, lyrics.indices.contains(drag.index) else { return }
        let i = drag.index
        let floor = i > 0 ? lyrics[i - 1].start + 0.03 : 0
        let ceiling = i + 1 < lyrics.count ? lyrics[i + 1].start - 0.03 : duration
        let length = drag.word.end - drag.word.start
        let begin = min(max(drag.word.start + seconds, floor), max(floor, ceiling))
        lyrics[i].start = begin
        lyrics[i].end = begin + length
    }

    func endWordDrag() {
        guard let drag = wordDrag else { return }
        wordDrag = nil
        movingWord = nil
        guard lyrics != drag.before else { return }
        if tapTiming {
            // While tapping: kept through the go's taps, and saved with them at Done.
            keepByHand(drag.index, times: true)
            return
        }
        let moved = lyrics
        lyrics = drag.before
        change(moved)
    }

    /// Done keeps the tapped times (Undo takes them all back); Cancel puts the words back.
    func finishTapTiming(keep: Bool) {
        pause()
        tapChecking = false
        guard tapTiming else { return }
        tapTiming = false
        let cleaned = tapCleaned
        forgetCleanUp()
        guard let before = tapBefore else { return }
        tapBefore = nil
        var timed = lyrics
        lyrics = before
        let byHand = tapByHand
        tapByHand = false
        guard keep, tapNext > tapFirst else {
            if byHand { save() }
            return
        }
        // The last tapped word ends before the next untapped one starts.
        let last = tapNext - 1
        if timed.indices.contains(last), timed.indices.contains(last + 1), timed[last].end > timed[last + 1].start {
            if timed[last + 1].start > timed[last].start + 0.04 {
                timed[last].end = timed[last + 1].start
            } else {
                let length = min(max(0.3, timed[last + 1].end - timed[last + 1].start), Self.tapLongest)
                timed[last + 1].start = timed[last].end
                timed[last + 1].end = timed[last + 1].start + length
            }
        }
        let count = tapNext - tapFirst
        change(timed)
        let words = count == 1 ? "Timed 1 word" : "Timed \(count) words"
        notice = cleaned ? words + ", cleaned up to the singing." : words + "."
    }

    // MARK: Clean up (the AI nudges the taps toward the singing)

    /// Clean up: moves this go's tapped words toward where the AI heard them sung, never more than
    /// a second either way. Tapped again, it puts the taps back as they were.
    func lyricTapCleanUp() {
        guard tapTiming, tapNext > tapFirst else { return }
        if tapCleaned, let raw = tapRaw {
            lyrics = raw
            forgetCleanUp()
            return
        }
        guard !heard.isEmpty else {
            if !canListen {
                tapCleanNote = "Clean up needs the song's sound to listen to."
            } else if cleanTried && cleanTask == nil {
                tapCleanNote = "Couldn't hear the singing well enough to clean up."
            } else {
                tapCleanBusy = true
                tapCleanNote = "Listening to the singing…"
                hearForCleanUp()
            }
            return
        }
        guard let result = LyricText.cleanUp(lyrics, range: tapFirst..<tapNext, heard: heard) else {
            tapCleanNote = "Couldn't match enough words to the singing to clean up."
            return
        }
        tapRaw = lyrics
        lyrics = result.words
        tapCleaned = true
        tapCleanBusy = false
        tapCleanNote = result.moved == 0 ? "Already right on the singing." :
            (result.moved == 1 ? "Cleaned up 1 word." : "Cleaned up \(result.moved) words.")
    }

    /// Any tap, Back or Start over drops Clean up (the button's ready to clean the new taps).
    private func forgetCleanUp() {
        tapRaw = nil
        tapCleaned = false
        tapCleanBusy = false
        tapCleanNote = nil
    }

    /// Listens to the song in the background for Clean up (once; Listen fills it in too).
    private func hearForCleanUp() {
        guard cleanTask == nil, listenTask == nil, heard.isEmpty, !cleanTried, let asset, LyricListener.isAvailable else { return }
        let quiet: @Sendable (String) -> Void = { _ in }
        cleanTask = Task { [weak self] in
            let found: [LyricWord] = (try? await LyricListener.listen(to: asset, update: quiet)) ?? []
            guard let self, !Task.isCancelled else { return }
            self.cleanTask = nil
            self.cleanTried = true
            if !found.isEmpty, self.heard.isEmpty { self.heard = found }
            guard self.tapCleanBusy else { return }
            self.tapCleanBusy = false
            self.lyricTapCleanUp()
        }
    }
}

/// The song's lyrics page: shown full screen from a song's page in creatrr.
struct SongLyricsView: View {
    @State var model: SongLyricsModel
    let done: () -> Void
    @State private var typing = false

    var body: some View {
        ZStack {
            Tint.backdrop.ignoresSafeArea()
            if model.tapTiming {
                LyricTapScreen(model: model) {
                    SongLyricStrip(model: model)
                        .frame(height: SongLyricStrip.height)
                }
                .transition(.move(edge: .bottom))
            } else {
                page
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.tapTiming)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .sheet(isPresented: $typing) {
            SongWordsSheet(text: model.typedText) { text in model.setTyped(text) }
                .presentationDetents([.large])
                .frostedSheet()
        }
    }

    private var page: some View {
        VStack(spacing: 14) {
            header
            if let loading = model.loading {
                Spacer()
                ProgressView(loading)
                    .tint(.white)
                Spacer()
            } else {
                SongLyricStrip(model: model)
                    .frame(height: SongLyricStrip.height)
                    .padding(.horizontal, -12)
                SongLyricPreview(model: model)
                    .frame(maxHeight: .infinity)
                playRow
                messages
                actions
                Text("Every edit that uses this song gets these lyrics, already timed.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack {
            Button {
                model.close()
                done()
            } label: {
                Text("Done").font(.body.weight(.bold)).foregroundStyle(Tint.accent)
            }
            .frame(width: 70, alignment: .leading)
            Spacer()
            VStack(spacing: 2) {
                Text(model.name).font(.headline).lineLimit(1)
                Text("Lyrics for the whole song").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward").font(.body.weight(.semibold))
            }
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.3)
            .frame(width: 70, alignment: .trailing)
            .accessibilityLabel("Undo")
        }
        .buttonStyle(.plain)
        .frame(height: 48)
    }

    private var playRow: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Text(Self.clock(model.time) + " / " + Self.clock(model.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
    }

    @ViewBuilder private var messages: some View {
        if let listening = model.listening {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(listening).font(.subheadline)
                Spacer()
                Button("Stop") { model.stopListening() }.buttonStyle(.plain).foregroundStyle(Tint.bad)
            }
        } else if let problem = model.problem {
            Text(problem).font(.subheadline).foregroundStyle(Tint.bad)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let notice = model.notice {
            Text(notice).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        let busy = model.listening != nil
        let none = model.lyrics.isEmpty
        return HStack(spacing: 10) {
            tile("Words", icon: "text.alignleft", on: !busy) {
                model.pause()
                typing = true
            }
            tile(none ? "Listen for them" : "Line up", icon: "waveform", on: !busy && model.canListen) {
                model.listen()
            }
            tile("Tap the timing", icon: "hand.tap", on: !busy && !none) { model.startTapping() }
        }
    }

    private func tile(_ text: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(text).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(Tint.surface2, in: Rectangle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.35)
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0))
        let minutes = whole / 60
        let rest = whole % 60
        return "\(minutes):" + (rest < 10 ? "0" : "") + "\(rest)"
    }
}

/// The song's waveform with the words under it as blocks, moving past a playhead in the middle.
/// Drag to move through the song; hold a word, then drag, to move its timing by hand.
struct SongLyricStrip: View {
    let model: SongLyricsModel
    @State private var dragFrom: Double?

    static let height: CGFloat = 130
    static let pixelsPerSecond: Double = 70
    static let waveHeight: CGFloat = 56
    static let rowTop: CGFloat = waveHeight + 14
    static let rowHeight: CGFloat = 26

    /// The word under a point (on its own row), with a little slop for short words.
    private func word(at point: CGPoint, width: CGFloat) -> Int? {
        let y = point.y - Self.rowTop
        guard y >= 0 else { return nil }
        let row = min(1, Int(y / (Self.rowHeight + 4)))
        let middle = width / 2
        let pps = Self.pixelsPerSecond
        var best: (index: Int, distance: CGFloat)?
        for (index, word) in model.lyrics.enumerated() where index % 2 == row {
            let start = middle + CGFloat((word.start - model.time) * pps)
            let end = middle + CGFloat((word.end - model.time) * pps)
            guard point.x >= start - 8, point.x <= end + 8 else { continue }
            let distance = point.x < start ? start - point.x : (point.x > end ? point.x - end : 0)
            if distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    var body: some View {
        let time = model.time
        let words = model.lyrics
        let sound = model.sound
        let duration = model.duration
        let now = model.nowIndex
        let moving = model.movingWord
        let pps = Self.pixelsPerSecond
        return Canvas { context, size in
            let middle = size.width / 2
            func x(_ seconds: Double) -> CGFloat { middle + CGFloat((seconds - time) * pps) }
            let waveHeight: CGFloat = Self.waveHeight
            let band = CGRect(x: x(0), y: 6, width: CGFloat(duration * pps), height: waveHeight)
            context.fill(Path(band), with: .color(SongTint.color))
            if let sound {
                var path = Path()
                var px = max(band.minX, 0)
                let end = min(band.maxX, size.width)
                while px < end {
                    let at = time + Double(px - middle) / pps
                    let frame = Int((at - sound.start) * SoundPrint.rate)
                    if frame >= 0, frame < sound.loudness.count {
                        let h = max(1, CGFloat(sound.loudness[frame]) * (waveHeight - 6))
                        path.addRect(CGRect(x: px, y: band.midY - h / 2, width: 2, height: h))
                    }
                    px += 3
                }
                context.fill(path, with: .color(SongTint.wave))
            }
            let rowTop: CGFloat = Self.rowTop
            let rowHeight: CGFloat = Self.rowHeight
            for (index, word) in words.enumerated() {
                let startX = x(word.start)
                let endX = x(word.end)
                guard endX > -60, startX < size.width + 60 else { continue }
                let row = CGFloat(index % 2)
                let block = CGRect(x: startX, y: rowTop + row * (rowHeight + 4), width: max(4, endX - startX),
                                   height: rowHeight)
                let sung = now == index
                context.fill(Path(block), with: .color(sung ? Tint.accent : Color.white.opacity(0.16)))
                context.fill(Path(CGRect(x: block.minX, y: block.minY, width: min(3, block.width), height: block.height)),
                             with: .color(sung ? Color.black.opacity(0.35) : Tint.accent))
                context.drawLayer { inside in
                    inside.clip(to: Path(block.insetBy(dx: 1, dy: 0)))
                    inside.draw(Text(word.text).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(sung ? Color.black : Color.white),
                                at: CGPoint(x: block.minX + 6, y: block.midY), anchor: .leading)
                }
                if moving == index {
                    context.stroke(Path(block), with: .color(.white), lineWidth: 2)
                }
            }
            context.fill(Path(CGRect(x: middle - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
        }
        .background(Color.white.opacity(0.04))
        .overlay {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                LaneTouches(
                    lift: { point in
                        guard let index = word(at: point, width: width) else { return false }
                        model.beginWordDrag(index)
                        return model.movingWord != nil
                    },
                    liftMoved: { travel in model.dragWord(by: Double(travel) / Self.pixelsPerSecond) },
                    trimBegan: { _ in false },
                    dropped: { model.endWordDrag() },
                    swipeBegan: {
                        dragFrom = model.time
                        model.beginScrub()
                    },
                    swipeMoved: { travel in
                        model.scrub(to: (dragFrom ?? model.time) - Double(travel) / Self.pixelsPerSecond)
                    },
                    swipeEnded: {
                        dragFrom = nil
                        model.endScrub()
                    },
                    tapped: { _ in },
                    pinchBegan: {},
                    pinched: { _ in },
                    pinchEnded: {}
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel("The song and its words. Drag to move through the song. Hold a word, then drag, to move it.")
    }
}

/// The lyric line being sung, big, with the word being sung in yellow, and the next line under it.
struct SongLyricPreview: View {
    let model: SongLyricsModel

    var body: some View {
        let words = model.lyrics
        let lines = LyricTiming.lines(words)
        let now = model.nowIndex
        let atLine: Int = lineIndex(lines, now: now, words: words)
        VStack(spacing: 14) {
            if words.isEmpty {
                Text("No words yet. Tap Words to type or paste them, or let the phone listen for them.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            } else {
                if lines.indices.contains(atLine) {
                    line(lines[atLine], words: words, now: now)
                        .font(.system(size: 30, weight: .heavy))
                }
                if lines.indices.contains(atLine + 1) {
                    line(lines[atLine + 1], words: words, now: nil)
                        .font(.title3.weight(.semibold))
                        .opacity(0.45)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: now)
    }

    /// The line with the word being sung, or the next line coming up.
    private func lineIndex(_ lines: [[Int]], now: Int?, words: [LyricWord]) -> Int {
        if let now, let found = lines.firstIndex(where: { $0.contains(now) }) { return found }
        let time = model.time
        let next = words.firstIndex(where: { $0.start > time }) ?? max(0, words.count - 1)
        return lines.firstIndex(where: { $0.contains(next) }) ?? 0
    }

    private func line(_ indices: [Int], words: [LyricWord], now: Int?) -> Text {
        var text = Text("")
        for (n, index) in indices.enumerated() {
            let sung: Bool = index == now
            let past: Bool = now.map { index < $0 } ?? false
            let color: Color = sung ? Tint.accent : (past ? Color.white : Color.white.opacity(0.6))
            let word = Text(words[index].text).foregroundColor(color)
            text = n == 0 ? word : text + Text(" ") + word
        }
        return text
    }
}

/// Typing or pasting the song's words, one lyric line per line.
struct SongWordsSheet: View {
    @State var text: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text("The words").font(.headline)
                Spacer()
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .font(.body.weight(.bold))
                .foregroundStyle(Tint.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            Text("One lyric line per line. Words you keep keep their timing.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .font(.body)
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}
