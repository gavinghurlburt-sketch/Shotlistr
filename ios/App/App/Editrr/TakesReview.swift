import AVFoundation
import AVKit
import SwiftUI

/// Your takes before you use them, like the Photos app: the take picked plays big (the newest
/// to start), the rest are thumbnails underneath. Delete a take, film more, or use them all.
struct TakesReview: View {
    let takes: [CapturedTake]
    /// Back to the camera to film another take.
    let filmMore: () -> Void
    let delete: (CapturedTake.ID) -> Void
    let use: () -> Void
    @State private var picked: CapturedTake.ID?
    @State private var player = AVPlayer()
    @State private var thumbs: [CapturedTake.ID: UIImage] = [:]
    @State private var askingDelete = false
    @State private var loop: NSObjectProtocol?

    private var shown: CapturedTake? { takes.first { $0.id == picked } ?? takes.last }
    private var shownNumber: Int { (shown.flatMap { take in takes.firstIndex { $0.id == take.id } } ?? 0) + 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { leave(filmMore) } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back to the camera")
                Spacer(minLength: 0)
                Text("Take \(shownNumber) of \(takes.count)")
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)

            // The take picked, big, playing over and over.
            VideoPlayer(player: player)
                .aspectRatio(shown?.wide == true ? 16.0 / 9.0 : 9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)

            strip

            HStack(spacing: 10) {
                Button { askingDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.headline)
                        .foregroundStyle(Tint.bad)
                        .frame(width: 48, height: 44)
                        .background(Color.white.opacity(0.1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete take \(shownNumber)")
                Button { leave(filmMore) } label: {
                    Label("Film more", systemImage: "video.badge.plus")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.1))
                }
                .buttonStyle(.plain)
                Button { leave(use) } label: {
                    Text(takes.count == 1 ? "Use 1 take" : "Use \(takes.count) takes")
                        .font(.headline)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Tint.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .confirmationDialog("Delete take \(shownNumber)?", isPresented: $askingDelete, titleVisibility: .visible) {
            Button("Delete take", role: .destructive) { deleteShown() }
        } message: {
            Text("The copy in Photos stays.")
        }
        .task(id: takes.map(\.id)) { await loadThumbs() }
        .onAppear { play(shown) }
        .onChange(of: picked) { _, _ in play(shown) }
        .onDisappear { stop() }
    }

    /// Every take, oldest first, like Photos. Tap one to see it big.
    private var strip: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                        let on = take.id == shown?.id
                        Button { picked = take.id } label: {
                            ZStack(alignment: .bottomLeading) {
                                Color.white.opacity(0.08)
                                if let image = thumbs[take.id] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                }
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 4)
                                    .background(Color.black.opacity(0.55))
                            }
                            .frame(width: 44, height: 64)
                            .clipped()
                            .overlay(Rectangle().strokeBorder(on ? Color.white : .clear, lineWidth: 2))
                            .opacity(on ? 1 : 0.7)
                        }
                        .buttonStyle(.plain)
                        .id(take.id)
                        .accessibilityLabel("Take \(index + 1)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { if let last = takes.last { scroller.scrollTo(last.id, anchor: .trailing) } }
        }
        .frame(height: 64)
    }

    private func play(_ take: CapturedTake?) {
        stop()
        guard let take else { return }
        let item = AVPlayerItem(url: take.url)
        player.replaceCurrentItem(with: item)
        let looping = player
        loop = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                      object: item, queue: .main) { [weak looping] _ in
            MainActor.assumeIsolated {
                looping?.seek(to: .zero)
                looping?.play()
            }
        }
        player.play()
    }

    private func stop() {
        player.pause()
        if let loop { NotificationCenter.default.removeObserver(loop) }
        loop = nil
    }

    /// Leaving the review: the take stops playing first.
    private func leave(_ next: () -> Void) {
        stop()
        player.replaceCurrentItem(with: nil)
        next()
    }

    private func deleteShown() {
        guard let take = shown, let index = takes.firstIndex(where: { $0.id == take.id }) else { return }
        stop()
        player.replaceCurrentItem(with: nil)
        // The take next to it shows next (the one before, at the end).
        let next = index + 1 < takes.count ? takes[index + 1] : (index > 0 ? takes[index - 1] : nil)
        picked = next?.id
        delete(take.id)
        thumbs[take.id] = nil
        // The last one gone: back to the camera. Otherwise the new pick starts playing.
        if next == nil { filmMore() }
    }

    private func loadThumbs() async {
        for take in takes where thumbs[take.id] == nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                thumbs[take.id] = UIImage(cgImage: frame.image)
            }
        }
    }
}
