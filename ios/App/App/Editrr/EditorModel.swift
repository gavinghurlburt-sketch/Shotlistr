import SwiftUI
import PhotosUI
import AVFoundation
import UIKit
import Photos

/// Lets an AVAsset ride along to background work.
private struct AssetBox: @unchecked Sendable { let asset: AVAsset }

/// One step Undo can take back: the cuts and where every clip sat.
private struct EditState: Equatable {
    struct Place: Equatable {
        var offset: Double
        var trimStart: Double
        var trimEnd: Double
        var sync: SyncState
        var alternatives: [Double]
        var keyframes: [Keyframe]
    }
    var cuts: [Cut]
    var places: [Place]
    var lyrics: [LyricWord] = []
    var lyricStyle = LyricStyle()
    var titles: [TitleClip] = []
    var overlays: [SavedOverlay] = []
    var trackKeys: [Keyframe] = []
    var splits: [Double] = []
    var order: [Int] = []

    /// Where the clips sit (what needs a full rebuild when it changes), as one list.
    var timing: [Double] {
        places.flatMap { [$0.offset, $0.trimStart, $0.trimEnd] }
            + overlays.flatMap { [$0.start, $0.length, $0.trimStart] }
            + order.map(Double.init)
    }
}

/// The editor: a song lane on top, your videos as layers under it, lined up to the song by
/// their sound. Tap a layer to cut to it at the playhead; only that layer shows.
/// Drag a clip to move just that clip (Move), or drag its edge to trim it (Trim).
@MainActor
@Observable
final class EditorModel {
    enum Stage { case setup, editing }
    /// What a finger on a clip does: move the whole clip (after a hold), or trim one edge.
    enum Grip: Equatable { case move, trimStart, trimEnd }

    // MARK: State the screen shows

    var stage: Stage = .setup
    /// What the finger on `dragging` is doing.
    var grip: Grip = .move
    /// Locked: clips stay where they are (no moving, trimming or nudging), so swiping and
    /// tapping can't knock anything out of sync. Starts locked once everything is lined up.
    var locked = true
    /// The most lanes a project can hold: videos and text lanes together.
    static let maxLayers = 10
    /// A video shown on its own for a look, without cutting to it (one tap on its number).
    var previewing: Int?
    /// The clip picked for nudging (and outlined).
    var selected: Int?
    /// What's being made: videos back to back, or performance videos synced to a song.
    enum Kind: String { case video, performance }
    var kind: Kind = .performance
    /// The kind picked on the new video sheet (nil until one is picked).
    var pendingKind: Kind?
    /// A performance's own page (every video on its lane, synced to the song). Off: the edit page.
    var performancePage = false
    /// The clip picked on the edit page: the performance (0), or a video (editing a video).
    var editPick: Int?
    /// While an end of the performance clip is dragged on the edit page: which end.
    var draggingRange: Grip?
    @ObservationIgnored private var dragStartRange: (start: Double, end: Double) = (0, 0)
    /// The edit page's eyes on the video and sound tracks: hide the picture or mute the sound while
    /// you watch (the export is unchanged).
    var videoHidden = false {
        didSet {
            guard videoHidden != oldValue else { return }
            lyricsLive.setVideoHidden(videoHidden)
            redraw()
        }
    }
    var soundMuted = false {
        didSet { player.isMuted = soundMuted }
    }
    /// Pictures and videos on top of the main video track, bottom first.
    var overlays: [SavedOverlay] = []
    /// Keyframes on the whole performance track (in timeline seconds): zoom and move over every
    /// video at once, under the overlays and words.
    var trackKeys: [Keyframe] = []
    /// Where the performance is split on the edit page (timeline seconds, sorted).
    var splits: [Double] = []
    /// Which piece of the split performance is picked (an index into `performancePieces`).
    var piecePick: Int?
    /// Editing a video: the order the videos play in, as places in `layers` (empty: as listed).
    /// New videos always go on the end of `layers`, so Undo can take them off again.
    var order: [Int] = []
    /// The most clips that can sit on the main track (added before or after a split).
    static let maxCutaways = 12
    /// The overlay picked on the edit page (its tools show, and the video moves it).
    var overlayPick: UUID?
    /// Each overlay's small picture, for the timeline.
    var overlayThumbs: [UUID: UIImage] = [:]
    static let maxOverlays = 4
    @ObservationIgnored private var overlayMedia: [UUID: OverlayMedia] = [:]
    @ObservationIgnored private let overlayBoard = OverlayBoard()
    /// An overlay being moved or trimmed on the timeline: which, which end, and how it was.
    var draggingOverlay: UUID?
    @ObservationIgnored private var overlayDragStart: (overlay: SavedOverlay, grip: Grip, state: EditState)?
    /// An overlay being moved or sized on the video, or masked: how things were before.
    @ObservationIgnored private var overlayEditStart: (overlay: SavedOverlay, state: EditState)?
    /// The Mask sheet is open: touches on the video move and size the mask, not the overlay.
    private(set) var maskEditing = false
    /// The mask as it was when the fingers went down.
    @ObservationIgnored private var maskMoveStart: OverlayMask?
    /// The Custom mask point last tapped or added (it can be removed).
    var maskPoint: Int?
    /// The clip a finger is dragging right now.
    var dragging: Int?
    /// The hand-off (an index into `cuts`) a finger is dragging right now.
    var draggingCut: Int?

    /// Where an export stands.
    enum ExportState: Equatable {
        case idle
        case working(Double)
        case saved(URL)
        case failed(String)
    }
    var exportState: ExportState = .idle
    /// The part of the timeline that gets exported (seconds). Whole song until In or Out is set.
    var inPoint: Double = 0
    var outPoint: Double = 0
    /// True once In or Out narrows the export to part of the song.
    var hasRange: Bool { inPoint > 0.0005 || outPoint < duration - 0.0005 }
    /// Playback goes round and round between In and Out (the whole song when they aren't set).
    var looping: Bool = UserDefaults.standard.object(forKey: "loopInOut") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(looping, forKey: "loopInOut")
            updateLoop()
        }
    }
    /// Where the loop starts and ends.
    var loopStart: Double { min(max(0, inPoint), duration) }
    /// The performance's own End (where the clips after it start).
    var performanceEnd: Double {
        let end = outPoint > inPoint + 0.05 ? min(outPoint, duration) : duration
        return max(loopStart + 1.0 / 30, end)
    }
    /// Where the video ends: the performance's End, plus any clips added after it.
    var loopEnd: Double { performanceEnd + tailLength }
    /// The clips after the performance, back to back from its End.
    var tailClips: [SavedOverlay] { kind == .performance ? overlays.filter(\.isTail) : [] }
    var tailLength: Double { tailClips.reduce(0) { $0 + $1.length } }
    /// The whole timeline: the song, or longer when clips after the performance run past it.
    var timelineEnd: Double { max(duration, loopEnd) }
    var busy: String?
    var problem: String?
    var notice: String?

    // Setup picks
    var songName: String?
    var noSong = false
    var pickedVideoCount = 0
    var canStart: Bool {
        guard let pendingKind, pickedVideoCount > 0, busy == nil else { return false }
        return pendingKind == .video || pendingSong != nil || noSong
    }

    // Saved projects
    var projects: [SavedProject] = []
    var projectThumbs: [UUID: UIImage] = [:]
    /// The name typed on the setup screen for the next project.
    var projectName = ""
    /// The project being edited; every change saves into it.
    var currentProject: SavedProject?

    // The timeline
    var soundtrack: Soundtrack?
    var layers: [Layer] = []
    var cuts: [Cut] = []
    var segments: [Segment] = []
    var duration: Double = 0
    var time: Double = 0
    var isPlaying = false
    var fps: Double = 0
    var pixelsPerSecond: Double = 40
    var canUndo: Bool { !history.isEmpty }

    // Lyrics (from Lyric Sync), in timeline seconds.
    var lyrics: [LyricWord] = []
    var lyricStyle = LyricStyle()
    /// What the speech model last heard, kept so "Re-time" can line typed words up without listening again.
    var lyricsHeard: [LyricWord] = []
    /// Progress while listening for words (nil when not listening).
    var listening: String?
    /// The lyrics timeline shows in place of the video timeline.
    var lyricTimeline = false
    /// The lyrics timeline's zoom (kept apart from the video timeline's).
    var lyricPixelsPerSecond: Double = 140
    /// The word being moved or stretched on the lyrics timeline.
    var lyricDrag: (index: Int, grip: Grip)?
    /// The word picked on the lyrics timeline.
    var lyricSelected: Int?
    /// The lyrics are picked on the video (tap the words): a drag on the video moves them.
    var lyricsPicked = false
    /// Where the words sit while a finger moves them (percent), nil otherwise.
    private(set) var lyricMoveSpot: CGPoint?
    @ObservationIgnored private var lyricMoveStart: CGPoint?
    /// The words' size while a corner handle or a pinch is resizing them (nil otherwise).
    private(set) var lyricSizeSpot: Double?
    @ObservationIgnored private var lyricSizeStart: Double?
    /// The word showing at the playhead (changes only when the word does, so the list stays light).
    var lyricNow: Int?
    /// Tap to time: hold for each word while the song plays.
    var tapTiming = false

    // Titles and other text, each on a text lane under the videos.
    var titles: [TitleClip] = []
    /// The text whose sheet is open.
    var titleEditing: UUID?
    /// The text clip a finger is moving or stretching on the timeline.
    var titleDrag: (id: UUID, grip: Grip)?
    /// How many text lanes there are (lanes stay packed: T1, T2, ...).
    var textLaneCount: Int { (titles.map(\.lane).max() ?? -1) + 1 }
    /// Every lane under the song: videos, then text.
    var laneCount: Int { layers.count + textLaneCount }
    /// The next word a hold will time.
    var tapNext = 0

    let player: AVPlayer = {
        let player = AVPlayer()
        // Don't pick caption tracks from the phone's accessibility settings.
        player.appliesMediaSelectionCriteriaAutomatically = false
        return player
    }()

    // MARK: Behind the scenes

    @ObservationIgnored private var pendingSong: AVAsset?
    @ObservationIgnored private var pendingSongSource: MediaSource?
    @ObservationIgnored private var pendingVideos: [PickedMedia] = []
    /// Takes recorded in editrr to the song, by their place in pendingVideos: where the song was
    /// when each started, so they line up without a search.
    @ObservationIgnored private var pendingHints: [Int: TakeHint] = [:]

    /// The song for Performance capture, once one is picked.
    var captureSong: (asset: AVAsset, length: Double)? {
        guard let pendingSong, let length = pendingSongLength else { return nil }
        return (pendingSong, length)
    }
    @ObservationIgnored private var pendingSongLength: Double?
    /// Recorded takes (they count toward the 10 videos).
    var capturedCount = 0
    /// The parts of a song picked from creatrr (Verse, Chorus...), for Record to jump to.
    @ObservationIgnored private(set) var captureParts: [CreatrrPart] = []
    /// The tempo of a song picked from creatrr, for Record's count-in and click.
    @ObservationIgnored private(set) var captureTempo: CaptureTempo?

    // MARK: Shoot

    /// Shoot's list of creatrr songs and parts is showing.
    var shootPicking = false
    /// Shoot's camera, once its song is ready.
    var shootPlan: ShootPlan?
    /// The song and part picked on Shoot's list, waiting for the list to close.
    @ObservationIgnored var shootChoice: (song: CreatrrSong, part: CreatrrPart?)?

    /// Shoot: gets the song ready, then opens the camera at the part.
    func shoot(_ song: CreatrrSong, part: CreatrrPart?) async {
        guard busy == nil else { return }
        resetNewVideos()
        projectName = ""
        pendingKind = .performance
        await chooseCreatrrSong(song)
        guard let ready = captureSong, problem == nil else {
            pendingKind = nil
            return
        }
        shootPlan = ShootPlan(song: ready.asset, length: ready.length, songName: song.name, partName: part?.name,
                              parts: song.parts, part: part?.id, tempo: song.tempo)
    }

    /// Shoot's takes make a new project, named for the song and part, lined up and open.
    func finishShoot(_ plan: ShootPlan, takes: [CapturedTake]) async {
        guard !takes.isEmpty else {
            pendingKind = nil
            return
        }
        addCaptured(takes)
        projectName = plan.partName.map { "\(plan.songName) · \($0)" } ?? plan.songName
        await start()
    }

    /// A section's red record button in creatrr: finds the song (creatrr shares its songs as editrr
    /// opens) and shoots that part.
    func shootFromCreatrr(_ request: EditrrShoot.Request) async {
        if stage == .editing { startOver() }
        guard busy == nil else { return }
        problem = nil
        busy = "Getting the song from creatrr…"
        var found: CreatrrSong?
        for attempt in 0..<40 {
            // creatrr shares its songs fresh as editrr opens: give it a moment to bring the tempo too.
            if let song = CreatrrLibrary.songs().first(where: { $0.key == request.key }) {
                found = song
                if song.bpm != nil || attempt >= 12 { break }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        busy = nil
        guard let song = found else {
            problem = "Couldn't get that song from creatrr. Check it has a track, then try again."
            return
        }
        var part: CreatrrPart?
        if let time = request.time,
           let near = song.parts.min(by: { abs($0.time - time) < abs($1.time - time) }),
           abs(near.time - time) < 0.5 {
            part = near
        }
        await shoot(song, part: part)
    }

    /// Uses a song from creatrr, with its parts.
    func chooseCreatrrSong(_ song: CreatrrSong) async {
        guard let url = CreatrrLibrary.audioURL(song) else {
            problem = "Couldn't open that song from creatrr. Open creatrr, then try again."
            return
        }
        await chooseSongFile(url)
        guard pendingSong != nil, problem == nil else { return }
        songName = song.name
        captureParts = song.parts
        captureTempo = song.tempo
    }

    /// A fresh start for New video: nothing picked or recorded yet.
    func resetNewVideos() {
        pendingVideos = []
        pendingHints = [:]
        pickedVideoCount = 0
        capturedCount = 0
        TakeStore.clear()
    }

    /// Adds takes recorded to the song. They go after any videos already picked, up to 10 in all.
    func addCaptured(_ takes: [CapturedTake]) {
        problem = nil
        var added = 0
        for take in takes where pendingVideos.count < 10 {
            pendingHints[pendingVideos.count] = take.hint
            pendingVideos.append(PickedMedia(asset: AVURLAsset(url: take.url), source: .file(take.url.path)))
            added += 1
        }
        capturedCount += added
        pickedVideoCount = pendingVideos.count
        if added < takes.count {
            problem = "10 videos is the most, so some takes are left out."
        }
    }
    /// Where the open project's videos and song come from (layers point in by `video`).
    @ObservationIgnored private var videoSources: [MediaSource] = []
    @ObservationIgnored private var songSource: MediaSource?
    /// No song: which video's sound plays.
    @ObservationIgnored private var soundVideo: Int?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// What Auto edit has seen of each video: one look per second (seconds into the video).
    @ObservationIgnored private var looks: [Int: [Int: Look]] = [:]
    @ObservationIgnored private var built: TimelineBuilder.Built?
    /// Where the clips after the performance started when the video was last built.
    @ObservationIgnored private var builtTail: [Double] = []
    @ObservationIgnored private var history: [EditState] = [] {
        // A new change (not an undo or redo) means there's nothing left to redo.
        didSet { if history.count > oldValue.count && !redoing && !future.isEmpty { future = [] } }
    }
    /// Steps Undo took back, newest last, for Redo.
    private var future: [EditState] = []
    @ObservationIgnored private var redoing = false
    var canRedo: Bool { !future.isEmpty }
    /// Each video's strip of small frames for the timeline, by video (copies share one).
    var filmstrips: [ObjectIdentifier: Filmstrip] = [:]
    @ObservationIgnored private var filmstripTask: Task<Void, Never>?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var dragStartState: EditState?
    @ObservationIgnored private var dragStartLayer: Layer?
    @ObservationIgnored private var dragStartCutTime: Double = 0
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loopObserver: Any?
    /// Loop off: this play started before Out, so it stops there.
    @ObservationIgnored private var stopAtOut = false
    /// The lyrics the player draws; updated in place, so changes show without rebuilding.
    @ObservationIgnored private let lyricsLive = LyricsOverlay()
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    /// Previewing a lyric look: the play-through, and where to go back to after.
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewHome: Double?
    @ObservationIgnored private var titleEditStart: EditState?
    @ObservationIgnored private var titleDragStart: (state: EditState?, clip: TitleClip)?
    @ObservationIgnored private var titleRedrawn = Date.distantPast
    @ObservationIgnored private var tapHeld: Int?
    @ObservationIgnored private var tapStarted = false
    @ObservationIgnored private var lyricDragStart: (state: EditState, word: LyricWord)?

    init() {
        player.actionAtItemEnd = .pause
        _ = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing, !self.seeking, self.isPlaying else { return }
                self.time = min(max(0, now.seconds), self.timelineEnd)
                self.updateLyricNow(at: self.time)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.fps = self.isPlaying ? RenderStats.shared.snapshot().fps : 0
            }
        }
        refreshProjects()
    }

    // MARK: Setup

    func chooseSongFile(_ url: URL) async {
        problem = nil
        busy = "Opening the song…"
        defer { busy = nil }
        do {
            let kept = try ClipStore.keepSong(url)
            let asset = AVURLAsset(url: kept)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw EditorError.noSound }
            pendingSong = asset
            captureParts = []
            captureTempo = nil
            pendingSongLength = try? await asset.load(.duration).seconds
            pendingSongSource = .file(kept.path)
            songName = url.deletingPathExtension().lastPathComponent
            noSong = false
        } catch {
            problem = "Couldn't open that song: \(EditorError.explain(error))"
        }
    }

    func chooseSongVideo(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        problem = nil
        busy = "Opening the video's sound…"
        defer { busy = nil }
        guard let picked = await PhotosLoader.load(items).first else {
            problem = "Couldn't open that video. Try another."
            return
        }
        let asset = picked.asset
        do {
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw EditorError.noSound }
            pendingSong = asset
            captureParts = []
            captureTempo = nil
            pendingSongLength = try? await asset.load(.duration).seconds
            pendingSongSource = picked.source
            songName = "Sound from a video"
            noSong = false
        } catch {
            problem = "That video has no sound to use as the song."
        }
    }

    func chooseNoSong() {
        pendingSong = nil
        captureParts = []
        captureTempo = nil
        pendingSongLength = nil
        pendingSongSource = nil
        songName = nil
        noSong = true
    }

    func chooseVideos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        // Each video needs a little room for its pictures and sound, more if it has to be copied.
        guard Disk.hasRoom(for: Int64(200 + 100 * min(items.count, 10)) * Disk.megabyte) else {
            problem = Disk.fullMessage
            return
        }
        problem = nil
        busy = items.count == 1 ? "Opening your video…" : "Opening \(items.count) videos…"
        defer { busy = nil }
        ClipStore.reset()
        // Recorded takes stay; picked videos are replaced.
        let kept = pendingVideos.indices.filter { pendingHints[$0] != nil }
        let keptVideos = kept.map { pendingVideos[$0] }
        let keptHints = kept.compactMap { pendingHints[$0] }
        let assets = await PhotosLoader.load(Array(items.prefix(10 - keptVideos.count)))
        pendingVideos = keptVideos + assets
        pendingHints = [:]
        for (index, hint) in keptHints.enumerated() { pendingHints[index] = hint }
        pickedVideoCount = pendingVideos.count
        let tried = min(items.count, 10 - keptVideos.count)
        if assets.count < tried {
            problem = "\(tried - assets.count) of those videos couldn't be opened, so they're left out."
        }
    }

    /// Reads every video, finds where each one sits in the song, and opens the editor.
    func start() async {
        guard canStart else { return }
        problem = nil
        notice = nil
        overlays = []
        trackKeys = []
        splits = []
        order = []
        piecePick = nil
        overlayMedia = [:]
        overlayThumbs = [:]
        busy = "Lining up your videos…"
        defer { busy = nil }

        // 1. The videos' picture details and thumbnails.
        var made: [Layer] = []
        var sources: [MediaSource] = []
        // Recorded takes: where the song was when each started, by layer.
        var hints: [Int: TakeHint] = [:]
        for (pickIndex, pick) in pendingVideos.enumerated() {
            if var layer = try? await Self.makeLayer(id: made.count, from: pick.asset) {
                layer.video = sources.count
                sources.append(pick.source)
                if let hint = pendingHints[pickIndex] { hints[made.count] = hint }
                made.append(layer)
            }
        }
        guard !made.isEmpty else {
            problem = "None of those videos could be read. Try picking them again."
            return
        }

        // 2. Every sound, read side by side.
        let editingVideo = pendingKind == .video
        let prints = await Self.readSounds(videos: made.map { $0.asset }, song: editingVideo ? nil : pendingSong)
        for index in made.indices { made[index].sound = prints[index] }

        // Editing a video: they play back to back, each with its own sound. No lining up.
        if editingVideo {
            kind = .video
            soundtrack = nil
            soundVideo = nil
            songName = nil
            videoSources = sources
            songSource = nil
            layers = made.map { layer in
                var layer = layer
                layer.sync = .manual
                return layer
            }
            cuts = []
            layOutSequence()
            inPoint = 0
            outPoint = duration
            enterEditor()
            locked = false   // nothing is synced, so nothing to protect
            createProject()
            if let name = currentProject?.name { notice = "Saved as \u{201C}\(name)\u{201D}. Every change saves." }
            return
        }

        // 3. The soundtrack and the sound everything lines up to.
        var track: Soundtrack?
        var reference: SoundPrint?
        var referenceLayer: Int?
        if let song = pendingSong {
            guard let audio = try? await song.loadTracks(withMediaType: .audio).first,
                  let range = try? await audio.load(.timeRange) else {
                problem = "Couldn't read the song's sound."
                return
            }
            reference = prints[-1]
            track = Soundtrack(asset: song, track: audio, trackStart: range.start.seconds,
                               length: range.duration.seconds, shift: -range.start.seconds,
                               sound: prints[-1], name: songName ?? "Song")
        } else if let first = made.firstIndex(where: { $0.sound != nil }) {
            referenceLayer = first
            reference = made[first].sound
        }

        // 4. Find where every video's sound sits in the reference, off the main thread.
        //    The reference is prepared once; videos are matched one after another to keep memory low.
        let sounds = made.map { $0.sound }
        let skip = referenceLayer
        let target = reference
        let known: [Int: TakeHint] = track == nil ? [:] : hints
        let found: (matches: [Int: SoundMatch], speeds: [Double]) = await Task.detached(priority: .userInitiated) {
            () -> (matches: [Int: SoundMatch], speeds: [Double]) in
            var speeds = Array(repeating: 1.0, count: sounds.count)
            guard let target else { return ([:], speeds) }
            // Two different ways of lining up: one compares the sound itself, the other where
            // new sounds start in each pitch band. Agreement makes a place solid. A video that
            // doesn't fit at normal speed is tried at the usual slow-mo and sped-up speeds.
            var direct: [SoundMatch?] = Array(repeating: nil, count: sounds.count)
            var heard = sounds
            do {
                let main = LineUp.prepare(target)
                let second = FluxLineUp.prepare(target)
                for (layerIndex, sound) in sounds.enumerated() where layerIndex != skip {
                    guard let sound else { continue }
                    // A take recorded here already knows its speed; it's only matched at that speed.
                    if let hint = known[layerIndex] {
                        let heardAt = hint.speed != 1 ? sound.stretched(by: hint.speed) : sound
                        let primary = main.flatMap { LineUp.match(heardAt, to: $0) }
                        let backup = second.flatMap { FluxLineUp.scored(heardAt, to: $0) }
                        direct[layerIndex] = SoundMatch.combine(primary, backup?.lag)
                        speeds[layerIndex] = hint.speed
                        if hint.speed != 1 { heard[layerIndex] = heardAt }
                        continue
                    }
                    let best = TakeSpeed.best(sound, main: main, second: second, tryOthers: true)
                    direct[layerIndex] = best.match
                    speeds[layerIndex] = best.speed
                    if best.speed != 1 { heard[layerIndex] = sound.stretched(by: best.speed) }
                }
            }
            // Then the videos vote on each other's places, so one the song match got wrong is
            // pulled to where the others agree it goes (each at the speed it plays at).
            if heard.compactMap({ $0 }).count >= 2 {
                let links = Consensus.links(heard)
                var voted = Consensus.vote(direct: direct, fixed: skip, links: links)
                for index in direct.indices where voted[index] == nil || known[index] != nil {
                    voted[index] = direct[index]
                }
                return (voted, speeds)
            }
            var placed: [Int: SoundMatch] = [:]
            for (index, match) in direct.enumerated() { placed[index] = match }
            return (placed, speeds)
        }.value
        var matches = found.matches

        // Takes shot to a faster or slower song play slowed down or sped up, so the singing
        // lines up with the song again.
        var changedSpeed = 0
        for index in made.indices where index < found.speeds.count && found.speeds[index] != 1 {
            if let changed = await Self.withSpeed(made[index], found.speeds[index]) {
                made[index] = changed
                changedSpeed += 1
            } else {
                // Its place was found at the other speed, so it doesn't hold at normal speed.
                matches[index] = nil
            }
        }

        // 5. Where each video sits, in "reference time" (seconds from the reference's first sound).
        var places: [Double] = []
        var otherPlaces: [[Double]] = Array(repeating: [], count: made.count)
        for layer in made {
            var place = 0.0
            if layer.id == referenceLayer, let sound = layer.sound {
                place = layer.trackStart - sound.start
                made[layer.id].sync = .reference
            } else if track != nil, let hint = hints[layer.id] {
                // Recorded here: the place is known. The song in its sound fine-tunes it (only a
                // spot close to the known one counts, so a repeated chorus can't move it).
                // Song time counts from the song's first sound, like every place here.
                let knownPlace = hint.songTime - (track?.trackStart ?? 0)
                place = knownPlace
                if let sound = layer.sound, let match = matches[layer.id] {
                    let lead = layer.trackStart - sound.start
                    let spots = ([match.lag] + match.others).map { $0 + lead }
                    if let near = spots.min(by: { abs($0 - knownPlace) < abs($1 - knownPlace) }),
                       abs(near - knownPlace) <= 0.35 {
                        place = near
                    }
                }
                made[layer.id].sync = .matched
            } else if let sound = layer.sound, reference != nil {
                if var match = matches[layer.id] {
                    // With a song, the song comes first: a take placed well before it is
                    // moved to another likely spot that isn't (or marked to check).
                    if track != nil { match = SongFirst.fix(match, start: layer.trackStart - sound.start) }
                    // The video's first sound frame sits at match.lag; its first picture frame
                    // is (trackStart - sound.start) later than that. Always the best guess, even
                    // when the evidence is thin.
                    place = match.lag + (layer.trackStart - sound.start)
                    otherPlaces[layer.id] = match.others.map { $0 + (layer.trackStart - sound.start) }
                    made[layer.id].sync = match.sure ? .matched : .unsure
                } else {
                    made[layer.id].sync = .unsure
                }
            } else {
                made[layer.id].sync = .noSound
            }
            places.append(place)
        }

        // 6. Lay them out. With a song, the song starts at 0. Without, the earliest video does.
        if let track {
            for index in made.indices {
                made[index].offset = places[index]
                made[index].alternatives = otherPlaces[index]
            }
            duration = track.length
            soundtrack = track
        } else {
            let earliest = places.min() ?? 0
            for index in made.indices {
                made[index].offset = places[index] - earliest
                made[index].alternatives = otherPlaces[index].map { $0 - earliest }
            }
            duration = made.map { $0.offset + $0.length }.max() ?? 0
            if let referenceLayer, let audio = try? await made[referenceLayer].asset.loadTracks(withMediaType: .audio).first,
               let range = try? await audio.load(.timeRange) {
                let ref = made[referenceLayer]
                // Its sound plays in step with its picture.
                soundtrack = Soundtrack(asset: ref.asset, track: audio, trackStart: range.start.seconds,
                                        length: range.duration.seconds, shift: ref.offset - ref.trackStart,
                                        sound: ref.sound, name: "Sound of video \(referenceLayer + 1)")
            } else {
                soundtrack = nil
            }
        }

        soundVideo = (track == nil && soundtrack != nil) ? referenceLayer : nil
        videoSources = sources
        songSource = track == nil ? nil : pendingSongSource
        layers = made
        cuts = [Cut(time: 0, layer: made.first(where: { $0.footage(in: duration)?.contains(0) == true })?.id ?? 0)]
        inPoint = 0
        outPoint = duration
        kind = .performance
        enterEditor()
        performancePage = true   // a new performance starts on its own page, to sync and cut
        createProject()

        let unsure = made.filter { $0.sync == .unsure }.count
        let silent = made.filter { $0.sync == .noSound }.count
        var notes: [String] = []
        if unsure > 0 {
            notes.append(unsure == 1 ? "1 video might be a little off. It's marked Check sync."
                                     : "\(unsure) videos might be a little off. They're marked Check sync.")
        }
        let twins = made.filter { !$0.alternatives.isEmpty }.count
        if twins > 0 {
            notes.append(twins == 1 ? "1 video also fits another spot. Tap its dashed outline to move it there."
                                    : "\(twins) videos also fit other spots. Tap a dashed outline to move one there.")
        }
        if silent > 0 {
            notes.append(silent == 1 ? "1 video has no sound, so it starts at 0."
                                     : "\(silent) videos have no sound, so they start at 0.")
        }
        if changedSpeed > 0 {
            notes.append(changedSpeed == 1 ? "1 video was shot to the song at another speed, so it plays slowed down or sped up to match."
                                           : "\(changedSpeed) videos were shot to the song at another speed, so they play slowed down or sped up to match.")
        }
        if let name = currentProject?.name {
            notes.insert("Saved as \u{201C}\(name)\u{201D}. Every change saves.", at: 0)
        }
        if !notes.isEmpty { notice = notes.joined(separator: " ") }
    }

    /// Fresh editor state for the layers, cuts and In/Out just set.
    private func enterEditor() {
        history = []
        future = []
        // A project opens at its In point (a new one at the start).
        time = min(max(0, inPoint), duration)
        pixelsPerSecond = 40
        grip = .move
        locked = true
        previewing = nil
        selected = nil
        editPick = nil
        draggingRange = nil
        performancePage = false
        videoHidden = false
        soundMuted = false
        overlayPick = nil
        draggingOverlay = nil
        dragging = nil
        draggingCut = nil
        draft = nil
        looks = [:]
        rebuildAll()
        stage = .editing
    }

    /// Every sound, read side by side. Index -1 is the song.
    private static func readSounds(videos: [AVAsset], song: AVAsset?) async -> [Int: SoundPrint] {
        let boxes = videos.map { AssetBox(asset: $0) }
        let songBox = song.map { AssetBox(asset: $0) }
        return await withTaskGroup(of: (Int, SoundPrint?).self) { group in
            for (index, box) in boxes.enumerated() {
                group.addTask { (index, try? await SoundReader.read(box.asset)) }
            }
            if let songBox {
                group.addTask { (-1, try? await SoundReader.read(songBox.asset)) }
            }
            var found: [Int: SoundPrint] = [:]
            for await (index, sound) in group { if let sound { found[index] = sound } }
            return found
        }
    }

    // MARK: Auto edit

    /// The last Auto edit's settings, so Shuffle can make another cut the same way. Nil until
    /// Auto edit has run in this project.
    var lastAuto: (style: AutoStyle, plan: FXPlan, understood: String?)?
    var canShuffle: Bool { lastAuto != nil && kind == .performance }

    /// Shuffle: a fresh cut from the same clips, made the way the last Auto edit was.
    func shuffleEdit() async {
        guard let last = lastAuto else { return }
        await autoEdit(pace: last.style.pace, shuffle: true)
    }

    /// Cuts between In and Out on the beat, to whichever video looks best at each moment.
    /// `shuffle`: the last Auto edit's settings with some luck, for a different cut. `recipe`:
    /// a starter recipe's settings instead of the pace alone.
    /// `tapped`: cut at these times (from Tap the beat) instead of finding the cuts.
    func autoEdit(pace: AutoPace, request: String = "", shuffle: Bool = false, recipe: AutoStyle? = nil,
                  tapped: [Double]? = nil) async {
        guard busy == nil, !layers.isEmpty, duration > 0 else { return }
        pause()
        notice = nil
        problem = nil
        busy = "Watching your videos…"
        defer { busy = nil }

        let from = min(max(0, inPoint), duration)
        let to = outPoint > from ? min(outPoint, duration) : duration
        let clips = layers.compactMap { layer -> AutoEditor.Clip? in
            let start = max(from, layer.clipStart), end = min(to, layer.clipEnd)
            guard end - start > 0.05 else { return nil }
            return AutoEditor.Clip(layer: layer.id, video: layer.video, offset: layer.offset, start: start, end: end)
        }
        guard !clips.isEmpty else {
            notice = "There's no video between Start and End to edit."
            return
        }

        // 0. A typed request, read by Apple's on-device model.
        var style = recipe ?? AutoStyle(pace: pace)
        var plan = FXPlan()
        var recut = true
        var understood: String?
        let typed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let shuffling = shuffle && lastAuto != nil
        if shuffling, let last = lastAuto {
            style = last.style
            plan = last.plan
            understood = last.understood
        } else if !typed.isEmpty {
            busy = "Reading your request…"
            do {
                let looks = layers.map { ColorNamer.describe($0.thumbnail?.cgImage) }
                let reading = try await EditRequestReader.read(typed, pace: pace, videoCount: layers.count, looks: looks)
                style = reading.style
                plan = reading.fx
                recut = reading.recut
                let fxWords = EditRequestReader.describe(plan)
                understood = recut
                    ? [EditRequestReader.describe(style), fxWords].compactMap { $0 }.joined(separator: ", ")
                    : fxWords
            } catch {
                busy = nil
                problem = "Couldn't read that request: \(error.localizedDescription) Nothing changed."
                return
            }
            busy = "Watching your videos…"
        }

        // Only effects asked for: they go on the cuts already there, which stay as they are.
        if !recut {
            busy = "Adding effects…"
            var next = cuts
            let count = plan.apply(to: &next, from: from, until: to, duration: duration, loud: loudTest(from: from, to: to))
            guard count > 0, next != cuts else {
                notice = "There are no cuts \(hasRange ? "between Start and End " : "")to add that to yet. Nothing changed."
                return
            }
            history.append(snapshot())
            cuts = next
            previewing = nil
            redraw()
            notice = "Added \(understood ?? "effects"). Your cuts stayed as they were (\(count) changed). Undo takes it back."
            return
        }

        // Kept for Shuffle (without its luck), then a new roll when shuffling. (Tapped cuts are
        // yours, so Shuffle keeps to the last Auto edit.)
        if tapped == nil { lastAuto = (style, plan, understood) }
        if shuffling { style.shuffle = UInt64.random(in: 1...UInt64.max) }

        // 1. One look a second at every clip (only what hasn't been looked at yet), 3 at a time.
        var wanted: [Int: Set<Int>] = [:]
        for clip in clips {
            let layer = layers[clip.layer]
            let first = max(0, Int((clip.start - clip.offset).rounded(.down)))
            let last = min(Int(layer.length.rounded(.down)), Int((clip.end - clip.offset).rounded(.up)))
            guard last >= first else { continue }
            for second in first...last where looks[clip.video]?[second] == nil {
                wanted[clip.video, default: []].insert(second)
            }
        }
        var jobs: [WatchJob] = []
        for (video, seconds) in wanted {
            guard let layer = layers.first(where: { $0.video == video }) else { continue }
            let sorted = seconds.sorted()
            for chunk in stride(from: 0, to: sorted.count, by: 15) {
                jobs.append(WatchJob(asset: layer.asset, trackStart: layer.trackStart, video: video,
                                     seconds: Array(sorted[chunk..<min(chunk + 15, sorted.count)])))
            }
        }
        if !jobs.isEmpty {
            let total = jobs.count
            var results: [(Int, [Int: Look])] = []
            await withTaskGroup(of: (Int, [Int: Look]).self) { group in
                var next = 0
                while next < min(3, total) {
                    let job = jobs[next]
                    group.addTask { (job.video, await ClipWatcher.watch(job)) }
                    next += 1
                }
                while let result = await group.next() {
                    results.append(result)
                    busy = "Watching your videos… \(results.count * 100 / total)%"
                    if next < total {
                        let job = jobs[next]
                        group.addTask { (job.video, await ClipWatcher.watch(job)) }
                        next += 1
                    }
                }
            }
            for (video, found) in results { looks[video, default: [:]].merge(found) { $1 } }
        }

        // 2. The beat, and which parts of the song are loud.
        busy = "Finding the beat…"
        var beats: [Double] = []
        var barPhase = 0
        if let track = soundtrack, let sound = track.sound {
            let shift = track.shift
            if let found = await Task.detached(priority: .userInitiated, operation: { Beats.find(sound) }).value {
                beats = found.times.map { $0 + shift }
                barPhase = found.barPhase
            }
        }
        let loud = loudTest(from: from, to: to)

        // 3. Where to cut, and which video for each stretch. Tapped cuts land on the nearest beat
        // when one is close (a tap is usually a hair late), each on a whole frame.
        let times: [Double]
        if let tapped {
            var kept = [from]
            for tap in tapped.sorted() {
                var at = tap - 0.05
                if let near = beats.min(by: { abs($0 - tap) < abs($1 - tap) }), abs(near - tap) < 0.15 { at = near }
                at = (at * 30).rounded() / 30
                if at > (kept.last ?? from) + 0.25, at < to - 0.25 { kept.append(at) }
            }
            times = kept
        } else {
            times = AutoEditor.cutTimes(from: from, to: to, beats: beats, barPhase: barPhase, style: style, loud: loud)
        }
        let picks = AutoEditor.pick(times: times, to: to, clips: clips, looks: looks, style: style)

        // 4. Swap the new cuts in between In and Out; outside stays as it was.
        let showingAtEnd = cuts.last(where: { $0.time <= to + 1e-6 })?.layer
        var next = cuts.filter { $0.time < from - 1e-6 }
        for (time, layer) in zip(times, picks) { next.append(Cut(time: time, layer: layer)) }
        if to < duration - 0.01, let showingAtEnd { next.append(Cut(time: to, layer: showingAtEnd)) }
        next.append(contentsOf: cuts.filter { $0.time > to + 1e-6 })
        var cleaned: [Cut] = []
        for cut in next where cleaned.last?.layer != cut.layer { cleaned.append(cut) }
        if let first = cleaned.first, first.time > 0 { cleaned.insert(Cut(time: 0, layer: first.layer), at: 0) }
        let touched = plan.apply(to: &cleaned, from: from, until: to, duration: duration, loud: loud)

        history.append(snapshot())
        cuts = cleaned
        previewing = nil
        selected = nil
        redraw()
        let count = cleaned.filter { $0.time >= from - 1e-6 && $0.time < to - 1e-6 }.count
        let made = beats.isEmpty
            ? "Auto edit made \(count) cuts (no beat found, so evenly spaced). Undo takes it back."
            : "Auto edit made \(count) cuts on the beat. Undo takes it back."
        let effects = touched > 0 ? " Effects are on \(touched) of them." : ""
        if shuffling {
            notice = "Shuffled: a fresh cut with \(count) cuts. Shuffle again for another, or Undo to go back."
        } else if tapped != nil {
            notice = "Your taps made \(count) cuts, each to the best-looking take. Undo takes it back."
        } else {
            notice = understood.map { "Went with \($0). " + made + effects } ?? made + effects
        }
    }

    // MARK: Tap the beat

    /// Tap the beat is open: the song plays from Start and each tap drops a cut.
    var tapBeatOn = false
    /// The taps so far (timeline seconds).
    var beatTaps: [Double] = []

    func openTapBeat() {
        guard kind == .performance, busy == nil, !layers.isEmpty else { return }
        pause()
        beatTaps = []
        tapBeatOn = true
        notice = nil
    }

    /// Plays from Start so you can tap along (again: starts over, taps cleared).
    func startTapBeat() {
        beatTaps = []
        time = loopStart
        player.seek(to: CMTime(seconds: loopStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        play()
    }

    /// One tap: a cut here. Only while playing, and only forward (not after it loops round).
    func tapBeat() {
        guard tapBeatOn, isPlaying else { return }
        let now = player.currentTime().seconds
        guard now.isFinite, now > loopStart + 0.2, now < loopEnd - 0.2,
              now > (beatTaps.last ?? -1) + 0.15 else { return }
        beatTaps.append(now)
    }

    /// Done: the taps become cuts, each to the best-looking take. Cancel leaves the cuts alone.
    func finishTapBeat(keep: Bool) async {
        pause()
        tapBeatOn = false
        let taps = beatTaps
        beatTaps = []
        guard keep, !taps.isEmpty else { return }
        await autoEdit(pace: .normal, tapped: taps)
    }

    /// A starter recipe: sets Start and End, turns the lyrics on for a lyric video, then runs
    /// Auto edit its way. Undo takes the cuts back.
    func applyRecipe(_ recipe: StarterRecipe) async {
        guard busy == nil, kind == .performance, !layers.isEmpty, duration > 0 else { return }
        pause()
        switch recipe {
        case .performanceCut:
            inPoint = 0
            outPoint = duration
        case .lyricVideo:
            guard hasLyrics else {
                notice = "Add your lyrics first: tap Lyrics on the left, then try Lyric video again."
                return
            }
            inPoint = 0
            outPoint = duration
            if !lyricStyle.show { toggleLyricsShown() }
        case .teaser:
            let length = min(15, duration)
            let start = loudestStretch(seconds: length)
            inPoint = start
            outPoint = min(duration, start + length)
        }
        updateLoop()
        scheduleSave()
        time = loopStart
        requestSeek(time)
        let was = cuts
        await autoEdit(pace: recipe.style.pace, recipe: recipe.style)
        if problem == nil, cuts != was {
            notice = "\(recipe.name) is ready. Shuffle for another version, or Undo to go back."
        }
    }

    /// Where the loudest stretch of the song this long starts (timeline seconds, on a whole frame):
    /// usually the chorus or the drop. The start when there's no song to listen to.
    private func loudestStretch(seconds length: Double) -> Double {
        let latest = max(0, duration - length)
        guard latest > 0, let track = soundtrack, let sound = track.sound, !sound.loudness.isEmpty else { return 0 }
        let rate = SoundPrint.rate
        let zero = sound.start + track.shift          // timeline time of the first loudness value
        var running = [Double](repeating: 0, count: sound.loudness.count + 1)
        for index in sound.loudness.indices { running[index + 1] = running[index] + Double(sound.loudness[index]) }
        func total(from start: Double) -> Double {
            let a = min(max(0, Int(((start - zero) * rate).rounded())), sound.loudness.count)
            let b = min(max(0, Int(((start + length - zero) * rate).rounded())), sound.loudness.count)
            return running[b] - running[a]
        }
        var best = 0.0, bestTotal = -1.0
        var at = 0.0
        while at <= latest + 0.001 {
            let here = total(from: at)
            if here > bestTotal {
                bestTotal = here
                best = at
            }
            at += 0.5
        }
        return (min(best, latest) * 30).rounded() / 30
    }

    /// Whether a moment is in a loud part of the song (the chorus, a drop), judged against the
    /// stretch between `from` and `to`: the loudest third counts as loud.
    private func loudTest(from: Double, to: Double) -> (Double) -> Bool {
        guard let track = soundtrack, let sound = track.sound else { return { _ in false } }
        let shift = track.shift
        let loudness = sound.loudness
        guard loudness.count > 400, to > from else { return { _ in false } }
        var running = [Double](repeating: 0, count: loudness.count + 1)
        for index in loudness.indices { running[index + 1] = running[index] + Double(loudness[index]) }
        let sums = running
        let zero = sound.start + shift
        // Average loudness over 4 seconds around a moment.
        let level: (Double) -> Double = { time in
            let center = Int((time - zero) * SoundPrint.rate)
            let a = max(0, min(loudness.count, center - 200)), b = max(0, min(loudness.count, center + 200))
            return b > a ? (sums[b] - sums[a]) / Double(b - a) : 0
        }
        var levels: [Double] = []
        var at = from
        while at < to {
            levels.append(level(at))
            at += 0.5
        }
        levels.sort()
        guard !levels.isEmpty else { return { _ in false } }
        let bar = levels[min(levels.count - 1, Int(Double(levels.count) * 0.65))]
        return { level($0) > bar }
    }

    // MARK: Saved projects

    func refreshProjects() {
        projects = ProjectStore.list()
        var thumbs: [UUID: UIImage] = [:]
        for project in projects { thumbs[project.id] = ProjectStore.thumbnail(for: project.id) }
        projectThumbs = thumbs
    }

    /// Saves what was just lined up as a new named project.
    private func createProject() {
        let id = UUID()
        let typed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (songName == nil || songName == "Sound from a video") ? "Untitled" : songName!
        var name = typed.isEmpty ? fallback : typed
        let taken = Set(projects.map { $0.name })
        if taken.contains(name) {
            var number = 2
            while taken.contains("\(name) \(number)") { number += 1 }
            name = "\(name) \(number)"
        }
        videoSources = videoSources.map { ProjectStore.adopt($0, into: id) }
        songSource = songSource.map { ProjectStore.adopt($0, into: id) }
        overlays = overlays.map { overlay in
            var kept = overlay
            kept.source = ProjectStore.adopt(overlay.source, into: id)
            return kept
        }
        let now = Date()
        currentProject = SavedProject(id: id, name: name, created: now, updated: now, song: nil, songName: nil,
                                      videos: [], layers: [], cuts: [], duration: 0, inPoint: 0, outPoint: 0)
        if let thumbnail = layers.first?.thumbnail { ProjectStore.saveThumbnail(thumbnail, for: id) }
        projectName = ""
        saveNow(force: true)
    }

    /// The open project as it stands now.
    private func savedState() -> SavedProject? {
        guard var project = currentProject else { return nil }
        project.song = songSource
        project.songName = songSource == nil ? nil : soundtrack?.name
        project.videos = videoSources
        project.layers = layers.map {
            SavedLayer(video: $0.video, offset: $0.offset, trimStart: $0.trimStart, trimEnd: $0.trimEnd,
                       sync: $0.sync, alternatives: $0.alternatives, keyframes: $0.keyframes, color: $0.color,
                       speed: abs($0.speed - 1) > 0.001 ? $0.speed : nil)
        }
        project.cuts = cuts
        project.duration = duration
        project.inPoint = inPoint
        project.outPoint = outPoint
        project.soundVideo = soundVideo
        project.soundShift = soundVideo == nil ? nil : soundtrack?.shift
        project.soundName = soundVideo == nil ? nil : soundtrack?.name
        project.lyrics = lyrics.isEmpty ? nil : lyrics
        project.lyricStyle = lyricStyle == LyricStyle() ? nil : lyricStyle
        project.lyricsHeard = lyricsHeard.isEmpty ? nil : lyricsHeard
        project.titles = titles.isEmpty ? nil : titles
        project.kind = kind.rawValue
        project.overlays = overlays.isEmpty ? nil : overlays
        project.trackKeys = trackKeys.isEmpty ? nil : trackKeys
        project.splits = splits.isEmpty ? nil : splits
        project.order = order.isEmpty ? nil : order
        return project
    }

    /// Saves a moment after the last change, so a burst of edits writes once.
    private func scheduleSave() {
        guard currentProject != nil, stage == .editing else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the open project now, if anything changed.
    func saveNow(force: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        guard let current = currentProject, var project = savedState() else { return }
        project.updated = current.updated
        guard force || project != current else { return }
        project.updated = Date()
        do {
            try ProjectStore.save(project)
            currentProject = project
        } catch {
            problem = "Couldn't save the project: \(EditorError.explain(error))"
        }
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var project = projects.first(where: { $0.id == id }) else { return }
        project.name = trimmed
        try? ProjectStore.save(project)
        if currentProject?.id == id { currentProject?.name = trimmed }
        refreshProjects()
    }

    func deleteProject(_ id: UUID) {
        guard currentProject?.id != id else { return }
        ProjectStore.delete(id)
        refreshProjects()
    }

    /// Opens a saved project just as it was left: no lining up again.
    func open(_ saved: SavedProject) async {
        guard busy == nil else { return }
        problem = nil
        notice = nil
        busy = "Opening \u{201C}\(saved.name)\u{201D}…"
        defer { busy = nil }
        await PhotoAccess.ask()

        // 1. The videos and the song, from Photos or the project's folder.
        var assets: [AVAsset] = []
        for source in saved.videos {
            guard let asset = await PhotosLoader.open(source, project: saved.id) else {
                problem = "One of the videos in \u{201C}\(saved.name)\u{201D} isn't in Photos anymore, so it can't open."
                return
            }
            assets.append(asset)
        }
        var songAsset: AVAsset?
        if let song = saved.song {
            guard let asset = await PhotosLoader.open(song, project: saved.id) else {
                problem = "The song for \u{201C}\(saved.name)\u{201D} is missing, so it can't open."
                return
            }
            songAsset = asset
        }

        // 2. Picture details, and the sounds for the waveforms.
        var bases: [Layer] = []
        for (index, asset) in assets.enumerated() {
            guard var layer = try? await Self.makeLayer(id: index, from: asset) else {
                problem = "One of the videos in \u{201C}\(saved.name)\u{201D} couldn't be read."
                return
            }
            layer.video = index
            bases.append(layer)
        }
        let prints = await Self.readSounds(videos: assets, song: songAsset)
        for index in bases.indices { bases[index].sound = prints[index] }

        // 3. Every layer where it was left.
        var made: [Layer] = []
        for place in saved.layers {
            guard bases.indices.contains(place.video) else {
                problem = "\u{201C}\(saved.name)\u{201D} couldn't be read."
                return
            }
            let base = bases[place.video]
            var layer = Layer(id: made.count, asset: base.asset, track: base.track,
                              trackStart: base.trackStart, length: base.length,
                              orientation: base.orientation, displaySize: base.displaySize,
                              fps: base.fps, thumbnail: base.thumbnail, sound: base.sound,
                              offset: place.offset, sync: place.sync,
                              trimStart: place.trimStart, trimEnd: place.trimEnd,
                              alternatives: place.alternatives, keyframes: place.keyframes,
                              video: place.video, color: place.color, audio: base.audio)
            // A take shot to a faster or slower song plays slowed down or sped up again.
            if let speed = place.speed, abs(speed - 1) > 0.001, let changed = await Self.withSpeed(layer, speed) {
                layer = changed
                layer.offset = place.offset
                layer.trimStart = place.trimStart
                layer.trimEnd = place.trimEnd
            }
            made.append(layer)
        }
        guard !made.isEmpty else {
            problem = "\u{201C}\(saved.name)\u{201D} has no videos."
            return
        }

        // 4. The soundtrack.
        if let songAsset {
            guard let audio = try? await songAsset.loadTracks(withMediaType: .audio).first,
                  let range = try? await audio.load(.timeRange) else {
                problem = "Couldn't read the song's sound."
                return
            }
            soundtrack = Soundtrack(asset: songAsset, track: audio, trackStart: range.start.seconds,
                                    length: range.duration.seconds, shift: -range.start.seconds,
                                    sound: prints[-1], name: saved.songName ?? "Song")
            duration = range.duration.seconds
        } else if let video = saved.soundVideo, assets.indices.contains(video),
                  let audio = try? await assets[video].loadTracks(withMediaType: .audio).first,
                  let range = try? await audio.load(.timeRange) {
            soundtrack = Soundtrack(asset: assets[video], track: audio, trackStart: range.start.seconds,
                                    length: range.duration.seconds, shift: saved.soundShift ?? 0,
                                    sound: bases[video].sound, name: saved.soundName ?? "Sound of video \(video + 1)")
            duration = saved.duration
        } else {
            soundtrack = nil
            duration = saved.duration
        }

        songName = saved.songName
        videoSources = saved.videos
        songSource = saved.song
        soundVideo = soundtrack != nil && songAsset == nil ? saved.soundVideo : nil
        layers = made
        let valid = saved.cuts.filter { made.indices.contains($0.layer) }
        cuts = valid.isEmpty ? [Cut(time: 0, layer: 0)] : valid
        inPoint = min(max(0, saved.inPoint), duration)
        outPoint = saved.outPoint > inPoint && saved.outPoint <= duration ? saved.outPoint : duration
        currentProject = saved
        lyrics = saved.lyrics ?? []
        lyricStyle = saved.lyricStyle ?? LyricStyle()
        lyricsHeard = saved.lyricsHeard ?? []
        resetLyricEditing()
        syncLyrics()
        titles = saved.titles ?? []
        resetTitleEditing()
        syncTitles()
        kind = Kind(rawValue: saved.kind ?? "") ?? .performance
        trackKeys = saved.trackKeys ?? []
        splits = saved.splits ?? []
        order = saved.order ?? []
        piecePick = nil
        // Overlays: any whose picture or video is gone is left out.
        overlayMedia = [:]
        overlayThumbs = [:]
        var kept: [SavedOverlay] = []
        for overlay in saved.overlays ?? [] {
            guard let media = await OverlayLoader.reopen(overlay, project: saved.id) else { continue }
            overlayMedia[overlay.id] = media
            overlayThumbs[overlay.id] = media.thumbnail
            kept.append(overlay)
        }
        overlays = kept
        enterEditor()
        if kind == .video { locked = false }
        notice = nil
    }

    func startOver() {
        saveNow()
        lastAuto = nil
        currentProject = nil
        refreshProjects()
        pause()
        player.replaceCurrentItem(with: nil)
        built = nil
        layers = []
        cuts = []
        segments = []
        soundtrack = nil
        duration = 0
        time = 0
        notice = nil
        problem = nil
        selected = nil
        editPick = nil
        draggingRange = nil
        performancePage = false
        overlays = []
        trackKeys = []
        splits = []
        order = []
        piecePick = nil
        overlayMedia = [:]
        overlayThumbs = [:]
        overlayPick = nil
        draggingOverlay = nil
        previewing = nil
        dragging = nil
        draggingCut = nil
        draft = nil
        inPoint = 0
        outPoint = 0
        cancelExport()
        history = []
        future = []
        dropFilmstrips()
        lyrics = []
        lyricStyle = LyricStyle()
        lyricsHeard = []
        resetLyricEditing()
        syncLyrics()
        titles = []
        resetTitleEditing()
        syncTitles()
        stage = .setup
    }

    /// The video played `speed` times longer (2: half speed, 0.5: double speed), as a new layer.
    /// The slowed or sped-up copy is a composition with the video's own times multiplied by
    /// `speed`, so everything that reads the layer (the timeline, its frames, its waveform) just
    /// works. Speed 1 gives the video back as it was shot. Nil if it can't be made.
    private static func withSpeed(_ layer: Layer, _ speed: Double) async -> Layer? {
        let source = layer.original ?? LayerSource(asset: layer.asset, track: layer.track, audio: layer.audio,
                                                   trackStart: layer.trackStart, length: layer.length,
                                                   sound: layer.sound)
        func made(asset: AVAsset, track: AVAssetTrack, audio: AVAssetTrack?, factor: Double,
                  original: LayerSource?) -> Layer {
            Layer(id: layer.id, asset: asset, track: track,
                  trackStart: source.trackStart * factor, length: source.length * factor,
                  orientation: layer.orientation, displaySize: layer.displaySize, fps: layer.fps,
                  thumbnail: layer.thumbnail, sound: source.sound?.stretched(by: factor),
                  offset: layer.offset, sync: layer.sync, trimStart: layer.trimStart * factor / layer.speed,
                  trimEnd: layer.trimEnd * factor / layer.speed, alternatives: layer.alternatives,
                  keyframes: layer.keyframes, video: layer.video, color: layer.color, audio: audio,
                  speed: factor, original: original)
        }
        guard abs(speed - 1) > 0.001 else {
            return made(asset: source.asset, track: source.track, audio: source.audio, factor: 1, original: nil)
        }
        let composition = AVMutableComposition()
        /// Puts a track in at the same times it has in the video (so time t becomes t × speed).
        func copy(_ track: AVAssetTrack, as type: AVMediaType) async -> AVMutableCompositionTrack? {
            guard let range = try? await track.load(.timeRange), range.isValid, range.duration.seconds > 0,
                  let into = composition.addMutableTrack(withMediaType: type,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            do {
                if range.start > .zero {
                    into.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: range.start))
                }
                try into.insertTimeRange(range, of: track, at: range.start)
                return into
            } catch {
                composition.removeTrack(into)
                return nil
            }
        }
        guard let video = await copy(source.track, as: .video) else { return nil }
        if let transform = try? await source.track.load(.preferredTransform) {
            video.preferredTransform = transform
        }
        var audio: AVMutableCompositionTrack?
        if let sound = source.audio { audio = await copy(sound, as: .audio) }
        let whole = CMTimeRange(start: .zero, duration: composition.duration)
        composition.scaleTimeRange(whole, toDuration: CMTimeMultiplyByFloat64(whole.duration, multiplier: speed))
        return made(asset: composition, track: video, audio: audio, factor: speed, original: source)
    }

    private static func makeLayer(id: Int, from asset: AVAsset) async throws -> Layer {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError.noVideo }
        let (size, transform, fps, range) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        guard range.isValid, range.duration.seconds > 0 else { throw EditorError.noVideo }
        let turn = TimelineBuilder.orientation(of: transform)
        let turned = (turn == .left || turn == .right)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)   // sharp enough for tall tracks
        let at = CMTime(seconds: min(1, range.duration.seconds / 2) + range.start.seconds, preferredTimescale: 600)
        let thumbnail = (try? await generator.image(at: at)).map { UIImage(cgImage: $0.image) }
        let audio = try? await asset.loadTracks(withMediaType: .audio).first

        return Layer(id: id, asset: asset, track: track,
                     trackStart: range.start.seconds, length: range.duration.seconds,
                     orientation: turn,
                     displaySize: turned ? CGSize(width: size.height, height: size.width) : size,
                     fps: fps, thumbnail: thumbnail, sound: nil, offset: 0, sync: .noSound, audio: audio)
    }

    // MARK: Cutting

    /// Which layer is on screen at the playhead (the previewed one while previewing).
    var showing: Int? {
        if let previewing { return previewing }
        return segments.first(where: { time >= $0.start && time < $0.end })?.layer ?? segments.last?.layer
    }

    func hasFootage(_ layer: Int, at seconds: Double) -> Bool {
        guard layers.indices.contains(layer), let range = layers[layer].footage(in: duration) else { return false }
        return range.contains(seconds)
    }

    /// One tap on a layer's number: show that video on its own for a look (tap again to stop).
    func preview(_ index: Int) {
        notice = nil
        if previewing == index {
            previewing = nil
        } else {
            previewing = index
            let at = isPlaying ? min(max(0, player.currentTime().seconds), duration) : time
            if !hasFootage(index, at: at) { notice = "Video \(index + 1) has nothing at this spot." }
        }
        refreshCuts()
    }

    /// Two taps on a layer's number: cut to it at the playhead. Near the start of a clip (within a
    /// finger's width on screen) it swaps that whole clip instead, so a zoomed-out double tap never
    /// leaves a sliver of a few frames behind. Zoomed right in, it cuts exactly where you are.
    func cut(to index: Int) {
        let at = isPlaying ? min(max(0, player.currentTime().seconds), duration) : time
        previewing = nil
        let frame = 1.0 / 30
        let reach = pixelsPerSecond >= 160 ? frame : max(frame, 18 / pixelsPerSecond)
        if let near = cuts.indices
            .filter({ abs(cuts[$0].time - at) <= reach })
            .min(by: { abs(cuts[$0].time - at) < abs(cuts[$1].time - at) }),
           hasFootage(index, at: min(duration, cuts[near].time + frame / 2)) {
            notice = nil
            guard cuts[near].layer != index else {
                refreshCuts()
                return
            }
            // Same cut, new video: it keeps its zoom, transition and effects.
            var next = cuts
            next[near].layer = index
            if abs(cuts[near].time - at) > frame { notice = "Swapped that whole clip for video \(index + 1)." }
            apply(next)
            return
        }
        guard hasFootage(index, at: at) else {
            notice = "Video \(index + 1) has nothing at this spot."
            return
        }
        notice = nil
        apply(cuts + [Cut(time: at < frame ? 0 : at, layer: index)])
    }

    // MARK: The edit page

    /// Back from the performance's own page to the edit page, where the performance (In to Out)
    /// is one clip.
    func showEditPage() {
        selected = nil
        editPick = nil
        if previewing != nil {
            previewing = nil
            refreshCuts()
        }
        performancePage = false
        keepInRange()
    }

    /// The performance's own page: every video on its lane, synced to the song.
    func showPerformancePage() {
        guard kind == .performance else { return }
        editPick = nil
        overlayPick = nil
        // The eyes are the edit page's: the performance page always shows and plays everything.
        videoHidden = false
        soundMuted = false
        performancePage = true
    }

    /// A tap on the edit page picks a clip (nil lets go).
    func pickOnEdit(_ index: Int?) {
        editPick = index
        // The performance picked as a whole: the piece the playhead is in.
        piecePick = index == 0 && kind == .performance ? pieceIndex(at: playheadFrame) : nil
        if index != nil {
            overlayPick = nil
            lyricsPicked = false
        }
        selected = nil
        notice = nil
    }

    /// A finger took hold of an end of the performance clip: it moves In or Out.
    func beginRangeDrag(_ end: Grip) {
        guard kind == .performance, end != .move else { return }
        pause()
        draggingRange = end
        dragStartRange = (loopStart, performanceEnd)
        notice = nil
    }

    private func moveRange(_ end: Grip, by seconds: Double) {
        let frames = { (value: Double) in (value * 30).rounded() / 30 }
        switch end {
        case .trimStart:
            inPoint = max(0, min(frames(dragStartRange.start + seconds), dragStartRange.end - 0.5))
        case .trimEnd:
            outPoint = min(duration, max(frames(dragStartRange.end + seconds), dragStartRange.start + 0.5))
        case .move:
            break
        }
        layOutTail()
    }

    /// Lines the clips after the performance up back to back from its End, in list order.
    private func layOutTail() {
        guard kind == .performance else { return }
        var at = performanceEnd
        for index in overlays.indices where overlays[index].isTail {
            if abs(overlays[index].start - at) > 0.0005 { overlays[index].start = at }
            at += overlays[index].length
        }
    }

    /// Keeps the playhead inside the clip (In to Out).
    private func keepInRange() {
        guard time < loopStart || time > loopEnd else { return }
        time = loopStart
        requestSeek(time)
    }

    // MARK: Split, and a clip before or after

    /// Where a new clip goes, next to the picked piece.
    enum ClipSide { case before, after }

    /// Editing a video: the order the videos play in (every video once).
    var playOrder: [Int] {
        var seen = Set<Int>()
        var list = order.filter { layers.indices.contains($0) && seen.insert($0).inserted }
        for index in layers.indices where !seen.contains(index) { list.append(index) }
        return list
    }

    /// The performance on the edit page, cut at its splits: In to the first split, and so on to Out.
    var performancePieces: [(start: Double, end: Double)] {
        let start = loopStart, end = performanceEnd
        let inside = splits.filter { $0 > start + 0.001 && $0 < end - 0.001 }.sorted()
        let marks = [start] + inside + [end]
        return zip(marks, marks.dropFirst()).map { (start: $0, end: $1) }
    }

    private func pieceIndex(at seconds: Double) -> Int? {
        let pieces = performancePieces
        if let index = pieces.firstIndex(where: { seconds >= $0.start - 0.001 && seconds < $0.end }) { return index }
        return pieces.isEmpty ? nil : pieces.count - 1
    }

    /// The picked piece of the performance (the whole clip when it isn't split).
    var pickedPiece: (start: Double, end: Double)? {
        guard kind == .performance, !performancePage, editPick == 0, overlayPick == nil else { return nil }
        let pieces = performancePieces
        if let piecePick, pieces.indices.contains(piecePick) { return pieces[piecePick] }
        return pieces.count == 1 ? pieces[0] : nil
    }

    /// A tap on the performance on the edit page picks the piece under it (again lets go).
    func pickPiece(at seconds: Double) {
        let index = pieceIndex(at: seconds)
        if editPick == 0, piecePick == index {
            pickOnEdit(nil)
            return
        }
        pickOnEdit(0)
        piecePick = index
    }

    /// What a new clip goes next to: the picked clip on the main track, or the picked piece.
    private var clipAnchor: (start: Double, end: Double)? {
        if let id = overlayPick, let clip = overlay(id), clip.isCutaway { return (clip.start, clip.end) }
        return pickedPiece
    }

    /// Before and After can be used: something on the main track is picked and there's room for one more.
    var canAddClip: Bool {
        if kind == .video {
            guard let pick = editPick, layers.indices.contains(pick) else { return false }
            return laneCount < Self.maxLayers
        }
        return clipAnchor != nil && cutaways.count < Self.maxCutaways
    }

    /// The + at the end of the video track can add one more.
    var canAddToEnd: Bool {
        kind == .video ? laneCount < Self.maxLayers : cutaways.count < Self.maxCutaways
    }

    /// Split at the playhead: the picked overlay or clip there, else whatever is on the main track
    /// there, is cut in two.
    func splitHere() {
        pause()
        let at = playheadFrame
        let shortest = 0.1
        func inside(_ overlay: SavedOverlay) -> Bool {
            at > overlay.start + shortest && at < overlay.end - shortest
        }
        if let id = overlayPick, let index = overlays.firstIndex(where: { $0.id == id }) {
            guard inside(overlays[index]) else {
                notice = "Move the playhead inside it to split it there."
                return
            }
            splitOverlay(index, at: at)
            return
        }
        // A clip on the main track under the playhead (the top one), before the performance under it.
        if let index = overlays.lastIndex(where: { $0.isCutaway && !$0.hidden && inside($0) }) {
            splitOverlay(index, at: at)
            return
        }
        switch kind {
        case .performance:
            guard at > loopStart + shortest, at < performanceEnd - shortest else {
                notice = "Move the playhead inside the clip to split it there."
                return
            }
            guard !splits.contains(where: { abs($0 - at) < shortest }) else {
                notice = "It's already split there."
                return
            }
            history.append(snapshot())
            future = []
            splits.append(at)
            splits.sort()
            // The piece after the split is picked, ready for a clip before or after it.
            pickOnEdit(0)
            piecePick = pieceIndex(at: at)
            redraw()
            notice = "Split. Tap Before or After to add a clip there."
        case .video:
            guard let index = playOrder.first(where: {
                at > layers[$0].clipStart + shortest && at < layers[$0].clipEnd - shortest
            }) else {
                notice = "Move the playhead inside a clip to split it there."
                return
            }
            guard laneCount < Self.maxLayers else {
                notice = "\(Self.maxLayers) videos is the most, so it can't be split again."
                return
            }
            let before = snapshot()
            let original = layers[index]
            // Seconds into the video where it's cut.
            let cutAt = at - original.offset
            var second = copyOf(original)
            second.trimStart = cutAt
            layers[index].trimEnd = original.length - cutAt
            var list = playOrder
            let place = (list.firstIndex(of: index) ?? list.count - 1) + 1
            layers.append(second)
            list.insert(second.id, at: min(place, list.count))
            order = list
            history.append(before)
            future = []
            layOutSequence()
            pickOnEdit(second.id)
            rebuildAll()
            makeFilmstrips()
            notice = "Split. Tap Before or After to add a clip there."
        }
    }

    /// Cuts an overlay, or a clip on the main track, in two at a timeline second.
    private func splitOverlay(_ index: Int, at: Double) {
        let was = overlays[index]
        if was.isCutaway {
            guard cutaways.count < Self.maxCutaways else {
                notice = "\(Self.maxCutaways) clips is the most, so it can't be split again."
                return
            }
        } else if !canAddOverlay {
            notice = "\(Self.maxOverlays) overlays is the most, so it can't be split again."
            return
        }
        let before = snapshot()
        var first = was
        var second = was
        first.length = at - was.start
        second.id = UUID()
        second.start = at
        second.length = was.end - at
        if was.isVideo { second.trimStart = was.trimStart + (at - was.start) }
        // Keyframes count from the key origin; keep them at the same timeline seconds.
        let shift = second.keyOrigin - was.keyOrigin
        if shift != 0 {
            second.keys = second.keys?.map { var key = $0; key.time -= shift; return key }
            second.maskKeys = second.maskKeys?.map { var key = $0; key.time -= shift; return key }
        }
        overlayMedia[second.id] = overlayMedia[was.id]
        overlayThumbs[second.id] = overlayThumbs[was.id]
        overlays[index] = first
        overlays.insert(second, at: index + 1)
        history.append(before)
        future = []
        pickOverlay(second.id)
        rebuildAll()
        notice = "Split."
    }

    /// Adds a picked photo or video to the main track, before or after the picked piece. On a
    /// performance it plays over the performance and the song keeps going (everything stays in
    /// sync); editing a video, it goes in between the videos.
    func addClip(_ items: [PhotosPickerItem], _ side: ClipSide) async {
        guard let item = items.first, busy == nil else { return }
        pause()
        if kind == .video {
            await addVideoClip(item, side)
            return
        }
        guard let anchor = clipAnchor else {
            notice = "Tap the video track first, then Before or After."
            return
        }
        // Next to a clip after the performance, or After its last piece: it joins the clips after it.
        var tailSpot: Int?
        if let id = overlayPick, let index = overlays.firstIndex(where: { $0.id == id }), overlays[index].isTail {
            tailSpot = side == .after ? index + 1 : index
        } else if side == .after, overlayPick == nil, abs(anchor.end - performanceEnd) < 0.001 {
            tailSpot = firstTailSpot
        }
        guard let opened = await openTrackClip(item) else { return }
        let media = opened.0
        var clip = opened.1
        if let tailSpot {
            placeTail(clip, media: media, at: tailSpot)
            return
        }
        // A video for its length, a photo for 3 seconds, kept on the clip (Start to End).
        let want = clip.isVideo ? media.videoLength : 3
        let first = loopStart, last = performanceEnd
        var start: Double
        var end: Double
        switch side {
        case .after:
            start = anchor.end
            if start > last - 0.3 { start = max(first, last - want) }
            end = min(last, start + want)
        case .before:
            end = anchor.start
            if end < first + 0.3 { end = min(last, first + want) }
            start = max(first, end - want)
        }
        clip.start = start
        clip.length = max(0.3, min(want, end - start))
        let before = snapshot()
        overlayMedia[clip.id] = media
        overlayThumbs[clip.id] = media.thumbnail
        // Under every overlay: the main track's clips come first.
        overlays.insert(clip, at: overlays.firstIndex(where: { !$0.isCutaway }) ?? overlays.count)
        history.append(before)
        future = []
        pickOverlay(clip.id)
        rebuildAll()
        notice = "Added. The song keeps playing under it."
    }

    /// The + at the end of the video track: a photo or video goes on the same track, after
    /// everything (after the performance, or after the last video), and the video gets longer.
    func addToEnd(_ items: [PhotosPickerItem]) async {
        guard let item = items.first, busy == nil else { return }
        pause()
        if kind == .video {
            guard let last = playOrder.last else { return }
            pickOnEdit(last)
            await addVideoClip(item, .after)
            return
        }
        guard let opened = await openTrackClip(item) else { return }
        placeTail(opened.1, media: opened.0, at: overlays.firstIndex(where: { !$0.isCutaway }) ?? overlays.count)
    }

    /// Where a clip goes to be the first one after the performance.
    private var firstTailSpot: Int {
        overlays.firstIndex(where: \.isTail) ?? overlays.firstIndex(where: { !$0.isCutaway }) ?? overlays.count
    }

    /// Opens a picked photo or video as a clip for the main track (filling the frame). Nil when
    /// it couldn't be opened, or there's no room for another.
    private func openTrackClip(_ item: PhotosPickerItem) async -> (OverlayMedia, SavedOverlay)? {
        guard cutaways.count < Self.maxCutaways else {
            notice = "\(Self.maxCutaways) clips is the most."
            return nil
        }
        guard Disk.hasRoom(for: 300 * Disk.megabyte) else {
            problem = Disk.fullMessage
            return nil
        }
        busy = "Adding it…"
        defer { busy = nil }
        guard let loaded = await OverlayLoader.open(item, project: currentProject?.id) else {
            problem = "That couldn't be opened. Try another photo or video."
            return nil
        }
        problem = nil
        var clip = loaded.0
        clip.onTrack = true
        clip.scale = 1
        clip.x = 0.5
        clip.y = 0.5
        return (loaded.1, clip)
    }

    /// Puts a clip after the performance, at a spot in the list (the clips after it play in list
    /// order, back to back from End). A video plays for its length, a photo for 3 seconds.
    private func placeTail(_ made: SavedOverlay, media: OverlayMedia, at spot: Int) {
        guard kind == .performance else { return }
        var clip = made
        clip.tail = true
        clip.trimStart = 0
        clip.length = max(0.3, clip.isVideo ? media.videoLength : 3)
        // Keep it with the main track's clips, under every overlay.
        let lowest = overlays.firstIndex(where: { !$0.isCutaway }) ?? overlays.count
        let before = snapshot()
        overlayMedia[clip.id] = media
        overlayThumbs[clip.id] = media.thumbnail
        overlays.insert(clip, at: min(max(0, spot), lowest))
        history.append(before)
        future = []
        layOutTail()
        pickOverlay(clip.id)
        rebuildAll()
        if let placed = overlay(clip.id) { scrub(to: placed.start) }
        notice = "Added after the performance."
    }

    /// Editing a video: a new video goes in before or after the picked one.
    private func addVideoClip(_ item: PhotosPickerItem, _ side: ClipSide) async {
        guard let pick = editPick, layers.indices.contains(pick) else {
            notice = "Tap a clip first, then Before or After."
            return
        }
        guard laneCount < Self.maxLayers else {
            notice = "\(Self.maxLayers) videos is the most."
            return
        }
        guard Disk.hasRoom(for: 300 * Disk.megabyte) else {
            problem = Disk.fullMessage
            return
        }
        busy = "Adding it…"
        defer { busy = nil }
        guard let picked = await PhotosLoader.load([item]).first,
              var layer = try? await Self.makeLayer(id: layers.count, from: picked.asset) else {
            problem = "That video couldn't be opened. Try another one."
            return
        }
        let prints = await Self.readSounds(videos: [picked.asset], song: nil)
        // Things may have moved while it opened.
        guard stage == .editing, kind == .video, layers.indices.contains(pick),
              laneCount < Self.maxLayers else { return }
        problem = nil
        layer.sound = prints[0]
        layer.sync = .manual
        layer.video = videoSources.count
        let source = currentProject.map { ProjectStore.adopt(picked.source, into: $0.id) } ?? picked.source
        let before = snapshot()
        var list = playOrder
        let spot = list.firstIndex(of: pick).map { side == .before ? $0 : $0 + 1 } ?? list.count
        videoSources.append(source)
        layers.append(layer)
        list.insert(layer.id, at: min(spot, list.count))
        order = list
        history.append(before)
        future = []
        layOutSequence()
        pickOnEdit(layer.id)
        rebuildAll()
        makeFilmstrips()
        notice = "Added."
    }

    /// Editing a video: lays the videos end to end in order, with a cut at each one's start, and
    /// sets the length to all of them together.
    private func layOutSequence() {
        var at = 0.0
        var next: [Cut] = []
        for index in playOrder {
            layers[index].offset = at - layers[index].trimStart
            var cut = cuts.first(where: { $0.layer == index }) ?? Cut(time: 0, layer: index)
            cut.time = at
            next.append(cut)
            at += layers[index].clipEnd - layers[index].clipStart
        }
        let whole = outPoint >= duration - 0.0005
        cuts = next
        duration = at
        inPoint = min(inPoint, duration)
        outPoint = whole ? duration : min(outPoint, duration)
    }

    // MARK: Speed

    /// The speeds a take can play at, as how many times longer it plays than it was shot.
    static let speeds: [Double] = [4, 2, 1.5, 1, 0.75, 0.5, 0.25]

    /// How a speed reads: "½ speed", "Normal", "2x speed".
    static func speedName(_ speed: Double) -> String {
        switch speed {
        case 4: "¼ speed"
        case 2: "½ speed"
        case 1.5: "⅔ speed"
        case 0.75: "1⅓x speed"
        case 0.5: "2x speed"
        case 0.25: "4x speed"
        default: abs(speed - 1) < 0.001 ? "Normal" : String(format: "%.2gx speed", 1 / speed)
        }
    }

    /// Plays a video slowed down or sped up (for a take shot to the song at another speed) and
    /// lines it up to the song again at that speed. Picking Normal puts it back as it was shot.
    func setSpeed(_ index: Int, to speed: Double) async {
        guard layers.indices.contains(index), busy == nil,
              abs(layers[index].speed - speed) > 0.001 else { return }
        pause()
        busy = "Lining it up at that speed…"
        defer { busy = nil }
        guard var changed = await Self.withSpeed(layers[index], speed) else {
            problem = "That video couldn't be changed to that speed."
            return
        }
        problem = nil
        // Lined up to the sound everything else lines up to, at the new speed.
        if kind == .performance, let soundtrack, let target = soundtrack.sound, let sound = changed.sound,
           changed.sync != .reference {
            let match = await Task.detached(priority: .userInitiated) { () -> SoundMatch? in
                TakeSpeed.best(sound, main: LineUp.prepare(target), second: FluxLineUp.prepare(target),
                               tryOthers: false).match
            }.value
            // Reference seconds to timeline seconds.
            let toTimeline = target.start + soundtrack.shift + (changed.trackStart - sound.start)
            if let match {
                changed.offset = match.lag + toTimeline
                changed.alternatives = match.others.map { $0 + toTimeline }
                changed.sync = match.sure ? .matched : .unsure
            } else {
                changed.alternatives = []
                changed.sync = .unsure
            }
        }
        let oldKey = ObjectIdentifier(layers[index].asset)
        layers[index] = changed
        // The old copy's frames go unless another track still shows it.
        if !layers.contains(where: { ObjectIdentifier($0.asset) == oldKey }) { filmstrips[oldKey] = nil }
        // Undo steps from before hold this video's old times, so they're cleared.
        history = []
        future = []
        makeFilmstrips()
        rebuildAll()
        notice = abs(speed - 1) < 0.001
            ? "Video \(index + 1) plays at normal speed again."
            : "Video \(index + 1) plays at \(Self.speedName(speed).lowercased())\(changed.sync == .unsure ? ". Check that it lines up." : ".")"
    }

    // MARK: Overlays

    func overlay(_ id: UUID) -> SavedOverlay? { overlays.first { $0.id == id } }

    var canAddOverlay: Bool { onTop.count < Self.maxOverlays }

    /// Overlays proper: on top of the video, each on its own row.
    var onTop: [SavedOverlay] { overlays.filter { !$0.isCutaway } }
    /// Clips on the main video track (added before or after a split).
    var cutaways: [SavedOverlay] { overlays.filter(\.isCutaway) }

    /// Adds a picked photo or video on top of the main video, at the playhead. A photo shows for 3
    /// seconds; a video for its length (to the end of the clip at most).
    func addOverlay(_ items: [PhotosPickerItem]) async {
        guard let item = items.first, canAddOverlay, busy == nil else { return }
        pause()
        guard Disk.hasRoom(for: 300 * Disk.megabyte) else {
            problem = Disk.fullMessage
            return
        }
        busy = "Adding it…"
        defer { busy = nil }
        guard let loaded = await OverlayLoader.open(item, project: currentProject?.id) else {
            problem = "That couldn't be opened. Try another photo or video."
            return
        }
        problem = nil
        let media = loaded.1
        var overlay = loaded.0
        let end = loopEnd
        let start = min(max(time, loopStart), max(loopStart, end - 0.5))
        overlay.start = start
        overlay.length = max(0.5, min(overlay.isVideo ? media.videoLength : 3, end - start))
        // Starts at 60% of the frame's width, in the middle.
        overlay.scale = 0.6
        let before = snapshot()
        overlayMedia[overlay.id] = media
        overlayThumbs[overlay.id] = media.thumbnail
        overlays.append(overlay)
        history.append(before)
        future = []
        pickOverlay(overlay.id)
        rebuildAll()
        notice = "Drag it on the video to move it, pinch to size it."
    }

    /// A tap on an overlay's clip picks it (nil lets go).
    func pickOverlay(_ id: UUID?) {
        overlayPick = id
        if id != nil {
            editPick = nil
            selected = nil
            lyricsPicked = false
        }
        notice = nil
    }

    func deleteOverlay(_ id: UUID) {
        guard overlay(id) != nil else { return }
        let before = snapshot()
        overlays.removeAll { $0.id == id }
        if overlayPick == id { overlayPick = nil }
        history.append(before)
        future = []
        rebuildAll()
    }

    /// The overlay row's icon: hides or shows it (on the video and in the export).
    func toggleOverlayHidden(_ id: UUID) {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        history.append(snapshot())
        future = []
        overlays[index].hidden.toggle()
        redraw()
    }

    /// A finger took hold of an overlay's clip on the timeline: moves it (.move) or trims an end.
    func beginOverlayDrag(_ id: UUID, grip: Grip) {
        guard let overlay = overlay(id) else { return }
        pause()
        pickOverlay(id)
        draggingOverlay = id
        overlayDragStart = (overlay, grip, snapshot())
        notice = nil
    }

    private func dragOverlay(by seconds: Double) {
        guard let id = draggingOverlay, let start = overlayDragStart,
              let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        let was = start.overlay
        let frames = { (value: Double) in (value * 30).rounded() / 30 }
        let shortest = 0.3
        let videoLeft = was.isVideo ? (overlayMedia[id]?.videoLength ?? was.length) : .infinity
        // A clip on the main track stays on the performance (Start to End); a clip after the
        // performance only gets longer or shorter (the ones after it follow); an overlay can go
        // anywhere on the timeline. A photo after the performance shows for a minute at most.
        let longestPhoto = 60.0
        let low = was.isTail ? -Double.infinity : (was.isCutaway ? loopStart : 0)
        let high = was.isTail ? was.start + (was.isVideo ? videoLeft : longestPhoto)
            : (was.isCutaway ? performanceEnd : timelineEnd)
        var next = was
        switch start.grip {
        case .move:
            if !was.isTail {
                next.start = frames(min(max(low, was.start + seconds), max(low, high - was.length)))
            }
        case .trimStart:
            var shift = frames(seconds)
            shift = max(shift, low - was.start)                  // not before the start
            if was.isTail && !was.isVideo { shift = max(shift, was.length - longestPhoto) }
            if was.isVideo { shift = max(shift, -was.trimStart) } // not before the video's first frame
            shift = min(shift, was.length - shortest)
            next.start = was.start + shift
            next.length = was.length - shift
            if was.isVideo { next.trimStart = was.trimStart + shift }
        case .trimEnd:
            let longest = min(high - was.start, videoLeft - was.trimStart)
            next.length = frames(min(max(shortest, was.length + seconds), max(shortest, longest)))
        }
        if was.isTail {
            // It stays where it is; trimming its front shortens it from there.
            next.start = was.start
            overlays[index] = next
            layOutTail()
            return
        }
        overlays[index] = next
    }

    private func endOverlayDrag() {
        defer {
            draggingOverlay = nil
            overlayDragStart = nil
        }
        guard let start = overlayDragStart, overlays != start.state.overlays else { return }
        history.append(start.state)
        future = []
        rebuildAll()
    }

    /// Two fingers (or one, once it's picked) on the video move and size the picked overlay.
    func beginOverlayTransform() {
        guard let id = overlayPick, let overlay = overlay(id) else { return }
        pause()
        overlayEditStart = (overlay, snapshot())
    }

    /// `scale` from the pinch, `focus` where it started and `move` how far the fingers went, both
    /// as fractions of the frame (focus from the top left).
    func transformOverlay(scale: Double, focus: CGPoint, move: CGSize) {
        guard let start = overlayEditStart,
              let index = overlays.firstIndex(where: { $0.id == start.overlay.id }) else { return }
        // As it shows at the playhead (its keyframes played out).
        let at = playheadFrame
        let was = start.overlay.posed(at: at)
        var next = was
        // A clip on the main track always fills the frame: it zooms in, never out.
        next.scale = was.isCutaway ? min(Framing.maxScale, max(1, was.scale * scale))
                                   : min(3, max(0.08, was.scale * scale))
        let applied = next.scale / was.scale
        // The point under the fingers stays under them while it grows or shrinks.
        var x = Double(focus.x) + (was.x - Double(focus.x)) * applied + Double(move.width)
        var y = Double(focus.y) + (was.y - Double(focus.y)) * applied + Double(move.height)
        // Snaps to the middle.
        if abs(x - 0.5) < 0.02 { x = 0.5 }
        if abs(y - 0.5) < 0.015 { y = 0.5 }
        if was.isCutaway {
            // Moved only as far as it can go without an edge showing.
            let room = (next.scale - 1) / 2
            next.x = min(0.5 + room, max(0.5 - room, x))
            next.y = min(0.5 + room, max(0.5 - room, y))
        } else {
            next.x = min(1.2, max(-0.2, x))
            next.y = min(1.2, max(-0.2, y))
        }
        // With keyframes, this adds or updates the keyframe at the playhead.
        overlays[index] = start.overlay.storing(next.pose, at: at)
        showOverlayLive(overlays[index])
    }

    func endOverlayTransform() {
        guard let start = overlayEditStart else { return }
        overlayEditStart = nil
        guard overlays != start.state.overlays else { return }
        history.append(start.state)
        future = []
        scheduleSave()
        redraw()
    }

    /// The Mask sheet opened: changes until it closes are one Undo step.
    func beginMaskEdit() {
        guard let id = overlayPick, let overlay = overlay(id) else { return }
        pause()
        overlayEditStart = (overlay, snapshot())
        maskPoint = nil
        maskEditing = true
    }

    /// Fingers went down on the video while the Mask sheet is open.
    func beginMaskMove() {
        guard maskEditing, let id = overlayPick, let overlay = overlayHere(id) else { return }
        pause()
        var mask = overlay.mask
        // Moving a mask that's off shows a circle to move.
        if mask.shape == .off { mask.shape = .circle }
        maskMoveStart = mask
    }

    /// `scale` from the pinch and `move` how far the fingers went, as fractions of the frame.
    func moveMask(scale: Double, move: CGSize) {
        guard let start = maskMoveStart, let id = overlayPick, let box = overlayBox(id),
              box.width > 0, box.height > 0 else { return }
        var next = start
        next.size = min(OverlayMask.largest, max(0.1, start.size * scale))
        // The frame's fractions to the overlay's fractions.
        var x = start.middleX + Double(move.width) / box.width
        var y = start.middleY + Double(move.height) / box.height
        // Snaps to the overlay's middle.
        if abs(x - 0.5) < 0.03 { x = 0.5 }
        if abs(y - 0.5) < 0.03 { y = 0.5 }
        next.centerX = min(1.5, max(-0.5, x))
        next.centerY = min(1.5, max(-0.5, y))
        setOverlayMask(next)
    }

    func endMaskMove() {
        guard maskMoveStart != nil else { return }
        maskMoveStart = nil
        redraw()
    }

    /// A mask's middle on the video, and how long one shape unit is across and down, as fractions
    /// of the frame. The frame is 9 wide to 16 tall, so a unit is a bigger fraction across.
    private func maskUnits(_ mask: OverlayMask, in box: CGRect) -> (middle: CGPoint, x: Double, y: Double) {
        let size = min(OverlayMask.largest, max(0.1, mask.size))
        let unit = Double(min(box.width * 9, box.height * 16)) * size
        let middle = CGPoint(x: Double(box.minX) + Double(box.width) * mask.middleX,
                             y: Double(box.minY) + Double(box.height) * mask.middleY)
        return (middle, unit / 9, unit / 16)
    }

    /// Custom's points on the video, as fractions of the frame.
    func maskAnchors(_ id: UUID) -> [CGPoint] {
        guard let overlay = overlayHere(id), overlay.mask.shape == .custom, let box = overlayBox(id) else { return [] }
        let units = maskUnits(overlay.mask, in: box)
        return overlay.mask.anchors.map { point in
            CGPoint(x: Double(units.middle.x) + point.x * units.x, y: Double(units.middle.y) + point.y * units.y)
        }
    }

    /// Where the picked overlay's mask sits, as fractions of the frame (for its outline).
    func maskBox(_ id: UUID) -> CGRect? {
        guard let overlay = overlayHere(id), overlay.mask.shape != .off, let box = overlayBox(id) else { return nil }
        let mask = overlay.mask
        if mask.shape == .custom {
            let points = maskAnchors(id)
            guard let minX = points.map({ $0.x }).min(), let maxX = points.map({ $0.x }).max(),
                  let minY = points.map({ $0.y }).min(), let maxY = points.map({ $0.y }).max() else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let units = maskUnits(mask, in: box)
        let width: Double = units.x * min(OverlayMask.widest, max(OverlayMask.thinnest, mask.across))
        let height: Double = units.y * min(OverlayMask.widest, max(OverlayMask.thinnest, mask.down))
        return CGRect(x: Double(units.middle.x) - width / 2, y: Double(units.middle.y) - height / 2,
                      width: width, height: height)
    }

    /// A finger went down on one of the mask's handles.
    func beginMaskHandle() {
        guard maskEditing, let id = overlayPick, let overlay = overlayHere(id), overlay.mask.shape != .off else { return }
        pause()
        maskMoveStart = overlay.mask
    }

    /// A Circle or Square side handle (0 top, 1 right, 2 bottom, 3 left) dragged to `point`
    /// (fractions of the frame): that side follows the finger and the opposite side stays put.
    func dragMaskSide(_ side: Int, to point: CGPoint) {
        guard let start = maskMoveStart, let id = overlayPick, let box = overlayBox(id),
              box.width > 0, box.height > 0 else { return }
        let units = maskUnits(start, in: box)
        guard units.x > 0, units.y > 0 else { return }
        var next = start
        var middleX = Double(units.middle.x), middleY = Double(units.middle.y)
        let x = Double(point.x), y = Double(point.y)
        // How far the finger is from the side that stays, toward the side it holds (a side can't
        // be pulled past the other one: it stops at a sliver).
        if side == 1 || side == 3 {
            let half = units.x * start.across / 2
            let fixed = side == 1 ? middleX - half : middleX + half
            let pulled = side == 1 ? x - fixed : fixed - x
            let span = min(OverlayMask.widest, max(OverlayMask.thinnest, pulled / units.x))
            middleX = side == 1 ? fixed + units.x * span / 2 : fixed - units.x * span / 2
            next.wide = span
        } else {
            let half = units.y * start.down / 2
            let fixed = side == 2 ? middleY - half : middleY + half
            let pulled = side == 2 ? y - fixed : fixed - y
            let span = min(OverlayMask.widest, max(OverlayMask.thinnest, pulled / units.y))
            middleY = side == 2 ? fixed + units.y * span / 2 : fixed - units.y * span / 2
            next.tall = span
        }
        let centerX: Double = (middleX - Double(box.minX)) / Double(box.width)
        let centerY: Double = (middleY - Double(box.minY)) / Double(box.height)
        next.centerX = min(1.5, max(-0.5, centerX))
        next.centerY = min(1.5, max(-0.5, centerY))
        setOverlayMask(next)
    }

    /// One of Custom's points dragged to `point` (fractions of the frame).
    func dragMaskPoint(_ index: Int, to point: CGPoint) {
        guard let start = maskMoveStart, start.shape == .custom, let id = overlayPick, let box = overlayBox(id) else { return }
        let units = maskUnits(start, in: box)
        guard units.x > 0, units.y > 0 else { return }
        var points = start.anchors
        guard points.indices.contains(index) else { return }
        points[index] = unitPoint(point, units: units)
        var next = start
        next.points = points
        setOverlayMask(next)
    }

    private func unitPoint(_ point: CGPoint, units: (middle: CGPoint, x: Double, y: Double)) -> MaskPoint {
        let reach = MaskPoint.reach
        let x: Double = (Double(point.x) - Double(units.middle.x)) / units.x
        let y: Double = (Double(point.y) - Double(units.middle.y)) / units.y
        return MaskPoint(x: min(reach, max(-reach, x)), y: min(reach, max(-reach, y)))
    }

    /// A tap on the video with Custom on: a new point there, put into the outline between the two
    /// points whose line it's closest to.
    func addMaskPoint(at point: CGPoint) {
        guard maskEditing, let id = overlayPick, let overlay = overlayHere(id), overlay.mask.shape == .custom,
              let box = overlayBox(id) else { return }
        let units = maskUnits(overlay.mask, in: box)
        guard units.x > 0, units.y > 0 else { return }
        pause()
        let new = unitPoint(point, units: units)
        var points = overlay.mask.anchors
        // Shape units are as long across as down on screen, so distances can be measured in them.
        var best = points.count
        var nearest = Double.infinity
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((new.x - a.x) * dx + (new.y - a.y) * dy) / length)) : 0
            let distance = hypot(new.x - (a.x + t * dx), new.y - (a.y + t * dy))
            if distance < nearest {
                nearest = distance
                best = i + 1
            }
        }
        points.insert(new, at: best)
        var next = overlay.mask
        next.points = points
        maskPoint = best
        setOverlayMask(next)
        showOverlayNow()
    }

    /// Takes away the Custom point last tapped (a shape keeps at least three).
    func removeMaskPoint() {
        guard let index = maskPoint, let id = overlayPick, let overlay = overlayHere(id),
              overlay.mask.shape == .custom else { return }
        var points = overlay.mask.anchors
        guard points.count > 3, points.indices.contains(index) else { return }
        points.remove(at: index)
        var next = overlay.mask
        next.points = points
        maskPoint = nil
        setOverlayMask(next)
        showOverlayNow()
    }

    func setOverlayMask(_ mask: OverlayMask) {
        guard let id = overlayPick, let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        // The shape and Invert are the same all the way through; its place, size and soft edge
        // can be keyframed (with keyframes, a change adds or updates the one at the playhead).
        var stored = overlays[index]
        stored.mask.shape = mask.shape
        stored.mask.invert = mask.invert
        stored.mask.wide = mask.wide
        stored.mask.tall = mask.tall
        stored.mask.points = mask.points
        stored.mask.smooth = mask.smooth
        let at = playheadFrame
        var pose = stored.posed(at: at).pose
        pose.maskX = mask.middleX
        pose.maskY = mask.middleY
        pose.maskSize = mask.size
        pose.maskFeather = mask.feather
        overlays[index] = stored.storing(pose, at: at)
        showOverlayLive(overlays[index])
    }

    /// An overlay as it shows at the playhead, its keyframes played out.
    func overlayHere(_ id: UUID) -> SavedOverlay? {
        overlay(id)?.posed(at: time)
    }

    func endMaskEdit() {
        maskEditing = false
        maskMoveStart = nil
        maskPoint = nil
        endOverlayTransform()
    }

    /// Draws the frame again now (after a mask change settles).
    func showOverlayNow() {
        redraw()
    }

    /// Where an overlay sits on the video, as fractions of the frame (for its outline).
    func overlayBox(_ id: UUID) -> CGRect? {
        // A clip on the main track fills the frame.
        if overlay(id)?.isCutaway == true { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        guard let overlay = overlayHere(id), let size = overlayMedia[id]?.size, size.width > 0 else { return nil }
        let width = overlay.scale
        // The frame is 9:16, so a fraction of its width is 9/16 as much of its height.
        let height = overlay.scale * Double(size.height / size.width) * 9 / 16
        return CGRect(x: overlay.x - width / 2, y: overlay.y - height / 2, width: width, height: height)
    }

    /// Shows an overlay's new place or mask on the video right away (a redraw now and then).
    private func showOverlayLive(_ overlay: SavedOverlay) {
        overlayBoard.place(overlay)
        if Date().timeIntervalSince(titleRedrawn) > 0.06 {
            titleRedrawn = Date()
            redraw()
        }
    }

    /// Puts a new list of cuts in (sorted, starting at 0, with no two in a row on one video),
    /// with an undo step when anything changed.
    private func apply(_ list: [Cut]) {
        var next = list.sorted { $0.time < $1.time }
        if next.first?.time ?? 1 > 0 { next.insert(Cut(time: 0, layer: cuts.first?.layer ?? next.first?.layer ?? 0), at: 0) }
        var tidy: [Cut] = []
        for cut in next where tidy.last?.layer != cut.layer { tidy.append(cut) }
        guard tidy != cuts else {
            refreshCuts()
            return
        }
        history.append(snapshot())
        cuts = tidy
        refreshCuts()
    }

    func undo() {
        // An open text's changes so far become one step first, so Undo takes them back.
        let editing = titleEditStart != nil
        if let start = titleEditStart, titles != start.titles { history.append(start) }
        titleEditStart = nil
        defer { if editing && titleEditing != nil { titleEditStart = snapshot() } }
        guard let previous = history.popLast() else { return }
        let now = snapshot()
        future.append(now)
        let moved = previous.timing != now.timing
        restore(previous)
        if moved { rebuildAll() } else { redraw() }
    }

    /// Puts back the last step Undo took away.
    func redo() {
        guard let next = future.popLast() else { return }
        // A copy that Undo took away can't come back (its video was let go).
        guard next.places.count <= layers.count else {
            future = []
            notice = "That step can't be redone."
            return
        }
        if titleEditStart != nil { titleEditStart = nil }
        let now = snapshot()
        redoing = true
        history.append(now)
        redoing = false
        let moved = next.timing != now.timing
        restore(next)
        if titleEditing != nil { titleEditStart = snapshot() }
        if moved { rebuildAll() } else { redraw() }
    }

    // MARK: Filmstrips

    /// Makes the timeline's frame strips for any video that doesn't have one yet.
    func makeFilmstrips() {
        guard filmstripTask == nil else { return }
        var seen = Set<ObjectIdentifier>()
        let missing = layers.filter { layer in
            let key = ObjectIdentifier(layer.asset)
            guard filmstrips[key] == nil, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        guard !missing.isEmpty else { return }
        let jobs = missing.map { (key: ObjectIdentifier($0.asset), asset: $0.asset, start: $0.trackStart, length: $0.length) }
        filmstripTask = Task { [weak self] in
            for job in jobs {
                let strip = await Self.filmstrip(asset: job.asset, start: job.start, length: job.length)
                guard let self, !Task.isCancelled else { return }
                self.filmstrips[job.key] = strip
            }
            self?.filmstripTask = nil
            self?.makeFilmstrips()   // any video added meanwhile
        }
    }

    private func dropFilmstrips() {
        filmstripTask?.cancel()
        filmstripTask = nil
        filmstrips = [:]
    }

    /// Small frames along a video, about two a second (fewer for long videos), in its own turn.
    private static func filmstrip(asset: AVAsset, start: Double, length: Double) async -> Filmstrip {
        let step = max(0.5, length / 120)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 110, height: 110)
        let slack = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        var frames: [CGImage?] = []
        var second = 0.0
        while second < length {
            if Task.isCancelled { break }
            let at = CMTime(seconds: start + second + step / 2, preferredTimescale: 600)
            frames.append(try? await generator.image(at: at).image)
            second += step
        }
        return Filmstrip(step: step, frames: frames)
    }

    private func snapshot() -> EditState {
        EditState(cuts: cuts, places: layers.map {
            EditState.Place(offset: $0.offset, trimStart: $0.trimStart, trimEnd: $0.trimEnd,
                            sync: $0.sync, alternatives: $0.alternatives, keyframes: $0.keyframes)
        }, lyrics: lyrics, lyricStyle: lyricStyle, titles: titles, overlays: overlays, trackKeys: trackKeys,
           splits: splits, order: order)
    }

    private func restore(_ state: EditState) {
        cuts = state.cuts
        splits = state.splits
        order = state.order
        if let pick = piecePick, !performancePieces.indices.contains(pick) { piecePick = nil }
        if overlays != state.overlays || trackKeys != state.trackKeys {
            trackKeys = state.trackKeys
            overlays = state.overlays
            if let id = overlayPick, overlay(id) == nil { overlayPick = nil }
            // The renderer reads places and masks from the board, so Undo shows right away.
            overlayBoard.update(overlays, media: overlayMedia, track: trackKeys)
        }
        if titles != state.titles {
            titles = state.titles
            if let id = titleEditing, title(id) == nil { titleEditing = nil }
            syncTitles()
        }
        if lyrics != state.lyrics || lyricStyle != state.lyricStyle {
            lyrics = state.lyrics
            lyricStyle = state.lyricStyle
            if let index = lyricSelected, !lyrics.indices.contains(index) { lyricSelected = nil }
            tapNext = min(tapNext, lyrics.count)
            syncLyrics()
        }
        // Undoing a duplicate takes the copy away again.
        if layers.count > state.places.count {
            layers.removeLast(layers.count - state.places.count)
            // Editing a video: a video that was added and is now taken away goes from the list too.
            if kind == .video {
                let used = (layers.map(\.video).max() ?? -1) + 1
                if videoSources.count > used { videoSources.removeLast(videoSources.count - used) }
            }
            if let index = selected, !layers.indices.contains(index) { selected = nil }
            if let index = previewing, !layers.indices.contains(index) { previewing = nil }
        }
        for (index, place) in state.places.enumerated() where layers.indices.contains(index) {
            layers[index].offset = place.offset
            layers[index].trimStart = place.trimStart
            layers[index].trimEnd = place.trimEnd
            layers[index].sync = place.sync
            layers[index].alternatives = place.alternatives
            layers[index].keyframes = place.keyframes
        }
        if let pick = editPick, kind == .video, !layers.indices.contains(pick) { editPick = nil }
        // Editing a video: they stay back to back after an undo.
        if kind == .video { layOutSequence() }
    }

    // MARK: Moving and trimming one clip

    /// A tap on a clip picks it; a tap on empty space lets go.
    func select(_ index: Int?) {
        selected = index
        if index != nil { lyricsPicked = false }
        notice = nil
    }

    func toggleLock() {
        locked.toggle()
        notice = nil
    }

    /// Adds a copy of a video as a new layer at the bottom, in the same place with the same trims,
    /// so you can use the same take twice (for example, cut back to it later in the song).
    func duplicate(_ index: Int) {
        guard layers.indices.contains(index) else { return }
        guard laneCount < Self.maxLayers else {
            notice = "\(Self.maxLayers) lanes is the most (videos and text together)."
            return
        }
        pause()
        history.append(snapshot())
        let copy = copyOf(layers[index])
        layers.append(copy)
        selected = copy.id
        notice = "Video \(copy.id + 1) is a copy of video \(index + 1)."
        rebuildAll()
    }

    /// A copy of a video as a new layer (on the end of `layers`), in the same place with the same trims.
    private func copyOf(_ original: Layer) -> Layer {
        Layer(id: layers.count, asset: original.asset, track: original.track,
              trackStart: original.trackStart, length: original.length,
              orientation: original.orientation, displaySize: original.displaySize,
              fps: original.fps, thumbnail: original.thumbnail, sound: original.sound,
              offset: original.offset, sync: original.sync,
              trimStart: original.trimStart, trimEnd: original.trimEnd,
              alternatives: original.alternatives, keyframes: original.keyframes,
              video: original.video, color: original.color, audio: original.audio,
              speed: original.speed, original: original.original)
    }

    /// A finger took hold of a clip: held it to move it, or grabbed an edge to trim it.
    func beginDrag(on index: Int, grip: Grip) {
        guard !locked, layers.indices.contains(index) else { return }
        pause()
        selected = index
        dragging = index
        self.grip = grip
        dragStartState = snapshot()
        dragStartLayer = layers[index]
        notice = nil
    }

    /// A finger took hold of a hand-off (where one video switches to the next). Dragging it makes
    /// the video before it run longer or shorter, and the one after start later or sooner.
    /// Works while locked: it changes cuts, not clips.
    func beginCutDrag(_ index: Int) {
        guard cuts.indices.contains(index), index > 0 else { return }
        pause()
        draggingCut = index
        dragStartCutTime = cuts[index].time
        dragStartState = snapshot()
        notice = nil
    }

    /// The finger has moved this many seconds (right is positive) since the drag began.
    func drag(by seconds: Double) {
        if draggingOverlay != nil {
            dragOverlay(by: seconds)
            return
        }
        if let end = draggingRange {
            moveRange(end, by: seconds)
            return
        }
        if let index = draggingCut {
            moveCut(index, to: dragStartCutTime + seconds)
            return
        }
        guard let index = dragging, let start = dragStartLayer else { return }
        let shortest = 0.1
        switch grip {
        case .move:
            layers[index].offset = start.offset + seconds
            layers[index].sync = .manual
        case .trimStart:
            layers[index].trimStart = min(max(0, start.trimStart + seconds), start.length - start.trimEnd - shortest)
        case .trimEnd:
            layers[index].trimEnd = min(max(0, start.trimEnd - seconds), start.length - start.trimStart - shortest)
        }
        // Editing a video: the ones after it close up or make room as it's trimmed.
        if kind == .video {
            layOutSequence()
            segments = Program.segments(cuts: cuts, layers: layers, duration: duration)
        }
    }

    /// Keeps a hand-off on whole frames and between its neighbors, so cuts never cross or vanish.
    private func moveCut(_ index: Int, to seconds: Double) {
        guard cuts.indices.contains(index), index > 0 else { return }
        let frame = 1.0 / 30
        let lower = cuts[index - 1].time + frame
        let upper = (index + 1 < cuts.count ? cuts[index + 1].time : duration) - frame
        guard lower <= upper else { return }
        let snapped = (seconds * 30).rounded() / 30
        let next = min(max(snapped, lower), upper)
        guard next != cuts[index].time else { return }
        cuts[index].time = next
        refreshCuts()
    }

    func endDrag() {
        if draggingOverlay != nil {
            endOverlayDrag()
            return
        }
        if draggingRange != nil {
            draggingRange = nil
            updateLoop()
            scheduleSave()
            keepInRange()
            return
        }
        defer {
            dragging = nil
            draggingCut = nil
            dragStartLayer = nil
            dragStartState = nil
        }
        guard let before = dragStartState else { return }
        if draggingCut != nil {
            if before.cuts != cuts { history.append(before) }
            return
        }
        if before.places != snapshot().places {
            history.append(before)
            rebuildAll()
        }
    }

    /// Moves a clip to another spot its sound fits (a repeated chorus). Where it was becomes a
    /// dashed spot, so it can go back.
    func moveToAlternative(_ index: Int, choice: Int) {
        guard layers.indices.contains(index), layers[index].alternatives.indices.contains(choice) else { return }
        guard !locked else {
            notice = "Unlock to move video \(index + 1) there."
            return
        }
        pause()
        history.append(snapshot())
        let target = layers[index].alternatives[choice]
        layers[index].alternatives[choice] = layers[index].offset
        layers[index].offset = target
        selected = index
        notice = nil
        rebuildAll()
    }

    /// Moves the picked clip one frame earlier or later.
    func nudge(frames: Int) {
        guard !locked, let index = selected, layers.indices.contains(index) else { return }
        pause()
        history.append(snapshot())
        layers[index].offset += Double(frames) / 30
        layers[index].sync = .manual
        rebuildAll()
    }

    // MARK: Track colors

    /// Gives a track one of the palette's colors (an index into LayerTint.all).
    func setTrackColor(_ index: Int, to color: Int) {
        guard layers.indices.contains(index), LayerTint.all.indices.contains(color) else { return }
        layers[index].color = color
        scheduleSave()
    }

    // MARK: Playback

    func togglePlay() {
        stopLookPreview()
        if isPlaying {
            pause()
            return
        }
        // Looping: Play always starts inside the loop. Not looping and stopped at Out: starts at In again.
        let atOut = hasRange && abs(time - loopEnd) < 0.05
        if (looping && (time < loopStart - 0.02 || time >= loopEnd - 0.05)) || (!looping && atOut) {
            time = loopStart
            player.seek(to: CMTime(seconds: loopStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        if looping && time >= loopEnd - 0.05 {
            time = loopStart
            player.seek(to: CMTime(seconds: loopStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else if time >= timelineEnd - 0.05 {
            time = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Loop off: playing from before Out stops at Out. (Starting past Out plays on to the end.)
        stopAtOut = !looping && time < loopEnd - 0.05
        RenderStats.shared.reset()
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        let now = player.currentTime().seconds
        if now.isFinite, player.currentItem != nil { time = min(max(0, now), timelineEnd) }
    }

    func beginScrub() {
        stopLookPreview()
        scrubbing = true
        resumeAfterScrub = isPlaying
        if isPlaying { pause() }
    }

    func scrub(to seconds: Double) {
        time = min(max(0, seconds), timelineEnd)
        requestSeek(time)
    }

    func endScrub() {
        scrubbing = false
        if resumeAfterScrub { play() }
    }

    private func requestSeek(_ seconds: Double) {
        updateLyricNow(at: seconds)
        if seeking {
            pendingSeek = seconds
            return
        }
        seeking = true
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.requestSeek(next)
                }
            }
        }
    }

    // MARK: Building

    /// Rebuild everything (after a video moves).
    private func rebuildAll() {
        scheduleSave()
        let resume = isPlaying
        pause()
        layOutTail()
        builtTail = tailClips.map(\.start)
        do {
            overlayBoard.update(overlays, media: overlayMedia, track: trackKeys)
            let built = try TimelineBuilder.build(layers: layers, soundtrack: soundtrack, duration: duration,
                                                  length: timelineEnd, videoSound: kind == .video,
                                                  overlays: overlays, media: overlayMedia)
            self.built = built
            segments = Program.segments(cuts: cuts, layers: layers, duration: duration)
            let item = AVPlayerItem(asset: built.composition)
            // Never let the system draw its own captions over the picture (the Closed Captions
            // setting, or auto captions): the only words on the video are the lyrics you style.
            let captions = AVPlayerItemLegibleOutput()
            captions.suppressesPlayerRendering = true
            item.add(captions)
            item.videoComposition = TimelineBuilder.videoComposition(segments: onScreen, built: built,
                                                                     cuts: cuts, layers: layers, duration: duration,
                                                                     length: timelineEnd,
                                                                     lyrics: lyricsLive, overlays: overlays,
                                                                     media: overlayMedia, board: overlayBoard)
            player.replaceCurrentItem(with: item)
            watchForEnd(of: item)
            updateLoop()
            requestSeek(time)
            problem = nil
            if resume { play() }
        } catch {
            let detail = EditorError.explain(error)
            print("editrr couldn't build the timeline:", detail)
            problem = "Couldn't build the timeline: \(detail)"
        }
    }

    /// Only the cuts changed: swap which layer shows where, without stopping playback.
    private func refreshCuts() {
        scheduleSave()
        segments = Program.segments(cuts: cuts, layers: layers, duration: duration)
        guard let built, let item = player.currentItem else { return }
        overlayBoard.update(overlays, media: overlayMedia, track: trackKeys)
        item.videoComposition = TimelineBuilder.videoComposition(segments: onScreen, built: built,
                                                                     cuts: cuts, layers: layers, duration: duration,
                                                                     length: timelineEnd,
                                                                     lyrics: lyricsLive, overlays: overlays,
                                                                     media: overlayMedia, board: overlayBoard)
    }

    /// What actually plays: the cuts, or only the previewed video while you take a look.
    /// (The lanes keep showing the real cuts either way.)
    private var onScreen: [Segment] {
        guard let previewing else { return segments }
        return Program.segments(cuts: cuts, layers: layers, duration: duration, solo: previewing)
    }

    private func watchForEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.looping && self.isPlaying && !self.scrubbing {
                    self.jumpToLoopStart()
                    self.player.play()
                    return
                }
                self.isPlaying = false
                self.time = self.timelineEnd
            }
        }
    }

    /// Watches for the playhead reaching Out: looping goes back to In, otherwise playback stops
    /// there. (The end of the song is caught by the end-of-video notice instead.)
    private func updateLoop() {
        if let loopObserver {
            player.removeTimeObserver(loopObserver)
            self.loopObserver = nil
        }
        // The clips after the performance follow its End: when End moved, they move too.
        layOutTail()
        if tailClips.map(\.start) != builtTail, built != nil {
            rebuildAll()
            return
        }
        guard player.currentItem != nil, loopEnd < timelineEnd - 0.02 else { return }
        let end = NSValue(time: CMTime(seconds: loopEnd, preferredTimescale: 600))
        loopObserver = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.scrubbing else { return }
                if self.looping {
                    self.jumpToLoopStart()
                } else if self.stopAtOut {
                    self.stopAtOut = false
                    self.pause()
                    self.time = self.loopEnd
                    self.requestSeek(self.loopEnd)
                }
            }
        }
    }

    private func jumpToLoopStart() {
        time = loopStart
        requestSeek(loopStart)
    }

    func toggleLoop() {
        looping.toggle()
        notice = looping
            ? (hasRange ? "Loop on: plays Start to End over and over." : "Loop on: set Start and End to loop just that part.")
            : (hasRange ? "Loop off: plays once and stops at End." : "Loop off: plays once to the end.")
    }

    // MARK: Lyrics (brought over from Lyric Sync)

    var hasLyrics: Bool { !lyrics.isEmpty }
    /// Listening needs a soundtrack and a phone that has Apple's speech model.
    var canListen: Bool { soundtrack != nil && LyricListener.isAvailable }

    /// Hands the words and look to the player. Paused, the frame is drawn again right away.
    private func syncLyrics() {
        lyricsLive.update(words: lyrics, style: lyricStyle)
        guard stage == .editing else { return }
        if isPlaying { scheduleSave() } else { redraw() }
    }

    private func resetLyricEditing() {
        lyricTimeline = false
        lyricDrag = nil
        lyricDragStart = nil
        listenTask?.cancel()
        listenTask = nil
        listening = nil
        lyricSelected = nil
        lyricNow = nil
        tapTiming = false
        tapNext = 0
        tapHeld = nil
        tapStarted = false
    }

    private func updateLyricNow(at seconds: Double) {
        guard !lyrics.isEmpty else {
            if lyricNow != nil { lyricNow = nil }
            return
        }
        let frame = LyricTiming.frame(lyrics, style: lyricStyle, at: seconds)
        let now = frame.items.first?.words.last(where: { $0.active })?.index
        if now != lyricNow { lyricNow = now }
    }

    /// One Undo step for any change to the words or their look.
    private func editLyrics(_ change: () -> Void) {
        let before = snapshot()
        change()
        guard lyrics != before.lyrics || lyricStyle != before.lyricStyle else { return }
        history.append(before)
        if let index = lyricSelected, !lyrics.indices.contains(index) { lyricSelected = nil }
        tapNext = min(tapNext, lyrics.count)
        syncLyrics()
    }

    /// Listens to the soundtrack and writes the words down. With `retime`, the words already here
    /// stay as they are and only take the times from what was heard.
    func listenForLyrics(retime: Bool) {
        guard listening == nil, let built else { return }
        guard soundtrack != nil else {
            problem = LyricListenError.noSound.errorDescription
            return
        }
        pause()
        tapTiming = false
        problem = nil
        listening = "Getting the song ready…"
        let box = AssetBox(asset: built.composition)
        let report: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                guard let self, self.listening != nil else { return }
                self.listening = line
            }
        }
        listenTask = Task { [weak self] in
            do {
                let heard = try await LyricListener.listen(to: box.asset, update: report)
                guard let self, !Task.isCancelled else { return }
                self.finishListening(heard, retime: retime)
            } catch {
                guard let self else { return }
                self.listening = nil
                self.listenTask = nil
                if !(error is CancellationError) && !Task.isCancelled {
                    self.problem = (error as? LocalizedError)?.errorDescription ?? EditorError.explain(error)
                }
            }
        }
    }

    func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        listening = nil
    }

    private func finishListening(_ heard: [LyricWord], retime: Bool) {
        listening = nil
        listenTask = nil
        lyricsHeard = heard
        if retime && !lyrics.isEmpty {
            let result = LyricText.retime(lyrics, to: heard)
            editLyrics { lyrics = result.words }
            let total = result.words.count
            notice = result.missing == 0
                ? "Re-timed all \(total) words to the singing."
                : "Re-timed \(total - result.missing) of \(total) words. The rest sit between their neighbors."
        } else {
            editLyrics { lyrics = heard }
            notice = "Heard \(heard.count) words. Tap any word to fix it."
        }
        lyricSelected = nil
        tapNext = 0
        scheduleSave()
    }

    /// Lines the words up with the singing again, keeping them as typed. Uses what was already
    /// heard when there is some, so it's instant.
    func retimeLyrics() {
        guard !lyrics.isEmpty else { return }
        if lyricsHeard.isEmpty {
            listenForLyrics(retime: true)
            return
        }
        let result = LyricText.retime(lyrics, to: lyricsHeard)
        editLyrics { lyrics = result.words }
        let total = result.words.count
        notice = result.missing == 0
            ? "Re-timed all \(total) words to the singing."
            : "Re-timed \(total - result.missing) of \(total) words. The rest sit between their neighbors."
    }

    /// Typed or pasted words, one lyric line per line. Words that didn't change keep their times;
    /// new ones go between them.
    func setTypedLyrics(_ text: String) {
        let start = lyrics.first?.start ?? lyricsHeard.first?.start ?? 0
        let typed = LyricText.words(fromTyped: text, start: start)
        let next: [LyricWord]
        if typed.isEmpty {
            next = []
        } else if !lyrics.isEmpty {
            next = LyricText.retime(typed, to: lyrics).words
        } else if !lyricsHeard.isEmpty {
            next = LyricText.retime(typed, to: lyricsHeard).words
        } else {
            next = typed
        }
        editLyrics { lyrics = next }
        lyricSelected = nil
        if lyrics.isEmpty { return }
        notice = lyricsHeard.isEmpty
            ? "Words saved. Re-time lines them up with the singing."
            : "Words saved and lined up with what was heard."
    }

    func clearLyrics() {
        editLyrics { lyrics = [] }
        lyricSelected = nil
        tapTiming = false
    }

    /// Picks a word and shows it on the video.
    func selectLyric(_ index: Int) {
        guard lyrics.indices.contains(index) else { return }
        lyricSelected = index
        if tapTiming { tapNext = index }
        pause()
        let word = lyrics[index]
        let at = min(max(0, word.start + min(0.1, (word.end - word.start) / 2)), duration)
        time = at
        requestSeek(at)
    }

    /// Plays from a little before the word.
    func playLyric(_ index: Int) {
        guard lyrics.indices.contains(index) else { return }
        let at = max(0, lyrics[index].start - 0.6)
        time = at
        requestSeek(at)
        play()
    }

    /// Fixes a word. Typing spaces splits it into several words that share its time.
    func setLyricText(_ index: Int, _ text: String) {
        guard lyrics.indices.contains(index) else { return }
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else {
            deleteLyric(index)
            return
        }
        let word = lyrics[index]
        let step = (word.end - word.start) / Double(parts.count)
        var pieces: [LyricWord] = []
        for (i, part) in parts.enumerated() {
            pieces.append(LyricWord(text: part, start: word.start + step * Double(i),
                                    end: word.start + step * Double(i + 1),
                                    br: i == parts.count - 1 ? word.br : false, color: word.color))
        }
        editLyrics { lyrics.replaceSubrange(index...index, with: pieces) }
    }

    /// Moves a word a little earlier or later.
    func nudgeLyric(_ index: Int, by seconds: Double) {
        guard lyrics.indices.contains(index) else { return }
        let shift = max(seconds, -lyrics[index].start)
        editLyrics {
            lyrics[index].start += shift
            lyrics[index].end += shift
        }
        selectLyric(index)
    }

    /// Sets where a word starts or ends to the playhead.
    func setLyricEdge(_ index: Int, start: Bool) {
        guard lyrics.indices.contains(index) else { return }
        let at = playheadFrame
        editLyrics {
            if start {
                let length = max(0.1, lyrics[index].end - lyrics[index].start)
                lyrics[index].start = at
                if lyrics[index].end <= at + 0.04 { lyrics[index].end = at + length }
            } else {
                lyrics[index].end = max(lyrics[index].start + 0.04, at)
            }
        }
    }

    /// Ends the line after this word, or joins it to the next line.
    /// The word the color button works on: the picked word, else the one at the playhead.
    var lyricColorTarget: Int? {
        if let picked = lyricSelected, lyrics.indices.contains(picked) { return picked }
        if let now = lyricNow, lyrics.indices.contains(now) { return now }
        return lyrics.firstIndex { time >= $0.start && time < $0.end }
    }

    /// One word's own color (nil goes back to the look's color).
    func setLyricColor(_ index: Int, _ hex: String?) {
        guard lyrics.indices.contains(index), lyrics[index].color != hex else { return }
        editLyrics { lyrics[index].color = hex }
    }

    func toggleLyricBreak(_ index: Int) {
        guard lyrics.indices.contains(index), index < lyrics.count - 1 else { return }
        editLyrics { lyrics[index].br.toggle() }
    }

    /// Joins a word with the one after it.
    func mergeLyric(_ index: Int) {
        guard lyrics.indices.contains(index), index + 1 < lyrics.count else { return }
        editLyrics {
            let next = lyrics[index + 1]
            lyrics[index].text += " " + next.text
            lyrics[index].end = max(lyrics[index].end, next.end)
            lyrics[index].br = next.br
            lyrics.remove(at: index + 1)
        }
    }

    func deleteLyric(_ index: Int) {
        guard lyrics.indices.contains(index) else { return }
        editLyrics {
            let removed = lyrics.remove(at: index)
            if removed.br, index > 0 { lyrics[index - 1].br = true }
        }
        if lyrics.isEmpty { lyricSelected = nil } else { lyricSelected = min(index, lyrics.count - 1) }
    }

    func setLyricStyle(_ style: LyricStyle) {
        editLyrics { lyricStyle = style }
    }

    func useLyricPreset(_ index: Int) {
        applyLyricLook(lyricStyle.withPreset(index))
    }

    /// Puts on a saved or ready-made look (keeping where the words sit and how big), turns the
    /// lyrics on, and plays the word on screen so you see it.
    func applyLyricLook(_ look: LyricStyle) {
        var next = lyricStyle.taking(look)
        next.show = true
        setLyricStyle(next)
        previewLyricLook()
    }

    /// The edit page's lyrics eye: shows or hides the lyrics on the video (they stay on the timeline).
    func toggleLyricsShown() {
        if lyricStyle.show {
            hideLyrics()
        } else {
            var next = lyricStyle
            next.show = true
            setLyricStyle(next)
        }
    }

    /// Lyrics off (the crossed-out eye). They stay on the timeline.
    func hideLyrics() {
        guard lyricStyle.show else { return endLyricLive() }
        var next = lyricStyle
        next.show = false
        setLyricStyle(next)
    }

    /// Shows a look on the video while a finger is still down (a slider, the words, the look wheel).
    /// Nothing is saved until the finger lifts.
    func showLyricStyleLive(_ style: LyricStyle) {
        stopLookPreview()
        if isPlaying { pause() }
        lyricsLive.update(words: lyrics, style: style)
        if Date().timeIntervalSince(titleRedrawn) > 0.06 {
            titleRedrawn = Date()
            redraw()
        }
    }

    /// A live look let go without a change: back to the saved one.
    func endLyricLive() {
        lyricsLive.update(words: lyrics, style: lyricStyle)
        if !isPlaying { redraw() }
    }

    // MARK: Placing the lyrics on the video

    /// The fingers on the video move the words: on the lyrics page, or with the lyrics picked.
    var lyricsActive: Bool { hasLyrics && (lyricTimeline || (lyricsPicked && lyricStyle.show)) }

    /// Where the words show at the playhead (fractions of the frame from the top left).
    func lyricsBox() -> CGRect? {
        guard hasLyrics, lyricStyle.show else { return nil }
        _ = lyricMoveSpot   // follows a move as it happens
        _ = lyricSizeSpot   // and a resize
        return lyricsLive.lyricsBox(at: playheadFrame, canvas: TimelineBuilder.canvas)
    }

    /// A tap on the words picks them (true), a tap away lets go (false).
    func pickLyrics(_ on: Bool) {
        // Picked even while hidden, so its tools can show them again.
        lyricsPicked = on && hasLyrics
        guard lyricsPicked else { return }
        overlayPick = nil
        editPick = nil
        selected = nil
        guard lyricStyle.show else {
            notice = nil
            return
        }
        // The handles on the video show how to move and size them; no hint needed.
        notice = nil
        showWordForPlacing()
    }

    /// The words' sizes the handles and pinch allow (the same as the size slider).
    static let lyricSizes: ClosedRange<Double> = 60...320

    func beginLyricMove() {
        guard lyricsActive else { return }
        lyricMoveStart = CGPoint(x: lyricStyle.posX, y: lyricStyle.posY)
        lyricSizeStart = lyricStyle.size
        showWordForPlacing()
    }

    /// `move` is how far the finger went, in fractions of the frame; `scale` sizes the words
    /// (a pinch, or a corner handle pulled away from or toward the middle).
    func moveLyrics(_ move: CGSize, scale: Double = 1) {
        guard let start = lyricMoveStart else { return }
        var next = lyricStyle
        if move != .zero || lyricMoveSpot != nil {
            var x = Double(start.x) + Double(move.width) * 100
            var y = Double(start.y) + Double(move.height) * 100
            // Snaps to the middle across and up and down.
            x = abs(x - 50) < 2.5 ? 50 : min(max(x, 10), 90)
            y = abs(y - 50) < 2.5 ? 50 : min(max(y, 8), 92)
            next.posX = x
            next.posY = y
            lyricMoveSpot = CGPoint(x: x, y: y)
        }
        if let size = lyricSizeStart, abs(scale - 1) > 0.001 || lyricSizeSpot != nil {
            let sized = min(max(size * scale, Self.lyricSizes.lowerBound), Self.lyricSizes.upperBound)
            next.size = sized
            lyricSizeSpot = sized
        }
        showLyricStyleLive(next)
    }

    func endLyricMove() {
        if lyricMoveSpot != nil || lyricSizeSpot != nil {
            var next = lyricStyle
            if let spot = lyricMoveSpot {
                next.posX = Double(spot.x)
                next.posY = Double(spot.y)
            }
            if let size = lyricSizeSpot { next.size = size }
            setLyricStyle(next)
        }
        lyricMoveStart = nil
        lyricMoveSpot = nil
        lyricSizeStart = nil
        lyricSizeSpot = nil
    }

    /// So you can see what you're placing: with no word on screen, jumps to the middle of the nearest one.
    func showWordForPlacing() {
        guard lyricNow == nil, lyricStyle.show, !lyrics.isEmpty, player.currentItem != nil else { return }
        stopLookPreview()
        if isPlaying { pause() }
        let now = time
        let nearest = lyrics.min { a, b in
            abs((a.start + a.end) / 2 - now) < abs((b.start + b.end) / 2 - now)
        }
        guard let word = nearest else { return }
        scrub(to: (word.start + word.end) / 2)
    }

    /// Plays the word on screen (or the next one) with the current look, so a tapped animation
    /// shows right away, then goes back to where the playhead was.
    func previewLyricLook() {
        guard !lyrics.isEmpty, player.currentItem != nil else { return }
        let home = previewHome ?? time        // tapping again mid-preview still comes back here
        let index = lyrics.firstIndex(where: { $0.end + lyricStyle.tail >= home }) ?? lyrics.count - 1
        let word = lyrics[index]
        let from = max(0, word.start - 0.35)
        let length = (word.end - from) + min(max(lyricStyle.tail, 0.3), 0.8) + 0.15
        previewTask?.cancel()
        previewHome = home
        player.pause()
        isPlaying = false
        time = from
        updateLyricNow(at: from)
        previewTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.player.seek(to: CMTime(seconds: from, preferredTimescale: 600),
                                       toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            self.stopAtOut = false
            self.player.play()
            self.isPlaying = true
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled else { return }
            self.pause()
            self.previewHome = nil
            self.scrub(to: home)
        }
    }

    /// Any other playback move ends a preview where it is.
    private func stopLookPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewHome = nil
    }

    // Tap to time (Lyric Sync's tap sync): play the song and hold for each word while it's sung.

    func setTapTiming(_ on: Bool) {
        if !on, tapHeld != nil { tapUp() }
        tapTiming = on
        tapHeld = nil
        tapStarted = false
        guard on else { return }
        if let index = lyricSelected {
            tapNext = index
        } else {
            tapNext = lyrics.firstIndex(where: { $0.start >= time - 0.05 }) ?? 0
        }
    }

    func tapDown() {
        guard tapTiming, !lyrics.isEmpty else { return }
        guard isPlaying else {
            // The first press starts the song a moment before the next word.
            let index = min(tapNext, lyrics.count - 1)
            let at = max(0, lyrics[index].start - 2)
            time = at
            requestSeek(at)
            play()
            notice = "Hold the pad while each word is sung, and let go when it ends."
            return
        }
        let at = min(max(0, player.currentTime().seconds), duration)
        if !tapStarted {
            history.append(snapshot())
            tapStarted = true
        }
        if tapHeld != nil { tapUp() }
        let i = tapNext
        guard i < lyrics.count else { return }
        let length = max(0.1, lyrics[i].end - lyrics[i].start)
        lyrics[i].start = at
        if lyrics[i].end <= at { lyrics[i].end = at + length }
        if i > 0, lyrics[i - 1].end > at { lyrics[i - 1].end = max(lyrics[i - 1].start + 0.03, at) }
        tapHeld = i
        tapNext = i + 1
        lyricSelected = i
        lyricsLive.update(words: lyrics, style: lyricStyle)
    }

    func tapUp() {
        guard let i = tapHeld, lyrics.indices.contains(i) else {
            tapHeld = nil
            return
        }
        let at = min(max(0, player.currentTime().seconds), duration)
        lyrics[i].end = max(lyrics[i].start + 0.04, at)
        if i + 1 < lyrics.count, lyrics[i + 1].start < lyrics[i].end, lyrics[i + 1].end > lyrics[i].end + 0.05 {
            lyrics[i + 1].start = lyrics[i].end
        }
        tapHeld = nil
        lyricsLive.update(words: lyrics, style: lyricStyle)
        scheduleSave()
    }

    /// The next word a hold will time (for the pad's label).
    var tapNextWord: String? {
        lyrics.indices.contains(tapNext) ? lyrics[tapNext].text : nil
    }


    // MARK: The lyrics timeline

    /// Swaps the video timeline for the lyrics timeline, or back.
    func setLyricTimeline(_ on: Bool) {
        guard on != lyricTimeline else { return }
        pause()
        if lyricDrag != nil { endLyricDrag() }
        tapTiming = false
        lyricTimeline = on
        lyricSelected = nil
        notice = nil
        if on { select(nil) }
    }

    var lyricHint: String {
        if let drag = lyricDrag, lyrics.indices.contains(drag.index) {
            let word = "\u{201C}\(lyrics[drag.index].text)\u{201D}"
            switch drag.grip {
            case .move: return "Moving \(word)."
            case .trimStart: return "Moving where \(word) starts."
            case .trimEnd: return "Moving where \(word) ends."
            }
        }
        if listening != nil { return "Listening for the words…" }
        if lyrics.isEmpty { return "No words yet. Listen to the song, or type the words." }
        if let index = lyricSelected, lyrics.indices.contains(index) {
            return "Drag the picked word's ends to stretch it. Hold any word to move it."
        }
        return "Tap a word to pick it. Hold a word to move it. Pinch to zoom."
    }

    /// Starts moving a word (`.move`) or one of its ends.
    func beginLyricDrag(_ index: Int, grip: Grip) {
        guard lyrics.indices.contains(index), lyricDrag == nil else { return }
        pause()
        lyricDragStart = (state: snapshot(), word: lyrics[index])
        lyricDrag = (index: index, grip: grip)
        lyricSelected = index
    }

    /// The finger has moved this many seconds since the drag began. Words keep their order.
    func dragLyric(by seconds: Double) {
        guard let drag = lyricDrag, let start = lyricDragStart, lyrics.indices.contains(drag.index) else { return }
        let i = drag.index
        let word = start.word
        let floor = i > 0 ? lyrics[i - 1].start + 0.03 : 0
        let ceiling = i + 1 < lyrics.count ? lyrics[i + 1].start - 0.03 : duration
        let minimum = 0.05
        switch drag.grip {
        case .move:
            let length = word.end - word.start
            let begin = min(max(word.start + seconds, floor), max(floor, ceiling))
            lyrics[i].start = begin
            lyrics[i].end = begin + length
        case .trimStart:
            lyrics[i].start = min(max(word.start + seconds, floor), word.end - minimum)
        case .trimEnd:
            let limit = i + 1 < lyrics.count ? lyrics[i + 1].end - minimum : duration
            lyrics[i].end = min(max(word.end + seconds, word.start + minimum), max(word.start + minimum, limit))
        }
        lyricsLive.update(words: lyrics, style: lyricStyle)
    }

    func endLyricDrag() {
        guard let start = lyricDragStart else {
            lyricDrag = nil
            return
        }
        lyricDragStart = nil
        lyricDrag = nil
        guard lyrics != start.state.lyrics else { return }
        history.append(start.state)
        syncLyrics()
        scheduleSave()
    }

    /// Picks a word on the lyrics timeline (nil lets go). The video shows that word.
    func pickLyric(_ index: Int?) {
        guard let index, lyrics.indices.contains(index) else {
            lyricSelected = nil
            return
        }
        selectLyric(index)
    }

    /// Adds a word at the playhead, between the words around it.
    func addLyric(_ text: String) {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return }
        let at = playheadFrame
        let index = lyrics.firstIndex(where: { $0.start > at }) ?? lyrics.count
        let room = index < lyrics.count ? lyrics[index].start - at : 0.4 * Double(parts.count)
        let step = max(0.08, min(0.4, room / Double(parts.count)))
        var added: [LyricWord] = []
        for (i, part) in parts.enumerated() {
            added.append(LyricWord(text: part, start: at + step * Double(i), end: at + step * Double(i) + step * 0.9))
        }
        editLyrics {
            if index > 0, lyrics[index - 1].end > at { lyrics[index - 1].end = max(lyrics[index - 1].start + 0.05, at) }
            lyrics.insert(contentsOf: added, at: index)
        }
        lyricSelected = index
    }

    /// Splits a word holding several words ("let it") into one block each.
    func splitLyric(_ index: Int) {
        guard lyrics.indices.contains(index) else { return }
        setLyricText(index, lyrics[index].text)
    }

    func canSplitLyric(_ index: Int) -> Bool {
        lyrics.indices.contains(index) && lyrics[index].text.split(whereSeparator: { $0.isWhitespace }).count > 1
    }

    // MARK: Titles and text

    func title(_ id: UUID) -> TitleClip? { titles.first { $0.id == id } }

    /// Lit when a text shows at the playhead.
    var hasTitleAtPlayhead: Bool { titles.contains { time >= $0.start && time < $0.end } }

    /// The Text button: opens the text at the playhead, or adds a new one there (3 seconds, on the
    /// first text lane with room, or a new lane if there's room for one).
    func textButton() {
        pause()
        draft = nil
        if let here = titles.filter({ time >= $0.start && time < $0.end }).min(by: { $0.lane < $1.lane }) {
            openTitle(here.id)
        } else {
            addTitle()
        }
    }

    /// Adds a text at the playhead and opens it.
    func addTitle() {
        pause()
        draft = nil
        guard duration > 0.5 else { return }
        // The open one is finished first (an empty one goes away, which can free a lane).
        let wasOpen = titleEditing
        closeTitleEdit()
        let frame = 1.0 / 30
        var start = (min(max(0, time), duration) * 30).rounded() / 30
        if duration - start < 1 { start = max(0, duration - 3) }
        var end = min(start + 3, duration)
        var lane: Int?
        for candidate in 0..<textLaneCount {
            let here = titles.filter { $0.lane == candidate }
            guard !here.contains(where: { $0.start <= start + 1e-6 && $0.end > start + 1e-6 }) else { continue }
            let next = here.filter { $0.start > start }.map(\.start).min() ?? duration
            if next - start >= 1 {
                lane = candidate
                end = min(end, next)
                break
            }
        }
        if lane == nil {
            guard laneCount < Self.maxLayers else {
                notice = "\(Self.maxLayers) lanes is the most (videos and text together). Put this text where another text isn't."
                if let wasOpen, title(wasOpen) != nil { openTitle(wasOpen) }
                return
            }
            lane = textLaneCount
        }
        guard let picked = lane, end - start >= frame else { return }
        history.append(snapshot())
        let clip = TitleClip(start: start, end: end, lane: picked)
        titles.append(clip)
        notice = nil
        syncTitles()
        titleEditStart = snapshot()
        titleEditing = clip.id
    }

    /// Opens a text's sheet (a tap on its clip, or the Text button over it).
    func openTitle(_ id: UUID) {
        guard title(id) != nil else { return }
        pause()
        if titleEditing != id { closeTitleEdit() }
        if titleEditStart == nil { titleEditStart = snapshot() }
        titleEditing = id
        notice = nil
    }

    /// The sheet closed: all its changes are one Undo step. Empty text is taken away.
    func endTitleEdit() {
        closeTitleEdit()
    }

    private func closeTitleEdit() {
        if let id = titleEditing, let clip = title(id),
           clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titles.removeAll { $0.id == id }
            packTextLanes()
            syncTitles()
        }
        if let start = titleEditStart, start.titles != titles { history.append(start) }
        titleEditStart = nil
        titleEditing = nil
    }

    /// Changes one text. Inside its open sheet, the changes add up to one Undo step.
    func editTitle(_ id: UUID, _ change: (inout TitleClip) -> Void) {
        guard let index = titles.firstIndex(where: { $0.id == id }) else { return }
        var next = titles[index]
        change(&next)
        next.posX = min(max(next.posX, 2), 98)
        next.posY = min(max(next.posY, 2), 98)
        guard next != titles[index] else { return }
        if titleEditStart == nil { history.append(snapshot()) }
        titles[index] = next
        syncTitles()
    }

    /// Moving a text on the video with a finger: follows live, redrawn a few times a second.
    func placeTitle(_ id: UUID, x: Double, y: Double) {
        guard let index = titles.firstIndex(where: { $0.id == id }) else { return }
        pause()
        if titleEditStart == nil { titleEditStart = snapshot() }
        // Snaps to the middle across and up and down.
        titles[index].posX = abs(x - 50) < 2.5 ? 50 : min(max(x, 2), 98)
        titles[index].posY = abs(y - 50) < 2.5 ? 50 : min(max(y, 2), 98)
        lyricsLive.update(titles: titles)
        if Date().timeIntervalSince(titleRedrawn) > 0.06 {
            titleRedrawn = Date()
            redraw()
        }
    }

    func placeTitleEnded() {
        syncTitles()
    }

    func deleteTitle(_ id: UUID) {
        guard title(id) != nil else { return }
        let before = titleEditStart ?? snapshot()
        titleEditStart = nil
        if titleEditing == id { titleEditing = nil }
        titles.removeAll { $0.id == id }
        packTextLanes()
        history.append(before)
        notice = "Text deleted. Undo brings it back."
        syncTitles()
    }

    /// Starts moving a text clip (`.move`) or one of its ends on the timeline.
    func beginTitleDrag(_ id: UUID, grip: Grip) {
        guard let clip = title(id), titleDrag == nil else { return }
        pause()
        draft = nil
        // Inside an open sheet the drag joins the sheet's Undo step.
        titleDragStart = (state: titleEditStart == nil ? snapshot() : nil, clip: clip)
        titleDrag = (id: id, grip: grip)
        notice = nil
    }

    /// The finger has moved this many seconds since the drag began. A text stays inside its lane's
    /// gap, between the texts before and after it.
    func dragTitle(by seconds: Double) {
        guard let drag = titleDrag, let start = titleDragStart?.clip,
              let index = titles.firstIndex(where: { $0.id == drag.id }) else { return }
        let others = titles.filter { $0.lane == start.lane && $0.id != start.id }
        let floor = others.filter { $0.end <= start.start + 1e-6 }.map(\.end).max() ?? 0
        let ceiling = others.filter { $0.start >= start.end - 1e-6 }.map(\.start).min() ?? duration
        let shortest = 0.2
        func snap(_ value: Double) -> Double { (value * 30).rounded() / 30 }
        switch drag.grip {
        case .move:
            let length = start.end - start.start
            let begin = min(max(snap(start.start + seconds), floor), max(floor, ceiling - length))
            titles[index].start = begin
            titles[index].end = begin + length
        case .trimStart:
            titles[index].start = min(max(snap(start.start + seconds), floor), start.end - shortest)
        case .trimEnd:
            titles[index].end = min(max(snap(start.end + seconds), start.start + shortest), ceiling)
        }
        lyricsLive.update(titles: titles)
    }

    func endTitleDrag() {
        defer {
            titleDrag = nil
            titleDragStart = nil
        }
        guard let begun = titleDragStart else { return }
        if let state = begun.state, state.titles != titles { history.append(state) }
        syncTitles()
    }

    /// "Moving where your text starts." for the hint line while a text clip is held.
    var titleHint: String? {
        guard let drag = titleDrag, let clip = title(drag.id) else { return nil }
        let name = "\u{201C}\(clip.label)\u{201D}"
        switch drag.grip {
        case .move: return "Moving \(name)."
        case .trimStart: return "Moving where \(name) starts."
        case .trimEnd: return "Moving where \(name) ends."
        }
    }

    /// Text lanes stay T1, T2, ... with none left empty.
    private func packTextLanes() {
        let used = Array(Set(titles.map(\.lane))).sorted()
        for index in titles.indices {
            titles[index].lane = used.firstIndex(of: titles[index].lane) ?? 0
        }
    }

    private func resetTitleEditing() {
        titleEditing = nil
        titleEditStart = nil
        titleDrag = nil
        titleDragStart = nil
    }

    /// Hands the text to the player. Paused, the frame is drawn again right away.
    private func syncTitles() {
        lyricsLive.update(titles: titles)
        guard stage == .editing else { return }
        if isPlaying { scheduleSave() } else { redraw() }
    }

    // MARK: Framing and keyframes

    /// Swap in new cuts or framing and, when paused, draw the frame at the playhead again.
    private func redraw() {
        refreshCuts()
        if !isPlaying { requestSeek(time) }
    }

    /// What the fingers on the video and the + diamond frame: the video on screen at the playhead
    /// (its index, if it has footage there), or on a performance's edit page the whole performance
    /// track (`wholeTrack`) when it's picked. A performance's own videos are framed on its own page.
    private var framedLayer: Int? {
        guard videoFramingHere else { return trackPicked ? Self.wholeTrack : nil }
        guard let index = showing, hasFootage(index, at: playheadFrame) else { return nil }
        return index
    }

    /// `framedLayer` for the whole performance track.
    static let wholeTrack = -1

    /// False on a performance's edit page: there the + diamond and the fingers on the video work on
    /// what's picked (the whole performance track, an overlay, a mask), never on one of its videos.
    var videoFramingHere: Bool { kind != .performance || performancePage }

    /// The whole performance track is picked on the edit page (it's what gets framed and keyframed).
    var trackPicked: Bool {
        kind == .performance && !performancePage && editPick == 0 && overlayPick == nil
    }

    /// The keyframes being framed: a video's (in its own time) or the whole track's (timeline time).
    private func frameKeys(_ index: Int) -> [Keyframe] {
        index == Self.wholeTrack ? trackKeys : layers[index].keyframes
    }

    /// Where a framed thing's keyframe time 0 sits on the timeline.
    private func frameOffset(_ index: Int) -> Double {
        index == Self.wholeTrack ? 0 : layers[index].offset
    }

    private func setFrameKeys(_ index: Int, _ keys: [Keyframe]) {
        if index == Self.wholeTrack { trackKeys = keys } else { layers[index].keyframes = keys }
    }

    private func frameName(_ index: Int) -> String {
        index == Self.wholeTrack ? "the performance" : "video \(index + 1)"
    }

    /// Auto zoom only works inside the cuts, so it doesn't count when framing the whole track.
    private var frameZoomHere: Double {
        framedLayer == Self.wholeTrack ? 1 : zoomFactorHere
    }

    /// The top overlay showing at the playhead under a point on the video (fractions of the frame
    /// from the top left), or the top one showing at all when `point` is nil.
    func overlayAt(_ point: CGPoint?) -> UUID? {
        let at = playheadFrame
        for overlay in overlays.reversed() where !overlay.hidden && at >= overlay.start && at < overlay.end {
            guard let point else { return overlay.id }
            if let box = overlayBox(overlay.id), box.insetBy(dx: -0.03, dy: -0.03).contains(point) {
                return overlay.id
            }
        }
        return nil
    }

    /// The cut (an index into `cuts`) the playhead is in.
    private var cutAtPlayhead: Int? {
        cuts.lastIndex(where: { $0.time <= playheadFrame + 1e-6 })
    }

    /// The auto zoom of the cut the playhead is in.
    var zoomHere: AutoZoom {
        fxIndex.map { cuts[$0].zoom } ?? .off
    }

    /// How much auto zoom is adding right now (1 = none).
    private var zoomFactorHere: Double {
        guard let index = cutAtPlayhead else { return 1 }
        let start = cuts[index].time
        let end = index + 1 < cuts.count ? cuts[index + 1].time : duration
        guard end - start > 0.05 else { return 1 }
        return cuts[index].zoom.factor((playheadFrame - start) / (end - start))
    }

    /// Turns the slow zoom on or off for the cut the playhead is in.
    func setZoomHere(_ zoom: AutoZoom) {
        guard let index = fxIndex, cuts[index].zoom != zoom else { return }
        pause()
        history.append(snapshot())
        cuts[index].zoom = zoom
        notice = zoom == .off ? "Auto zoom off for this cut." : "\(zoom.name) on this cut. Each cut has its own."
        redraw()
    }

    // MARK: Effects and transitions

    /// The cut the effects sheet works on, fixed while the sheet is open so playing doesn't move it.
    var fxTarget: Int?

    /// Picks the cut at the playhead for the effects sheet. False when there's no cut there.
    func beginFX() -> Bool {
        pause()
        draft = nil
        fxTarget = cutAtPlayhead
        return fxTarget != nil
    }

    func endFX() {
        fxTarget = nil
    }

    private var fxIndex: Int? {
        guard let index = fxTarget ?? cutAtPlayhead, cuts.indices.contains(index) else { return nil }
        return index
    }

    /// "Cut 3 of 12" for the sheet.
    var fxCutName: String {
        guard let index = fxIndex else { return "" }
        return "Cut \(index + 1) of \(cuts.count)"
    }

    /// The first cut has nothing before it to come in from.
    var canTransitionHere: Bool { (fxIndex ?? 0) > 0 }

    var transitionHere: Transition {
        fxIndex.flatMap { cuts[$0].transition } ?? Transition()
    }

    var fxHere: CutFX {
        fxIndex.flatMap { cuts[$0].fx } ?? CutFX()
    }

    /// True when the cut at the playhead has a transition or any effect (lights the FX button).
    var hasFXAtPlayhead: Bool {
        guard let index = cutAtPlayhead else { return false }
        let cut = cuts[index]
        return (cut.transition?.kind ?? .none) != .none || !(cut.fx?.isEmpty ?? true)
    }

    func setTransitionHere(_ transition: Transition) {
        let next: Transition? = transition.kind == .none ? nil : transition
        guard let index = fxIndex, index > 0, cuts[index].transition != next else { return }
        pause()
        history.append(snapshot())
        cuts[index].transition = next
        redraw()
    }

    func setFXHere(_ fx: CutFX) {
        guard let index = fxIndex, (cuts[index].fx ?? CutFX()) != fx else { return }
        pause()
        history.append(snapshot())
        cuts[index].fx = fx == CutFX() ? nil : fx
        redraw()
    }

    /// Takes every effect and the transition off this cut (keeps what face it found).
    func clearFXHere() {
        guard let index = fxIndex else { return }
        var cleared = CutFX()
        cleared.faces = cuts[index].fx?.faces ?? []
        cleared.facesLayer = cuts[index].fx?.facesLayer
        let next: CutFX? = cleared == CutFX() ? nil : cleared
        guard cuts[index].fx != next || cuts[index].transition != nil else { return }
        pause()
        history.append(snapshot())
        cuts[index].fx = next
        cuts[index].transition = nil
        redraw()
    }

    /// Puts this cut's transition and effects on every cut. Face follow only goes where a face
    /// was already found, since each cut has its own face.
    func useFXOnEveryCut() {
        guard let index = fxIndex else { return }
        let source = cuts[index].fx ?? CutFX()
        let transition = cuts[index].transition
        pause()
        history.append(snapshot())
        for i in cuts.indices {
            var fx = source
            fx.faces = cuts[i].fx?.faces ?? []
            fx.facesLayer = cuts[i].fx?.facesLayer
            fx.followFace = source.followFace && !fx.faces.isEmpty && fx.facesLayer == cuts[i].layer
            cuts[i].fx = fx == CutFX() ? nil : fx
            if i > 0, index > 0 { cuts[i].transition = transition }
        }
        notice = "Every cut has these effects now. Undo takes it back."
        redraw()
    }

    /// Plays from just before the cut, so its transition shows.
    func playCutHere() {
        guard let index = fxIndex else { return }
        let lead = (cuts[index].transition?.kind ?? .none) != .none ? 1.0 : 0
        let start = max(0, cuts[index].time - lead)
        time = start
        requestSeek(start)
        play()
    }

    /// Finds the face in this cut and keeps it centered. Off takes face follow away.
    func followFaceHere(_ on: Bool) async {
        guard let index = fxIndex else { return }
        var fx = cuts[index].fx ?? CutFX()
        guard on else {
            fx.followFace = false
            setFXHere(fx)
            return
        }
        let start = cuts[index].time
        let end = index + 1 < cuts.count ? cuts[index + 1].time : duration
        let middle = (start + end) / 2
        let shown = hasFootage(cuts[index].layer, at: middle)
            ? cuts[index].layer
            : segments.first(where: { middle >= $0.start && middle < $0.end })?.layer
        guard let shown, layers.indices.contains(shown), let range = layers[shown].footage(in: duration) else {
            notice = "There's no video in this cut to follow."
            return
        }
        // Already found on this video: just turn it on.
        if fx.facesLayer == shown, !fx.faces.isEmpty {
            fx.followFace = true
            setFXHere(fx)
            return
        }
        guard busy == nil else { return }
        pause()
        let layer = layers[shown]
        let job = FaceJob(asset: layer.asset, trackStart: layer.trackStart, offset: layer.offset,
                          from: max(range.lowerBound, start - 0.5), to: min(range.upperBound, end + 0.5))
        let cutTime = cuts[index].time
        busy = "Finding the face…"
        let points = await FaceTracker.track(job)
        busy = nil
        // The cuts may have changed while it looked.
        guard cuts.indices.contains(index), abs(cuts[index].time - cutTime) < 1e-6 else { return }
        guard !points.isEmpty else {
            notice = "No face found in this cut."
            return
        }
        history.append(snapshot())
        var found = cuts[index].fx ?? CutFX()
        found.faces = points
        found.facesLayer = shown
        found.followFace = true
        cuts[index].fx = found
        notice = "Following the face in this cut."
        redraw()
    }

    /// The keyframed framing (without auto zoom) of the video on screen, at the playhead.
    private var framingHere: Framing? {
        guard let index = framedLayer else { return nil }
        return Keyframes.framing(frameKeys(index), at: playheadFrame - frameOffset(index))
    }

    /// A framing pinched or dragged into place but not kept yet. Tap Set keyframe to keep it.
    /// It only counts while the playhead stays on the same frame of the same video.
    struct FramingDraft: Equatable {
        let layer: Int
        let time: Double
        let framing: Framing
    }
    var draft: FramingDraft?

    /// The draft, if it still belongs to the frame at the playhead.
    private var draftHere: FramingDraft? {
        guard let draft, draft.layer == framedLayer, abs(draft.time - playheadFrame) < 0.5 / 30 else { return nil }
        return draft
    }

    /// True while there's a framing waiting for Set keyframe.
    var hasDraft: Bool { draftHere != nil }

    /// How to show the picture on top of what's rendered: the draft (if any), plus a pinch or drag
    /// that's still going. Held inside the frame so it never shows black edges. `shift` is in
    /// fractions of the frame.
    func framingPreview(scale: Double, shift: CGSize) -> (scale: Double, shift: CGSize) {
        guard let rendered = framingHere else { return (1, .zero) }
        let zoom = frameZoomHere
        let shown = rendered.zoomed(zoom)
        let from = (draftHere?.framing ?? rendered).zoomed(zoom)
        let wanted = Framing(scale: from.scale * scale,
                             x: from.x * scale + Double(shift.width),
                             y: from.y * scale + Double(shift.height))
        let held = wanted.zoomed(1 / zoom).clamped().zoomed(zoom)
        let applied = held.scale / shown.scale
        return (applied, CGSize(width: held.x - shown.x * applied, height: held.y - shown.y * applied))
    }

    /// A pinch or drag on the video finished: hold the new framing as a draft. Nothing is kept
    /// until Set keyframe.
    func stageFraming(scale: Double, shift: CGSize) {
        guard abs(scale - 1) > 0.002 || abs(shift.width) > 0.001 || abs(shift.height) > 0.001 else { return }
        guard let index = framedLayer, let rendered = framingHere else {
            notice = "No video at the playhead to frame."
            return
        }
        let zoom = frameZoomHere
        let from = (draftHere?.framing ?? rendered).zoomed(zoom)
        let wanted = Framing(scale: from.scale * scale,
                             x: from.x * scale + Double(shift.width),
                             y: from.y * scale + Double(shift.height))
        draft = FramingDraft(layer: index, time: playheadFrame, framing: wanted.zoomed(1 / zoom).clamped())
        notice = "Tap the + diamond to keep this. Moving the playhead first throws it away."
    }

    /// Keeps the framing on screen (the draft, or the current framing) as a keyframe at the playhead.
    /// The first keyframe sets the framing for the whole clip; more keyframes animate between them.
    /// It keyframes whatever is picked: the mask while Mask is open, the picked overlay, the whole
    /// performance track (picked on the edit page), or the video on screen.
    func setKeyframe() {
        // On a keyframe with nothing new to keep: the + diamond takes it off (a toggle).
        if keyframeOnHere {
            deleteKeyframeHere()
            return
        }
        if maskEditing {
            setMaskKey()
            return
        }
        if overlayPick != nil {
            setOverlayKey()
            return
        }
        if !videoFramingHere, !trackPicked {
            notice = "Pick what to keyframe first: tap the performance or an overlay on the timeline, or touch it on the video."
            return
        }
        guard let index = framedLayer, let rendered = framingHere else {
            notice = "No video at the playhead to keyframe."
            return
        }
        let framing = draftHere?.framing ?? rendered
        draft = nil
        history.append(snapshot())
        let at = playheadFrame - frameOffset(index)
        var keys = frameKeys(index)
        if let same = keys.firstIndex(where: { abs($0.time - at) < 0.5 / 30 }) {
            keys[same].framing = framing
        } else {
            keys.append(Keyframe(time: at, framing: framing))
            keys.sort { $0.time < $1.time }
        }
        setFrameKeys(index, keys)
        notice = keys.count == 1
            ? "Keyframe set on \(frameName(index)). Move the playhead, frame it again and set another to animate."
            : "Keyframe \(keys.count) on \(frameName(index)) at \(Self.clock(playheadFrame))."
        redraw()
    }

    /// The playhead sits on a keyframe of what's picked, with no new framing waiting: the + diamond
    /// would take that keyframe off.
    var keyframeOnHere: Bool { keyframeHere != nil && !hasDraft }

    /// A tap near a keyframe's diamond on the timeline: picks what it belongs to and puts the
    /// playhead on it, so the + diamond can take it off. `overlay` nil is the whole performance.
    func pickKeyframe(overlay id: UUID?, at seconds: Double, mask: Bool = false) {
        pause()
        if let id { pickOverlay(id) } else { pickOnEdit(0) }
        draft = nil
        time = min(max(0, seconds), timelineEnd)
        requestSeek(time)
        notice = mask
            ? "Mask keyframe. Open Mask, then tap the diamond to take it off."
            : "Keyframe picked. Tap the diamond beside the video to take it off."
    }

    /// Throws the draft away.
    func discardDraft() {
        draft = nil
        notice = nil
    }

    /// The keyframe of the video on screen sitting at the playhead (within a frame), if any.
    var keyframeHere: Int? {
        if let id = overlayPick {
            let list = maskEditing ? SavedOverlay.maskKeyList : SavedOverlay.placeKeys
            return overlay(id)?.keyIndex(list, at: playheadFrame)
        }
        guard let index = framedLayer else { return nil }
        let at = playheadFrame - frameOffset(index)
        return frameKeys(index).firstIndex { abs($0.time - at) < 0.5 / 30 }
    }

    /// Keyframe count of the video on screen.
    var keyframeCountHere: Int {
        if maskEditing { return maskKeyCount }
        if let id = overlayPick { return overlay(id)?.keys?.count ?? 0 }
        return framedLayer.map { frameKeys($0).count } ?? 0
    }

    /// How the keyframe at (or just before) the playhead moves on to the next one.
    var easeHere: Ease? {
        if let id = overlayPick, let overlay = overlay(id) {
            let at = playheadFrame - overlay.keyOrigin
            let keys = maskEditing ? overlay.maskKeys : overlay.keys
            return keys?.last(where: { $0.time <= at + 0.5 / 30 })?.ease
        }
        guard let index = framedLayer else { return nil }
        let at = playheadFrame - frameOffset(index)
        return frameKeys(index).last(where: { $0.time <= at + 0.5 / 30 })?.ease
    }

    func setEaseHere(_ ease: Ease) {
        if let id = overlayPick {
            let list = maskEditing ? SavedOverlay.maskKeyList : SavedOverlay.placeKeys
            changeOverlayKeys(id) { overlay, at in
                let local = at - overlay.keyOrigin
                guard let key = overlay[keyPath: list]?.lastIndex(where: { $0.time <= local + 0.5 / 30 }) else {
                    return nil
                }
                overlay[keyPath: list]?[key].ease = ease
                return "\(ease.name) from this keyframe to the next."
            }
            return
        }
        guard let index = framedLayer else { return }
        let at = playheadFrame - frameOffset(index)
        var keys = frameKeys(index)
        guard let key = keys.lastIndex(where: { $0.time <= at + 0.5 / 30 }) else { return }
        history.append(snapshot())
        keys[key].ease = ease
        setFrameKeys(index, keys)
        notice = "\(ease.name) from this keyframe to the next."
        redraw()
    }

    func deleteKeyframeHere() {
        if maskEditing {
            deleteMaskKeyHere()
            return
        }
        if let id = overlayPick {
            changeOverlayKeys(id) { overlay, at in
                guard let key = overlay.keyIndex(at: at) else { return nil }
                let shown = overlay.posed(at: at)
                overlay.keys?.remove(at: key)
                // The last keyframe gone: it stays as it showed, all the way through.
                if overlay.keys?.isEmpty == true {
                    overlay = shown
                    overlay.keys = nil
                }
                return "Keyframe deleted."
            }
            return
        }
        guard let index = framedLayer, let key = keyframeHere else { return }
        history.append(snapshot())
        var keys = frameKeys(index)
        keys.remove(at: key)
        setFrameKeys(index, keys)
        notice = "Keyframe deleted."
        redraw()
    }

    /// Takes all zoom and position off the video on screen.
    func resetFramingHere() {
        if maskEditing {
            clearMaskKeys()
            return
        }
        if let id = overlayPick {
            changeOverlayKeys(id) { overlay, at in
                guard overlay.keys?.isEmpty == false else { return nil }
                overlay = overlay.posed(at: at)
                overlay.keys = nil
                return "Keyframes taken off. The overlay stays as it shows here."
            }
            return
        }
        guard let index = framedLayer, !frameKeys(index).isEmpty else { return }
        history.append(snapshot())
        setFrameKeys(index, [])
        notice = index == Self.wholeTrack ? "The performance fills the frame again." : "Video \(index + 1) fills the frame again."
        redraw()
    }

    /// Moves the playhead to the previous or next keyframe of the video on screen.
    func jumpToKeyframe(forward: Bool) {
        if maskEditing {
            jumpToMaskKey(forward: forward)
            return
        }
        let times: [Double]
        if let id = overlayPick {
            guard let overlay = overlay(id) else { return }
            times = (overlay.keys ?? []).map { $0.time + overlay.keyOrigin }
        } else {
            guard let index = framedLayer else { return }
            let offset = frameOffset(index)
            times = frameKeys(index).map { $0.time + offset }
        }
        pause()
        let now = playheadFrame
        let target = forward ? times.first(where: { $0 > now + 0.5 / 30 }) : times.last(where: { $0 < now - 0.5 / 30 })
        guard let target else {
            notice = forward ? "No later keyframe." : "No earlier keyframe."
            return
        }
        time = min(max(0, target), timelineEnd)
        requestSeek(time)
    }

    // MARK: Overlay keyframes

    /// Keeps the picked overlay as it shows at the playhead as a keyframe: its place and size
    /// (the side + diamond), or its mask (Keyframe in the Mask panel). Nothing animates until the
    /// first one; after it, each change to that part makes or updates the keyframe at the playhead.
    private func setOverlayKey(_ list: SavedOverlay.KeyList = SavedOverlay.placeKeys) {
        guard let id = overlayPick else { return }
        let mask = list == SavedOverlay.maskKeyList
        changeOverlayKeys(id) { overlay, at in
            guard at >= overlay.start - 0.5 / 30, at <= overlay.end + 0.5 / 30 else {
                return "Move the playhead over this overlay to keyframe it."
            }
            overlay = overlay.addingKey(list, overlay.posed(at: at).pose, at: at)
            let count = overlay[keyPath: list]?.count ?? 0
            let what = mask ? "the mask" : "the overlay"
            return count == 1
                ? "Keyframing \(what) from here. Move the playhead and change it: each change makes a keyframe there."
                : "Keyframe \(count) on \(what) at \(Self.clock(at))."
        }
    }

    // The mask's own keyframes, for the Mask panel.

    func setMaskKey() { setOverlayKey(SavedOverlay.maskKeyList) }

    var maskKeyHere: Bool {
        guard let id = overlayPick else { return false }
        return overlay(id)?.keyIndex(SavedOverlay.maskKeyList, at: playheadFrame) != nil
    }

    var maskKeyCount: Int {
        overlayPick.flatMap { overlay($0)?.maskKeys?.count } ?? 0
    }

    func deleteMaskKeyHere() {
        guard let id = overlayPick else { return }
        changeOverlayKeys(id) { overlay, at in
            guard let key = overlay.keyIndex(SavedOverlay.maskKeyList, at: at) else { return nil }
            let shown = overlay.posed(at: at)
            overlay.maskKeys?.remove(at: key)
            // The last one gone: the mask stays as it showed here, all the way through.
            if overlay.maskKeys?.isEmpty == true {
                overlay = shown
                overlay.maskKeys = nil
                return "The mask isn't animated any more."
            }
            return "Mask keyframe deleted."
        }
    }

    /// Stops animating the mask: it stays as it shows at the playhead, all the way through.
    func clearMaskKeys() {
        guard let id = overlayPick else { return }
        changeOverlayKeys(id) { overlay, at in
            guard overlay.maskKeys?.isEmpty == false else { return nil }
            overlay = overlay.posed(at: at)
            overlay.maskKeys = nil
            return "The mask isn't animated any more."
        }
    }

    func jumpToMaskKey(forward: Bool) {
        guard let id = overlayPick, let overlay = overlay(id) else { return }
        pause()
        let times = (overlay.maskKeys ?? []).map { $0.time + overlay.keyOrigin }
        let now = playheadFrame
        let target = forward ? times.first(where: { $0 > now + 0.5 / 30 }) : times.last(where: { $0 < now - 0.5 / 30 })
        guard let target else {
            notice = forward ? "No later mask keyframe." : "No earlier mask keyframe."
            return
        }
        time = min(max(0, target), timelineEnd)
        requestSeek(time)
    }

    /// Changes an overlay's keyframes as one Undo step. `change` returns the notice, or nil when
    /// there's nothing to change.
    private func changeOverlayKeys(_ id: UUID, _ change: (inout SavedOverlay, Double) -> String?) {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        pause()
        let before = snapshot()
        var next = overlays[index]
        guard let message = change(&next, playheadFrame) else { return }
        notice = message
        guard next != overlays[index] else { return }
        // While the Mask panel is open its changes are already one Undo step.
        if overlayEditStart == nil {
            history.append(before)
            future = []
        }
        overlays[index] = next
        overlayBoard.place(next)
        scheduleSave()
        redraw()
    }

    // MARK: In and out

    /// Where the playhead is right now, on a whole frame.
    private var playheadFrame: Double {
        let at = isPlaying ? min(max(0, player.currentTime().seconds), timelineEnd) : time
        return min(max(0, (at * 30).rounded() / 30), timelineEnd)
    }

    /// Marks where the export starts. If that's past Out, Out goes back to the end of the song.
    func setIn() {
        defer { scheduleSave() }
        let at = playheadFrame
        inPoint = at
        if outPoint - at < 0.5 { outPoint = duration }
        notice = rangeNote(start: "Start")
        updateLoop()
    }

    /// Marks where the export ends. If that's before In, In goes back to the start of the song.
    func setOut() {
        defer { scheduleSave() }
        let at = playheadFrame
        guard at > 0.5 else {
            notice = "Move the playhead later before setting End."
            return
        }
        outPoint = at
        if at - inPoint < 0.5 { inPoint = 0 }
        notice = rangeNote(start: "End")
        updateLoop()
    }

    /// Export the whole song again.
    func clearInOut() {
        defer { scheduleSave() }
        inPoint = 0
        outPoint = duration
        notice = nil
        updateLoop()
    }

    private func rangeNote(start: String) -> String {
        "\(start) set. Export: \(Self.clock(inPoint)) to \(Self.clock(outPoint)) (\(Self.length(outPoint - inPoint)))."
    }

    /// "30 seconds", "1:05".
    static func length(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole) seconds" : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: Exporting

    /// Renders the edit (the real cuts, never a preview) to a 1080 x 1920, 30 fps video and saves it
    /// to Photos. That one file fits Reels, TikTok and Shorts. Without sound, the song can be added
    /// inside Instagram or TikTok instead.
    func startExport(withSound: Bool) {
        guard let built, duration > 0 else { return }
        if case .working = exportState { return }
        pause()
        // Stops before it starts when the phone is too full to hold the video.
        let needs = Disk.exportNeeds(seconds: loopEnd - loopStart)
        guard Disk.hasRoom(for: needs) else {
            exportState = .failed("Not enough space on your iPhone. This video needs about \(Disk.describe(needs)) free. Free some up in Settings > General > iPhone Storage, then export again.")
            return
        }
        // The edit page's switches count: muted sound exports silent, hidden video exports black
        // under the overlays, text and lyrics.
        let withSound = withSound && !soundMuted
        let source: TimelineBuilder.Built
        do {
            if withSound {
                source = built
            } else {
                // Built again without the song, so the file has no sound at all.
                source = try TimelineBuilder.build(layers: layers, soundtrack: nil, duration: duration,
                                                   length: timelineEnd, overlays: overlays, media: overlayMedia)
            }
        } catch {
            exportState = .failed(EditorError.explain(error))
            return
        }
        guard let session = AVAssetExportSession(asset: source.composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            exportState = .failed("This phone can't export that video.")
            return
        }
        let cutsOnly = Program.segments(cuts: cuts, layers: layers, duration: duration)
        // Its own copy of where the overlays sit, so moving one during the export changes nothing.
        let board = OverlayBoard()
        board.update(overlays, media: overlayMedia, track: trackKeys)
        let words = LyricsOverlay(words: lyrics, style: lyricStyle, titles: titles)
        words.setVideoHidden(videoHidden)
        session.videoComposition = TimelineBuilder.videoComposition(segments: cutsOnly, built: source,
                                                                     cuts: cuts, layers: layers, duration: duration,
                                                                     length: timelineEnd, lyrics: words,
                                                                     overlays: overlays, media: overlayMedia, board: board)
        session.shouldOptimizeForNetworkUse = true
        // Only the part between Start and End, plus any clips added after the performance.
        let start = loopStart
        let end = max(start + 1.0 / 30, min(loopEnd, source.composition.duration.seconds))
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editrr-\(stamp).mp4")
        try? FileManager.default.removeItem(at: url)

        exportState = .working(0)
        exportTask = Task { [weak self] in
            let progress = Task { [weak self] in
                for await state in session.states(updateInterval: 0.2) {
                    // Only while still exporting, so a late update can't cover "Saved".
                    if case .exporting(progress: let made) = state, self?.exportState.isWorking == true {
                        self?.exportState = .working(made.fractionCompleted)
                    }
                }
            }
            defer { progress.cancel() }
            do {
                try await session.export(to: url, as: .mp4)
                try await EditorModel.saveToPhotos(url)
                self?.exportState = .saved(url)
            } catch is CancellationError {
                self?.exportState = .idle
            } catch {
                if Task.isCancelled {
                    self?.exportState = .idle
                } else {
                    print("editrr export failed:", EditorError.explain(error))
                    self?.exportState = .failed(EditorError.explain(error))
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportState = .idle
    }

    /// Back to the start of the export sheet (after it's saved, failed or closed).
    func resetExport() {
        if case .working = exportState { return }
        exportState = .idle
    }

    nonisolated private static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw EditorError.couldNotBuild("editrr isn't allowed to save to Photos. Turn it on in Settings > editrr > Photos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    // MARK: Words for the screen

    static func clock(_ seconds: Double) -> String {
        let whole = max(0, seconds)
        let minutes = Int(whole) / 60
        let rest = whole - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }

    /// Minutes and whole seconds only ("0:31"), for the time under the video.
    static func clockWhole(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    var hint: String {
        if lyricTimeline { return lyricHint }
        if let titleHint { return titleHint }
        if let index = dragging {
            return grip == .move ? "Moving video \(index + 1)." : "Trimming video \(index + 1)."
        }
        if let index = draggingCut, cuts.indices.contains(index) {
            return "Moving the switch to video \(cuts[index].layer + 1)."
        }
        if let index = previewing {
            return "Previewing video \(index + 1). Tap its number twice to cut to it, or once to stop."
        }
        if let index = selected {
            return locked
                ? "Video \(index + 1) picked. Duplicate copies it. Tap empty space to let go."
                : "Video \(index + 1) picked. The arrows move it 1 frame. Tap empty space to let go."
        }
        return locked
            ? "Tap a number to preview, twice to cut. Drag a switch on the song lane to move it."
            : "Unlocked: hold a clip to move it, drag its end to trim. Lock when you're done."
    }
}
