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
        var muted = false
        var voice = false
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
    /// The performance's In and Out, kept only for a step that moved them (nil: left as they are).
    var range: [Double]?

    /// Where the clips sit (what needs a full rebuild when it changes), as one list.
    var timing: [Double] {
        // Built up step by step (one long expression is too slow for the compiler to check).
        var list: [Double] = []
        for place in places {
            list.append(place.offset)
            list.append(place.trimStart)
            list.append(place.trimEnd)
            list.append(place.muted ? 1 : 0)
            list.append(place.voice ? 1 : 0)
        }
        for overlay in overlays {
            list.append(overlay.start)
            list.append(overlay.length)
            list.append(overlay.trimStart)
        }
        for index in order { list.append(Double(index)) }
        if let range { list.append(contentsOf: range) }
        return list
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
    /// A horizontal project: a 16:9 frame that exports at 1920 x 1080. Off: vertical, 1080 x 1920.
    var wide = false {
        didSet { TimelineBuilder.canvas = TimelineBuilder.frame(wide: wide) }
    }
    /// The frame's width over its height, for the views that show it.
    var aspect: CGFloat { wide ? 16.0 / 9.0 : 9.0 / 16.0 }
    /// The next project is horizontal (its takes were filmed sideways).
    @ObservationIgnored var pendingWide = false
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
    /// The Song (or Sound) row is off: the song, or the videos' own sound, is silent. Added music
    /// and sound effects still play.
    var soundMuted = false {
        didSet {
            guard soundMuted != oldValue else { return }
            player.currentItem?.audioMix = built.flatMap { songMix($0) }
        }
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
    /// The fisheye circle while a finger moves it: where it started, and where it is now (drawn as
    /// a yellow ring over the video; the picture catches up when the finger lets go).
    @ObservationIgnored private var fishMoveStart: CGPoint?
    private(set) var fishLive: CGPoint?
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
    var isPlaying = false {
        // The zoom boxes show while stopped and the zoom itself while playing.
        didSet {
            guard oldValue != isPlaying, let index = fxTarget, cuts.indices.contains(index),
                  cuts[index].zoom != .off else { return }
            refreshCuts()
            if !isPlaying { requestSeek(time) }
        }
    }
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
    /// Music and sound effects added with the + under the tracks, each on an audio row. They play
    /// under everything.
    var sounds: [SavedMusic] = []
    /// The music or sound effect picked: its tools show (start it at the playhead, delete).
    var soundPick: UUID?
    /// Each added sound's file track, and where its sound starts in the file (usually 0).
    /// The file is kept too: a track only holds its file weakly, and once the file is let go the
    /// track adds no sound (added music went quiet after reopening a project).
    @ObservationIgnored private var soundTracks: [UUID: (asset: AVAsset, track: AVAssetTrack, start: Double)] = [:]
    /// Where the words sit while a finger moves them (percent), nil otherwise.
    private(set) var lyricMoveSpot: CGPoint?
    @ObservationIgnored private var lyricMoveStart: CGPoint?
    /// The words' size while a corner handle or a pinch is resizing them (nil otherwise).
    private(set) var lyricSizeSpot: Double?
    @ObservationIgnored private var lyricSizeStart: Double?
    /// The word showing at the playhead (changes only when the word does, so the list stays light).
    var lyricNow: Int?
    /// Tap the timing: the song plays and you tap each time a new word starts.
    var tapTiming = false

    // Titles and other text, each on a text lane under the videos.
    var titles: [TitleClip] = []
    /// The text whose sheet is open.
    var titleEditing: UUID?
    /// The text picked (a tap on its clip): its tools, its box and handles on the video, and its
    /// ends' grips on the timeline. A double tap opens its sheet.
    var titlePick: UUID?
    /// The text clip a finger is moving or stretching on the timeline.
    var titleDrag: (id: UUID, grip: Grip)?
    /// How many text lanes there are (lanes stay packed: T1, T2, ...).
    var textLaneCount: Int { (titles.map(\.lane).max() ?? -1) + 1 }
    /// Every lane under the song: videos, then text.
    var laneCount: Int { layers.count + textLaneCount }
    /// The next word a tap will time.
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
    func shoot(_ song: CreatrrSong, part: CreatrrPart?, end: Double? = nil, fromCreatrr: Bool = false) async {
        guard busy == nil else { return }
        resetNewVideos()
        projectName = ""
        pendingKind = .performance
        await chooseCreatrrSong(song)
        guard let ready = captureSong, problem == nil else {
            pendingKind = nil
            return
        }
        // Where the part ends: what creatrr said, or the next part's start.
        let known = part.flatMap { picked in song.parts.firstIndex(where: { $0.id == picked.id }) }
        let partEnd = end ?? known.flatMap { song.partEnd($0) }
        shootPlan = ShootPlan(song: ready.asset, length: ready.length, songName: song.name, partName: part?.name,
                              parts: song.parts, part: part?.id, start: part?.time ?? 0,
                              end: part == nil ? nil : partEnd, tempo: song.tempo, fromCreatrr: fromCreatrr)
    }

    /// Shoot of one part: the new project's In and Out go there (its start, and 30 seconds on).
    @ObservationIgnored private var shootRange: Double?

    /// Shoot's takes make a new project, named for the song and part, lined up and open.
    /// `draft` saves the project and goes back to Edits instead of opening it.
    func finishShoot(_ plan: ShootPlan, takes: [CapturedTake], draft: Bool = false) async {
        guard !takes.isEmpty else {
            pendingKind = nil
            return
        }
        addCaptured(takes)
        projectName = plan.partName.map { "\(plan.songName) · \($0)" } ?? plan.songName
        shootRange = plan.partName == nil ? nil : plan.start
        await start()
        shootRange = nil
        guard draft, stage == .editing else { return }
        let name = currentProject?.name
        startOver()
        if let name { notice = "Saved \u{201C}\(name)\u{201D} as a draft. Open it from Edits when you're ready." }
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
        // The section tapped, even when the shared song lists other sections (a song can sit in
        // more than one creatrr project, each with its own sections).
        var part: CreatrrPart?
        if let time = request.time {
            if let near = song.parts.min(by: { abs($0.time - time) < abs($1.time - time) }),
               abs(near.time - time) < 0.5 {
                part = near
            } else {
                part = CreatrrPart(name: request.name ?? "Section", time: time, color: "")
            }
        }
        await shoot(song, part: part, end: request.end, fromCreatrr: true)
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
        pendingWide = false
        TakeStore.clear()
    }

    /// Adds takes recorded to the song. They go after any videos already picked, up to 10 in all.
    func addCaptured(_ takes: [CapturedTake]) {
        problem = nil
        // Takes filmed horizontal make a horizontal project.
        if takes.contains(where: { $0.wide }) { pendingWide = true }
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
    /// The words as they were when tapping started (Cancel puts them back; Back restores one).
    @ObservationIgnored private var tapBefore: [LyricWord]?
    /// The first word this go of tapping times.
    @ObservationIgnored private var tapFirst = 0
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
        wide = pendingWide
        filter = .none
        clearSounds()
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
        // Shot to one part: start and end there (30 seconds), not at the top of the song.
        if let from = shootRange, from >= 0, from < duration - 1 {
            inPoint = from
            outPoint = min(duration, from + 30)
        }
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
                       speed: abs($0.speed - 1) > 0.001 ? $0.speed : nil, muted: $0.muted ? true : nil,
                       voice: $0.voice != nil ? true : nil)
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
        project.wide = wide ? true : nil
        project.music = nil
        project.sounds = sounds.isEmpty ? nil : sounds
        project.filter = filter == .none ? nil : filter
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
        wide = saved.wide ?? false
        filter = saved.filter ?? .none

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
        // Added music and sound effects: any whose file is gone are left out (with a note).
        clearSounds()
        var missing = 0
        for added in saved.sounds ?? saved.music.map({ [$0] }) ?? [] {
            if let asset = await PhotosLoader.open(added.source, project: saved.id),
               let audio = try? await asset.loadTracks(withMediaType: .audio).first {
                let start = (try? await audio.load(.timeRange))?.start.seconds ?? 0
                soundTracks[added.id] = (asset, audio, start)
                sounds.append(added)
            } else {
                missing += 1
            }
        }
        packSoundLanes()
        if missing > 0 {
            notice = missing == 1
                ? "A sound added to \u{201C}\(saved.name)\u{201D} is missing, so it's left out."
                : "\(missing) sounds added to \u{201C}\(saved.name)\u{201D} are missing, so they're left out."
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
            layer.muted = place.muted ?? false
            // The voice-isolated sound, if it was on (left as recorded if its file is gone).
            if place.voice == true {
                let url = Self.voiceURL(layer, in: saved.id)
                if let kept = voiceCache[url] {
                    layer.voice = kept
                } else if let audio = layer.audio,
                          let opened = await VoiceTrack.open(url, start: (try? await audio.load(.timeRange))?.start.seconds ?? 0) {
                    voiceCache[url] = opened
                    layer.voice = opened
                }
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
        wide = false
        filter = .none
        clearSounds()
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
                  speed: factor, original: original, muted: layer.muted)
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
        titlePick = nil
        // The eyes are the edit page's: the performance page always shows and plays everything.
        videoHidden = false
        soundMuted = false
        performancePage = true
    }

    /// A tap on the edit page picks a clip (nil lets go).
    /// A tap beside the video lets go of whatever is picked: a clip, text, sound, lyrics or overlay.
    /// (Not while a mask is being drawn; its handles need the overlay.)
    func letGoOfAll() {
        guard !maskEditing else { return }
        titlePick = nil
        soundPick = nil
        lyricsPicked = false
        lyricPiecePick = nil
        overlayPick = nil
        editPick = nil
        piecePick = nil
        selected = nil
        lyricSelected = nil
        notice = nil
    }

    func pickOnEdit(_ index: Int?) {
        editPick = index
        // The performance picked as a whole: the piece the playhead is in.
        piecePick = index == 0 && kind == .performance ? pieceIndex(at: playheadFrame) : nil
        if index != nil {
            overlayPick = nil
            lyricsPicked = false
            soundPick = nil
            titlePick = nil
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

    /// Editing a video: the videos on the track, in order (a deleted one left out).
    var shownOrder: [Int] { playOrder.filter { !layers[$0].gone } }

    /// Editing a video: room for one more video (a deleted one doesn't count).
    private var videoRoom: Bool { layers.filter { !$0.gone }.count + textLaneCount < Self.maxLayers }

    /// The picked clip can be deleted: a video while another stays, or the first or last piece of
    /// a split performance (its middle stays in time with the song).
    var canDeleteClip: Bool {
        switch kind {
        case .video:
            guard let pick = editPick, layers.indices.contains(pick), !layers[pick].gone else { return false }
            return shownOrder.contains { $0 != pick }
        case .performance:
            guard performancePieces.count > 1, let piece = pickedPiece else { return false }
            return abs(piece.start - loopStart) < 0.001 || abs(piece.end - performanceEnd) < 0.001
        }
    }

    /// Voice-isolated sounds opened this session, by file (Undo brings one back from here).
    @ObservationIgnored private var voiceCache: [URL: VoiceTrack] = [:]

    /// The file in the project's folder that holds a video's voice-isolated sound (one per video
    /// and speed; clips cut from the same video share it).
    private static func voiceURL(_ layer: Layer, in project: UUID) -> URL {
        let name = abs(layer.speed - 1) > 0.001
            ? "voice-\(layer.video)-\(Int((layer.speed * 1000).rounded())).caf"
            : "voice-\(layer.video).caf"
        return ProjectStore.folder(for: project).appendingPathComponent(name)
    }

    /// Editing a video: plays a clip's own sound with the voice isolated (background noise taken
    /// out), or back as it was recorded. Clips cut from the same video change together, as
    /// they're one recording. The first time, the voice isolation model downloads.
    func toggleVoice(_ index: Int) async {
        guard kind == .video, layers.indices.contains(index), busy == nil, let id = currentProject?.id else { return }
        pause()
        problem = nil
        let url = Self.voiceURL(layers[index], in: id)
        func setAll(_ voice: VoiceTrack?) {
            history.append(snapshot())
            future = []
            for other in layers.indices where Self.voiceURL(layers[other], in: id) == url {
                layers[other].voice = voice
            }
            rebuildAll()
        }
        if layers[index].voice != nil {
            setAll(nil)
            return
        }
        guard let audio = layers[index].audio else {
            problem = "This clip has no sound to clean up."
            return
        }
        let asset = layers[index].asset
        let start = (try? await audio.load(.timeRange))?.start.seconds ?? 0
        var found = voiceCache[url]
        if found == nil { found = await VoiceTrack.open(url, start: start) }
        if found == nil {
            defer { busy = nil }
            do {
                if !VoiceIsolation.isReady {
                    busy = "Getting voice isolation ready…"
                    try await VoiceIsolation.prepare()
                }
                busy = "Isolating the voice…"
                try await VoiceIsolation.isolate(audio, of: asset, to: url)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? "The voice couldn't be isolated. Try again."
                return
            }
            found = await VoiceTrack.open(url, start: start)
        }
        guard let made = found else {
            problem = "The voice couldn't be isolated. Try again."
            return
        }
        voiceCache[url] = made
        // Still the same project and clip (it can take a while).
        guard currentProject?.id == id, layers.indices.contains(index),
              Self.voiceURL(layers[index], in: id) == url, layers[index].voice == nil else { return }
        setAll(made)
    }

    /// Editing a video: turns a clip's own sound off or back on.
    func toggleMute(_ index: Int) {
        guard kind == .video, layers.indices.contains(index) else { return }
        pause()
        history.append(snapshot())
        future = []
        layers[index].muted.toggle()
        rebuildAll()
    }

    /// Deletes the picked clip: the rest close up behind it (Undo brings it back).
    func deleteClip() {
        guard canDeleteClip else { return }
        pause()
        switch kind {
        case .video:
            guard let pick = editPick else { return }
            history.append(snapshot())
            future = []
            // No length left, so it drops off the track; the videos after it move up.
            layers[pick].trimEnd = layers[pick].length - layers[pick].trimStart
            layOutSequence()
            pickOnEdit(nil)
            rebuildAll()
        case .performance:
            guard let piece = pickedPiece else { return }
            history.append(snapshot(range: true))
            future = []
            // The first piece: Start moves to its end. The last: End moves to its start.
            if abs(piece.start - loopStart) < 0.001 {
                inPoint = piece.end
            } else {
                outPoint = piece.start
            }
            splits.removeAll { $0 <= loopStart + 0.001 || $0 >= performanceEnd - 0.001 }
            pickOnEdit(nil)
            updateLoop()
            redraw()
        }
        keepInRange()
        scheduleSave()
        notice = nil
    }

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
            return videoRoom
        }
        return clipAnchor != nil && cutaways.count < Self.maxCutaways
    }

    /// The + at the end of the video track can add one more.
    var canAddToEnd: Bool {
        kind == .video ? videoRoom : cutaways.count < Self.maxCutaways
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
            guard videoRoom else {
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
            guard let last = shownOrder.last else { return }
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
        guard videoRoom else {
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
              videoRoom else { return }
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
            soundPick = nil
            titlePick = nil
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
    /// of the frame. A vertical frame is 9 wide to 16 tall, so a unit is a bigger fraction across
    /// (a horizontal one the other way round).
    private func maskUnits(_ mask: OverlayMask, in box: CGRect) -> (middle: CGPoint, x: Double, y: Double) {
        let size = min(OverlayMask.largest, max(0.1, mask.size))
        let across = Double(TimelineBuilder.canvas.width) / 120, down = Double(TimelineBuilder.canvas.height) / 120
        let unit = Double(min(Double(box.width) * across, Double(box.height) * down)) * size
        let middle = CGPoint(x: Double(box.minX) + Double(box.width) * mask.middleX,
                             y: Double(box.minY) + Double(box.height) * mask.middleY)
        return (middle, unit / across, unit / down)
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
        // A fraction of the frame's width is width/height as much of its height (9/16 when vertical).
        let frame = TimelineBuilder.canvas
        let height = overlay.scale * Double(size.height / size.width) * Double(frame.width / frame.height)
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
        let now = snapshot(range: previous.range != nil)
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
        let now = snapshot(range: next.range != nil)
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

    /// `range`: also keep In and Out, for a step that moves them.
    private func snapshot(range: Bool = false) -> EditState {
        EditState(cuts: cuts, places: layers.map {
            EditState.Place(offset: $0.offset, trimStart: $0.trimStart, trimEnd: $0.trimEnd,
                            sync: $0.sync, alternatives: $0.alternatives, keyframes: $0.keyframes,
                            muted: $0.muted, voice: $0.voice != nil)
        }, lyrics: lyrics, lyricStyle: lyricStyle, titles: titles, overlays: overlays, trackKeys: trackKeys,
           splits: splits, order: order, range: range ? [inPoint, outPoint] : nil)
    }

    private func restore(_ state: EditState) {
        cuts = state.cuts
        splits = state.splits
        order = state.order
        if let range = state.range, range.count == 2 {
            inPoint = range[0]
            outPoint = range[1]
            updateLoop()
            keepInRange()
        }
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
            if let id = titlePick, title(id) == nil { titlePick = nil }
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
            layers[index].muted = place.muted
            if (layers[index].voice != nil) != place.voice {
                layers[index].voice = place.voice
                    ? currentProject.flatMap { voiceCache[Self.voiceURL(layers[index], in: $0.id)] } : nil
            }
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
              speed: original.speed, original: original.original, muted: original.muted,
              voice: original.voice)
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
        // Set first: with the Fx page's zoom boxes up, this puts the zoom back before it plays.
        isPlaying = true
        player.play()
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
                                                  music: soundsPlay, overlays: overlays, media: overlayMedia)
            self.built = built
            segments = Program.segments(cuts: cuts, layers: layers, duration: duration)
            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = songMix(built)
            // Never let the system draw its own captions over the picture (the Closed Captions
            // setting, or auto captions): the only words on the video are the lyrics you style.
            let captions = AVPlayerItemLegibleOutput()
            captions.suppressesPlayerRendering = true
            item.add(captions)
            item.videoComposition = TimelineBuilder.videoComposition(segments: onScreen, built: built,
                                                                     cuts: screenCuts, layers: layers, duration: duration,
                                                                     length: timelineEnd,
                                                                     lyrics: lyricsLive, overlays: overlays,
                                                                     media: overlayMedia, board: overlayBoard,
                                                                     filter: filter)
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
                                                                     cuts: screenCuts, layers: layers, duration: duration,
                                                                     length: timelineEnd,
                                                                     lyrics: lyricsLive, overlays: overlays,
                                                                     media: overlayMedia, board: overlayBoard,
                                                                     filter: filter)
    }

    /// The cuts as the video on screen draws them: the same, except that while the Fx page shows
    /// the zoom's Start and End boxes, that cut's zoom is held off so the whole frame shows.
    private var screenCuts: [Cut] {
        guard zoomFramesShown, let index = fxTarget, cuts.indices.contains(index) else { return cuts }
        var shown = cuts
        shown[index].zoom = .off
        return shown
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
    var canListen: Bool { !lyricAudioChoices.isEmpty && LyricListener.isAvailable }

    /// Which sound Lyrics listens to for the words.
    enum LyricAudio: String, CaseIterable {
        case song, video
        var name: String { self == .song ? "The song" : "Video sound" }
    }
    /// The one picked when there's both (see `lyricAudioChoices`).
    var lyricAudio: LyricAudio = .song

    /// The sounds there are to listen to: the song (the performance's song, or music added from
    /// creatrr or Files), and the videos' own sound.
    var lyricAudioChoices: [LyricAudio] {
        guard let built else { return [] }
        var song = built.musicTracks
        if let id = built.songTrack { song.insert(id) }
        let audio = built.composition.tracks(withMediaType: .audio).map(\.trackID)
        var choices: [LyricAudio] = []
        if audio.contains(where: { song.contains($0) }) { choices.append(.song) }
        if audio.contains(where: { !song.contains($0) }) { choices.append(.video) }
        return choices
    }

    /// The sound tracks to listen to for the words.
    private func lyricTrackIDs(_ built: TimelineBuilder.Built) -> Set<CMPersistentTrackID> {
        var song = built.musicTracks
        if let id = built.songTrack { song.insert(id) }
        let audio = Set(built.composition.tracks(withMediaType: .audio).map(\.trackID))
        let choices = lyricAudioChoices
        let pick = choices.contains(lyricAudio) ? lyricAudio : (choices.first ?? .song)
        return pick == .song ? audio.intersection(song) : audio.subtracting(song)
    }

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
        tapBefore = nil
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
        guard !lyricAudioChoices.isEmpty else {
            problem = LyricListenError.noSound.errorDescription
            return
        }
        let trackIDs = lyricTrackIDs(built)
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
                let heard = try await LyricListener.listen(to: box.asset, trackIDs: trackIDs, update: report)
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
        if tapTiming {
            // Tapping a word while tapping out the timing: the next tap times that word.
            tapNext = index
            tapFirst = min(tapFirst, index)
        }
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
                                    br: i == parts.count - 1 ? word.br : false).styled(like: word))
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

    /// One word's own style (font, size, outline), over the look.
    func setLyricWordStyle(_ index: Int, _ change: (inout LyricWord) -> Void) {
        guard lyrics.indices.contains(index) else { return }
        var word = lyrics[index]
        change(&word)
        guard word != lyrics[index] else { return }
        editLyrics { lyrics[index] = word }
    }

    /// Takes a word back to the look: no color, font, size or outline of its own.
    func clearLyricWordStyle(_ index: Int) {
        guard lyrics.indices.contains(index), lyrics[index].hasOwnStyle else { return }
        editLyrics { lyrics[index] = LyricWord(text: lyrics[index].text, start: lyrics[index].start,
                                               end: lyrics[index].end, br: lyrics[index].br) }
        notice = "Back to the look."
    }

    /// A double tap on a word asks the lyrics tools to open its text.
    var lyricTextEditRequest: Int?
    func editLyricText(_ index: Int) {
        guard lyrics.indices.contains(index) else { return }
        if lyricSelected != index { selectLyric(index) }
        lyricTextEditRequest = index
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

    // MARK: Where the lyrics come in and go out, and their pieces (the edit page)

    /// An end of a lyrics piece is held: where it comes in, or where it goes out.
    var lyricsTrimming: Grip?
    /// The lyrics piece picked on the timeline (its ends get handles; Delete removes it).
    var lyricPiecePick: Int?
    @ObservationIgnored private var lyricsTrimStart: (piece: Int, from: Double, to: Double, before: EditState)?

    /// The words' own reach on the timeline: the first word to the last, inside the clip.
    private var lyricsReach: (first: Double, last: Double) {
        let first = max(loopStart, lyrics.map(\.start).min() ?? loopStart)
        let last = min(loopEnd, lyrics.map(\.end).max() ?? loopEnd)
        return (first, max(first, last))
    }

    /// Where the lyrics show, in order: one piece from the first word to the last, unless trimmed
    /// or split.
    var lyricsPieces: [(from: Double, to: Double)] {
        let reach = lyricsReach
        guard let pieces = lyricStyle.pieces else { return [(reach.first, reach.last)] }
        return pieces
            .map { piece -> (from: Double, to: Double) in
                let from = min(max(reach.first, piece.from), reach.last)
                return (from, max(min(reach.last, piece.to), from))
            }
            .sorted { $0.from < $1.from }
    }

    /// Stores the pieces, sorted. One piece reaching the words' own ends counts as untrimmed.
    private func setLyricsPieces(_ pieces: [(from: Double, to: Double)]) {
        let reach = lyricsReach
        let sorted = pieces.sorted { $0.from < $1.from }
        if sorted.count == 1, sorted[0].from <= reach.first + 0.02, sorted[0].to >= reach.last - 0.02 {
            lyricStyle.pieces = nil
        } else {
            lyricStyle.pieces = sorted.map { LyricPiece(from: $0.from, to: $0.to) }
        }
        lyricsLive.update(words: lyrics, style: lyricStyle)
    }

    /// The lyrics piece under a time on the timeline.
    func lyricsPiece(at seconds: Double) -> Int? {
        lyricsPieces.firstIndex { seconds >= $0.from && seconds <= $0.to }
    }

    func beginLyricsTrim(_ end: Grip, piece: Int) {
        let pieces = lyricsPieces
        guard end != .move, hasLyrics, pieces.indices.contains(piece) else { return }
        pause()
        lyricsTrimming = end
        lyricPiecePick = piece
        lyricsTrimStart = (piece, pieces[piece].from, pieces[piece].to, snapshot())
        notice = nil
    }

    /// Moves the held end, up to the next piece over (or the first or last word), keeping the
    /// piece at least 0.3 s long.
    func dragLyricsTrim(by seconds: Double) {
        guard let end = lyricsTrimming, let start = lyricsTrimStart else { return }
        var pieces = lyricsPieces
        guard pieces.indices.contains(start.piece) else { return }
        let reach = lyricsReach
        let frames = { (value: Double) in (value * 30).rounded() / 30 }
        let before = start.piece > 0 ? pieces[start.piece - 1].to : reach.first
        let after = start.piece + 1 < pieces.count ? pieces[start.piece + 1].from : reach.last
        switch end {
        case .trimStart:
            pieces[start.piece].from = min(max(frames(start.from + seconds), before), start.to - 0.3)
        case .trimEnd:
            pieces[start.piece].to = max(min(frames(start.to + seconds), after), start.from + 0.3)
        case .move:
            return
        }
        setLyricsPieces(pieces)
        redraw()
    }

    func endLyricsTrim() {
        guard lyricsTrimming != nil else { return }
        lyricsTrimming = nil
        if let before = lyricsTrimStart?.before, before.lyricStyle != lyricStyle { history.append(before) }
        lyricsTrimStart = nil
        syncLyrics()
        scheduleSave()
    }

    /// Whether Split would cut a lyrics piece at the playhead (each side at least 0.3 s).
    var canSplitLyrics: Bool {
        let t = time
        return lyricsPieces.contains { t - $0.from >= 0.3 && $0.to - t >= 0.3 }
    }

    /// Cuts the lyrics piece under the playhead in two there; the piece after the cut is picked.
    func splitLyrics() {
        let t = (time * 30).rounded() / 30
        var pieces = lyricsPieces
        guard let index = pieces.firstIndex(where: { t - $0.from >= 0.3 && $0.to - t >= 0.3 }) else { return }
        pause()
        history.append(snapshot())
        let piece = pieces[index]
        pieces[index] = (piece.from, t)
        pieces.insert((t, piece.to), at: index + 1)
        setLyricsPieces(pieces)
        lyricPiecePick = index + 1
        syncLyrics()
        redraw()
        scheduleSave()
    }

    /// Removes the picked lyrics piece (never the last one; Hide is for that).
    func deleteLyricsPiece() {
        var pieces = lyricsPieces
        guard pieces.count > 1, let index = lyricPiecePick, pieces.indices.contains(index) else { return }
        history.append(snapshot())
        pieces.remove(at: index)
        setLyricsPieces(pieces)
        lyricPiecePick = nil
        lyricsPicked = false
        syncLyrics()
        redraw()
        scheduleSave()
    }

    /// A tap on the words picks them (true), a tap away lets go (false).
    func pickLyrics(_ on: Bool, piece: Int? = nil) {
        // Picked even while hidden, so its tools can show them again.
        lyricsPicked = on && hasLyrics
        // Which piece: the one tapped on the timeline, else the one under the playhead.
        lyricPiecePick = lyricsPicked ? (piece ?? lyricsPiece(at: time) ?? 0) : nil
        guard lyricsPicked else { return }
        soundPick = nil
        titlePick = nil
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

    // Tap the timing: the song plays and you tap a pad each time a new word starts. A word lasts
    // until the next tap (3 seconds at most, so it doesn't hang over a gap in the singing).

    /// The longest a tapped word stays up before the next tap.
    static let tapLongest = 3.0

    /// Starts tapping out the words (off keeps what was tapped). It starts from the picked word,
    /// else the next word at the playhead, with the playhead a few seconds before it.
    func setTapTiming(_ on: Bool) {
        if !on {
            if tapTiming { finishTapTiming(keep: true) }
            return
        }
        guard !lyrics.isEmpty, !tapTiming else { return }
        pause()
        if lyricDrag != nil { endLyricDrag() }
        tapBefore = lyrics
        let from = lyricSelected ?? (lyrics.firstIndex(where: { $0.start >= time - 0.05 }) ?? 0)
        tapNext = min(max(0, from), lyrics.count - 1)
        tapFirst = tapNext
        tapTiming = true
        let at = tapNext == 0 ? max(0, min(time, lyrics[0].start - 3)) : max(0, lyrics[tapNext].start - 3)
        time = at
        requestSeek(at)
        notice = nil
    }

    /// A pad: plays from the playhead when stopped; while playing, the next word starts now.
    func lyricTap() {
        guard tapTiming, !lyrics.isEmpty else { return }
        guard isPlaying else {
            play()
            return
        }
        let now = player.currentTime().seconds
        guard now.isFinite, lyrics.indices.contains(tapNext) else { return }
        let i = tapNext
        let at = min(max(0, now), duration)
        // Two taps closer than a couple of frames are one tap (both thumbs at once).
        if i > tapFirst, at < lyrics[i - 1].start + 0.06 { return }
        let length = lyrics[i].end - lyrics[i].start
        lyrics[i].start = at
        lyrics[i].end = at + min(max(0.3, length), Self.tapLongest)
        if i > 0 {
            if i > tapFirst {
                // The word before ends where this one starts (or sooner, after a long gap).
                lyrics[i - 1].end = max(lyrics[i - 1].start + 0.04, min(at, lyrics[i - 1].start + Self.tapLongest))
            } else if lyrics[i - 1].end > at {
                lyrics[i - 1].end = max(lyrics[i - 1].start + 0.04, at)
            }
        }
        tapNext = i + 1
        lyricSelected = i
        lyricsLive.update(words: lyrics, style: lyricStyle)
        if tapNext >= lyrics.count {
            notice = "That's every word. Tap Done to keep it."
        }
    }

    /// Back: takes the last tap off and goes a little before it, to tap it again.
    func lyricTapBack() {
        guard tapTiming, tapNext > tapFirst, let before = tapBefore else { return }
        pause()
        tapNext -= 1
        let i = tapNext
        if before.indices.contains(i), lyrics.indices.contains(i) {
            lyrics[i] = before[i]
        }
        let from = i > tapFirst ? lyrics[i - 1].start : lyrics[i].start - 2
        let at = max(0, from - 1)
        time = at
        requestSeek(at)
        lyricSelected = i > tapFirst ? i - 1 : nil
        lyricsLive.update(words: lyrics, style: lyricStyle)
    }

    /// How many words have been tapped this go.
    var lyricTapCount: Int { tapTiming ? max(0, tapNext - tapFirst) : 0 }

    /// Done keeps the tapped times (one Undo takes them all back); Cancel puts the words back.
    func finishTapTiming(keep: Bool) {
        pause()
        guard tapTiming else { return }
        tapTiming = false
        guard let before = tapBefore else { return }
        tapBefore = nil
        var timed = lyrics
        lyrics = before
        guard keep, tapNext > tapFirst else {
            lyricsLive.update(words: lyrics, style: lyricStyle)
            return
        }
        // The last tapped word ends before the next untapped one starts.
        let last = tapNext - 1
        if timed.indices.contains(last), timed.indices.contains(last + 1), timed[last].end > timed[last + 1].start {
            if timed[last + 1].start > timed[last].start + 0.04 {
                timed[last].end = timed[last + 1].start
            } else {
                // The next word's old time is behind the tapped ones: it moves just after them.
                let length = min(max(0.3, timed[last + 1].end - timed[last + 1].start), Self.tapLongest)
                timed[last + 1].start = timed[last].end
                timed[last + 1].end = timed[last + 1].start + length
            }
        }
        let count = tapNext - tapFirst
        editLyrics { lyrics = timed }
        scheduleSave()
        notice = count == 1 ? "Timed 1 word." : "Timed \(count) words."
    }

    /// The next word a tap will time (for the pads).
    var tapNextWord: String? {
        lyrics.indices.contains(tapNext) ? lyrics[tapNext].text : nil
    }


    // MARK: The lyrics timeline

    /// Swaps the video timeline for the lyrics timeline, or back.
    func setLyricTimeline(_ on: Bool) {
        guard on != lyricTimeline else { return }
        pause()
        if lyricDrag != nil { endLyricDrag() }
        if tapTiming { finishTapTiming(keep: true) }
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
    /// Where Split cuts a word block: the playhead when it's inside the block, else its middle.
    private func lyricSplitPoint(_ word: LyricWord) -> Double {
        let at = playheadFrame
        return at > word.start + 0.05 && at < word.end - 0.05 ? at : (word.start + word.end) / 2
    }

    /// The block holds more than one word, so Split can share them out with no typing.
    func lyricHasWords(_ index: Int) -> Bool {
        lyrics.indices.contains(index) && lyrics[index].text.split(whereSeparator: { $0.isWhitespace }).count > 1
    }

    /// Splits a word block at the playhead (its middle if the playhead isn't on it), for one word
    /// held over words that are really sung there. A block of several words keeps the ones before
    /// the cut and the rest go after it. A single word keeps the first part, and `after` (what's
    /// sung in the second part) fills the rest, spread evenly when it's more than one word.
    func splitLyric(_ index: Int, after: String? = nil) {
        guard lyrics.indices.contains(index) else { return }
        let word = lyrics[index]
        guard word.end - word.start > 0.12 else {
            notice = "That word is too short to split."
            return
        }
        let at = lyricSplitPoint(word)
        let parts = word.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var first = word
        first.end = at
        first.br = false
        var second: [LyricWord] = []
        if parts.count > 1 {
            let share = (at - word.start) / (word.end - word.start)
            let keep = min(parts.count - 1, max(1, Int((Double(parts.count) * share).rounded())))
            first.text = parts[..<keep].joined(separator: " ")
            second = [LyricWord(text: parts[keep...].joined(separator: " "), start: at, end: word.end,
                                br: word.br).styled(like: word)]
        } else {
            let typed = (after ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !typed.isEmpty else { return }
            let step = (word.end - at) / Double(typed.count)
            for (i, text) in typed.enumerated() {
                second.append(LyricWord(text: text, start: at + step * Double(i), end: at + step * Double(i + 1),
                                        br: i == typed.count - 1 ? word.br : false).styled(like: word))
            }
        }
        editLyrics { lyrics.replaceSubrange(index...index, with: [first] + second) }
        notice = "Split into \(1 + second.count) at \(Self.clock(at))."
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
        pickTitle(clip.id)
    }

    /// Opens a text's sheet (a tap on its clip, or the Text button over it).
    func openTitle(_ id: UUID) {
        guard title(id) != nil else { return }
        pause()
        if titleEditing != id { closeTitleEdit() }
        if titleEditStart == nil { titleEditStart = snapshot() }
        titleEditing = id
        pickTitle(id)
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
            if titlePick == id { titlePick = nil }
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
        refit(&next)
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
        // Picked but not open: the move or resize is its own Undo step.
        if titleEditing == nil, let start = titleEditStart {
            if start.titles != titles { history.append(start) }
            titleEditStart = nil
        }
    }

    /// Picks a text (nil lets go): its tools under the timeline, and its box on the video.
    func pickTitle(_ id: UUID?) {
        titlePick = id.flatMap { title($0) != nil ? $0 : nil }
        guard titlePick != nil else { return }
        overlayPick = nil
        editPick = nil
        piecePick = nil
        selected = nil
        lyricsPicked = false
        soundPick = nil
        notice = nil
    }

    /// The text on the video under a finger (fractions of the frame), T1 first.
    func titleAt(_ point: CGPoint) -> UUID? {
        titles.filter { time >= $0.start && time < $0.end }
            .sorted { $0.lane < $1.lane }
            .first { titleBox($0.id)?.insetBy(dx: -0.03, dy: -0.02).contains(point) == true }?.id
    }

    /// A text's box on the video, in fractions of the frame.
    func titleBox(_ id: UUID) -> CGRect? {
        guard let clip = title(id) else { return nil }
        let canvas = TimelineBuilder.canvas
        let laid = TitleLayout.lay(clip, canvas: canvas)
        let w = laid.width / max(Double(canvas.width), 1)
        let h = laid.height / max(Double(canvas.height), 1)
        return CGRect(x: clip.posX / 100 - w / 2, y: clip.posY / 100 - h / 2, width: w, height: h)
    }

    /// The box's handles on the video: a new width, and a height (the text then fills the box), and
    /// its middle, all in percent of the frame. Follows live; Undo takes the whole drag back.
    func shapeTitle(_ id: UUID, width: Double, height: Double?, x: Double, y: Double) {
        guard let index = titles.firstIndex(where: { $0.id == id }) else { return }
        pause()
        if titleEditStart == nil { titleEditStart = snapshot() }
        var next = titles[index]
        next.boxW = min(max(width, 12), 100)
        if let height { next.boxH = min(max(height, 3), 100) }
        next.posX = min(max(x, 2), 98)
        next.posY = min(max(y, 2), 98)
        refit(&next)
        guard next != titles[index] else { return }
        titles[index] = next
        lyricsLive.update(titles: titles)
        if Date().timeIntervalSince(titleRedrawn) > 0.06 {
            titleRedrawn = Date()
            redraw()
        }
    }

    /// A text filling its box keeps its size in step, so the Size slider shows it.
    private func refit(_ clip: inout TitleClip) {
        guard clip.boxH != nil else { return }
        let canvas = TimelineBuilder.canvas
        let fitted = TitleLayout.lay(clip, canvas: canvas).size / TitleLayout.scale(canvas)
        clip.size = min(max(fitted.rounded(), TitleLayout.smallest), TitleLayout.biggest)
    }

    /// Cut: the picked text becomes two at the playhead, the same words and look.
    func splitTitle(_ id: UUID) {
        guard let index = titles.firstIndex(where: { $0.id == id }) else { return }
        pause()
        let at = (time * 30).rounded() / 30
        let clip = titles[index]
        guard at > clip.start + 0.1, at < clip.end - 0.1 else {
            notice = "Move the playhead onto the text to cut it there."
            return
        }
        if titleEditing != nil { closeTitleEdit() }
        guard let again = titles.firstIndex(where: { $0.id == id }) else { return }
        history.append(snapshot())
        var second = titles[again]
        second.id = UUID()
        second.start = at
        titles[again].end = at
        titles.append(second)
        notice = nil
        syncTitles()
    }

    func canSplitTitle(_ id: UUID) -> Bool {
        guard let clip = title(id) else { return false }
        return time > clip.start + 0.1 && time < clip.end - 0.1
    }

    func deleteTitle(_ id: UUID) {
        guard title(id) != nil else { return }
        let before = titleEditStart ?? snapshot()
        titleEditStart = nil
        if titleEditing == id { titleEditing = nil }
        if titlePick == id { titlePick = nil }
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
        // A held text is picked too, so its tools and handles are ready after the drag.
        if titleEditing == nil { pickTitle(id) }
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
        titlePick = nil
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
    private var frameZoomHere: ZoomBox {
        framedLayer == Self.wholeTrack ? .full : zoomBoxAtPlayhead
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

    /// Where auto zoom's frame is right now (the whole frame when there's none, or while the
    /// Fx page holds it off to show its boxes).
    private var zoomBoxAtPlayhead: ZoomBox {
        guard let index = cutAtPlayhead, cuts[index].zoom != .off else { return .full }
        if zoomFramesShown, index == fxTarget { return .full }
        let start = cuts[index].time
        let end = index + 1 < cuts.count ? cuts[index + 1].time : duration
        guard end - start > 0.05 else { return .full }
        let p = Ease.smooth.apply((playheadFrame - start) / (end - start))
        return ZoomBox.between(cuts[index].zoomStart, cuts[index].zoomEnd, p)
    }

    /// The Fx page is open on a cut with a slow zoom and nothing is playing: the video shows the
    /// whole frame with the green Start and red End boxes on it. Playing shows the zoom itself.
    var zoomFramesShown: Bool {
        guard let index = fxTarget, cuts.indices.contains(index) else { return false }
        return cuts[index].zoom != .off && !isPlaying
    }

    /// The Start and End boxes of the cut the Fx page is on.
    var zoomFramesHere: (start: ZoomBox, end: ZoomBox) {
        guard let index = fxIndex else { return (.full, .full) }
        return (cuts[index].zoomStart, cuts[index].zoomEnd)
    }

    /// Keeps a moved or resized Start or End box (one Undo each).
    func setZoomFrame(start: Bool, _ box: ZoomBox) {
        guard let index = fxIndex, cuts[index].zoom != .off else { return }
        let box = box.held()
        guard box != (start ? cuts[index].zoomStart : cuts[index].zoomEnd) else { return }
        pause()
        history.append(snapshot())
        let other = start ? cuts[index].zoomEnd : cuts[index].zoomStart
        cuts[index].zoomFrom = start ? box : other
        cuts[index].zoomTo = start ? other : box
        // The label on the timeline follows the boxes: a smaller End box zooms in.
        cuts[index].zoom = cuts[index].zoomTo!.size <= cuts[index].zoomFrom!.size ? .zoomIn : .zoomOut
        redraw()
    }

    /// Zoom in or Zoom out's ready-made frames, from the icons on the Zoom card.
    func useZoomPreset(_ zoom: AutoZoom) {
        guard let index = fxIndex, zoom != .off else { return }
        guard cuts[index].zoom != zoom || cuts[index].zoomFrom != nil || cuts[index].zoomTo != nil else { return }
        pause()
        history.append(snapshot())
        cuts[index].zoom = zoom
        cuts[index].zoomFrom = nil
        cuts[index].zoomTo = nil
        notice = "\(zoom.name) on this cut. Drag the green Start and red End boxes on the video to change it."
        redraw()
    }

    /// Turns the slow zoom on or off for the cut the playhead is in.
    func setZoomHere(_ zoom: AutoZoom) {
        guard let index = fxIndex, cuts[index].zoom != zoom else { return }
        pause()
        history.append(snapshot())
        cuts[index].zoom = zoom
        if zoom == .off {
            cuts[index].zoomFrom = nil
            cuts[index].zoomTo = nil
        }
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
        if let index = fxTarget, cuts[index].zoom != .off { redraw() }
        return fxTarget != nil
    }

    func endFX() {
        let hadZoom = fxTarget.map { cuts.indices.contains($0) && cuts[$0].zoom != .off } ?? false
        fxTarget = nil
        if hadZoom { redraw() }
        fishMoveStart = nil
        fishLive = nil
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
        var fx = cut.fx ?? CutFX()
        fx.mirror = false   // Mirror has its own button
        return (cut.transition?.kind ?? .none) != .none || !fx.isEmpty
    }

    /// The cut at the playhead is mirrored (side to side).
    var mirrorHere: Bool { fxHere.mirror }

    /// Mirror on the toolbar: flips the cut at the playhead side to side, or back.
    func toggleMirrorHere() {
        guard fxIndex != nil else {
            notice = "Move the playhead onto a clip to mirror it."
            return
        }
        var fx = fxHere
        fx.mirror.toggle()
        setFXHere(fx)
        notice = fx.mirror ? "This cut is mirrored. Each cut has its own." : "Mirror off for this cut."
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
        cleared.mirror = cuts[index].fx?.mirror ?? false   // Mirror is its own button, not on the Fx page
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
            fx.mirror = cuts[i].fx?.mirror ?? false   // each cut keeps its own Mirror
            // Keyframed sliders belong to this cut's stretch: the others get the value showing now.
            if i != index, let keys = fx.keys {
                for (name, list) in keys {
                    if let param = FXParam(rawValue: name), let value = FXValueKey.value(list, at: playheadFrame) {
                        fx[param] = value
                    }
                }
                fx.keys = nil
            }
            fx.followFace = source.followFace && !fx.faces.isEmpty && fx.facesLayer == cuts[i].layer
            // The circle's keyframes belong to this cut's stretch: the others get it where it sits now.
            if i != index, fx.fishKeys != nil {
                let spot = source.fishSpot(at: playheadFrame)
                fx.fishKeys = nil
                fx.fishX = Double(spot.x)
                fx.fishY = Double(spot.y)
            }
            cuts[i].fx = fx == CutFX() ? nil : fx
            if i > 0, index > 0 { cuts[i].transition = transition }
        }
        notice = "Every cut has these effects now. Undo takes it back."
        redraw()
    }

    // MARK: Fx page (one card per effect)

    /// Whether this effect is on the cut the Fx page is on.
    func effectOn(_ kind: FXKind) -> Bool {
        let fx = fxHere
        switch kind {
        case .transition: return transitionHere.kind != .none
        case .zoom: return zoomHere != .off
        case .color: return fx.color != .none
        case .blur: return fx.blur >= 0.01 || !fxKeys(.blur).isEmpty
        case .tilt: return abs(fx.rotate) >= 0.1 || !fxKeys(.tilt).isEmpty
        case .shake: return fx.shake >= 0.01 || !fxKeys(.shake).isEmpty
        case .mirror: return fx.mirror
        case .face: return fx.followFace
        case .rgbSplit, .fisheye: return fx.custom != nil && fx.custom == kind.customID
        }
    }

    /// Puts an effect on this cut, already showing (a starting amount you can change after).
    func addEffect(_ kind: FXKind) {
        guard fxIndex != nil, !effectOn(kind) else { return }
        var fx = fxHere
        switch kind {
        case .transition:
            guard canTransitionHere else {
                notice = "The first cut has nothing before it to come in from."
                return
            }
            var next = transitionHere
            next.kind = .crossfade
            setTransitionHere(next)
            return
        case .zoom:
            setZoomHere(.zoomIn)
            return
        case .face:
            Task { await followFaceHere(true) }
            return
        case .color: fx.color = .blackWhite
        case .blur: fx.blur = 0.3
        case .tilt: fx.rotate = 8
        case .shake: fx.shake = 0.4
        case .mirror: fx.mirror = true
        case .rgbSplit, .fisheye:
            fx.custom = kind.customID
            fx.customAmount = 0.5
        }
        setFXHere(fx)
    }

    /// Takes an effect off this cut.
    func removeEffect(_ kind: FXKind) {
        guard fxIndex != nil else { return }
        var fx = fxHere
        switch kind {
        case .transition:
            var next = transitionHere
            next.kind = .none
            setTransitionHere(next)
            return
        case .zoom:
            setZoomHere(.off)
            return
        case .face:
            Task { await followFaceHere(false) }
            return
        case .color:
            fx.color = .none
            fx.colorAmount = 1
            fx.keys?[FXParam.colorMix.rawValue] = nil
        case .blur:
            fx.blur = 0
            fx.keys?[FXParam.blur.rawValue] = nil
        case .tilt:
            fx.rotate = 0
            fx.keys?[FXParam.tilt.rawValue] = nil
        case .shake:
            fx.shake = 0
            fx.keys?[FXParam.shake.rawValue] = nil
        case .mirror: fx.mirror = false
        case .rgbSplit, .fisheye:
            guard fx.custom == kind.customID else { return }
            fx.custom = nil
            fx.fishKeys = nil
            fx.keys?[FXParam.amount.rawValue] = nil
        }
        if fx.keys?.isEmpty == true { fx.keys = nil }
        setFXHere(fx)
    }

    // MARK: Filter (the whole video)

    /// A color look over the whole video (each cut can still have its own Color in Fx).
    private(set) var filter: ColorLook = .none

    func setFilter(_ look: ColorLook) {
        guard look != filter else { return }
        pause()
        filter = look
        notice = look == .none ? "No filter on the video." : "\(look.name) on the whole video."
        redraw()
    }

    // MARK: Fisheye circle

    /// The effects sheet is open on a cut with Fisheye: a drag on the video moves its circle, and a
    /// tap puts it there.
    var fishEditing: Bool {
        fxTarget != nil && fxHere.custom == CustomFX.fisheye
    }

    /// Where the circle sits at the playhead (or under the finger), as fractions of the frame.
    var fishSpotHere: CGPoint {
        fishLive ?? fxHere.fishSpot(at: playheadFrame)
    }

    /// The cut the sheet is on, from its start to the next cut (for the playhead slider in the sheet).
    var fxCutRange: ClosedRange<Double> {
        guard let index = fxIndex else { return 0...max(0.1, timelineEnd) }
        let start = min(cuts[index].time, timelineEnd)
        let end = index + 1 < cuts.count ? cuts[index + 1].time : timelineEnd
        return start...max(start + 0.1, min(end, timelineEnd))
    }

    /// Moves the playhead inside the cut the sheet is on (so the circle can be keyframed across it).
    func scrubInCut(to seconds: Double) {
        let range = fxCutRange
        // Stops a frame short of the next cut, so the playhead stays on this one.
        let last = max(range.lowerBound, range.upperBound - 1.0 / 30)
        time = min(max(range.lowerBound, seconds), last)
        requestSeek(time)
    }

    func beginFishMove() {
        guard fishEditing else { return }
        pause()
        fishMoveStart = fxHere.fishSpot(at: playheadFrame)
        fishLive = fishMoveStart
    }

    /// `move` is how far the finger went, as fractions of the frame.
    func moveFish(by move: CGSize) {
        guard let start = fishMoveStart else { return }
        var x = Double(start.x) + Double(move.width)
        var y = Double(start.y) + Double(move.height)
        // Snaps to the middle.
        if abs(x - 0.5) < 0.03 { x = 0.5 }
        if abs(y - 0.5) < 0.03 { y = 0.5 }
        fishLive = CGPoint(x: min(0.95, max(0.05, x)), y: min(0.95, max(0.05, y)))
    }

    func endFishMove() {
        guard fishMoveStart != nil else { return }
        let spot = fishLive
        fishMoveStart = nil
        fishLive = nil
        if let spot { setFishSpot(spot) }
    }

    /// A tap on the video puts the circle's middle there.
    func placeFish(at point: CGPoint) {
        guard fishEditing else { return }
        setFishSpot(CGPoint(x: min(0.95, max(0.05, point.x)), y: min(0.95, max(0.05, point.y))))
    }

    func centerFish() {
        setFishSpot(CGPoint(x: 0.5, y: 0.5))
    }

    /// Puts the circle here. Without keyframes it sits there for the whole cut; with them, this
    /// makes (or moves) the keyframe at the playhead.
    private func setFishSpot(_ spot: CGPoint) {
        var fx = fxHere
        if var keys = fx.fishKeys, !keys.isEmpty {
            let at = playheadFrame
            var key = FishKey(time: at, x: Double(spot.x), y: Double(spot.y))
            let moved: Bool
            if let index = keys.firstIndex(where: { abs($0.time - at) < 0.5 / 30 }) {
                key.ease = keys[index].ease
                keys[index] = key
                moved = true
            } else {
                keys.append(key)
                keys.sort { $0.time < $1.time }
                moved = false
            }
            fx.fishKeys = keys
            setFXHere(fx)
            notice = moved ? "Circle keyframe moved." : "Circle keyframe \(keys.count) at \(Self.clock(at))."
        } else {
            fx.fishX = Double(spot.x)
            fx.fishY = Double(spot.y)
            setFXHere(fx)
        }
    }

    /// The circle's keyframe at the playhead, if there is one.
    var fishKeyHere: Int? {
        let at = playheadFrame
        return fxHere.fishKeys?.firstIndex { abs($0.time - at) < 0.5 / 30 }
    }

    var fishKeyCount: Int { fxHere.fishKeys?.count ?? 0 }

    /// Keeps where the circle is now as a keyframe at the playhead. The first one starts the
    /// animating: after it, each move of the circle makes or updates the keyframe at the playhead.
    func addFishKey() {
        guard fishKeyHere == nil else { return }
        var fx = fxHere
        let at = playheadFrame
        let spot = fx.fishSpot(at: at)
        var keys = fx.fishKeys ?? []
        keys.append(FishKey(time: at, x: Double(spot.x), y: Double(spot.y)))
        keys.sort { $0.time < $1.time }
        fx.fishKeys = keys
        setFXHere(fx)
        notice = keys.count == 1
            ? "Keyframing the circle from here. Move the playhead and drag the circle: each move makes a keyframe there."
            : "Circle keyframe \(keys.count) at \(Self.clock(at))."
    }

    func deleteFishKeyHere() {
        guard let index = fishKeyHere else { return }
        var fx = fxHere
        let shown = fx.fishSpot(at: playheadFrame)
        fx.fishKeys?.remove(at: index)
        // The last one gone: the circle stays where it showed here, for the whole cut.
        if fx.fishKeys?.isEmpty == true {
            fx.fishKeys = nil
            fx.fishX = Double(shown.x)
            fx.fishY = Double(shown.y)
            setFXHere(fx)
            notice = "The circle isn't animated any more."
            return
        }
        setFXHere(fx)
        notice = "Circle keyframe deleted."
    }

    /// Stops animating the circle: it stays where it shows at the playhead, for the whole cut.
    func stopFishKeys() {
        var fx = fxHere
        guard fx.fishKeys != nil else { return }
        let shown = fx.fishSpot(at: playheadFrame)
        fx.fishKeys = nil
        fx.fishX = Double(shown.x)
        fx.fishY = Double(shown.y)
        setFXHere(fx)
        notice = "The circle isn't animated any more."
    }

    // MARK: Keyframed sliders on the Fx page

    /// A slider's keyframes on the cut the Fx page is on (empty when it isn't keyframed).
    func fxKeys(_ param: FXParam) -> [FXValueKey] {
        fxHere.keys?[param.rawValue] ?? []
    }

    /// The playhead sits on one of this slider's keyframes.
    func fxKeyOnHere(_ param: FXParam) -> Bool {
        let at = playheadFrame
        return fxKeys(param).contains { abs($0.time - at) < 0.5 / 30 }
    }

    /// What the slider shows: its value at the playhead (keyframed) or its one value.
    func fxValueHere(_ param: FXParam) -> Double {
        FXValueKey.value(fxKeys(param), at: playheadFrame) ?? fxHere[param]
    }

    /// A slider let go: a keyframed one keeps the value as a keyframe at the playhead (a new one,
    /// or the one already there); otherwise it's the slider's one value for the whole cut.
    func setFXValue(_ param: FXParam, _ value: Double) {
        var fx = fxHere
        var keys = fx.keys?[param.rawValue] ?? []
        if keys.isEmpty {
            fx[param] = value
        } else {
            let at = playheadFrame
            if let same = keys.firstIndex(where: { abs($0.time - at) < 0.5 / 30 }) {
                keys[same].value = value
            } else {
                keys.append(FXValueKey(time: at, value: value))
                keys.sort { $0.time < $1.time }
            }
            var all = fx.keys ?? [:]
            all[param.rawValue] = keys
            fx.keys = all
        }
        setFXHere(fx)
    }

    /// The diamond beside a slider: on a keyframe it takes it off; anywhere else it adds one with
    /// the value showing now. The first one starts keyframing that slider.
    func toggleFXKey(_ param: FXParam, name: String) {
        guard fxIndex != nil else { return }
        var fx = fxHere
        var all = fx.keys ?? [:]
        var keys = all[param.rawValue] ?? []
        let at = playheadFrame
        let shown = fxValueHere(param)
        if let same = keys.firstIndex(where: { abs($0.time - at) < 0.5 / 30 }) {
            keys.remove(at: same)
            if keys.isEmpty {
                // The last one gone: the slider holds the value it showed here, for the whole cut.
                fx[param] = shown
                notice = "\(name) isn't animated any more."
            } else {
                notice = "\(name) keyframe taken off."
            }
        } else {
            keys.append(FXValueKey(time: at, value: shown))
            keys.sort { $0.time < $1.time }
            notice = keys.count == 1
                ? "Keyframing \(name) from here. Move the playhead and the slider: each change makes a keyframe there."
                : "\(name) keyframe \(keys.count) at \(Self.clock(at))."
        }
        all[param.rawValue] = keys.isEmpty ? nil : keys
        fx.keys = all.isEmpty ? nil : all
        setFXHere(fx)
    }

    /// Stop on the Fx page: stops playing and goes back to where this cut starts.
    func stopCutPlay() {
        pause()
        let start = fxCutRange.lowerBound
        time = start
        requestSeek(start)
    }

    func jumpToFishKey(forward: Bool) {
        pause()
        let times = (fxHere.fishKeys ?? []).map { $0.time }
        let now = playheadFrame
        let target = forward ? times.first(where: { $0 > now + 0.5 / 30 }) : times.last(where: { $0 < now - 0.5 / 30 })
        guard let target else {
            notice = forward ? "No later circle keyframe." : "No earlier circle keyframe."
            return
        }
        time = min(max(0, target), timelineEnd)
        requestSeek(time)
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
        let shown = zoom.apply(to: rendered)
        let from = zoom.apply(to: draftHere?.framing ?? rendered)
        let wanted = Framing(scale: from.scale * scale,
                             x: from.x * scale + Double(shift.width),
                             y: from.y * scale + Double(shift.height))
        let held = zoom.apply(to: zoom.undo(wanted).clamped())
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
        let from = zoom.apply(to: draftHere?.framing ?? rendered)
        let wanted = Framing(scale: from.scale * scale,
                             x: from.x * scale + Double(shift.width),
                             y: from.y * scale + Double(shift.height))
        draft = FramingDraft(layer: index, time: playheadFrame, framing: zoom.undo(wanted).clamped())
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
        // The effects sheet is open on Fisheye: the diamond keyframes its circle.
        if fishEditing {
            addFishKey()
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
        if fishEditing { return fishKeyHere }
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
        if fishEditing { return fishKeyCount }
        if maskEditing { return maskKeyCount }
        if let id = overlayPick { return overlay(id)?.keys?.count ?? 0 }
        return framedLayer.map { frameKeys($0).count } ?? 0
    }

    /// How the keyframe at (or just before) the playhead moves on to the next one.
    var easeHere: Ease? {
        if fishEditing {
            let at = playheadFrame
            return fxHere.fishKeys?.last(where: { $0.time <= at + 0.5 / 30 })?.ease
        }
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
        if fishEditing {
            var fx = fxHere
            let at = playheadFrame
            guard let key = fx.fishKeys?.lastIndex(where: { $0.time <= at + 0.5 / 30 }) else { return }
            fx.fishKeys?[key].ease = ease
            setFXHere(fx)
            notice = "\(ease.name) from this keyframe to the next."
            return
        }
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
        if fishEditing {
            deleteFishKeyHere()
            return
        }
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
        if fishEditing {
            stopFishKeys()
            return
        }
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
        if fishEditing {
            jumpToFishKey(forward: forward)
            return
        }
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

    // MARK: Music and sound effects

    /// The most audio rows (music and sound effects together).
    static let maxSoundLanes = 3

    /// How many audio rows there are (rows stay packed: A1, A2, ...).
    var soundLaneCount: Int { (sounds.map(\.lane).max() ?? -1) + 1 }

    func sound(_ id: UUID) -> SavedMusic? { sounds.first { $0.id == id } }

    /// With the Song row off: the song and the videos' own sound at zero, added sounds as they are
    /// (nil: everything plays).
    private func songMix(_ built: TimelineBuilder.Built) -> AVAudioMix? {
        guard soundMuted else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = built.composition.tracks(withMediaType: .audio)
            .filter { !built.musicTracks.contains($0.trackID) }
            .map { track in
                let silent = AVMutableAudioMixInputParameters(track: track)
                silent.setVolume(0, at: .zero)
                return silent
            }
        return mix
    }

    /// Added sounds, ready for the timeline (any whose file couldn't be read are left out).
    private var soundsPlay: [TimelineBuilder.Music] {
        sounds.compactMap { sound in
            guard let file = soundTracks[sound.id] else { return nil }
            return TimelineBuilder.Music(track: file.track, from: file.start + sound.from,
                                         at: sound.at, length: sound.length)
        }
    }

    private func clearSounds() {
        sounds = []
        soundTracks = [:]
        soundPick = nil
    }

    /// The + under the tracks: music or a sound effect from Files, from the playhead on.
    func addSoundFile(_ url: URL, effect: Bool) async {
        guard let id = currentProject?.id else { return }
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        guard let source = Self.keepSound(url, in: id) else {
            problem = "Couldn't open that file. Try another one."
            return
        }
        await placeSound(source, name: url.deletingPathExtension().lastPathComponent, from: 0, length: nil,
                         effect: effect)
    }

    /// The + under the tracks: a creatrr song, or just one of its sections, from the playhead on.
    func addMusic(_ song: CreatrrSong, part: CreatrrPart?) async {
        guard let id = currentProject?.id else { return }
        guard let url = CreatrrLibrary.audioURL(song), let source = Self.keepSound(url, in: id) else {
            problem = "Couldn't open that song from creatrr. Check it has a track, then try again."
            return
        }
        var from = 0.0
        var length: Double?
        var name = song.name
        if let part {
            from = max(0, part.time)
            if let index = song.parts.firstIndex(where: { $0.id == part.id }), let end = song.partEnd(index), end > from {
                length = end - from
            }
            name = "\(song.name) · \(part.name)"
        }
        await placeSound(source, name: name, from: from, length: length, effect: false)
    }

    /// A copy of the file in the project's folder, so the sound stays with the project.
    private static func keepSound(_ url: URL, in id: UUID) -> MediaSource? {
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = "music-" + UUID().uuidString + "." + ext
        let to = ProjectStore.folder(for: id).appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: to)
        } catch {
            return nil
        }
        return .file(name)
    }

    /// The first audio row with room from `at` for `length` (nil: none, and no room for a new row).
    private func soundLane(at: Double, length: Double, skipping id: UUID? = nil, prefer: Int? = nil) -> Int? {
        func free(_ lane: Int) -> Bool {
            !sounds.contains { $0.id != id && $0.lane == lane && $0.at < at + length - 0.001 && at < $0.at + $0.length - 0.001 }
        }
        if let prefer, free(prefer) { return prefer }
        let used = sounds.filter { $0.id != id }.map(\.lane)
        let rows = (used.max() ?? -1) + 1
        if let lane = (0..<rows).first(where: free) { return lane }
        return rows < Self.maxSoundLanes ? rows : nil
    }

    /// Puts the music or sound effect on the timeline at the playhead, on the first audio row with
    /// room (or a new row).
    private func placeSound(_ source: MediaSource, name: String, from: Double, length: Double?, effect: Bool) async {
        guard let id = currentProject?.id else { return }
        pause()
        problem = nil
        busy = effect ? "Adding the sound…" : "Adding the music…"
        defer { busy = nil }
        func dropFile() {
            if let url = ProjectStore.url(of: source, in: id) { try? FileManager.default.removeItem(at: url) }
        }
        guard let asset = await PhotosLoader.open(source, project: id),
              let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await audio.load(.timeRange), range.duration.seconds > 0.05 else {
            dropFile()
            problem = "That file has no sound to add."
            return
        }
        let fileLength = range.duration.seconds
        let start = min(max(0, from), max(0, fileLength - 0.05))
        let plays = min(length ?? fileLength - start, fileLength - start)
        let at = min(max(time, loopStart), max(loopStart, loopEnd - 0.1))
        guard let lane = soundLane(at: at, length: plays) else {
            dropFile()
            notice = "\(Self.maxSoundLanes) audio rows is the most. Move the playhead to where an audio row is free."
            return
        }
        let added = SavedMusic(source: source, name: name, from: start, at: at, length: plays, lane: lane, effect: effect)
        soundTracks[added.id] = (asset, audio, range.start.seconds)
        sounds.append(added)
        pickSound(added.id)
        rebuildAll()
    }

    /// Picks a piece of music or a sound effect (nil lets go): its tools.
    func pickSound(_ id: UUID?) {
        soundPick = id.flatMap { sound($0) != nil ? $0 : nil }
        guard soundPick != nil else { return }
        overlayPick = nil
        editPick = nil
        lyricsPicked = false
        titlePick = nil
    }

    /// The picked sound starts at the playhead instead (on another row if its own is taken there).
    func moveSoundHere(_ id: UUID) {
        guard let index = sounds.firstIndex(where: { $0.id == id }) else { return }
        let at = min(max(time, loopStart), max(loopStart, loopEnd - 0.1))
        guard abs(at - sounds[index].at) > 0.001 else { return }
        guard let lane = soundLane(at: at, length: sounds[index].length, skipping: id, prefer: sounds[index].lane) else {
            notice = "Every audio row is taken there. Move the playhead, or delete a sound first."
            return
        }
        sounds[index].at = at
        sounds[index].lane = lane
        packSoundLanes()
        notice = nil
        rebuildAll()
    }

    /// Takes the music or sound effect off (the song or the videos' own sound stays).
    func deleteSound(_ id: UUID) {
        guard let gone = sound(id) else { return }
        if let project = currentProject?.id, let url = ProjectStore.url(of: gone.source, in: project) {
            try? FileManager.default.removeItem(at: url)
        }
        sounds.removeAll { $0.id == id }
        soundTracks[id] = nil
        if soundPick == id { soundPick = nil }
        packSoundLanes()
        rebuildAll()
    }

    /// Audio rows stay A1, A2, ... with none left empty.
    private func packSoundLanes() {
        let used = Array(Set(sounds.map(\.lane))).sorted()
        for index in sounds.indices {
            sounds[index].lane = used.firstIndex(of: sounds[index].lane) ?? 0
        }
    }

    // MARK: Exporting

    /// Renders the edit (the real cuts, never a preview) to a 1080 x 1920 (or 1920 x 1080 horizontal), 30 fps video and saves it
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
        // A muted song with added music or sound effects: those play, the song doesn't.
        let addedOnly = withSound && soundMuted && !sounds.isEmpty
        let withSound = withSound && !soundMuted
        let source: TimelineBuilder.Built
        do {
            if withSound {
                source = built
            } else if addedOnly {
                source = try TimelineBuilder.build(layers: layers, soundtrack: nil, duration: duration,
                                                   length: timelineEnd, music: soundsPlay,
                                                   overlays: overlays, media: overlayMedia)
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
                                                                     overlays: overlays, media: overlayMedia, board: board,
                                                                     filter: filter)
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
