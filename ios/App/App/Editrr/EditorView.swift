import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The whole app for now: pick the song and videos, then edit between them on the timeline.
struct EditorView: View {
    @State private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Back to creatrr (nil when editrr runs on its own).
    @Environment(\.creatrrBack) private var creatrrBack

    var body: some View {
        ZStack {
            Backdrop()
            switch model.stage {
            case .setup: SetupView(model: model)
            case .editing: EditingView(model: model)
            }
            if let busy = model.busy {
                BusyCard(message: busy)
            }
        }
        // Leaving the app writes any change that's still waiting.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
        // creatrr swiped back to the artist page: stop the song and save.
        .onReceive(NotificationCenter.default.publisher(for: .editrrPause)) { _ in
            if model.isPlaying { model.pause() }
            model.saveNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editrrSave)) { _ in model.saveNow() }
        // Shoot: the list of creatrr songs and parts, then the camera at the part picked.
        .sheet(isPresented: $model.shootPicking, onDismiss: {
            guard let choice = model.shootChoice else { return }
            model.shootChoice = nil
            Task { await model.shoot(choice.song, part: choice.part) }
        }) {
            ShootSongSheet { song, part in model.shootChoice = (song, part) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .frostedSheet()
        }
        .fullScreenCover(item: $model.shootPlan) { plan in
            CaptureView(song: plan.song, length: plan.length, songName: plan.songName, parts: plan.parts,
                        start: plan.start, end: plan.end, partName: plan.partName, tempo: plan.tempo, maxTakes: 10,
                        draft: { takes in Task { await model.finishShoot(plan, takes: takes, draft: true) } }) { takes in
                // Closed with nothing filmed from a section's record button: straight back to that section.
                if takes.isEmpty, plan.fromCreatrr, let creatrrBack {
                    Task { await model.finishShoot(plan, takes: takes) }
                    creatrrBack()
                    return
                }
                Task { await model.finishShoot(plan, takes: takes) }
            }
        }
        // A section's red record button in creatrr.
        .onReceive(NotificationCenter.default.publisher(for: .editrrShoot)) { _ in takeShoot() }
        .onAppear { takeShoot() }
        // Inside creatrr, the left-edge swipe back to the artist page only works from home, so it
        // never fights the timeline.
        .onChange(of: model.stage, initial: true) { _, stage in
            EditrrStage.editing = stage == .editing
        }
    }

    /// Picks up a part creatrr asked to shoot.
    private func takeShoot() {
        guard let request = EditrrShoot.pending else { return }
        EditrrShoot.pending = nil
        Task { await model.shootFromCreatrr(request) }
    }
}

// MARK: - Setup

/// Home, like Edits: "Projects" over a two-column grid of tall thumbnails, and a round + in the
/// corner that opens the new video sheet.
struct SetupView: View {
    @Bindable var model: EditorModel
    @State private var renaming: SavedProject?
    @State private var newName = ""
    @State private var deleting: SavedProject?
    @State private var showNew = false
    /// Shoot was picked on the new video pop-up: its song list opens once the pop-up closes.
    @State private var shootNext = false
    /// The new video pop-up: short for the first choice, full height once the steps show.
    @State private var newHeight: PresentationDetent = .medium
    @Environment(\.creatrrBack) private var back
    @Environment(\.creatrrBackTitle) private var backTitle
    @Environment(\.creatrrBare) private var bare

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if back == nil || bare {
                        // Opened from inside a creatrr page (no tabs above): a way back.
                        if bare, let back {
                            Button(action: back) {
                                Label("Back", systemImage: "chevron.left")
                                    .font(.headline)
                                    .foregroundStyle(Tint.accent)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                        }
                        Text("Edits")
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-0.8)
                            .padding(.top, 16)
                            .padding(.bottom, 18)
                    } else {
                        // Inside creatrr, creatrr's own header and tabs (Projects, Artists, Edits) sit above.
                        Color.clear.frame(height: 6)
                    }

                    if let problem = model.problem, !showNew {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(Tint.bad)
                            .padding(.bottom, 16)
                    }
                    else if let notice = model.notice, !showNew {
                        // e.g. a shoot just saved as a draft.
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.bottom, 16)
                    }

                    if model.projects.isEmpty {
                        Text("Nothing yet. Tap New to start one.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.vertical, 12)
                    } else {
                        projectsGrid
                    }
                }
                // Full width even with no projects yet, so nothing shrinks toward the middle.
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // New: a frosted "+ New…" pill at the bottom, like creatrr's.
            Button {
                model.problem = nil
                model.notice = nil
                model.pendingKind = nil
                model.resetNewVideos()
                newHeight = .medium
                showNew = true
            } label: {
                FrostedNewLabel()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New video")
            .padding(.bottom, 18)
        }
        .background(Tint.backdrop.ignoresSafeArea())
        // Inside creatrr: swipe right anywhere to go back to Artists (or Projects).
        .simultaneousGesture(swipeBack)
        .sheet(isPresented: $showNew, onDismiss: {
            guard shootNext else { return }
            shootNext = false
            model.shootPicking = true
        }) {
            // A glassy pop-up from the bottom, like the lyrics options.
            NewVideoSheet(model: model, close: { showNew = false }, shoot: {
                shootNext = true
                showNew = false
            })
                .presentationDetents([.medium, .large], selection: $newHeight)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .frostedSheet()
        }
        .onChange(of: model.pendingKind) { _, kind in
            withAnimation(.snappy) { newHeight = kind == nil ? .medium : .large }
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let project = renaming { model.renameProject(project.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                if let project = deleting { model.deleteProject(project.id) }
                deleting = nil
            }
        } message: {
            Text("Your videos stay in Photos. Only the edit is deleted.")
        }
    }

    private var swipeBack: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard let back else { return }
                let across = max(value.translation.width, value.predictedEndTranslation.width * 0.6)
                guard across > 70, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                back()
            }
    }

    /// Saved projects, last edited first, three to a row. Tap to open; hold for Rename and Delete.
    private var projectsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3),
                  spacing: 16) {
            ForEach(model.projects) { project in
                Button {
                    Task { await model.open(project) }
                } label: {
                    ProjectTile(project: project, thumbnail: model.projectThumbs[project.id])
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        newName = project.name
                        renaming = project
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = project }
                }
            }
        }
    }
}

/// The glass sheet from New video: the song, the videos, a name, then Line them up.
struct NewVideoSheet: View {
    @Bindable var model: EditorModel
    let close: () -> Void
    /// Shoot: film takes to a part of a creatrr song.
    var shoot: (() -> Void)? = nil
    @State private var showFiles = false
    @State private var showSongVideo = false
    @State private var showVideos = false
    @State private var songPick: [PhotosPickerItem] = []
    @State private var videoPicks: [PhotosPickerItem] = []
    @State private var capturing = false
    @State private var creatrrSongs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    Spacer(minLength: 0)
                    if model.pendingKind != nil {
                        Button("Change") { model.pendingKind = nil }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tint.accent)
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 4)

                if let kind = model.pendingKind {
                    if kind == .performance {
                        songStep
                        divider
                    }
                    videosStep(kind)
                    divider
                    nameStep

                    Button {
                        // Close the sheet first so the progress shows while it gets ready.
                        close()
                        Task { await model.start() }
                    } label: {
                        Label(kind == .performance ? "Line them up" : "Start editing",
                              systemImage: kind == .performance ? "waveform.badge.magnifyingglass" : "film")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: model.canStart, big: true))
                    .disabled(!model.canStart)
                    .opacity(model.canStart ? 1 : 0.45)
                    .padding(.top, 24)

                    Text(kind == .performance
                         ? "Each video goes on its own lane, lined up to the song by the song playing in its own sound."
                         : "The videos play one after another, in the order you pick them, each with its own sound.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 12)
                } else {
                    kindChoice
                }

                if let busy = model.busy {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(busy).font(.callout)
                    }
                    .padding(.top, 14)
                }
                if let problem = model.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(Tint.bad)
                        .padding(.top, 14)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                Task { await model.chooseSongFile(url) }
            }
        }
    }

    private var title: String {
        switch model.pendingKind {
        case .video: "Edit a video"
        case .performance: "Edit a performance"
        case nil: "What are you making?"
        }
    }

    /// The first choice: a plain video edit, or a performance synced to a song.
    private var kindChoice: some View {
        VStack(spacing: 0) {
            kindCard(.video, icon: "film", title: "Edit a video",
                     detail: "Put videos together, then add text, lyrics and effects.")
            divider.padding(.leading, 48)
            kindCard(.performance, icon: PerformanceGlyph.name, title: "Edit a performance",
                     detail: "Sync takes to the song and cut between them.")
            if let shoot {
                divider.padding(.leading, 48)
                choiceCard(icon: "record.circle", tint: Tint.bad, title: "Shoot",
                           detail: "Pick part of a song and film up to 10 takes. Each one lines up to the song.",
                           action: shoot)
            }
        }
        .padding(.top, 6)
    }

    private func kindCard(_ kind: EditorModel.Kind, icon: String, title: String, detail: String) -> some View {
        choiceCard(icon: icon, tint: Tint.accent, title: title, detail: detail) { model.pendingKind = kind }
    }

    private func choiceCard(icon: String, tint: Color, title: String, detail: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
    }

    private var songStep: some View {
        StepCard(number: 1, title: "The song",
                 detail: model.songName ?? (model.noSong ? "No song. The first video's sound plays." : "Pick the song the video goes with."),
                 done: model.songName != nil || model.noSong) {
            HStack(spacing: 8) {
                // creatrr's songs, with their parts for Record.
                Button("creatrr") { creatrrSongs = true }
                    .buttonStyle(GlassButtonStyle(tint: Tint.calm))
                Button("Files") { showFiles = true }
                    .buttonStyle(GlassButtonStyle(tint: Tint.calm))
                Button("From a video") { openPicker { showSongVideo = true } }
                    .buttonStyle(GlassButtonStyle(tint: Tint.calm))
                Button("No song") { model.chooseNoSong() }
                    .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: model.noSong))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .sheet(isPresented: $creatrrSongs) {
            CreatrrSongsSheet { song in
                Task { await model.chooseCreatrrSong(song) }
            }
            .presentationDetents([.medium, .large])
            .frostedSheet()
        }
        .photosPicker(isPresented: $showSongVideo, selection: $songPick, maxSelectionCount: 1,
                      selectionBehavior: .ordered, matching: .videos,
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .onChange(of: songPick) { _, chosen in
            guard !chosen.isEmpty else { return }
            songPick = []
            Task { await model.chooseSongVideo(chosen) }
        }
    }

    private func videosStep(_ kind: EditorModel.Kind) -> some View {
        StepCard(number: kind == .performance ? 2 : 1, title: "Your videos",
                 detail: videosDetail(kind),
                 done: model.pickedVideoCount > 0) {
            HStack(spacing: 8) {
                Button {
                    openPicker { showVideos = true }
                } label: {
                    Label(model.pickedVideoCount == model.capturedCount ? "Pick videos" : "Pick again",
                          systemImage: "photo.stack")
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.calm))
                // Performance capture: film takes to the song right here; they line up on their own.
                if kind == .performance {
                    Button {
                        capturing = true
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.bad))
                    .disabled(model.captureSong == nil || model.pickedVideoCount >= 10)
                    .opacity(model.captureSong == nil || model.pickedVideoCount >= 10 ? 0.45 : 1)
                    .accessibilityHint("Film takes while the song plays. They line up on their own.")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .fullScreenCover(isPresented: $capturing) {
            if let song = model.captureSong {
                CaptureView(song: song.asset, length: song.length,
                            songName: model.songName ?? "Song", parts: model.captureParts,
                            tempo: model.captureTempo, maxTakes: 10 - model.pickedVideoCount) { takes in
                    model.addCaptured(takes)
                }
            }
        }
        .photosPicker(isPresented: $showVideos, selection: $videoPicks, maxSelectionCount: 10,
                      selectionBehavior: .ordered, matching: .videos,
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .onChange(of: videoPicks) { _, chosen in
            guard !chosen.isEmpty else { return }
            videoPicks = []
            Task { await model.chooseVideos(chosen) }
        }
    }

    private func videosDetail(_ kind: EditorModel.Kind) -> String {
        let count = model.pickedVideoCount
        guard count > 0 else {
            if kind == .performance {
                return model.captureSong == nil
                    ? "Pick 1 to 10 takes. To record, pick the song first."
                    : "Pick 1 to 10 takes, or record them to the song."
            }
            return "Pick 1 to 10, in the order they should play."
        }
        let recorded = model.capturedCount
        if recorded == 0 { return "\(count) \(count == 1 ? "video" : "videos") picked." }
        if recorded == count { return "\(count) \(count == 1 ? "take" : "takes") recorded." }
        return "\(count - recorded) picked, \(recorded) recorded."
    }

    private var nameStep: some View {
        StepCard(number: model.pendingKind == .performance ? 3 : 2, title: "Name it",
                 detail: "It saves as you edit, so you can open it again from home.",
                 done: !model.projectName.trimmingCharacters(in: .whitespaces).isEmpty) {
            TextField("", text: $model.projectName,
                      prompt: Text(model.songName.map { $0 == "Sound from a video" ? "Untitled" : $0 } ?? "Untitled")
                        .foregroundStyle(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
                }
        }
    }

    /// Asks for Photos access the first time (so videos open instantly), then shows the picker.
    private func openPicker(_ show: @escaping () -> Void) {
        Task {
            await PhotoAccess.ask()
            show()
        }
    }
}

/// One step of a new video: a number (a check once done), a title, a line, and its buttons.
/// Plain text, no card behind it.
struct StepCard<Actions: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .font(.title2)
                    .foregroundStyle(done ? Tint.good : .white.opacity(0.8))
                Text(title).font(.headline)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

// MARK: - Editing

struct EditingView: View {
    let model: EditorModel
    @AppStorage("safeZone") private var safeZone: SafeZone = .off
    @State private var fullScreen = false
    @State private var exporting = false
    @State private var autoEditing = false
    @State private var lyricsOpen = false
    /// The lyrics' look on its own (from the lyrics track's Look tool).
    @State private var lookOpen = false
    /// The track whose color picker is open, from the clip tools.
    @State private var coloring: Int?
    /// Picking a photo or video to put on top, and the Mask sheet.
    @State private var overlayPicking = false
    @State private var overlayItems: [PhotosPickerItem] = []
    /// The Fx page (effects on the cut at the playhead) is open.
    @State private var fxOpen = false
    /// The Filters panel (one color look over the whole video) is open.
    @State private var filtersOpen = false
    /// The editor's height, for the bottom panels (about half of it, like a half-height sheet).
    @State private var editorHeight: CGFloat = 700
    @State private var masking = false
    /// Picking a clip to go before or after the picked piece of the video track.
    @State private var clipPicking = false
    @State private var clipSide: EditorModel.ClipSide = .after
    @State private var clipItems: [PhotosPickerItem] = []
    /// Picking a clip for the + at the end of the video track: it goes after everything.
    @State private var endPicking = false
    @State private var endItems: [PhotosPickerItem] = []
    /// The + at the bottom of the timeline: music or a sound effect from Files, or a creatrr song
    /// or section.
    @State private var soundFiles = false
    @State private var soundIsEffect = false
    @State private var musicSongs = false
    /// Add sound on the toolbar: picking music, a sound effect or a creatrr song.
    @State private var soundChoosing = false
    /// Read here so the timeline's height follows the tall-tracks switch.
    @AppStorage(LaneMetrics.tallKey) private var tallTracks = false

    var body: some View {
        VStack(spacing: 8) {
            // The video stays clear: its buttons sit in the columns on either side, halfway between
            // hugging the video and the screen edges (the three stay centered together).
            GeometryReader { geo in
            // The frame's width over its height: 9/16 vertical, 16/9 horizontal.
            let ratio = model.aspect
            let atEdges = max(1, min(geo.size.width - 2 * (36 + 6), geo.size.height * ratio))
            let edgeGap = 6 + max(0, (geo.size.width - 2 * (36 + 6) - atEdges) / 2)
            let gap = max(10, (10 + edgeGap) / 2)
            let videoWidth = max(1, min(geo.size.width - 2 * (36 + gap), geo.size.height * ratio))
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: 6) {
                    // X: saves the project and goes back to Projects (New lives there now).
                    Button { model.startOver() } label: {
                        SideTile(icon: "xmark", text: "Close project")
                    }
                    .buttonStyle(.plain)
                    showingBadge
                    // The apps' safe zones are for vertical video only.
                    if !model.wide {
                        SafeZonePicker(zone: $safeZone, tile: true)
                            .zIndex(1)   // its fanned-out apps draw over the tiles under it
                    }
                    // Lyrics swaps the timeline for the lyrics timeline; it then reads Editing to go back.
                    Button { model.setLyricTimeline(!model.lyricTimeline) } label: {
                        if model.lyricTimeline {
                            SideTile(icon: "film", text: "Editing", tint: Tint.teal, lit: true)
                        } else {
                            SideTile(icon: "quote.bubble", text: "Lyrics",
                                     lit: model.hasLyrics && model.lyricStyle.show)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.lyricTimeline ? "Back to editing" : "Lyrics")
                    .sheet(isPresented: $lyricsOpen, onDismiss: { model.setTapTiming(false) }) {
                        LyricsSheet(model: model)
                            .presentationDetents([.medium])
                            .presentationContentInteraction(.scrolls)
                            .presentationBackground(.ultraThinMaterial)
                            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    }
                }
                .frame(width: 36)
                .frame(maxHeight: .infinity, alignment: .top)

                VideoStage(model: model, fullScreen: $fullScreen)
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { SafeZoneOverlay(zone: model.wide ? .off : safeZone) }
                    .clipShape(Corner.card)
                    // The picked clip is the one on screen: the video gets the same outline.
                    .overlay {
                        if let index = model.selected, model.showing == index {
                            Corner.card.strokeBorder(Tint.accent, lineWidth: 2).allowsHitTesting(false)
                        }
                    }
                    // The picked overlay: a yellow outline where it sits.
                    .overlay {
                        if let id = model.overlayPick, let box = model.overlayBox(id) {
                            GeometryReader { stage in
                                Rectangle()
                                    .strokeBorder(Tint.accent.opacity(model.maskEditing ? 0.4 : 1), lineWidth: 2)
                                    .frame(width: box.width * stage.size.width, height: box.height * stage.size.height)
                                    .position(x: box.midX * stage.size.width, y: box.midY * stage.size.height)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    // While the Mask sheet is open: the mask's yellow outline with its handles.
                    .overlay {
                        if model.maskEditing, let id = model.overlayPick {
                            MaskHandles(model: model, id: id)
                        }
                    }
                    // While the Fx page is open on a cut with a slow zoom (and stopped): the whole
                    // frame with the zoom's green Start and red End boxes, like DaVinci's Dynamic Zoom.
                    .overlay {
                        if model.zoomFramesShown {
                            ZoomFrames(model: model)
                        }
                    }
                    // While Fisheye is open in the effects sheet: where its circle sits.
                    .overlay {
                        if model.fishEditing {
                            FishRing(spot: model.fishSpotHere, keyed: model.fishKeyHere != nil)
                        }
                    }
                    // The lyrics, picked (or on the lyrics page): a yellow box with transform handles.
                    .overlay {
                        if model.lyricsActive, model.titleEditing == nil, let box = model.lyricsBox() {
                            LyricsHandles(model: model, box: box)
                        }
                    }
                    .overlay(alignment: .bottom) { message }
                    .frame(width: videoWidth, height: videoWidth / ratio)

                // As tall as the video (a horizontal one is short, so its tools can run past it),
                // top-aligned beside it.
                FramingControls(model: model, openFilters: {
                    closeFX()
                    withAnimation(.spring(duration: 0.35)) { filtersOpen = true }
                }, openLyricLook: {
                    lyricsOpen = true
                })
                    .frame(width: 36)
                    .frame(height: model.wide ? max(videoWidth / ratio, geo.size.height) : videoWidth / ratio,
                           alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A tap beside the video (in the columns around its buttons) lets go of whatever is picked.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.letGoOfAll() }
                    .accessibilityHidden(true)
            }
            }
            .frame(maxHeight: .infinity)
                .fullScreenCover(isPresented: $fullScreen) { FullScreenPreview(model: model) }
                .sheet(isPresented: $autoEditing) {
                    AutoEditSheet(model: model)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                }
                .sheet(isPresented: $exporting, onDismiss: {
                    // Made it: the phone's own share sheet comes up from the edit page itself, so it
                    // gets the full width (over the export sheet it was squeezed narrow).
                    if case .saved(let url) = model.exportState {
                        SharePopUp.present(url) { _, _ in }
                    }
                }) {
                    // creatrr's dark frosted glass, like the Fx panel (was the plain light material,
                    // which showed as flat grey).
                    ExportSheet(model: model)   // sizes itself to fit, with the pull-down bar
                        .frostedSheet()
                        .interactiveDismissDisabled(model.exportState.isWorking)
                }

            playBar

            if model.lyricTimeline {
                // Just the two rows of words: the room left over goes to the video. The handles on
                // the video move and size the words.
                LyricsLane(model: model).frame(height: LyricsLane.height)
            } else if onPerformancePage {
                // Grows out of the performance track, and shrinks back into it on Done.
                LanesView(model: model)
                    .frame(height: LaneMetrics.height(layers: model.laneCount, tall: tallTracks))
                    .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
            } else {
                EditTimeline(model: model) { addition in
                    model.pause()
                    switch addition {
                    case .clip: endPicking = true
                    case .musicFile:
                        soundIsEffect = false
                        soundFiles = true
                    case .soundFile:
                        soundIsEffect = true
                        soundFiles = true
                    case .creatrrSong: musicSongs = true
                    }
                }
                    .frame(height: EditMetrics.height(lyrics: model.hasLyrics, overlays: model.onTop.count,
                                                      texts: model.textLaneCount, sounds: model.soundLaneCount))
                    // The grey rows run edge to edge of the screen, as in Edits.
                    .padding(.horizontal, -12)
                    .transition(.opacity)
            }

            if model.tapBeatOn {
                TapBeatPanel(model: model)
            } else if model.lyricTimeline {
                LyricsToolbar(model: model) {
                    model.pause()
                    lyricsOpen = true
                }
            } else {
                toolbar
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorHeight = $0 }
        // Fx and Filters: panels from the bottom, edge to edge (a half-height sheet floats with a
        // gap at each side). The video above stays live: the Fisheye circle and zoom boxes are on it.
        .overlay(alignment: .bottom) {
            if fxOpen {
                BottomPanel(height: editorHeight * 0.5, close: closeFX) {
                    FXSheet(model: model, close: closeFX)
                }
            } else if filtersOpen {
                BottomPanel(height: 300, close: closeFilters) {
                    FilterSheet(model: model, close: closeFilters)
                }
            }
        }
        .photosPicker(isPresented: $overlayPicking, selection: $overlayItems, maxSelectionCount: 1,
                      matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .onChange(of: overlayItems) { _, chosen in
            guard !chosen.isEmpty else { return }
            overlayItems = []
            Task { await model.addOverlay(chosen) }
        }
        // The + at the end of the video track: a clip on the same track, after the performance
        // (only videos when editing a video).
        .photosPicker(isPresented: $endPicking, selection: $endItems, maxSelectionCount: 1,
                      matching: model.kind == .video ? PHPickerFilter.videos : PHPickerFilter.any(of: [.images, .videos]),
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .onChange(of: endItems) { _, chosen in
            guard !chosen.isEmpty else { return }
            endItems = []
            Task { await model.addToEnd(chosen) }
        }
        // The bottom +: music or a sound effect from Files, or a creatrr song or section, at the playhead.
        .fileImporter(isPresented: $soundFiles, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let effect = soundIsEffect
            Task { await model.addSoundFile(url, effect: effect) }
        }
        .sheet(isPresented: $musicSongs) {
            ShootSongSheet(forMusic: true) { song, part in
                Task { await model.addMusic(song, part: part) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .frostedSheet()
        }
        .sheet(isPresented: $masking, onDismiss: { model.endMaskEdit() }) {
            MaskSheet(model: model)
                .presentationDetents([.height(380)])
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(380)))
        }
        // The first time a project opens: three short tips, then never again.
        .overlay { FirstTips() }
        // Tapping out the lyrics takes the whole screen: the song and words on top, big pads below.
        .overlay {
            ZStack {
                if model.lyricTimeline && model.tapTiming {
                    LyricTapScreen(model: model) {
                        LyricsLane(model: model)
                            .frame(height: LyricsLane.height)
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.tapTiming)
        }
    }

    /// A problem or a notice, over the bottom of the video only while there is one (notices fade
    /// after a few seconds), so the timeline gets that space.
    @ViewBuilder private var message: some View {
        if let text = model.problem ?? model.notice {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(model.problem != nil ? Tint.bad : Tint.warn)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75))
                .padding(8)
                .allowsHitTesting(false)
                .transition(.opacity)
                .task(id: text) {
                    guard model.problem == nil else { return }
                    try? await Task.sleep(for: .seconds(4))
                    if model.notice == text { withAnimation { model.notice = nil } }
                }
        }
    }

    /// Which video shows, on the performance page only (the edit page doesn't need it).
    @ViewBuilder private var showingBadge: some View {
        if onPerformancePage, let index = model.showing {
            SideTile(icon: model.previewing == index ? "eye" : "video",
                     text: model.previewing == index ? "Preview \(index + 1)" : "Video \(index + 1)",
                     tint: model.layers.indices.contains(index) ? LayerTint.color(model.layers[index]) : LayerTint.color(index),
                     lit: true, badge: "\(index + 1)")
                .allowsHitTesting(false)
        }
    }

    /// Play and Loop on the left, the time in the middle (now over the whole length), Undo and Redo on the right.
    private var playBar: some View {
        ZStack {
            HStack(spacing: 4) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: true))
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                // Loop, beside Play: Play goes round between Start and End.
                Button { model.toggleLoop() } label: {
                    Image(systemName: "repeat").frame(width: 24)
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.warn, selected: model.looping))
                .accessibilityLabel(model.looping ? "Loop on" : "Loop off")
                Spacer(minLength: 0)
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(!model.canUndo)
                .opacity(model.canUndo ? 1 : 0.35)
                .accessibilityLabel("Undo")
                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(!model.canRedo)
                .opacity(model.canRedo ? 1 : 0.35)
                .accessibilityLabel("Redo")
            }
            // On the edit page the clock counts from the clip's start (In), over the clip's length.
            let origin = onPerformancePage ? 0 : model.loopStart
            let now = max(0, model.time - origin)
            let length = onPerformancePage ? model.duration : model.loopEnd - model.loopStart
            VStack(spacing: 0) {
                Text(EditorModel.clockWhole(now))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(EditorModel.clockWhole(length))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(EditorModel.clockWhole(now)) of \(EditorModel.clockWhole(length))")
        }
        .lineLimit(1)
    }

    /// The performance's own page (every video on its lane, synced to the song). Everything else is
    /// the edit page.
    private var onPerformancePage: Bool { model.kind == .performance && model.performancePage }

    /// The tools under the timeline. With nothing picked: the page's tools. Tap a clip and they swap
    /// for that clip's tools, with a back arrow to let go of it.
    private var toolbar: some View {
        Group {
            if onPerformancePage {
                if let index = model.selected, model.layers.indices.contains(index) {
                    clipTools(index)
                } else {
                    performanceTools
                }
            } else if let id = model.titlePick, model.title(id) != nil {
                titleTools(id)
            } else if let id = model.soundPick, let sound = model.sound(id) {
                soundTools(sound)
            } else if model.lyricsPicked, model.hasLyrics {
                lyricsTools
            } else if let id = model.overlayPick, model.overlay(id) != nil {
                overlayTools(id)
            } else if let picked = model.editPick {
                editClipTools(picked)
            } else {
                editTools
            }
        }
        .frame(height: 52)
        // The Fx page: effects on the cut at the playhead. The video stays usable above it (the
        // Fisheye circle is moved there).
        // The lyrics' look (colors, font, animation...), without the word editing.
        .sheet(isPresented: $lookOpen) {
            LyricsSheet(model: model, lookOnly: true)
                .presentationDetents([.medium])
                .presentationContentInteraction(.scrolls)
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        // A photo or video for before or after the picked piece (only videos when editing a video).
        .photosPicker(isPresented: $clipPicking, selection: $clipItems, maxSelectionCount: 1,
                      matching: model.kind == .video ? PHPickerFilter.videos : PHPickerFilter.any(of: [.images, .videos]),
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .onChange(of: clipItems) { _, chosen in
            guard !chosen.isEmpty else { return }
            clipItems = []
            let side = clipSide
            Task { await model.addClip(chosen, side) }
        }
    }

    /// Split at the playhead, and a clip before or after the picked piece.
    @ViewBuilder private var splitTools: some View {
        ToolItem(icon: "scissors", text: "Split", spoken: "Split at the playhead") { model.splitHere() }
        ToolItem(icon: "arrow.left.square", text: "Before", enabled: model.canAddClip,
                 spoken: "Add a clip before it") {
            model.pause()
            clipSide = .before
            clipPicking = true
        }
        ToolItem(icon: "arrow.right.square", text: "After", enabled: model.canAddClip,
                 spoken: "Add a clip after it") {
            model.pause()
            clipSide = .after
            clipPicking = true
        }
    }

    /// The edit page's tools with nothing picked.
    private var editTools: some View {
        ToolStrip {
            // Split cuts the video track at the playhead.
            ToolItem(icon: "scissors", text: "Split", spoken: "Split the video track at the playhead") {
                model.splitHere()
            }
            // Aa: opens the text at the playhead, or adds one there.
            ToolItem(icon: "textformat", text: "Title", on: model.hasTitleAtPlayhead,
                     spoken: "Add or change text") {
                model.textButton()
            }
            fxTool
            mirrorTool
            // Music or a sound effect at the playhead: its row shows once there is one.
            ToolItem(icon: "music.note", text: "Add sound", tint: MusicTint.color,
                     spoken: "Add music or a sound effect at the playhead") {
                model.pause()
                soundChoosing = true
            }
            .confirmationDialog("Add at the playhead", isPresented: $soundChoosing, titleVisibility: .visible) {
                Button("Music from Files") {
                    soundIsEffect = false
                    soundFiles = true
                }
                Button("Sound effect from Files") {
                    soundIsEffect = true
                    soundFiles = true
                }
                Button("Song or section from creatrr") { musicSongs = true }
                Button("Cancel", role: .cancel) {}
            }
            if model.kind == .performance {
                ToolItem(icon: PerformanceGlyph.name, text: "Performance",
                         spoken: "Performance: every video synced to the song") {
                    withAnimation(.spring(duration: 0.35)) { model.showPerformancePage() }
                }
                // No Auto edit, Shuffle or Tap beat here: the performance is already edited
                // (on its own page), so nothing on this page can re-cut it by accident.
            }
            // A photo or video on top of the main video.
            ToolItem(icon: "square.on.square", text: "Overlay", enabled: model.canAddOverlay,
                     spoken: "Add an overlay: a photo or video on top") {
                model.pause()
                overlayPicking = true
            }
            // Export last, after every other tool.
            ToolItem(icon: "square.and.arrow.up", text: "Export", on: true) {
                model.resetExport()
                exporting = true
            }
        }
    }

    /// A text picked: open it to change its words and look, cut it at the playhead, or delete it.
    private func titleTools(_ id: UUID) -> some View {
        HStack(spacing: 0) {
            Button { model.pickTitle(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all tools")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 30)
            ToolStrip {
                ToolItem(icon: "textformat", text: "Edit", spoken: "Change the text's words and look") {
                    model.openTitle(id)
                }
                ToolItem(icon: "scissors", text: "Cut", enabled: model.canSplitTitle(id),
                         spoken: "Cut the text in two at the playhead") { model.splitTitle(id) }
                ToolItem(icon: "trash", text: "Delete", tint: Tint.bad, on: true,
                         spoken: "Delete the text") { model.deleteTitle(id) }
            }
        }
    }

    /// Music or a sound effect picked: start it at the playhead, or delete it.
    private func soundTools(_ sound: SavedMusic) -> some View {
        let what = sound.effect ? "sound effect" : "music"
        return HStack(spacing: 0) {
            Button { model.pickSound(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all tools")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 30)
            ToolStrip {
                ToolItem(icon: "arrow.right.to.line", text: "Start here",
                         spoken: "Start the \(what) at the playhead") { model.moveSoundHere(sound.id) }
                ToolItem(icon: "trash", text: "Delete", tint: Tint.bad, on: true,
                         spoken: "Delete the \(what)") { model.deleteSound(sound.id) }
            }
        }
    }

    /// A lyrics piece picked: split at the playhead, delete the piece, show or hide them, their look,
    /// or the lyric editor (the words).
    private var lyricsTools: some View {
        HStack(spacing: 0) {
            Button { model.pickLyrics(false) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all tools")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 30)
            ToolStrip {
                ToolItem(icon: "scissors", text: "Split", enabled: model.canSplitLyrics,
                         spoken: "Split the lyrics at the playhead") { model.splitLyrics() }
                if model.lyricsPieces.count > 1 {
                    ToolItem(icon: "trash", text: "Delete", tint: Tint.bad, on: true,
                             spoken: "Delete this piece of the lyrics") { model.deleteLyricsPiece() }
                }
                ToolItem(icon: model.lyricStyle.show ? "eye" : "eye.slash",
                         text: model.lyricStyle.show ? "Hide" : "Show",
                         spoken: model.lyricStyle.show ? "Hide the lyrics" : "Show the lyrics") {
                    model.toggleLyricsShown()
                    // Picked again, so the words can be dragged once they're showing.
                    model.pickLyrics(true, piece: model.lyricPiecePick)
                }
                ToolItem(icon: "paintpalette", text: "Look", spoken: "Edit the lyrics' look") {
                    model.pause()
                    lookOpen = true
                }
                ToolItem(icon: "quote.bubble", text: "Lyric editor", spoken: "Open the lyric editor") {
                    model.pickLyrics(false)
                    model.setLyricTimeline(true)
                }
            }
        }
    }

    /// A picked overlay's tools: back, Mask and Delete. The video moves and sizes it.
    private func overlayTools(_ id: UUID) -> some View {
        HStack(spacing: 0) {
            Button { model.pickOverlay(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all tools")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 30)
            ToolStrip {
                if model.overlay(id)?.isCutaway == true {
                    // A clip on the video track: split it, add one next to it, or delete it.
                    splitTools
                    ToolItem(icon: "trash", text: "Delete", tint: Tint.bad, on: true) { model.deleteOverlay(id) }
                    Text("Drag it on the video to frame it. Hold it on the track to move it.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .frame(maxWidth: 190, alignment: .leading)
                        .padding(.horizontal, 8)
                } else {
                    ToolItem(icon: "scissors", text: "Split", spoken: "Split it at the playhead") { model.splitHere() }
                    ToolItem(icon: "circle.dashed", text: "Mask",
                             on: model.overlay(id).map { $0.mask.shape != .off } ?? false) {
                        model.beginMaskEdit()
                        masking = true
                    }
                    ToolItem(icon: "trash", text: "Delete", tint: Tint.bad, on: true) { model.deleteOverlay(id) }
                    Text("Drag it on the video to move it. Pinch to size it. The + diamond animates it.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .frame(maxWidth: 190, alignment: .leading)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    /// A picked clip's tools on the edit page: the performance (back to its page) or one video.
    private func editClipTools(_ index: Int) -> some View {
        HStack(spacing: 0) {
            Button { model.pickOnEdit(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all tools")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 30)
            ToolStrip {
                splitTools
                fxTool
                mirrorTool
                if model.kind == .performance {
                    ToolItem(icon: PerformanceGlyph.name, text: "Edit performance",
                             spoken: "Edit the performance: every video synced to the song") {
                        withAnimation(.spring(duration: 0.35)) { model.showPerformancePage() }
                    }
                    // The song off or on (its band along the bottom of the performance shows which).
                    let muted = model.soundMuted
                    ToolItem(icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             text: muted ? "Unmute" : "Mute", tint: Tint.warn, on: muted,
                             spoken: muted ? "Turn the song back on" : "Turn the song off") {
                        model.soundMuted.toggle()
                    }
                } else if model.layers.indices.contains(index) {
                    // The clip's own sound off or on (its band on the track shows which).
                    let muted = model.layers[index].muted
                    ToolItem(icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             text: muted ? "Unmute" : "Mute", tint: Tint.warn, on: muted,
                             spoken: muted ? "Turn this clip's sound back on" : "Turn this clip's sound off") {
                        model.toggleMute(index)
                    }
                    // The clip's sound with the background noise taken out, leaving the voice.
                    let voice = model.layers[index].voice != nil
                    ToolItem(icon: "person.wave.2.fill", text: "Voice", tint: Tint.accent, on: voice,
                             enabled: model.layers[index].audio != nil && model.busy == nil,
                             spoken: voice ? "Play this clip's sound as recorded" : "Isolate the voice in this clip's sound") {
                        Task { await model.toggleVoice(index) }
                    }
                }
                // Gets rid of the picked clip (a piece split off, say); the rest close up.
                ToolItem(icon: "trash", text: "Delete", tint: Tint.bad, on: true,
                         enabled: model.canDeleteClip, spoken: "Delete this clip") {
                    model.deleteClip()
                }
            }
        }
    }

    /// Start and End on the performance page (the code still calls them In and Out).
    @ViewBuilder private var exportRangeTools: some View {
        // Start and End: where the performance clip starts and ends, set at the playhead.
        ToolItem(icon: "arrow.right.to.line", text: "Start", tint: Tint.warn,
                 on: model.inPoint > 0.0005) { model.setIn() }
            .accessibilityHint("The performance starts at the playhead")
        ToolItem(icon: "arrow.left.to.line", text: "End", tint: Tint.warn,
                 on: model.outPoint < model.duration - 0.0005) { model.setOut() }
            .accessibilityHint("The performance ends at the playhead")
    }

    /// Shuffle, once Auto edit has run: a fresh cut from the same clips.
    @ViewBuilder private var shuffleTool: some View {
        if model.canShuffle {
            ToolItem(icon: "shuffle", text: "Shuffle", spoken: "Shuffle: a fresh cut from the same clips") {
                Task { await model.shuffleEdit() }
            }
        }
    }

    private func closeFX() {
        guard fxOpen else { return }
        withAnimation(.spring(duration: 0.3)) { fxOpen = false }
        model.endFX()
    }

    private func closeFilters() {
        withAnimation(.spring(duration: 0.3)) { filtersOpen = false }
    }

    /// Fx: effects on the cut at the playhead (each cut has its own).
    private var fxTool: some View {
        ToolItem(icon: "sparkles", text: "Fx", on: model.hasFXAtPlayhead || model.zoomHere != .off,
                 spoken: "Effects for the clip at the playhead") {
            if model.beginFX() {
                filtersOpen = false
                withAnimation(.spring(duration: 0.35)) { fxOpen = true }
            } else {
                model.notice = "Move the playhead onto a clip to add effects."
            }
        }
    }

    /// Mirror: flips the cut at the playhead side to side (it's either mirrored or it isn't).
    private var mirrorTool: some View {
        ToolItem(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", text: "Mirror",
                 on: model.mirrorHere, spoken: "Mirror the clip at the playhead") {
            model.toggleMirrorHere()
        }
    }

    /// Tap beat: the song plays and each tap drops a cut.
    private var tapBeatTool: some View {
        ToolItem(icon: "hand.tap", text: "Tap beat", spoken: "Tap the beat to make cuts") {
            model.openTapBeat()
        }
    }

    /// The performance page's tools with no video picked. Done goes to the edit page.
    private var performanceTools: some View {
        ToolStrip {
            ToolItem(icon: "checkmark", text: "Done", tint: Tint.accent, on: true,
                     spoken: "Done: edit the performance from Start to End") {
                withAnimation(.spring(duration: 0.35)) { model.showEditPage() }
            }
            fxTool
            mirrorTool
            ToolItem(icon: "wand.and.stars", text: "Auto edit") { autoEditing = true }
            shuffleTool
            tapBeatTool
            exportRangeTools
            // Lock: clips can't be moved, trimmed or nudged while it's on.
            lockTool
        }
    }

    private var lockTool: some View {
        ToolItem(icon: model.locked ? "lock" : "lock.open", text: model.locked ? "Locked" : "Unlocked",
                 tint: model.locked ? Tint.accent : Tint.warn, on: true) { model.toggleLock() }
            .accessibilityHint(model.locked ? "Unlock to move or trim clips" : "Lock clips in place")
    }

    private func clipTools(_ index: Int) -> some View {
        let layer = model.layers[index]
        let tint = LayerTint.color(layer)
        let full = model.laneCount >= EditorModel.maxLayers
        return HStack(spacing: 0) {
            Button { model.select(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all tools")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 30)
            ToolStrip {
                // Which video this is, in its color.
                VStack(spacing: 3) {
                    Text("\(index + 1)")
                        .font(.headline.weight(.heavy).monospacedDigit())
                        .foregroundStyle(tint)
                    Text("Video").font(.caption2)
                }
                .frame(width: 52, height: 52)
                .accessibilityElement(children: .combine)
                ToolItem(icon: "scissors", text: "Cut to it", tint: tint, on: model.showing == index) {
                    model.cut(to: index)
                }
                .accessibilityHint("Shows this video from the playhead on")
                fxTool
                mirrorTool
                ToolItem(icon: "eye", text: "Preview", on: model.previewing == index) { model.preview(index) }
                ToolItem(icon: "plus.square.on.square", text: "Duplicate", enabled: !full) { model.duplicate(index) }
                ToolItem(icon: "backward.frame", text: "1 frame", enabled: !model.locked,
                         spoken: "1 frame earlier") { model.nudge(frames: -1) }
                ToolItem(icon: "forward.frame", text: "1 frame", enabled: !model.locked,
                         spoken: "1 frame later") { model.nudge(frames: 1) }
                // A take shot to the song played faster or slower: play it slowed down or sped up.
                Menu {
                    Section("Shot to a faster or slower song? Pick how it plays.") {
                        ForEach(EditorModel.speeds, id: \.self) { speed in
                            Button {
                                Task { await model.setSpeed(index, to: speed) }
                            } label: {
                                if abs(layer.speed - speed) < 0.001 {
                                    Label(EditorModel.speedName(speed), systemImage: "checkmark")
                                } else {
                                    Text(EditorModel.speedName(speed))
                                }
                            }
                        }
                    }
                } label: {
                    let normal = abs(layer.speed - 1) < 0.001
                    VStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(height: 22)
                        Text(normal ? "Speed" : EditorModel.speedName(layer.speed))
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(normal ? Color.white.opacity(0.9) : tint)
                    .frame(width: 60, height: 52)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Speed: \(EditorModel.speedName(layer.speed))")
                ToolItem(icon: "paintpalette", text: "Color", tint: tint) { coloring = index }
                    .popover(isPresented: Binding(get: { coloring == index },
                                                  set: { if !$0 { coloring = nil } })) {
                        TrackColorPicker(selected: LayerTint.pick(layer)) { pick in
                            model.setTrackColor(index, to: pick)
                            coloring = nil
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                lockTool
            }
        }
    }
}

extension EditorModel.ExportState {
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

/// Export: one 1080 x 1920 (or 1920 x 1080 horizontal) video, with or without the song. Once it's made
/// the sheet closes by itself and the phone's share sheet opens (Save Video, Messages, Instagram, …).
struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    /// The sheet's height: just what its content needs (measured), so there's no empty space.
    @State private var fit: CGFloat = 300

    var body: some View {
        VStack(spacing: 12) {
            // Once it's saved the sheet is on its way out (the share sheet follows).
            if case .saved = model.exportState {
                EmptyView()
            } else {
                Text("Export").font(.title2.weight(.bold))
                Text(model.wide ? "1920 x 1080, 30 fps. A horizontal video for YouTube and screens."
                                : "1080 x 1920, 30 fps. One video that fits Reels, TikTok and Shorts.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                range
            }

            switch model.exportState {
            case .idle:
                choices
            case .working(let done):
                ProgressView(value: done)
                    .tint(Tint.teal)
                Text("Making your video: \(Int((done * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                Button("Cancel") { model.cancelExport() }
                    .buttonStyle(GlassButtonStyle())
            case .saved:
                ProgressView().tint(.white)
            case .failed(let why):
                Text("Couldn't export: \(why)")
                    .font(.footnote)
                    .foregroundStyle(Tint.bad)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                Button("Try again") { model.resetExport() }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 30)      // room for the pull-down bar
        .padding(.bottom, 8)    // the sheet adds the phone's own bottom space under this
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(fit)])
        .presentationDragIndicator(.visible)
        .onChange(of: model.exportState) { _, state in
            if case .saved = state { dismiss() }
        }
    }

    /// What gets exported: the clip on the edit page (a performance's In to Out, or every video).
    @ViewBuilder private var range: some View {
        let length = EditorModel.length(model.loopEnd - model.loopStart)
        if model.kind == .video {
            Text("Exports all your videos, back to back (\(length)).")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        } else if model.hasRange {
            VStack(spacing: 6) {
                Text("Exports \(EditorModel.clock(model.loopStart)) to \(EditorModel.clock(model.loopEnd)) (\(length))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if !model.exportState.isWorking {
                    Button("Use the whole song") { model.clearInOut() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Tint.warn)
                }
            }
        } else {
            Text("Exports the whole song (\(length)). Drag the performance's yellow ends to export part of it.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
    }

    /// What the edit page's switches do to the export (nil: nothing).
    private var editPageNote: String? {
        var sound: String?
        if model.soundMuted {
            sound = model.sounds.isEmpty
                ? "the sound is muted, so the export has no sound"
                : "the \(model.kind == .video ? "videos' sound" : "song") is muted, so the export has only your added music and sound effects"
        }
        let video = model.videoHidden
            ? "the video is hidden, so the export has a black background under the overlays and words" : nil
        let parts = [sound, video].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let line = "On the edit page, " + parts.joined(separator: ", and ") + "."
        return line
    }

    private var choices: some View {
        VStack(spacing: 10) {
            // Sound muted on the edit page: only No sound is offered, or the added music and sound
            // effects without the song.
            if !model.soundMuted {
                Button { model.startExport(withSound: true) } label: {
                    Label(model.kind == .video ? "With sound" : "With the song",
                          systemImage: model.kind == .video ? "speaker.wave.2" : "music.note")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
            } else if !model.sounds.isEmpty {
                Button { model.startExport(withSound: true) } label: {
                    Label("With your added sounds", systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
            }

            Button { model.startExport(withSound: false) } label: {
                Label("No sound", systemImage: "speaker.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: model.soundMuted && model.sounds.isEmpty))
            if let note = editPageNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Tint.warn)
                    .multilineTextAlignment(.center)
            }
            if model.kind == .performance, !model.soundMuted {
                Text("No sound: add the song inside Instagram or TikTok so it's linked to your track.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            if model.kind == .performance, model.loopEnd - model.loopStart > 60 {
                Text("This export is \(EditorModel.length(model.loopEnd - model.loopStart)). Shorts with a label's song stop at 60 seconds.")
                    .font(.caption)
                    .foregroundStyle(Tint.warn)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Tap the beat: the song plays from Start, and each tap on the big square drops a cut there.
/// Done turns the taps into cuts, each to the best-looking take.
struct TapBeatPanel: View {
    let model: EditorModel

    var body: some View {
        let playing = model.isPlaying
        VStack(spacing: 8) {
            HStack {
                Button("Cancel") { Task { await model.finishTapBeat(keep: false) } }
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(model.beatTaps.isEmpty ? "Tap along while it plays" : "\(model.beatTaps.count) cuts")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                Button("Done") { Task { await model.finishTapBeat(keep: true) } }
                    .font(.body.weight(.bold))
                    .foregroundStyle(model.beatTaps.isEmpty ? Color.white.opacity(0.35) : Tint.accent)
                    .disabled(model.beatTaps.isEmpty)
            }
            .buttonStyle(.plain)
            // A pad for each thumb: either one taps.
            HStack(spacing: 10) {
                TapPad(playing: playing, idle: model.beatTaps.isEmpty ? "Play" : "Start over",
                       spoken: playing ? "Tap for a cut" : "Play and tap along", trigger: model.beatTaps.count) { press() }
                TapPad(playing: playing, idle: model.beatTaps.isEmpty ? "Play" : "Start over",
                       spoken: playing ? "Tap for a cut" : "Play and tap along", trigger: model.beatTaps.count) { press() }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    private func press() {
        if model.isPlaying { model.tapBeat() } else { model.startTapBeat() }
    }
}

/// What the tap screen drives: an edit's lyrics, or a creatrr song's lyrics for the whole song.
@MainActor
protocol LyricTapping: AnyObject {
    var lyrics: [LyricWord] { get }
    var tapNext: Int { get }
    /// Taps so far on the word being recorded (one a syllable).
    var tapSyllable: Int { get }
    /// Playing back the taps to check them.
    var tapChecking: Bool { get }
    var isPlaying: Bool { get }
    var time: Double { get }
    var lyricTapCount: Int { get }
    /// Clean up has nudged the taps toward the singing.
    var tapCleaned: Bool { get }
    /// Clean up is waiting on the AI to finish listening.
    var tapCleanBusy: Bool { get }
    /// What Clean up did, or why it couldn't.
    var tapCleanNote: String? { get }
    func lyricTapCleanUp()
    func lyricTap()
    func lyricTapBack()
    func lyricTapRestart()
    func lyricTapCheck(_ on: Bool)
    func setSyllables(_ index: Int, _ count: Int)
    func finishTapTiming(keep: Bool)
}

extension EditorModel: LyricTapping {}

/// Tap the lyrics' timing, full screen: the song's waveform and the word blocks on top (they
/// move as you tap), then the words: the one before in green with a check, the one being recorded
/// big in yellow, and the ones coming up in white. A word of more than one syllable takes a tap
/// for each (its dots fill as you tap). Play back plays it all to check before Done; Back takes the
/// last word off and Start over takes them all off. A tall pad for each thumb at the bottom.
struct LyricTapScreen<Model: LyricTapping, Top: View>: View {
    let model: Model
    /// The song's waveform and the word blocks.
    @ViewBuilder let top: Top

    var body: some View {
        let checking = model.tapChecking
        let playing = model.isPlaying && !checking
        let count = model.lyricTapCount
        let spoken: String = checking ? "Back to tapping" : (playing ? "Next word or syllable now" : "Play")
        let idle: String = checking ? "Back to tapping" : "Play"
        let trigger: Int = count * 8 + model.tapSyllable
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                header(count: count)
                top
                    .padding(.horizontal, -12)
                Spacer(minLength: 8)
                queue
                Spacer(minLength: 8)
                tryAgainRow(count: count)
                // A pad for each thumb: either one taps.
                HStack(spacing: 10) {
                    TapPad(playing: playing, idle: idle, spoken: spoken, trigger: trigger,
                           height: 170) { model.lyricTap() }
                    TapPad(playing: playing, idle: idle, spoken: spoken, trigger: trigger,
                           height: 170) { model.lyricTap() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .foregroundStyle(.white)
        }
    }

    private func header(count: Int) -> some View {
        HStack {
            Button("Cancel") { model.finishTapTiming(keep: false) }
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text(model.tapChecking ? "Checking your timing" : (model.tapCleanNote ?? TapQueueLook.timedText(count)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(model.tapCleaned && !model.tapChecking ? Tint.accent : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Button("Done") { model.finishTapTiming(keep: true) }
                .font(.body.weight(.bold))
                .foregroundStyle(count == 0 ? Color.white.opacity(0.35) : Tint.accent)
                .disabled(count == 0)
        }
        .buttonStyle(.plain)
        .frame(height: 44)
    }

    /// Back (the last word off), Play back (check it with the music), Clean up (the AI nudges the
    /// taps toward the singing, a second at most), Start over (all of them off).
    private func tryAgainRow(count: Int) -> some View {
        let dim: Color = Color.white.opacity(0.3)
        let none: Bool = count == 0
        let checking = model.tapChecking
        let cleaned = model.tapCleaned
        let busy = model.tapCleanBusy
        return HStack(spacing: 0) {
            Button { model.lyricTapBack() } label: {
                TapRowLabel(title: "Back", icon: "arrow.uturn.backward")
            }
            .foregroundStyle(none ? dim : Color.white)
            .disabled(none)
            .accessibilityHint("Takes the last word off to do it again")
            Button { model.lyricTapCheck(!checking) } label: {
                TapRowLabel(title: checking ? "Stop" : "Play back", icon: checking ? "stop.fill" : "play.fill")
            }
            .foregroundStyle(none ? dim : Tint.accent)
            .disabled(none)
            .accessibilityHint("Plays from the start with the words as you tapped them")
            Button { model.lyricTapCleanUp() } label: {
                if busy {
                    VStack(spacing: 4) {
                        ProgressView().tint(.white).frame(height: 20)
                        Text("Listening").font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    TapRowLabel(title: cleaned ? "Undo clean up" : "Clean up",
                                icon: cleaned ? "arrow.uturn.backward.circle" : "wand.and.stars")
                }
            }
            .foregroundStyle(none || busy ? dim : (cleaned ? Tint.accent : Color.white))
            .disabled(none || busy)
            .accessibilityHint(cleaned ? "Puts your taps back as you tapped them"
                               : "The AI moves your taps toward the singing, a second at most")
            Button { model.lyricTapRestart() } label: {
                TapRowLabel(title: "Start over", icon: "arrow.counterclockwise")
            }
            .foregroundStyle(none ? dim : Color.white)
            .disabled(none)
            .accessibilityHint("Takes every tap off and goes back to the start")
        }
        .buttonStyle(.plain)
    }
}

/// A tap screen button: its icon over its name, the four sharing the row.
private struct TapRowLabel: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(height: 20)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// The tap screen's word queue: how words fade and move (kept outside the screen, since a generic
/// view can't hold stored statics).
@MainActor
enum TapQueueLook {
    /// Words further down the queue fade: 0.85 for the next one, then less, 0.25 at least.
    static func fade(_ ahead: Int) -> Double {
        let step: Double = Double(ahead) * 0.18
        return max(0.25, 0.85 - step)
    }

    /// The word just done goes up to the green line.
    static let doneGoes: AnyTransition = AnyTransition.asymmetric(
        insertion: AnyTransition.move(edge: .bottom).combined(with: .opacity),
        removal: AnyTransition.move(edge: .top).combined(with: .opacity))
    /// The word being recorded comes up from the line below.
    static let nowComes: AnyTransition = AnyTransition.asymmetric(
        insertion: AnyTransition.move(edge: .bottom).combined(with: .opacity),
        removal: AnyTransition.move(edge: .top).combined(with: .opacity))
    static let slideIn: AnyTransition = AnyTransition.asymmetric(
        insertion: AnyTransition.move(edge: .trailing).combined(with: .opacity),
        removal: AnyTransition.opacity)

    static func timedText(_ count: Int) -> String {
        if count == 0 { return "Tap as each word starts" }
        return count == 1 ? "1 word timed" : "\(count) words timed"
    }

    /// A dot for each syllable, the tapped ones filled.
    static func dots(total: Int, filled: Int, size: CGFloat) -> some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < filled ? Tint.good : Color.white.opacity(0.35))
                    .frame(width: size, height: size)
            }
        }
    }
}

extension LyricTapScreen {
    /// The word being recorded (or, while checking, the word being sung). Before the first tap
    /// there's none: the first word waits big and faint.
    private var currentIndex: Int? {
        let words = model.lyrics
        if model.tapChecking {
            let now = model.time + 0.01
            return words.lastIndex(where: { $0.start <= now })
        }
        if model.lyricTapCount > 0 && words.indices.contains(model.tapNext - 1) { return model.tapNext - 1 }
        return nil
    }

    /// The words lined up: the one before in green with a check, the one being recorded big in
    /// yellow (its syllable dots under it), and the next few in white.
    var queue: some View {
        let words = model.lyrics
        let checking = model.tapChecking
        let current: Int? = currentIndex
        let firstTapped: Int = model.tapNext - model.lyricTapCount
        // Checking, before the first word: the first word is next.
        let next: Int = current.map { $0 + 1 } ?? (checking ? 0 : model.tapNext)
        let upTo: Int = min(words.count, next + 4)
        let ahead: [Int] = next < upTo ? Array(next..<upTo) : []
        let big: Int? = current ?? (words.indices.contains(next) ? next : nil)
        var prev: Int? = nil
        if let current, current > 0, checking || current - 1 >= firstTapped { prev = current - 1 }
        let spoken: String = big.map { "Now: " + words[$0].text } ?? "All words timed"
        return VStack(spacing: 10) {
            // The word before: done.
            ZStack {
                if let prev {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(words[prev].text)
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Tint.good)
                    .id("d\(prev)")
                    .transition(TapQueueLook.doneGoes)
                }
            }
            .frame(height: 30)
            // The word being recorded, big in yellow (the first word waits faint before any tap).
            ZStack {
                if let big {
                    Text(words[big].text)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(current == nil ? Color.white.opacity(0.35) : Tint.accent)
                        .id("w\(big)")
                        .transition(TapQueueLook.nowComes)
                }
            }
            .frame(height: 70)
            syllables(big, recording: current != nil && !checking)
                .frame(height: 24)
            // Coming up.
            ZStack {
                if ahead.isEmpty && !checking && model.lyricTapCount > 0 {
                    Text("That's every word. Play back to check it, then Done.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tint.good)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(ahead, id: \.self) { i in
                            upcoming(i, ahead: i - next)
                                .id("u\(i)")
                                .transition(TapQueueLook.slideIn)
                        }
                    }
                }
            }
            .frame(height: 44)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.spring(duration: 0.28, bounce: 0.3), value: current)
        .animation(.easeOut(duration: 0.12), value: model.tapSyllable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// The big word's syllable dots: tap them to change how many taps it takes.
    @ViewBuilder
    private func syllables(_ index: Int?, recording: Bool) -> some View {
        if let index, model.lyrics.indices.contains(index) {
            let total: Int = LyricSyllables.count(model.lyrics[index])
            let filled: Int = recording ? min(model.tapSyllable, total) : 0
            let label: String = total == 1 ? "1 tap" : "\(total) taps"
            Button {
                model.setSyllables(index, total % 4 + 1)
            } label: {
                HStack(spacing: 8) {
                    TapQueueLook.dots(total: total, filled: filled, size: 10)
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.tapChecking)
            .accessibilityLabel(label)
            .accessibilityHint("Changes how many taps this word takes, one a syllable")
        }
    }

    /// A word coming up, with its syllable dots when it takes more than one tap.
    private func upcoming(_ i: Int, ahead: Int) -> some View {
        let word = model.lyrics[i]
        let total: Int = LyricSyllables.count(word)
        return VStack(spacing: 4) {
            Text(word.text)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.white.opacity(TapQueueLook.fade(ahead)))
            if total > 1 {
                TapQueueLook.dots(total: total, filled: 0, size: 5)
            }
        }
    }
}

/// One tap pad: yellow with TAP while the song plays, a Play button while it doesn't. It fires on
/// the touch down (not the lift), so the timing is where the thumb lands.
struct TapPad: View {
    let playing: Bool
    let idle: String
    let spoken: String
    let trigger: Int
    var height: CGFloat = 84
    let action: () -> Void
    @State private var down = false

    var body: some View {
        Corner.card
            .fill(playing ? (down ? Color.white : Tint.accent) : Tint.surface2)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                Text(playing ? "TAP" : idle)
                    .font(playing ? Font.title.weight(.heavy) : Font.headline)
                    .foregroundStyle(playing ? Color.black : Color.white)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    action()
                }
                .onEnded { _ in down = false })
            .sensoryFeedback(.impact(weight: .light), trigger: trigger)
            .accessibilityElement()
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// The phone's own share pop up for a video, over whatever is showing. It lists the apps on this
/// phone that take a video (Instagram, TikTok, YouTube, Facebook only show when they're installed).
@MainActor
enum SharePopUp {
    static func present(_ url: URL, finished: @escaping (UIActivity.ActivityType?, Bool) -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        // Already up: don't stack a second one.
        if top is UIActivityViewController { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Less clutter: Apple's own extras that don't fit a video, and creatrr itself. Other apps'
        // extras (Notes, Freeform, …) can't be hidden.
        sheet.excludedActivityTypes = [.mail, .print, .copyToPasteboard, .assignToContact, .addToReadingList,
                                       .markupAsPDF, .openInIBooks, .postToVimeo, .postToFlickr, .postToWeibo,
                                       .postToTencentWeibo, .sharePlay, .collaborationInviteWithLink,
                                       .collaborationCopyLink,
                                       UIActivity.ActivityType("art.gavingeddes.producrr.ShareExtension")]
        sheet.completionWithItemsHandler = { activity, completed, _, _ in
            finished(activity, completed)
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: a popover pointing at the middle of the screen.
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
        } else {
            // iPhone: iOS 26 floats a half-height sheet as an inset card (narrower than the screen);
            // only a full-height sheet runs edge to edge. The share sheet is a popover underneath that
            // turns into a sheet on iPhone, so its height is set on that sheet (and on the plain sheet
            // in case it comes up as one).
            let fullHeight: [UISheetPresentationController.Detent] = [.large()]
            if let pop = sheet.popoverPresentationController {
                pop.adaptiveSheetPresentationController.detents = fullHeight
                pop.adaptiveSheetPresentationController.prefersGrabberVisible = true
            }
            if let card = sheet.sheetPresentationController {
                card.detents = fullHeight
                card.prefersGrabberVisible = true
            }
        }
        top.present(sheet, animated: true)
    }

    /// One line for what was just done with the video.
    static func sentLine(_ activity: UIActivity.ActivityType?) -> String {
        guard let raw = activity?.rawValue else { return "Shared." }
        if activity == .saveToCameraRoll { return "Saved to Photos, at the top." }
        if activity == .message { return "Sent in Messages." }
        if activity == .airDrop { return "Sent with AirDrop." }
        let lower = raw.lowercased()
        if lower.contains("instagram") { return "Sent to Instagram." }
        if lower.contains("tiktok") || lower.contains("musically") || lower.contains("aweme") { return "Sent to TikTok." }
        if lower.contains("youtube") { return "Sent to YouTube." }
        if lower.contains("facebook") { return "Sent to Facebook." }
        return "Shared."
    }
}

/// The edit, full screen. Double tap (or the X) goes back.
struct FullScreenPreview: View {
    let model: EditorModel
    @AppStorage("safeZone") private var safeZone: SafeZone = .off
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: model.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { dismiss() }
            // Same spot as the picture: fitted 9:16 (or 16:9), centered.
            Color.clear
                .aspectRatio(model.aspect, contentMode: .fit)
                .overlay { SafeZoneOverlay(zone: model.wide ? .off : safeZone) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if !model.wide {
                SafeZonePicker(zone: $safeZone).padding(16)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GlassButtonStyle())
            .accessibilityLabel("Close full screen")
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
                }
                .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Text("\(EditorModel.clockWhole(model.time)) / \(EditorModel.clockWhole(model.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 24)
        }
        .statusBarHidden()
    }
}

/// Three short tips the first time the editor opens. Next steps through them; Skip or the last
/// one's Got it puts them away for good.
struct FirstTips: View {
    @AppStorage("firstTipsSeen") private var seen = false
    @State private var step = 0

    private struct Tip {
        let icon: String
        let title: String
        let text: String
    }

    private let tips = [
        Tip(icon: "wand.and.stars", title: "Start with Auto edit",
            text: "On the Performance page, it makes a whole cut from your takes in one tap. Change anything you like after."),
        Tip(icon: "hand.tap", title: "Double tap the performance",
            text: "Pick which take shows at each moment. Done brings you back here."),
        Tip(icon: "plus.square", title: "Tap anything to edit it",
            text: "Its tools show along the bottom. The + at the end of the track adds a photo or video after the performance."),
    ]

    var body: some View {
        if !seen {
            let tip = tips[min(step, tips.count - 1)]
            let last = step >= tips.count - 1
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: tip.icon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Tint.accent)
                        Spacer()
                        Text("\(step + 1) of \(tips.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(tip.title).font(.title3.weight(.bold))
                    Text(tip.text)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if !last {
                            Button("Skip") { seen = true }
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Button(last ? "Got it" : "Next") {
                            if last { seen = true } else { step += 1 }
                        }
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.white)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(22)
                .background(Tint.surface, in: Corner.card)
                .padding(28)
            }
            .transition(.opacity)
        }
    }
}

struct BusyCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(28)
        .background(Tint.surface, in: Corner.card)
        .padding(40)
    }
}

/// creatrr's near-black behind everything, so the glass and the color coding stand out.
struct Backdrop: View {
    var body: some View {
        Tint.backdrop.ignoresSafeArea()
    }
}

/// The video, with the framing gestures on it:
/// - Two fingers: zoom around the spot between them, and slide to move the picture.
/// - Press and hold, then drag: move the picture.
/// - Double tap: full-screen preview.
/// The change waits as a draft until Set keyframe. With an overlay picked, the same gestures
/// move and size the overlay instead (one finger drags it straight away).
struct VideoStage: View {
    let model: EditorModel
    @Binding var fullScreen: Bool
    @State private var pinch: Double = 1
    /// Where the fingers started (from the middle) and how far they've moved, as fractions.
    @State private var focus: CGSize = .zero
    @State private var move: CGSize = .zero
    /// The fingers are moving the mask (the Mask sheet is open).
    @State private var maskMoving = false
    /// The fingers are moving the lyrics.
    @State private var lyricMoving = false
    /// The fingers are moving the fisheye circle (the effects sheet is open on a Fisheye cut).
    @State private var fishMoving = false
    @State private var framing = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let active = framing && (pinch != 1 || move != .zero)
            let live = active || model.hasDraft
                ? model.framingPreview(scale: pinch, shift: shift) : (scale: 1.0, shift: CGSize.zero)

            PlayerView(player: model.player)
                .scaleEffect(live.scale)
                .offset(x: live.shift.width * size.width, y: live.shift.height * size.height)
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .overlay {
                    StageTouches(quickDrag: model.overlayPick != nil || model.lyricsActive || model.fishEditing,
                                 began: { at in began(at) },
                                 changed: { scale, moved in changed(scale, moved) },
                                 ended: { ended() },
                                 doubleTapped: { fullScreen = true },
                                 tapped: { at in tapped(at) })
                }
                // While a text is open, or picked and on screen, its box and handles: a drag on the
                // video moves the text instead.
                .overlay {
                    if let id = model.titleEditing {
                        TitleMover(model: model, id: id).id(id)
                    } else if let id = model.titlePick, let clip = model.title(id),
                              model.time >= clip.start, model.time < clip.end {
                        TitleMover(model: model, id: id).id(id)
                    }
                }
        }
    }

    /// A tap on the words picks the lyrics; a tap away from them lets go. A tap on an overlay picks it.
    private func tapped(_ at: CGPoint) {
        guard !model.lyricTimeline else { return }
        // The effects sheet is open on a Fisheye cut: a tap puts the circle there.
        if model.fishEditing {
            model.placeFish(at: at)
            return
        }
        // The Mask sheet is open: a tap adds a point to a Custom shape (and does nothing otherwise).
        if model.maskEditing {
            model.addMaskPoint(at: at)
            return
        }
        if let box = model.lyricsBox(), box.insetBy(dx: -0.04, dy: -0.03).contains(at) {
            model.pickLyrics(true)
            return
        }
        if model.lyricsPicked {
            model.pickLyrics(false)
            model.notice = nil
            return
        }
        // A tap on a text picks it: its box and handles, and its tools.
        if let id = model.titleAt(at) {
            model.pickTitle(id)
            return
        }
        if let id = model.overlayAt(at) { model.pickOverlay(id) }
    }

    /// Keeps the spot under the fingers still while zooming: the shift that goes with the pinch.
    private var shift: CGSize {
        CGSize(width: focus.width * (1 - pinch) + move.width,
               height: focus.height * (1 - pinch) + move.height)
    }

    private func began(_ at: CGPoint) {
        model.pause()
        if model.fishEditing {
            fishMoving = true
            model.beginFishMove()
            return
        }
        if model.maskEditing {
            maskMoving = true
            model.beginMaskMove()
            return
        }
        // The lyrics page, or the lyrics picked: the fingers move the words.
        if model.lyricsActive {
            lyricMoving = true
            model.beginLyricMove()
            return
        }
        // On a performance's edit page the fingers work on what's picked. With nothing picked, they
        // pick what's under them: an overlay, or else the whole performance track.
        if !model.videoFramingHere, model.overlayPick == nil, !model.trackPicked {
            if let id = model.overlayAt(at) {
                model.pickOverlay(id)
            } else {
                model.pickOnEdit(0)
            }
        }
        if model.overlayPick != nil {
            focus = CGSize(width: at.x, height: at.y)
            model.beginOverlayTransform()
            return
        }
        framing = true
        pinch = 1
        move = .zero
        focus = CGSize(width: at.x - 0.5, height: at.y - 0.5)
    }

    private func changed(_ scale: Double, _ moved: CGSize) {
        if fishMoving {
            model.moveFish(by: moved)
            return
        }
        if lyricMoving {
            // One finger moves the words; a pinch sizes them too.
            model.moveLyrics(moved, scale: scale)
            return
        }
        if maskMoving {
            model.moveMask(scale: scale, move: moved)
            return
        }
        if !framing {
            model.transformOverlay(scale: scale, focus: CGPoint(x: focus.width, y: focus.height), move: moved)
            return
        }
        pinch = scale
        move = moved
    }

    private func ended() {
        if fishMoving {
            fishMoving = false
            model.endFishMove()
            return
        }
        if lyricMoving {
            lyricMoving = false
            model.endLyricMove()
            return
        }
        if maskMoving {
            maskMoving = false
            model.endMaskMove()
            return
        }
        guard framing else {
            model.endOverlayTransform()
            return
        }
        let scale = pinch
        let kept = shift
        framing = false
        pinch = 1
        move = .zero
        model.stageFraming(scale: scale, shift: kept)
    }
}

/// A slow zoom's Start (green) and End (red) frames on the video, like DaVinci's Dynamic Zoom.
/// Drag inside a box to move it, drag a corner to size it (the opposite corner stays put). Each box
/// keeps the frame's shape and stays inside it. Where they overlap, the smaller box is the one moved.
struct ZoomFrames: View {
    let model: EditorModel
    static let startColor = Color(red: 0.25, green: 0.9, blue: 0.4)
    static let endColor = Color(red: 1, green: 0.27, blue: 0.27)
    private static let reach: CGFloat = 26

    private enum Grab {
        case move(start: Bool, from: ZoomBox)
        /// `fixed` is the opposite corner (fractions); `dx`, `dy` the side the finger's corner is on.
        case corner(start: Bool, fixed: CGPoint, dx: Double, dy: Double)
    }
    @State private var grab: Grab?
    @State private var liveStart: ZoomBox?
    @State private var liveEnd: ZoomBox?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let saved = model.zoomFramesHere
            let start = liveStart ?? saved.start
            let end = liveEnd ?? saved.end
            ZStack {
                box(end, color: Self.endColor, label: "End", size: size)
                box(start, color: Self.startColor, label: "Start", size: size)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Path { path in
                path.addRect(rect(end, size).insetBy(dx: -Self.reach, dy: -Self.reach))
                path.addRect(rect(start, size).insetBy(dx: -Self.reach, dy: -Self.reach))
            })
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(value, size: size, start: start, end: end) }
                    .onEnded { _ in ended() }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Zoom start and end frames")
    }

    private func rect(_ b: ZoomBox, _ size: CGSize) -> CGRect {
        let side: CGFloat = CGFloat(b.size)
        let left: CGFloat = CGFloat(b.x) - side / 2
        let top: CGFloat = CGFloat(b.y) - side / 2
        return CGRect(x: left * size.width, y: top * size.height, width: side * size.width, height: side * size.height)
    }

    private func box(_ b: ZoomBox, color: Color, label: String, size: CGSize) -> some View {
        let r = rect(b, size)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(color, lineWidth: 2)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .padding(4)
            ForEach(0..<4, id: \.self) { corner in
                Rectangle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
                    .position(cornerPoint(corner, r))
            }
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    /// A box's corner, 0 to 3 (top left, top right, bottom left, bottom right), in the box's own space.
    private func cornerPoint(_ corner: Int, _ r: CGRect) -> CGPoint {
        let x: CGFloat = corner % 2 == 0 ? 0 : r.width
        let y: CGFloat = corner < 2 ? 0 : r.height
        return CGPoint(x: x, y: y)
    }

    /// The corner grab for one corner of a box: the opposite corner stays put.
    private func cornerGrab(isStart: Bool, corner: CGPoint, r: CGRect, w: Double, h: Double) -> Grab {
        let left: Bool = corner.x == r.minX
        let top: Bool = corner.y == r.minY
        let fixedX: Double = Double(left ? r.maxX : r.minX) / w
        let fixedY: Double = Double(top ? r.maxY : r.minY) / h
        let dx: Double = left ? -1 : 1
        let dy: Double = top ? -1 : 1
        return .corner(start: isStart, fixed: CGPoint(x: fixedX, y: fixedY), dx: dx, dy: dy)
    }

    private func changed(_ value: DragGesture.Value, size: CGSize, start: ZoomBox, end: ZoomBox) {
        let w = Double(max(size.width, 1)), h = Double(max(size.height, 1))
        if grab == nil {
            model.pause()
            let at = value.startLocation
            // A corner first (the nearest within reach), then inside the smaller box, then the bigger.
            var bestGrab: Grab?
            var bestDistance: CGFloat = .infinity
            let boxes: [(Bool, ZoomBox)] = [(true, start), (false, end)]
            for (isStart, b) in boxes {
                let r: CGRect = rect(b, size)
                let corners: [CGPoint] = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                          CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                for corner in corners {
                    let d: CGFloat = hypot(corner.x - at.x, corner.y - at.y)
                    guard d <= Self.reach, d < bestDistance else { continue }
                    bestDistance = d
                    bestGrab = cornerGrab(isStart: isStart, corner: corner, r: r, w: w, h: h)
                }
            }
            if let bestGrab {
                grab = bestGrab
            } else {
                let smallerFirst: [(Bool, ZoomBox)] = start.size <= end.size ? boxes : boxes.reversed()
                if let hit = smallerFirst.first(where: { rect($0.1, size).insetBy(dx: -8, dy: -8).contains(at) }) {
                    grab = .move(start: hit.0, from: hit.1)
                } else {
                    return
                }
            }
        }
        guard let grab else { return }
        switch grab {
        case let .move(isStart, from):
            var next = from
            let moveX: Double = Double(value.translation.width) / w
            let moveY: Double = Double(value.translation.height) / h
            next.x += moveX
            next.y += moveY
            set(isStart, next.held())
        case let .corner(isStart, fixed, dx, dy):
            let fx: Double = Double(fixed.x)
            let fy: Double = Double(fixed.y)
            let px: Double = Double(value.location.x) / w
            let py: Double = Double(value.location.y) / h
            var s: Double = max(abs(px - fx), abs(py - fy))
            // Room from the fixed corner to the frame's edges on the finger's side.
            let roomX: Double = dx > 0 ? 1 - fx : fx
            let roomY: Double = dy > 0 ? 1 - fy : fy
            s = min(max(s, ZoomBox.smallest), roomX, roomY)
            let centerX: Double = fx + dx * s / 2
            let centerY: Double = fy + dy * s / 2
            set(isStart, ZoomBox(x: centerX, y: centerY, size: s).held())
        }
    }

    private func set(_ isStart: Bool, _ b: ZoomBox) {
        if isStart { liveStart = b } else { liveEnd = b }
    }

    private func ended() {
        guard let grab else { return }
        switch grab {
        case let .move(isStart, _), let .corner(isStart, _, _, _):
            if let b = isStart ? liveStart : liveEnd { model.setZoomFrame(start: isStart, b) }
        }
        self.grab = nil
        liveStart = nil
        liveEnd = nil
    }
}

/// While Fisheye is open in the effects sheet: where its circle sits, in creatrr yellow (dashed
/// between keyframes, solid on one).
struct FishRing: View {
    /// The circle's middle, as fractions of the frame (0,0 top left).
    let spot: CGPoint
    /// The playhead is on one of its keyframes.
    let keyed: Bool

    var body: some View {
        GeometryReader { stage in
            let size = stage.size
            let radius = min(size.width, size.height) * 0.49
            let middle = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
            ZStack {
                Circle()
                    .stroke(Tint.accent.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: keyed ? [] : [6, 5]))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(middle)
                Image(systemName: keyed ? "diamond.fill" : "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Tint.accent)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.45))
                    .position(middle)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// While the Mask sheet is open: the mask's outline in creatrr yellow with small square handles.
/// Circle and Square have one on each side: drag it to stretch that side while the other stays.
/// Custom has one on each point: drag it to move the point, tap it to pick it (to remove it), and
/// tap the video to add one. Dragging anywhere else moves the whole mask, and a pinch sizes it.
struct MaskHandles: View {
    let model: EditorModel
    let id: UUID
    private static let space = "maskHandles"
    /// Where the held handle was when the finger went down, as fractions of the frame.
    @State private var grab: CGPoint?
    @State private var moved = false

    var body: some View {
        GeometryReader { stage in
            let w = max(stage.size.width, 1), h = max(stage.size.height, 1)
            if let mask = model.overlayHere(id)?.mask, mask.shape != .off, let box = model.maskBox(id) {
                let frame = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
                let points = model.maskAnchors(id).map { CGPoint(x: $0.x * w, y: $0.y * h) }
                ZStack {
                    outline(mask, frame: frame, points: points)
                        .shadow(color: .black.opacity(0.45), radius: 1.5)
                        .allowsHitTesting(false)
                    if mask.shape == .custom {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                            handle(picked: model.maskPoint == index)
                                .gesture(pointDrag(index, from: point, w: w, h: h))
                                .position(point)
                                .accessibilityLabel("Mask point \(index + 1)")
                        }
                    } else {
                        ForEach(0..<4, id: \.self) { side in
                            let point = sidePoint(side, frame)
                            handle(picked: false)
                                .gesture(sideDrag(side, from: point, w: w, h: h))
                                .position(point)
                                .accessibilityLabel(["Top", "Right", "Bottom", "Left"][side] + " side of the mask")
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: Self.space)
    }

    @ViewBuilder
    private func outline(_ mask: OverlayMask, frame: CGRect, points: [CGPoint]) -> some View {
        switch mask.shape {
        case .circle:
            Ellipse()
                .stroke(Tint.accent, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        case .custom:
            Path(MaskOutline.path(points, smooth: mask.curved))
                .stroke(Tint.accent, lineWidth: 2)
        default:
            Rectangle()
                .stroke(Tint.accent, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    /// A small square: white, or yellow when it's the picked point.
    private func handle(picked: Bool) -> some View {
        Rectangle()
            .fill(picked ? Tint.accent : Color.white)
            .overlay(Rectangle().strokeBorder(Tint.accent, lineWidth: 2))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.4), radius: 1.5)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    /// The middle of a side: 0 top, 1 right, 2 bottom, 3 left.
    private func sidePoint(_ side: Int, _ frame: CGRect) -> CGPoint {
        switch side {
        case 0: CGPoint(x: frame.midX, y: frame.minY)
        case 1: CGPoint(x: frame.maxX, y: frame.midY)
        case 2: CGPoint(x: frame.midX, y: frame.maxY)
        default: CGPoint(x: frame.minX, y: frame.midY)
        }
    }

    /// Where the held handle is now: where it started plus how far the finger went (so grabbing a
    /// handle off its middle doesn't make it jump).
    private func target(_ value: DragGesture.Value, w: CGFloat, h: CGFloat) -> CGPoint {
        let start = grab ?? .zero
        return CGPoint(x: start.x + value.translation.width / w, y: start.y + value.translation.height / h)
    }

    private func sideDrag(_ side: Int, from point: CGPoint, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if grab == nil {
                    grab = CGPoint(x: point.x / w, y: point.y / h)
                    model.beginMaskHandle()
                }
                model.dragMaskSide(side, to: target(value, w: w, h: h))
            }
            .onEnded { _ in
                grab = nil
                model.endMaskMove()
            }
    }

    /// A tap picks the point; a drag moves it.
    private func pointDrag(_ index: Int, from point: CGPoint, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if grab == nil {
                    grab = CGPoint(x: point.x / w, y: point.y / h)
                    model.maskPoint = index
                    model.beginMaskHandle()
                }
                guard moved || hypot(value.translation.width, value.translation.height) > 3 else { return }
                moved = true
                model.dragMaskPoint(index, to: target(value, w: w, h: h))
            }
            .onEnded { _ in
                grab = nil
                moved = false
                model.endMaskMove()
            }
    }
}

/// The picked lyrics' transform handles, as on a picked layer in other editors: a yellow box, a
/// square at each corner (pull it away from the middle to make the words bigger, in to make them
/// smaller) and a move handle in the middle. Anywhere else on the video still drags them too.
struct LyricsHandles: View {
    let model: EditorModel
    /// Where the words are, in fractions of the frame.
    let box: CGRect
    private static let space = "lyricsHandles"
    /// A corner's drag: the box's middle and the finger's distance from it when it started.
    @State private var resizing: (center: CGPoint, distance: CGFloat)?
    @State private var moving = false

    var body: some View {
        GeometryReader { stage in
            let w = max(stage.size.width, 1), h = max(stage.size.height, 1)
            let frame = CGRect(x: box.minX * w - 6, y: box.minY * h - 6,
                               width: box.width * w + 12, height: box.height * h + 12)
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            ZStack {
                Rectangle()
                    .strokeBorder(Tint.accent, lineWidth: 2)
                    .frame(width: frame.width, height: frame.height)
                    .position(middle)
                    .allowsHitTesting(false)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().strokeBorder(Tint.accent, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .gesture(resize(middle))
                        .position(x: i % 2 == 0 ? frame.minX : frame.maxX, y: i < 2 ? frame.minY : frame.maxY)
                        .accessibilityLabel("Size the lyrics")
                }
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Tint.accent))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .gesture(move(width: w, height: h))
                    .position(middle)
                    .accessibilityLabel("Move the lyrics")
            }
        }
        .coordinateSpace(name: Self.space)
    }

    /// A corner: the words size with the finger's distance from the box's middle.
    private func resize(_ middle: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if resizing == nil {
                    let start = hypot(value.startLocation.x - middle.x, value.startLocation.y - middle.y)
                    resizing = (middle, max(start, 12))
                    model.beginLyricMove()
                }
                guard let started = resizing else { return }
                let now = hypot(value.location.x - started.center.x, value.location.y - started.center.y)
                model.moveLyrics(.zero, scale: Double(now / started.distance))
            }
            .onEnded { _ in
                resizing = nil
                model.endLyricMove()
            }
    }

    /// The middle handle: drags the words.
    private func move(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !moving {
                    moving = true
                    model.beginLyricMove()
                }
                model.moveLyrics(CGSize(width: value.translation.width / width,
                                        height: value.translation.height / height))
            }
            .onEnded { _ in
                moving = false
                model.endLyricMove()
            }
    }
}

/// Filters for the whole video, and the keyframes of the video on screen.
struct FramingControls: View {
    let model: EditorModel
    /// Opens the Filters panel (it sits at the bottom of the editor, edge to edge).
    let openFilters: () -> Void
    /// On the lyrics page: opens the words and their look (Aa) in place of Filters.
    let openLyricLook: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if model.lyricTimeline {
                // The lyrics page: their words and look, there whether or not a word is picked.
                Button {
                    model.pause()
                    openLyricLook()
                } label: {
                    SideTile(icon: "textformat", text: "Words & look")
                }
                .accessibilityLabel("The lyrics' words and look")
            } else {
                // Filters: a color look over the whole video. (Each clip's own effects are Fx, below.)
                Button {
                    model.pause()
                    openFilters()
                } label: {
                    SideTile(icon: "camera.filters", text: "Filters", lit: model.filter != .none)
                }
                .accessibilityLabel("Filters for the whole video")
            }

            // On a keyframe, the diamond takes it off; anywhere else it sets one.
            Button { model.setKeyframe() } label: {
                if model.keyframeOnHere {
                    SideTile(icon: "minus.diamond", text: "Remove keyframe", tint: Tint.warn, lit: true)
                } else {
                    SideTile(icon: "plus.diamond", text: "Set keyframe", tint: model.hasDraft ? Tint.warn : Tint.calm,
                             lit: model.hasDraft)
                }
            }
            .accessibilityLabel(model.keyframeOnHere ? "Remove this keyframe" : "Set keyframe")

            if model.hasDraft {
                Button { model.discardDraft() } label: {
                    SideTile(icon: "xmark", text: "Discard")
                }
                .accessibilityLabel("Throw this framing away")
            }

            Menu {
                if model.keyframeCountHere == 0 {
                    if model.maskEditing {
                        Text("Place the mask, then tap the + diamond to start animating it. Each change after that makes a keyframe at the playhead.")
                    } else if model.overlayPick != nil {
                        Text("Move or size the overlay, then tap the + diamond to start animating it. Each change after that makes a keyframe at the playhead. The mask has its own Start keyframing in Mask.")
                    } else if model.trackPicked {
                        Text("Pinch the video to zoom the whole performance, or drag to move it, then tap the + diamond. Overlays and words stay put.")
                    } else if !model.videoFramingHere {
                        Text("Pick what to keyframe: tap the performance or an overlay on the timeline, or touch it on the video. Then tap the + diamond.")
                    } else {
                        Text("Pinch the video to zoom, or hold and drag to move it, then tap the + diamond.")
                    }
                } else {
                    Picker("From this keyframe to the next", selection: Binding(
                        get: { model.easeHere ?? .smooth },
                        set: { model.setEaseHere($0) }
                    )) {
                        ForEach(Ease.allCases, id: \.self) { ease in
                            Text(ease.name).tag(ease)
                        }
                    }
                    Button("Previous keyframe", systemImage: "chevron.left") { model.jumpToKeyframe(forward: false) }
                    Button("Next keyframe", systemImage: "chevron.right") { model.jumpToKeyframe(forward: true) }
                    if model.keyframeHere != nil {
                        Button("Delete this keyframe", systemImage: "trash", role: .destructive) {
                            model.deleteKeyframeHere()
                        }
                    }
                    Button(model.maskEditing ? "Stop animating the mask"
                           : model.overlayPick != nil ? "Take all keyframes off this overlay"
                           : model.trackPicked ? "Reset framing on the performance" : "Reset framing on this video",
                           systemImage: "arrow.counterclockwise", role: .destructive) {
                        model.resetFramingHere()
                    }
                }
            } label: {
                let count = model.keyframeCountHere
                SideTile(icon: model.keyframeHere != nil ? "diamond.fill" : "diamond",
                         text: count == 1 ? "1 key" : "\(count) keys",
                         tint: model.keyframeHere != nil ? Tint.warn : Tint.calm,
                         lit: model.keyframeHere != nil,
                         badge: count > 0 ? "\(count)" : nil)
            }
            .accessibilityLabel("Keyframes")
        }
        // The text sheet: opened by Title in the tools under the timeline, or a tap on a text's clip.
        .sheet(isPresented: Binding(get: { model.titleEditing != nil },
                                    set: { if !$0 { model.endTitleEdit() } })) {
            TitleSheet(model: model)
                .presentationDetents([.medium])
                .presentationContentInteraction(.scrolls)
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}

/// One saved project on home: its picture, name, when it was last edited and how long it is.
struct ProjectTile: View {
    let project: SavedProject
    let thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tint.surface2
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .clipShape(Corner.card)
                .overlay(alignment: .topLeading) {
                    // A performance gets a small mark, so the two kinds are easy to tell apart.
                    if project.kind != "video" {
                        Image(systemName: PerformanceGlyph.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(Tint.accent, in: Capsule())
                            .padding(6)
                            .accessibilityLabel("Performance")
                    }
                }
            Text(project.name)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Text("\(project.updated.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))) \u{00B7} \(EditorModel.clockWhole(max(0, (project.outPoint > project.inPoint ? project.outPoint : project.duration) - project.inPoint)))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

/// Auto edit: pick how often to cut, then let it cut on the beat to the best-looking video.
struct AutoEditSheet: View {
    let model: EditorModel
    @AppStorage("autoPace") private var pace: AutoPace = .normal
    @State private var request = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Scrolls, so the bigger request box never pushes the button off a half-height sheet.
        ScrollView {
        VStack(spacing: 16) {
            Text("Auto edit")
                .font(.title3.weight(.bold))
            Text(model.hasRange
                 ? "Cuts between Start and End on the beat, to whichever video looks best: faces, close-ups, sharp and well lit."
                 : "Cuts the whole song on the beat, to whichever video looks best: faces, close-ups, sharp and well lit.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                Text("How often to cut")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 8) {
                    ForEach(AutoPace.allCases, id: \.self) { option in
                        Button(option.name) { pace = option }
                            .buttonStyle(GlassButtonStyle(tint: Tint.calm, selected: pace == option))
                    }
                }
            }

            if EditRequestReader.isAvailable {
                TextField("", text: $request,
                          prompt: Text("Optional: faster cuts, crossfades, flashes in the chorus, black & white…")
                            .foregroundStyle(.white.opacity(0.45)),
                          axis: .vertical)
                    // Room for a few sentences: 5 lines tall, growing to 10.
                    .lineLimit(5...10)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Tint.surface, in: Corner.card)
            } else if let reason = EditRequestReader.unavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
                let typed = request
                Task { await model.autoEdit(pace: pace, request: typed) }
            } label: {
                Label("Make the edit", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true, big: true))

            Text("It replaces the cuts there. Ask only for effects or transitions and it keeps your cuts and adds them. Typed requests are read on your phone; nothing is sent anywhere. Undo takes it back.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Effects sheet

/// The Fx page for one cut. It starts empty with + Add an effect. The + opens a grid of every
/// effect (each tile shows what it does to a ✨); picking one adds it as a card with its controls.
struct FXSheet: View {
    let model: EditorModel
    let close: () -> Void
    /// Effects added while the page is open keep their card, even turned all the way down.
    @State private var kept: [FXKind] = []
    @State private var picking = false
    /// Tapped the dimmed Transition tile on the first cut: say why, under the tiles.
    @State private var noTransitionWhy = false

    private var shown: [FXKind] {
        FXKind.onFxPage.filter { model.effectOn($0) || kept.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if picking {
                picker
            } else if shown.isEmpty {
                empty
            } else {
                cutScrubber
                cards
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if picking {
                Button { picking = false } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(picking ? "Add an effect" : "Fx").font(.title3.weight(.bold))
                Text(model.fxCutName).font(.footnote).foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
            // Play this cut (Stop while it plays: back to the cut's start), and Pause where it is.
            Button {
                if model.isPlaying { model.stopCutPlay() } else { model.playCutHere() }
            } label: {
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Stop" : "Play this cut")
            Button { model.pause() } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(model.isPlaying ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isPlaying)
            .accessibilityLabel("Pause")
            Button { close() } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Tint.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Nothing on this cut yet: one big +.
    private var empty: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Button { picking = true } label: {
                VStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Tint.accent)
                        .frame(width: 76, height: 76)
                        .background(Color.white.opacity(0.08))
                    Text("Add an effect")
                        .font(.subheadline.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Effects go on this cut only.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Every effect, as a tile showing what it does to a ✨.
    private var picker: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(FXKind.onFxPage) { kind in
                    let on = model.effectOn(kind)
                    let blocked = kind == .transition && !model.canTransitionHere
                    Button { choose(kind) } label: {
                        VStack(spacing: 6) {
                            FXIcon(kind: kind)
                                .frame(width: 52, height: 52)
                            Text(kind.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(on ? Tint.accent : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(blocked ? 0.35 : 1)
                    .accessibilityLabel(on ? "\(kind.name), on" : kind.name)
                }
            }
            if noTransitionWhy && !model.canTransitionHere {
                note("The first cut has nothing before it to come in from, so it has no transition.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .task {
                        // Shows for 3 seconds, then fades.
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(.easeOut(duration: 0.6)) { noTransitionWhy = false }
                    }
            }
          }
        }
        .padding(.horizontal, 20)
        .onChange(of: model.canTransitionHere) { _, _ in noTransitionWhy = false }
    }

    private func choose(_ kind: FXKind) {
        if kind == .transition && !model.canTransitionHere {
            withAnimation { noTransitionWhy = true }
            return
        }
        if !model.effectOn(kind) { model.addEffect(kind) }
        // One custom shader at a time: the other one's card goes.
        if let id = kind.customID {
            kept.removeAll { $0.customID != nil && $0.customID != id }
        }
        if !kept.contains(kind) { kept.append(kind) }
        picking = false
    }

    /// The effects on this cut, one card each, and + to add another.
    private var cards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(shown) { kind in
                    card(kind)
                }
                Button { picking = true } label: {
                    Label("Add an effect", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tint.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.08))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    plainButton("Use on every cut", icon: "square.stack.3d.down.right") { model.useFXOnEveryCut() }
                    plainButton("Clear", icon: "xmark", tint: Tint.bad) {
                        model.clearFXHere()
                        kept = []
                    }
                }
                note("Undo takes back any change.")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func card(_ kind: FXKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.icon)
                    .foregroundStyle(Tint.accent)
                    .frame(width: 22)
                Text(kind.name).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    model.removeEffect(kind)
                    kept.removeAll { $0 == kind }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take \(kind.name) off")
            }
            controls(kind)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
    }

    @ViewBuilder private func controls(_ kind: FXKind) -> some View {
        let fx = model.fxHere
        let transition = model.transitionHere
        switch kind {
        case .transition:
            chips(TransitionKind.allCases.filter { $0 != .none }, selected: transition.kind, name: { $0.name }) { pick in
                var next = transition
                next.kind = pick
                model.setTransitionHere(next)
            }
            chips(Transition.lengths.map { $0.name },
                  selected: Transition.lengths.first(where: { abs(transition.length - $0.seconds) < 0.01 })?.name ?? "",
                  name: { $0 }) { pick in
                guard let length = Transition.lengths.first(where: { $0.name == pick }) else { return }
                var next = transition
                next.length = length.seconds
                model.setTransitionHere(next)
            }
        case .zoom:
            HStack(spacing: 8) {
                zoomPreset(.zoomIn)
                zoomPreset(.zoomOut)
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 4) {
                    Rectangle().strokeBorder(ZoomFrames.startColor, lineWidth: 2).frame(width: 14, height: 14)
                    Rectangle().strokeBorder(ZoomFrames.endColor, lineWidth: 2).frame(width: 14, height: 14)
                }
                .padding(.top, 2)
                note("Drag the green Start box and the red End box on the video, and drag a corner to size one. Play shows the zoom.")
            }
        case .color:
            chips(ColorLook.allCases.filter { $0 != .none }, selected: fx.color, name: { $0.name }) { look in
                var next = fx
                next.color = look
                model.setFXHere(next)
            }
            keyedSlider(.colorMix, name: "Color", range: 0...1, ends: ("Original", "Full look"))
        case .blur:
            keyedSlider(.blur, name: "Blur", range: 0...1, ends: ("None", "Soft"))
        case .tilt:
            keyedSlider(.tilt, name: "Tilt", range: -30...30, ends: ("Tilt left", "Tilt right"), snapToZero: true)
        case .shake:
            keyedSlider(.shake, name: "Shake", range: 0...1, ends: ("Gentle", "Big shake"))
        case .mirror:
            note("Mirror is its own button in the tools under the timeline.")
        case .face:
            if model.busy == "Finding the face…" {
                note("Finding the face…")
            } else {
                note(fx.followFace ? "Keeps the face in the middle, zoomed in a little."
                     : "No face was found to follow in this cut.")
            }
        case .glow:
            chips(GlowStyle.allCases, selected: fx.glow ?? .glimmer, name: { $0.name }) { style in
                var next = fx
                next.glow = style
                model.setFXHere(next)
            }
            keyedSlider(.glow, name: "Glow", range: 0...1, ends: ("Faint", "Bright"))
            note(glowNote(fx.glow ?? .glimmer))
        case .rgbSplit, .fisheye:
            if fx.custom == kind.customID {
                keyedSlider(.amount, name: kind.name, range: 0...1, ends: ("Subtle", "Strong"))
                if kind == .fisheye {
                    fishPanel
                }
                if !CustomFX.isReady {
                    note("The custom shaders didn't load in this build.")
                }
            } else {
                note("Off. Only one of RGB split and Fisheye can be on at a time.")
            }
        }
    }

    private func glowNote(_ style: GlowStyle) -> String {
        switch style {
        case .glimmer: "X shaped stars and a glow on the brightest spots."
        case .fog: "A soft, blurry glow around the brightest spots."
        case .cross: "Stars that go up, down and sideways, and a glow."
        }
    }

    /// Fisheye's circle: drag or tap the video to place it. The diamond keyframes where it sits.
    private var fishPanel: some View {
        let count = model.fishKeyCount
        let here = model.fishKeyHere != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .foregroundStyle(Tint.accent)
                Text("Drag the video, or tap it, to move the circle.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                plainButton("Center it", icon: "scope") { model.centerFish() }
                    .fixedSize()
                Button {
                    if here { model.deleteFishKeyHere() } else { model.addFishKey() }
                } label: {
                    Image(systemName: here ? "diamond.fill" : "plus.diamond")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(count > 0 ? Tint.accent : .white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.08))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(here ? "Take off this circle keyframe" : "Add a circle keyframe here")
            }
            if count > 0 {
                note("\(count == 1 ? "1 circle keyframe" : "\(count) circle keyframes"). Move the playhead and move the circle: each move makes a keyframe there.")
            }
        }
    }

    /// The playhead, kept inside this cut (where its effects are), for keyframing.
    private var cutScrubber: some View {
        let range = model.fxCutRange
        return HStack(spacing: 8) {
            Slider(value: Binding(get: { min(max(model.time, range.lowerBound), range.upperBound) },
                                  set: { model.scrubInCut(to: $0) }),
                   in: range,
                   onEditingChanged: { editing in
                       if editing { model.beginScrub() } else { model.endScrub() }
                   })
                .tint(Tint.accent)
                .accessibilityLabel("Playhead in this cut")
            Text(EditorModel.clock(model.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// A slider with its keyframe diamond beside it. Once a slider has a keyframe, moving it
    /// sets (or adds) a keyframe at the playhead.
    private func keyedSlider(_ param: FXParam, name: String, range: ClosedRange<Double>,
                             ends: (String, String), snapToZero: Bool = false) -> some View {
        let keyed = !model.fxKeys(param).isEmpty
        let on = model.fxKeyOnHere(param)
        return HStack(alignment: .top, spacing: 8) {
            FXSlider(value: model.fxValueHere(param), range: range, ends: ends, snapToZero: snapToZero) { value in
                model.setFXValue(param, value)
            }
            Button {
                model.toggleFXKey(param, name: name)
            } label: {
                Image(systemName: on ? "diamond.fill" : "plus.diamond")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(keyed ? Tint.accent : Color.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(on ? "Take off this \(name) keyframe" : "Add a \(name) keyframe here")
        }
    }

    /// Zoom in or Zoom out: a square with arrows pointing in or out, and its name under it.
    private func zoomPreset(_ zoom: AutoZoom) -> some View {
        let on = model.zoomHere == zoom
        let arrows = zoom == .zoomIn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        return Button {
            model.useZoomPreset(zoom)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Image(systemName: "square")
                        .font(.system(size: 30, weight: .regular))
                    Image(systemName: arrows)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(zoom.name)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(on ? Tint.accent : Color.white.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color.white.opacity(on ? 0.14 : 0.08))
            .overlay(Rectangle().strokeBorder(on ? Tint.accent : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(zoom.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func plainButton(_ title: String, icon: String, tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Color.white.opacity(0.08))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chips<Item: Hashable>(_ items: [Item], selected: Item, name: @escaping (Item) -> String,
                                       pick: @escaping (Item) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = item == selected
                    Button { pick(item) } label: {
                        Text(name(item))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(on ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(on ? Tint.accent : Color.white.opacity(0.08))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// An effect's tile in the Fx picker: the same ✨ for every effect, with that effect done to it,
/// its strength swelling and easing off so the difference is easy to see.
struct FXIcon: View {
    let kind: FXKind

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 0 ... 1 ... 0 every 1.6 seconds.
            let p = (sin(t * 2 * .pi / 1.6) + 1) / 2
            glyph(p: p, t: t)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var sparkle: some View { sparkle(Tint.accent) }

    private func sparkle(_ color: Color) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(color)
    }

    @ViewBuilder private func glyph(p: Double, t: Double) -> some View {
        switch kind {
        case .transition:
            // One ✨ fades out as the next slides in.
            ZStack {
                sparkle.opacity(1 - p).offset(x: -14 * p)
                sparkle(.white).opacity(p).offset(x: 14 * (1 - p))
            }
        case .zoom:
            sparkle.scaleEffect(0.7 + 0.6 * p)
        case .color:
            sparkle.hueRotation(.degrees(300 * p)).saturation(1 - 0.9 * max(0, p - 0.6) / 0.4)
        case .blur:
            sparkle.blur(radius: 5 * p)
        case .tilt:
            sparkle.rotationEffect(.degrees(-30 + 60 * p))
        case .shake:
            sparkle.offset(x: 4 * p * sin(t * 37), y: 4 * p * sin(t * 29 + 1))
        case .mirror:
            sparkle.scaleEffect(x: cos(p * .pi), y: 1)
        case .face:
            // A square that keeps hold of the ✨ while it drifts.
            let x = 8 * sin(t * 1.7), y = 6 * sin(t * 2.3)
            ZStack {
                sparkle.scaleEffect(0.85)
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 34, height: 34)
            }
            .offset(x: x * (1 - p), y: y * (1 - p))
        case .glow:
            // Glows, and a little star turns and twinkles over it.
            ZStack {
                sparkle.shadow(color: .white.opacity(0.9 * p), radius: 10 * p)
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(45 + 90 * p))
                    .scaleEffect(0.4 + 0.8 * p)
                    .opacity(p)
                    .offset(x: 11, y: -11)
            }
        case .rgbSplit:
            // Red and blue pull apart; where all three meet it's white.
            ZStack {
                sparkle(.red).offset(x: -5 * p).blendMode(.screen)
                sparkle(.green).blendMode(.screen)
                sparkle(.blue).offset(x: 5 * p).blendMode(.screen)
            }
            .compositingGroup()
            .overlay { sparkle.opacity(1 - p) }
        case .fisheye:
            // Swells inside a round lens with a blue rim, dark around it.
            ZStack {
                Color.black.opacity(0.6 * p)
                sparkle.scaleEffect(1 + 0.5 * p)
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
                    .background(Circle().fill(Color(red: 0.22, green: 0.5, blue: 1).opacity(0.18 * p)))
                Circle()
                    .stroke(Color(red: 0.22, green: 0.5, blue: 1).opacity(0.9 * p), lineWidth: 2)
                    .frame(width: 46, height: 46)
                    .blur(radius: 1.5)
            }
        }
    }
}

/// Filters: one color look over the whole video (over every clip and overlay, under the words).
/// Each clip can still have its own Color in Fx.
struct FilterSheet: View {
    let model: EditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filters").font(.title3.weight(.bold))
                    Text("The whole video").font(.footnote).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                Button { close() } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Tint.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ColorLook.allCases, id: \.self) { look in
                    let on = model.filter == look
                    Button { model.setFilter(look) } label: {
                        Text(look.name)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(on ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? Tint.accent : Color.white.opacity(0.08))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.filter != .none {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How much").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                    FXSlider(value: model.filterAmount, range: 0...1, ends: ("Original", "Full look")) { value in
                        model.setFilterAmount(value)
                    }
                    .id(model.filter)
                }
            }
            Text("Effects for one clip are in Fx, in the tools under the timeline.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }
}

/// A panel that comes up from the bottom of the editor, edge to edge, in creatrr's dark frosted
/// glass. Drag its grabber down to close it.
struct BottomPanel<Content: View>: View {
    let height: CGFloat
    let close: () -> Void
    @ViewBuilder var content: Content
    @State private var pulled: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { pulled = max(0, $0.translation.height) }
                        .onEnded { value in
                            if value.translation.height > 80 || value.predictedEndTranslation.height > 220 {
                                close()
                            }
                            withAnimation(.spring(duration: 0.3)) { pulled = 0 }
                        }
                )
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { close() }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background {
            // Rounded at the top like creatrr's pop-ups, square where it meets the screen's bottom.
            FrostSheet()
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
                .ignoresSafeArea(edges: [.bottom, .horizontal])
        }
        .environment(\.colorScheme, .dark)
        .offset(y: pulled)
        .transition(.move(edge: .bottom))
    }
}

/// A slider that changes the edit when you let go (so one drag is one Undo).
struct FXSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let ends: (String, String)
    var snapToZero = false
    let commit: (Double) -> Void
    @State private var live: Double
    @State private var dragging = false

    init(value: Double, range: ClosedRange<Double>, ends: (String, String), snapToZero: Bool = false,
         commit: @escaping (Double) -> Void) {
        self.value = value
        self.range = range
        self.ends = ends
        self.snapToZero = snapToZero
        self.commit = commit
        _live = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: $live, in: range, onEditingChanged: { editing in
                dragging = editing
                if !editing {
                    var final = live
                    if snapToZero, abs(final) < (range.upperBound - range.lowerBound) * 0.04 { final = 0 }
                    live = final
                    commit(final)
                }
            })
            .tint(Tint.accent)
            HStack {
                Text(ends.0)
                Spacer()
                Text(ends.1)
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.55))
        }
        .onAppear { live = value }
        .onChange(of: value) { _, new in
            if !dragging { live = new }
        }
    }
}

/// A picked overlay's mask: a shape (none, circle or rectangle), how big it is, how soft its edge
/// is, and Invert to keep the outside instead.
struct MaskSheet: View {
    let model: EditorModel

    var body: some View {
        let mask = model.overlayPick.flatMap { model.overlayHere($0)?.mask } ?? OverlayMask()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mask").font(.headline)
                    Text(hint(mask.shape))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach(MaskShape.allCases, id: \.self) { shape in
                        let on = mask.shape == shape
                        Button {
                            var next = mask
                            next.shape = shape
                            // Custom starts from the corners of the shape as it is, ready to drag.
                            if shape == .custom, (next.points?.count ?? 0) < 3 { next.points = mask.corners }
                            model.maskPoint = nil
                            model.setOverlayMask(next)
                            model.showOverlayNow()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: shape.icon).font(.title3)
                                Text(shape.name).font(.caption)
                            }
                            .foregroundStyle(on ? Tint.accent : .white.opacity(0.85))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(on ? Tint.surface3 : Tint.surface2, in: Corner.chip)
                            .overlay(Corner.chip.strokeBorder(on ? Tint.accent : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                if mask.shape == .custom { points(mask) }
                if mask.shape != .off {
                    row("Size", value: mask.size, range: 0.1...OverlayMask.largest) { value in
                        var next = mask
                        next.size = value
                        return next
                    }
                    row("Soft edge", value: mask.feather, range: 0...1) { value in
                        var next = mask
                        next.feather = value
                        return next
                    }
                    Toggle("Invert (keep the outside)", isOn: Binding(
                        get: { mask.invert },
                        set: { value in
                            var next = mask
                            next.invert = value
                            model.setOverlayMask(next)
                            model.showOverlayNow()
                        }
                    ))
                    .font(.subheadline)
                    .tint(Tint.accent)
                    keyframes
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.white)
    }

    private func hint(_ shape: MaskShape) -> String {
        switch shape {
        case .off: "Pick a shape to cut the overlay out."
        case .custom: "Tap the video to add a point. Drag a point to move it. Drag anywhere else to move the shape, pinch to size it."
        default: "Drag a square handle to stretch that side. Drag anywhere else to move it, pinch to size it."
        }
    }

    /// Custom: straight or curved lines between the points, and removing the picked point.
    private func points(_ mask: OverlayMask) -> some View {
        let count = mask.anchors.count
        let canRemove = model.maskPoint.map { $0 < count } == true && count > 3
        return HStack(spacing: 8) {
            Button {
                var next = mask
                next.smooth = !mask.curved
                model.setOverlayMask(next)
                model.showOverlayNow()
            } label: {
                Label("Curved", systemImage: mask.curved ? "checkmark" : "scribble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(mask.curved ? Tint.accent : .white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Tint.surface2, in: Corner.chip)
                    .overlay(Corner.chip.strokeBorder(mask.curved ? Tint.accent : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(mask.curved ? .isSelected : [])
            Button {
                model.removeMaskPoint()
            } label: {
                Label("Remove point", systemImage: "minus.square")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canRemove ? Tint.bad : .white.opacity(0.35))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Tint.surface2, in: Corner.chip)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
        }
    }

    /// The mask's keyframes. Until the first one, placing the mask sets it for the whole overlay.
    private var keyframes: some View {
        let count = model.maskKeyCount
        let here = model.maskKeyHere
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if count > 0 {
                    square("chevron.left", spoken: "Previous mask keyframe") { model.jumpToMaskKey(forward: false) }
                }
                Button { model.setMaskKey() } label: {
                    Label(count == 0 ? "Start keyframing" : (here ? "Keyframe here" : "Add keyframe"),
                          systemImage: here ? "diamond.fill" : "plus.diamond")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(here || count == 0 ? Tint.accent : .white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Tint.surface2, in: Corner.chip)
                        .overlay(Corner.chip.strokeBorder(here ? Tint.accent : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if count > 0 {
                    square("chevron.right", spoken: "Next mask keyframe") { model.jumpToMaskKey(forward: true) }
                    if here {
                        square("trash", spoken: "Delete this mask keyframe", tint: Tint.bad) { model.deleteMaskKeyHere() }
                    } else {
                        square("xmark.diamond", spoken: "Stop animating the mask", tint: Tint.bad) { model.clearMaskKeys() }
                    }
                }
            }
            Text(count == 0
                 ? "The mask stays where you place it. Start keyframing to animate it from the playhead."
                 : "\(count == 1 ? "1 keyframe" : "\(count) keyframes"). Move the playhead and change the mask: each change makes a keyframe there.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func square(_ icon: String, spoken: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.08))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
    }

    private func row(_ name: String, value: Double, range: ClosedRange<Double>,
                     change: @escaping (Double) -> OverlayMask) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.subheadline).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { model.setOverlayMask(change($0)) }), in: range,
                   onEditingChanged: { editing in
                       if !editing { model.showOverlayNow() }
                   })
            .tint(Tint.accent)
        }
    }
}

/// creatrr's floating "+ New…" pill: frosted glass with a thin light edge.
struct FrostedNewLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("+").font(.system(size: 24, weight: .regular)).offset(y: -1)
            Text("New\u{2026}").font(.system(size: 16, weight: .bold))
        }
        .foregroundStyle(Tint.text)
        .padding(.horizontal, 28)
        .frame(height: 54)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color(red: 50 / 255, green: 50 / 255, blue: 54 / 255).opacity(0.2))
        }
        .overlay { FrostEdge() }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.38), radius: 20, y: 14)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .contentShape(Capsule())
    }
}
