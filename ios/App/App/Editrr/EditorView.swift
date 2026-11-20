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
                Group {
                    if icon == PerformanceGlyph.name {
                        PerformanceGlyph().frame(width: 26, height: 21).frame(height: 28)
                    } else {
                        Image(systemName: icon).font(.title2.weight(.semibold))
                    }
                }
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
                FramingControls(model: model)
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
                .sheet(isPresented: $exporting) {
                    ExportSheet(model: model)
                        .presentationDetents([.medium])
                        .presentationBackground(.ultraThinMaterial)
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

            if model.lyricTimeline {
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
        .fullScreenCover(isPresented: Binding(get: { model.tapBeatOn }, set: { model.tapBeatOn = $0 })) {
            TapGameView(model: model)
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
                // No Auto edit, Shuffle or Tap to cut here: the performance is already edited
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

    /// Tap to cut: a rhythm game where the song plays and each tap is a cut.
    private var tapBeatTool: some View {
        ToolItem(icon: "hand.tap", text: "Tap to cut", spoken: "Tap to cut: tap along with the song to make cuts") {
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

/// Export: one 1080 x 1920 (or 1920 x 1080 horizontal) video saved to Photos, with or without the song.
struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            // Once it's saved, the celebration takes the whole sheet.
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
            case .saved(let url):
                ReadyToPost(url: url) { dismiss() }
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
        .padding(24)
        .frame(maxWidth: .infinity)
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

/// After an export: a quick celebration, then one tap to post. The video is already in Photos
/// (newest first), so Instagram and TikTok open straight to where you pick it. More is the share
/// sheet. You do the posting.
struct ReadyToPost: View {
    let url: URL
    let done: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var pop = false
    /// An app that didn't open (not on this phone).
    @State private var missing: String?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Burst(pop: pop)
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(Tint.good)
                    .scaleEffect(pop ? 1 : 0.3)
            }
            .frame(height: 96)
            Text("Ready to post!").font(.title2.weight(.bold))
            Text("It's in Photos, at the top.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 10) {
                post("Instagram", icon: "camera", links: ["instagram://camera", "instagram://app"])
                post("TikTok", icon: "music.note", links: ["tiktok://", "snssdk1233://"])
            }
            HStack(spacing: 10) {
                ShareLink(item: url) {
                    Label("More", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
                Button(action: done) {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }
            if let missing {
                Text("\(missing) didn't open. Tap More to share it another way.")
                    .font(.caption)
                    .foregroundStyle(Tint.warn)
                    .multilineTextAlignment(.center)
            }
        }
        .sensoryFeedback(.success, trigger: pop)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { pop = true }
        }
    }

    /// Opens the app (trying each link in turn); says so when none opens.
    private func post(_ name: String, icon: String, links: [String]) -> some View {
        Button {
            missing = nil
            open(links, name: name)
        } label: {
            Label(name, systemImage: icon)
                .font(.body.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
        .accessibilityLabel("Post to \(name)")
    }

    private func open(_ links: [String], name: String) {
        guard let first = links.first, let link = URL(string: first) else {
            missing = name
            return
        }
        openURL(link) { opened in
            if !opened { open(Array(links.dropFirst()), name: name) }
        }
    }
}

/// Little colored squares that fly out from the middle once.
struct Burst: View {
    let pop: Bool
    private static let colors: [Color] = [Tint.accent, Tint.good, Tint.warn, .pink, .cyan, .white]

    var body: some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                let angle = Double(index) / 18 * 2 * .pi + (index.isMultiple(of: 2) ? 0.2 : 0)
                let reach = 60.0 + Double(index % 3) * 18
                Rectangle()
                    .fill(Self.colors[index % Self.colors.count])
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(pop ? Double(index) * 40 : 0))
                    .offset(x: pop ? cos(angle) * reach : 0, y: pop ? sin(angle) * reach : 0)
                    .opacity(pop ? 0 : 1)
                    .animation(.easeOut(duration: 0.9), value: pop)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                    StageTouches(quickDrag: model.overlayPick != nil || model.lyricsActive,
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

/// Effects for the cut at the playhead, and the keyframes of the video on screen.
struct FramingControls: View {
    let model: EditorModel
    @State private var showingFX = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if model.beginFX() { showingFX = true }
            } label: {
                SideTile(icon: "sparkles", text: "Effects",
                         lit: model.hasFXAtPlayhead || model.zoomHere != .off)
            }
            .accessibilityLabel("Transitions and effects for this cut")
            .sheet(isPresented: $showingFX, onDismiss: { model.endFX() }) {
                FXSheet(model: model)
                    .presentationDetents([.medium])
                    .presentationContentInteraction(.scrolls)
                    .presentationBackground(.ultraThinMaterial)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
                        PerformanceGlyph()
                            .frame(width: 13, height: 10)
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

/// Transitions, zoom, color, blur, movement, face follow and custom shaders for one cut.
struct FXSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let fx = model.fxHere
        let transition = model.transitionHere
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Effects").font(.title3.weight(.bold))
                        Text(model.fxCutName).font(.footnote).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    Button { model.playCutHere() } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.teal, selected: true))
                    Button("Done") { dismiss() }
                        .buttonStyle(GlassButtonStyle())
                }

                section("Transition in") {
                    if model.canTransitionHere {
                        chips(TransitionKind.allCases, selected: transition.kind, name: { $0.name }) { kind in
                            var next = transition
                            next.kind = kind
                            model.setTransitionHere(next)
                        }
                        if transition.kind != .none {
                            HStack(spacing: 8) {
                                ForEach(Transition.lengths.indices, id: \.self) { i in
                                    let length = Transition.lengths[i]
                                    Button(length.name) {
                                        var next = transition
                                        next.length = length.seconds
                                        model.setTransitionHere(next)
                                    }
                                    .buttonStyle(GlassButtonStyle(tint: Tint.calm,
                                                                  selected: abs(transition.length - length.seconds) < 0.01))
                                }
                            }
                        }
                    } else {
                        note("The first cut has nothing before it to come in from.")
                    }
                }

                section("Zoom") {
                    chips(AutoZoom.allCases, selected: model.zoomHere, name: { $0.name }) { model.setZoomHere($0) }
                }

                section("Color") {
                    chips(ColorLook.allCases, selected: fx.color, name: { $0.name }) { look in
                        var next = fx
                        next.color = look
                        model.setFXHere(next)
                    }
                }

                section("Blur") {
                    FXSlider(value: fx.blur, range: 0...1, ends: ("None", "Soft")) { value in
                        var next = fx
                        next.blur = value
                        model.setFXHere(next)
                    }
                }

                section("Move") {
                    FXSlider(value: fx.rotate, range: -30...30, ends: ("Tilt left", "Tilt right"), snapToZero: true) { value in
                        var next = fx
                        next.rotate = value
                        model.setFXHere(next)
                    }
                    FXSlider(value: fx.shake, range: 0...1, ends: ("No shake", "Big shake")) { value in
                        var next = fx
                        next.shake = value
                        model.setFXHere(next)
                    }
                    Button {
                        var next = fx
                        next.mirror.toggle()
                        model.setFXHere(next)
                    } label: {
                        Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.calm, selected: fx.mirror))
                }

                section("Face") {
                    Button {
                        let on = !fx.followFace
                        Task { await model.followFaceHere(on) }
                    } label: {
                        Label(model.busy == "Finding the face…" ? "Finding the face…" : "Follow face",
                              systemImage: "face.smiling")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.calm, selected: fx.followFace))
                    .disabled(model.busy != nil)
                    note("Finds the face in this cut and keeps it in the middle, zoomed in a little.")
                }

                section("Custom") {
                    let none = "none"
                    let ids = [none] + CustomFX.all.map { $0.id }
                    chips(ids, selected: fx.custom ?? none,
                          name: { id in id == none ? "None" : (CustomFX.entry(id)?.name ?? id) }) { id in
                        var next = fx
                        next.custom = id == none ? nil : id
                        model.setFXHere(next)
                    }
                    if fx.custom != nil {
                        FXSlider(value: fx.customAmount, range: 0...1, ends: ("Subtle", "Strong")) { value in
                            var next = fx
                            next.customAmount = value
                            model.setFXHere(next)
                        }
                    }
                    if !CustomFX.isReady {
                        note("The custom shaders didn't load in this build.")
                    }
                }

                HStack(spacing: 8) {
                    Button { model.useFXOnEveryCut() } label: {
                        Label("Use on every cut", systemImage: "square.stack.3d.down.right")
                    }
                    .buttonStyle(GlassButtonStyle())
                    Button { model.clearFXHere() } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Tint.bad))
                }
                note("Undo takes back any change.")
            }
            .padding(20)
        }
        .foregroundStyle(.white)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
    }

    private func chips<Item: Hashable>(_ items: [Item], selected: Item, name: @escaping (Item) -> String,
                                       pick: @escaping (Item) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button(name(item)) { pick(item) }
                        .buttonStyle(GlassButtonStyle(tint: Tint.calm, selected: item == selected))
                }
            }
        }
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
