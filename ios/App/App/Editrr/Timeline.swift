import AVFoundation
import UIKit
import ImageIO

/// How a video got its place on the timeline.
enum SyncState: String, Equatable, Codable {
    case reference   // it's the sound everything else lines up to (no-song mode)
    case matched     // lined up by its sound
    case unsure      // placed at the best guess, but the evidence was thin: worth a look
    case noSound     // nothing to match, so it starts at 0
    case manual      // the person moved it
}

/// How a video sits in the 9:16 frame. Scale 1 fills the frame; x and y shift it by fractions of
/// the frame (right and down are positive).
struct Framing: Equatable, Sendable, Codable {
    var scale: Double = 1
    var x: Double = 0
    var y: Double = 0

    static let identity = Framing()
    static let maxScale = 5.0

    /// Keeps the picture covering the whole frame, so there are never black edges.
    func clamped() -> Framing {
        let s = min(max(scale, 1), Self.maxScale)
        let room = (s - 1) / 2
        return Framing(scale: s, x: min(max(x, -room), room), y: min(max(y, -room), room))
    }

    /// Part way (0...1) from this framing to another. Zoom moves evenly to the eye.
    func mixed(with other: Framing, _ amount: Double) -> Framing {
        let scale = exp(log(self.scale) + (log(other.scale) - log(self.scale)) * amount)
        return Framing(scale: scale, x: x + (other.x - x) * amount, y: y + (other.y - y) * amount)
    }

    /// Zooms the whole framing about the middle of the frame (used by auto zoom).
    func zoomed(_ factor: Double) -> Framing {
        Framing(scale: scale * factor, x: x * factor, y: y * factor)
    }
}

/// How a keyframe moves on to the next one.
enum Ease: String, CaseIterable, Sendable, Codable {
    case smooth, linear, hold

    var name: String {
        switch self {
        case .smooth: "Smooth"
        case .linear: "Even"
        case .hold: "Jump"
        }
    }

    func apply(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        switch self {
        case .smooth: return p * p * (3 - 2 * p)
        case .linear: return p
        case .hold: return 0
        }
    }
}

/// A framing at a moment in a video (seconds into the video, so it moves with the clip).
struct Keyframe: Equatable, Sendable, Codable {
    var time: Double
    var framing: Framing
    var ease: Ease = .smooth
}

/// A slow zoom across one cut (the stretch from a switch to the next), like DaVinci's dynamic zoom.
enum AutoZoom: String, CaseIterable, Sendable, Codable {
    case off, zoomIn, zoomOut

    var name: String {
        switch self {
        case .off: "Off"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        }
    }

    /// How much bigger the picture gets over the cut with the ready-made Zoom in and Zoom out.
    static let amount = 0.15

    /// The ready-made start and end frames: Zoom in ends on a smaller frame in the middle, Zoom
    /// out starts on one.
    var presetFrames: (start: ZoomBox, end: ZoomBox) {
        let inner = ZoomBox(x: 0.5, y: 0.5, size: 1 / (1 + Self.amount))
        switch self {
        case .off: return (.full, .full)
        case .zoomIn: return (.full, inner)
        case .zoomOut: return (inner, .full)
        }
    }
}

/// A slow zoom's start or end frame, like DaVinci's Dynamic Zoom boxes: the part of the frame
/// that fills the screen. Same shape as the frame; `x`, `y` is its middle and `size` its width,
/// all as fractions of the frame. It always stays inside the frame, so no black edges show.
struct ZoomBox: Equatable, Sendable, Codable {
    var x: Double = 0.5
    var y: Double = 0.5
    var size: Double = 1

    static let full = ZoomBox()
    static let smallest = 0.2

    /// Kept inside the frame and no smaller than `smallest`.
    func held() -> ZoomBox {
        let s = min(max(size, Self.smallest), 1)
        let half = s / 2
        return ZoomBox(x: min(max(x, half), 1 - half), y: min(max(y, half), 1 - half), size: s)
    }

    /// The framing that makes this box fill the screen, on top of a video's own framing.
    func apply(to framing: Framing) -> Framing {
        let s = max(size, 0.01)
        return Framing(scale: framing.scale / s, x: (framing.x - (x - 0.5)) / s, y: (framing.y - (y - 0.5)) / s)
    }

    /// Takes this box back off a framing (the opposite of `apply`).
    func undo(_ framing: Framing) -> Framing {
        Framing(scale: framing.scale * size, x: framing.x * size + (x - 0.5), y: framing.y * size + (y - 0.5))
    }

    /// Part way (0...1, already eased) from one box to another. The size moves evenly to the eye.
    static func between(_ a: ZoomBox, _ b: ZoomBox, _ t: Double) -> ZoomBox {
        let size = exp(log(max(a.size, 0.01)) + (log(max(b.size, 0.01)) - log(max(a.size, 0.01))) * t)
        return ZoomBox(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, size: size)
    }
}

enum Keyframes {
    /// The framing at a time, from keyframes sorted by time (same time base as `time`).
    static func framing(_ keys: [Keyframe], at time: Double) -> Framing {
        guard let first = keys.first else { return .identity }
        if time <= first.time { return first.framing }
        guard let last = keys.last, time < last.time else { return keys.last?.framing ?? .identity }
        for (a, b) in zip(keys, keys.dropFirst()) where time >= a.time && time < b.time {
            let span = b.time - a.time
            let progress = span > 0 ? (time - a.time) / span : 1
            return a.framing.mixed(with: b.framing, a.ease.apply(progress))
        }
        return last.framing
    }
}

/// One video layer on the timeline. Layer 1 is the top layer.
struct Layer: Identifiable {
    let id: Int
    let asset: AVAsset
    let track: AVAssetTrack
    /// Asset time (seconds) of the first video frame.
    let trackStart: Double
    /// Video length in seconds.
    let length: Double
    let orientation: CGImagePropertyOrientation
    let displaySize: CGSize
    let fps: Float
    var thumbnail: UIImage?
    var sound: SoundPrint?
    /// Timeline second where the first video frame plays. Can be negative (starts before the song).
    var offset: Double
    var sync: SyncState
    /// Seconds trimmed off the video's start and end.
    var trimStart: Double = 0
    var trimEnd: Double = 0
    /// Other offsets where its sound also fits the song (a repeated chorus). Tap one to move there.
    var alternatives: [Double] = []
    /// Zoom and position over time, sorted by time (seconds into the video).
    var keyframes: [Keyframe] = []
    /// Which picked video this layer shows (copies share one), for saving the project.
    var video: Int = 0
    /// The track's color, from LayerTint.all (nil: the color for its number).
    var color: Int? = nil
    /// The video's own sound (played when editing a video; a performance plays the song).
    var audio: AVAssetTrack? = nil
    /// How many times longer it plays than it was shot: 2 for a take shot to the song at double
    /// speed (it plays in slow motion), 0.5 for one shot to the song at half speed. When it isn't
    /// 1, `asset` is the video already slowed down or sped up, and `original` is the video as shot.
    var speed: Double = 1
    var original: LayerSource? = nil
    /// Its own sound is off (editing a video).
    var muted = false
    /// Its own sound with the voice isolated (nil: as recorded). Plays in place of `audio`.
    var voice: VoiceTrack? = nil

    /// Timeline seconds where the kept part of the clip starts and ends (can run past 0...duration).
    var clipStart: Double { offset + trimStart }
    var clipEnd: Double { offset + length - trimEnd }
    /// Deleted on the edit page: no length left (kept, so Undo can bring it back).
    var gone: Bool { clipEnd - clipStart < 0.001 }

    /// The part of the timeline this video covers, inside 0...duration.
    func footage(in duration: Double) -> ClosedRange<Double>? {
        let start = max(0, clipStart)
        let end = min(duration, clipEnd)
        return end - start > 0.001 ? start...end : nil
    }
}

/// A video as it was shot, before it was slowed down or sped up.
struct LayerSource {
    let asset: AVAsset
    let track: AVAssetTrack
    let audio: AVAssetTrack?
    let trackStart: Double
    let length: Double
    let sound: SoundPrint?
}

/// The sound that plays: the song, or (with no song) the first video's own sound.
struct Soundtrack {
    let asset: AVAsset
    let track: AVAssetTrack
    let trackStart: Double
    let length: Double
    /// Timeline time = asset time + shift.
    var shift: Double
    let sound: SoundPrint?
    let name: String
}

/// From this time on, show this layer.
struct Cut: Equatable, Codable {
    /// Where this cut's slow zoom starts and ends (its own frames, or Zoom in / out's).
    var zoomStart: ZoomBox { zoomFrom ?? zoom.presetFrames.start }
    var zoomEnd: ZoomBox { zoomTo ?? zoom.presetFrames.end }

    var time: Double
    var layer: Int
    /// A slow zoom across this cut only (each cut has its own).
    var zoom: AutoZoom = .off
    /// The slow zoom's own start and end frames (nil: Zoom in or Zoom out's ready-made ones).
    var zoomFrom: ZoomBox?
    var zoomTo: ZoomBox?
    /// How this cut comes in from the one before (nil: a plain cut).
    var transition: Transition?
    /// Effects on this cut (nil: none).
    var fx: CutFX?
}

/// A stretch of the finished video and which layer shows in it (nil: nothing there, black).
struct Segment: Equatable {
    var start: Double
    var end: Double
    var layer: Int?
}

enum Program {
    /// The layer the cuts ask for at a time.
    static func chosen(at time: Double, cuts: [Cut]) -> Int {
        var layer = cuts.first?.layer ?? 0
        for cut in cuts where cut.time <= time + 1e-6 { layer = cut.layer }
        return layer
    }

    /// What shows when. If the chosen layer has no footage at a spot, the top layer that does
    /// shows instead. `solo` shows one layer wherever it has footage.
    static func segments(cuts: [Cut], layers: [Layer], duration: Double, solo: Int? = nil) -> [Segment] {
        guard duration > 0 else { return [] }
        var marks: Set<Double> = [0, duration]
        for cut in cuts where cut.time > 0 && cut.time < duration { marks.insert(cut.time) }
        for layer in layers {
            if let range = layer.footage(in: duration) {
                marks.insert(range.lowerBound)
                marks.insert(range.upperBound)
            }
        }
        let times = marks.sorted()
        var result: [Segment] = []
        for (start, end) in zip(times, times.dropFirst()) where end - start > 0.0005 {
            let middle = (start + end) / 2
            let has: (Int) -> Bool = { index in
                guard layers.indices.contains(index), let range = layers[index].footage(in: duration) else { return false }
                return range.contains(middle)
            }
            let pick: Int?
            if let solo {
                pick = has(solo) ? solo : nil
            } else {
                let wanted = chosen(at: middle, cuts: cuts)
                pick = has(wanted) ? wanted : layers.indices.first(where: has)
            }
            if let last = result.last, last.layer == pick {
                result[result.count - 1].end = end
            } else {
                result.append(Segment(start: start, end: end, layer: pick))
            }
        }
        return result
    }
}

/// Turns the timeline into something AVPlayer can play: the soundtrack plus one composition
/// track per video, each placed at its offset.
@MainActor
enum TimelineBuilder {
    struct Built {
        let composition: AVMutableComposition
        let tracks: [Int: LayerInfo]
        /// Video overlays' composition tracks.
        var overlayTracks: [UUID: CMPersistentTrackID] = [:]
        /// The added music and sound effects' sound tracks (they keep playing when the song is muted).
        var musicTracks: Set<CMPersistentTrackID> = []
        /// The song's sound track, when there's a song.
        var songTrack: CMPersistentTrackID?
        var duration: CMTime { composition.duration }
    }

    /// Music or a sound effect added on the edit page: plays from `from` (file time) for `length`,
    /// at timeline `at`.
    struct Music {
        let track: AVAssetTrack
        let from: Double
        let at: Double
        let length: Double
    }

    /// The open project's frame: 1080 x 1920 (vertical), or 1920 x 1080 for a horizontal project.
    /// EditorModel sets it as a project opens or starts.
    static var canvas = CGSize(width: 1080, height: 1920)

    static func frame(wide: Bool) -> CGSize {
        wide ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// `videoSound`: each video's own sound plays under its picture (editing a video, where the
    /// videos sit back to back), instead of the song. `length`: the whole timeline when clips
    /// after the performance run past the song (the song and videos still stop at `duration`).
    static func build(layers: [Layer], soundtrack: Soundtrack?, duration: Double, length: Double? = nil,
                      videoSound: Bool = false, music: [Music] = [],
                      overlays: [SavedOverlay] = [], media: [UUID: OverlayMedia] = [:]) throws -> Built {
        let composition = AVMutableComposition()
        let total = max(duration, length ?? duration)

        // Added music and sound effects: each its own sound track, under everything, cut off where
        // the timeline ends.
        var musicTracks: Set<CMPersistentTrackID> = []
        for piece in music {
            let place = max(0, piece.at)
            let play = min(piece.length, total - place)
            guard play > 0.01, let audio = composition.addMutableTrack(withMediaType: .audio,
                                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do {
                try audio.insertTimeRange(CMTimeRange(start: time(piece.from), duration: time(play)),
                                          of: piece.track, at: time(place))
                musicTracks.insert(audio.trackID)
            } catch {
                composition.removeTrack(audio)
            }
        }

        var songTrack: CMPersistentTrackID?
        if let soundtrack, let audio = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
            let place = soundtrack.trackStart + soundtrack.shift          // timeline time of its first sound
            let skip = max(0, -place)                                     // part before the timeline starts
            let length = min(soundtrack.length - skip, duration - max(0, place))
            if length > 0.01 {
                try audio.insertTimeRange(
                    CMTimeRange(start: time(soundtrack.trackStart + skip), duration: time(length)),
                    of: soundtrack.track, at: time(max(0, place)))
                songTrack = audio.trackID
            } else {
                composition.removeTrack(audio)
            }
        }

        var tracks: [Int: LayerInfo] = [:]
        var problems: [String] = []
        for layer in layers {
            guard let range = layer.footage(in: duration) else { continue }
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let skip = range.lowerBound - layer.offset                    // seconds cut off the video's start
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: time(layer.trackStart + skip), duration: time(range.upperBound - range.lowerBound)),
                    of: layer.track, at: time(range.lowerBound))
                tracks[layer.id] = LayerInfo(trackID: track.trackID, orientation: layer.orientation)
                if videoSound, !layer.muted, let sound = layer.voice?.track ?? layer.audio,
                   let audio = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                    // The voice-isolated sound starts (at 0) where the video's own sound starts.
                    let from = max(0, layer.trackStart + skip - (layer.voice?.start ?? 0))
                    do {
                        try audio.insertTimeRange(
                            CMTimeRange(start: time(from),
                                        duration: time(range.upperBound - range.lowerBound)),
                            of: sound, at: time(range.lowerBound))
                    } catch {
                        composition.removeTrack(audio)   // a sound shorter than its picture: left out
                    }
                }
            } catch {
                composition.removeTrack(track)
                problems.append("video \(layer.id + 1): \(EditorError.explain(error))")
            }
        }
        if tracks.isEmpty && !layers.isEmpty {
            throw EditorError.couldNotBuild(problems.isEmpty ? "None of the videos overlap the song." : problems.joined(separator: "; "))
        }
        if !problems.isEmpty { print("editrr timeline problems:", problems.joined(separator: "; ")) }

        // Video overlays: each on its own track, silent, where it sits on the timeline.
        var overlayTracks: [UUID: CMPersistentTrackID] = [:]
        for overlay in overlays where overlay.isVideo {
            guard let source = media[overlay.id], let sourceTrack = source.track else { continue }
            let from = max(0, overlay.start)
            let to = min(total, overlay.end, overlay.start + source.videoLength - overlay.trimStart)
            guard to - from > 0.05,
                  let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let skip = overlay.trimStart + (from - overlay.start)
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: time(source.trackStart + skip), duration: time(to - from)),
                    of: sourceTrack, at: time(from))
                overlayTracks[overlay.id] = track.trackID
            } catch {
                composition.removeTrack(track)
            }
        }
        // A photo after the song has no frames of its own: an empty stretch keeps the video going
        // to the end of the timeline, and the compositor draws the photo there.
        let have = composition.duration.seconds
        if total - have > 0.02,
           let padding = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            padding.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: time(total)))
        }
        return Built(composition: composition, tracks: tracks, overlayTracks: overlayTracks, musicTracks: musicTracks,
                     songTrack: songTrack)
    }

    /// One instruction per stretch, each asking for just the layer that shows, so the phone only
    /// decodes one video at a time no matter how many layers there are.
    static func videoComposition(segments: [Segment], built: Built, cuts: [Cut], layers: [Layer],
                                 duration: Double, length: Double? = nil, lyrics: LyricsOverlay? = nil,
                                 overlays: [SavedOverlay] = [], media: [UUID: OverlayMedia] = [:],
                                 board: OverlayBoard? = nil, filter: ColorLook = .none,
                                 filterAmount: Double = 1, adjust: ColorAdjust = ColorAdjust()) -> AVVideoComposition {
        let end = built.duration
        let total = max(duration, length ?? duration)
        let windows = Transitions.windows(cuts: cuts, duration: duration)

        // Stretches split wherever the layer changes or a transition starts or ends.
        var marks: Set<Double> = []
        for segment in segments {
            marks.insert(segment.start)
            marks.insert(segment.end)
        }
        for window in windows {
            marks.insert(max(0, window.start))
            marks.insert(min(duration, window.end))
        }
        // Overlays come and go too. A video overlay shows only where its track has frames.
        func overlaySpan(_ overlay: SavedOverlay) -> (Double, Double)? {
            if overlay.isVideo {
                guard built.overlayTracks[overlay.id] != nil, let source = media[overlay.id] else { return nil }
                let to = min(total, overlay.end, overlay.start + source.videoLength - overlay.trimStart)
                return (max(0, overlay.start), to)
            }
            guard media[overlay.id]?.image != nil else { return nil }
            return (max(0, overlay.start), min(total, overlay.end))
        }
        let spans = overlays.compactMap { overlay in overlaySpan(overlay).map { (overlay, $0) } }
        for (_, span) in spans where span.1 > span.0 {
            marks.insert(span.0)
            marks.insert(span.1)
        }
        func overlaysAt(_ time: Double) -> [OverlayRef] {
            spans.filter { time > $0.1.0 && time < $0.1.1 }.map { entry in
                OverlayRef(id: entry.0.id, trackID: built.overlayTracks[entry.0.id],
                           orientation: media[entry.0.id]?.orientation ?? .up)
            }
        }
        let times = marks.sorted()

        func showing(_ time: Double) -> Int? {
            segments.first(where: { time >= $0.start && time < $0.end })?.layer
        }
        func covers(_ index: Int, _ from: Double, _ to: Double) -> Bool {
            guard layers.indices.contains(index), let range = layers[index].footage(in: duration) else { return false }
            return range.lowerBound <= from + 0.001 && range.upperBound >= to - 0.001
        }
        // A layer with the keyframes (moved onto the timeline), auto zoom and effects of one cut.
        func info(_ index: Int, section: Int) -> LayerInfo? {
            guard var info = built.tracks[index], layers.indices.contains(index) else { return nil }
            let layer = layers[index]
            let sectionStart = cuts.indices.contains(section) ? cuts[section].time : 0
            let sectionEnd = section + 1 < cuts.count ? cuts[section + 1].time : duration
            info.motion = LayerMotion(
                keyframes: layer.keyframes.map {
                    Keyframe(time: $0.time + layer.offset, framing: $0.framing, ease: $0.ease)
                },
                zoom: cuts.indices.contains(section) ? cuts[section].zoom : .off,
                sectionStart: sectionStart, sectionEnd: sectionEnd,
                zoomStart: cuts.indices.contains(section) ? cuts[section].zoomStart : .full,
                zoomEnd: cuts.indices.contains(section) ? cuts[section].zoomEnd : .full)
            info.fx = cuts.indices.contains(section) ? cuts[section].fx : nil
            info.layer = index
            return info
        }

        var instructions: [LayerInstruction] = []
        for (from, to) in zip(times, times.dropFirst()) where to - from > 0.0005 {
            // Each stretch starts exactly where the last one ended, so there's never a gap.
            let start = instructions.last?.timeRange.end ?? .zero
            let stop = time(to) < end ? time(to) : end
            guard start < stop else { continue }
            let middle = (from + to) / 2
            let section = cuts.lastIndex(where: { $0.time <= middle + 1e-6 }) ?? 0

            var stack: [LayerInfo] = []
            var transition: TransitionWindow?
            if let window = windows.first(where: { middle > $0.start && middle < $0.end }),
               let outgoing = showing(cuts[window.cut].time - 0.001),
               let incoming = showing(cuts[window.cut].time + 0.001),
               outgoing != incoming,
               covers(outgoing, window.start, window.end), covers(incoming, window.start, window.end),
               let into = info(incoming, section: window.cut),
               let out = info(outgoing, section: window.cut - 1) {
                stack = [into, out]
                transition = window
            } else if let index = showing(middle), let single = info(index, section: section) {
                stack = [single]
            }
            instructions.append(LayerInstruction(timeRange: CMTimeRange(start: start, end: stop),
                                                 layers: stack, transition: transition, lyrics: lyrics,
                                                 overlays: overlaysAt(middle), board: board, filter: filter,
                                                 filterAmount: filterAmount, adjust: adjust))
            if stop == end { break }
        }
        // The instructions must cover the whole video with no gap.
        if instructions.isEmpty || instructions.last!.timeRange.end != end {
            let from = instructions.last?.timeRange.end ?? .zero
            if from < end {
                instructions.append(LayerInstruction(timeRange: CMTimeRange(start: from, end: end), layers: [],
                                                     lyrics: lyrics, board: board, filter: filter,
                                                     filterAmount: filterAmount, adjust: adjust))
            }
        }

        let configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: LayerCompositor.self,
            frameDuration: CMTime(value: 1, timescale: 30),
            instructions: instructions,
            perFrameHDRDisplayMetadataPolicy: .propagate,
            renderSize: canvas
        )
        return AVVideoComposition(configuration: configuration)
    }

    /// Phone videos are stored sideways with a "turn me" note; this reads that note.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let degrees = atan2(transform.b, transform.a) * 180 / .pi
        switch degrees {
        case 45..<135: return .right
        case -135 ..< -45: return .left
        case 135...180, -180 ..< -135: return .down
        default: return .up
        }
    }
}
