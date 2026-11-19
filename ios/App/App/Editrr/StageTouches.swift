import SwiftUI
import UIKit

/// The video's touch handling, done with UIKit so two fingers can zoom and move at once:
/// - Two fingers: pinch to zoom around the spot between them, and slide them to move.
/// - Press and hold with one finger, then drag: move (no hold needed when `quickDrag` is on).
/// - Double tap: full screen.
/// Everything is reported as fractions of the view, so the model doesn't need its size.
struct StageTouches: UIViewRepresentable {
    /// One finger moves without the hold first (an overlay is picked).
    var quickDrag: Bool
    /// A move or pinch started. `focus` is where, from the top left (0...1).
    var began: @MainActor (_ focus: CGPoint) -> Void
    /// How much bigger, and how far the fingers moved since it began (fractions of the view).
    var changed: @MainActor (_ scale: Double, _ move: CGSize) -> Void
    var ended: @MainActor () -> Void
    var doubleTapped: @MainActor () -> Void
    /// One tap (after a double tap is ruled out). `at` is from the top left (0...1).
    var tapped: @MainActor (_ at: CGPoint) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.parent = self

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))

        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.25
        press.allowableMovement = 12
        press.numberOfTouchesRequired = 1

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = quickDrag

        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2

        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.numberOfTapsRequired = 1
        single.require(toFail: double)

        for recognizer in [pinch, press, pan, double, single] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        coordinator.panRecognizer = pan
        coordinator.pressRecognizer = press
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.panRecognizer?.isEnabled = quickDrag
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: StageTouches?
        weak var panRecognizer: UIPanGestureRecognizer?
        weak var pressRecognizer: UILongPressGestureRecognizer?
        private let haptic = UIImpactFeedbackGenerator(style: .medium)

        private enum Mode { case none, oneFinger, twoFingers }
        private var mode = Mode.none
        private var startPoint: CGPoint = .zero

        private func fraction(_ point: CGPoint, in view: UIView?) -> CGPoint {
            let size = view?.bounds.size ?? CGSize(width: 1, height: 1)
            return CGPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
        }

        private func moved(_ point: CGPoint, in view: UIView?) -> CGSize {
            let size = view?.bounds.size ?? CGSize(width: 1, height: 1)
            return CGSize(width: (point.x - startPoint.x) / max(size.width, 1),
                          height: (point.y - startPoint.y) / max(size.height, 1))
        }

        private func finish() {
            guard mode != .none else { return }
            mode = .none
            parent?.ended()
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            let view = recognizer.view
            switch recognizer.state {
            case .began:
                // Two fingers take over from a one-finger move that's going.
                finish()
                startPoint = recognizer.location(in: view)
                mode = .twoFingers
                parent?.began(fraction(startPoint, in: view))
            case .changed:
                guard mode == .twoFingers else { return }
                // With a finger lifted the middle point jumps, so it only follows two fingers.
                guard recognizer.numberOfTouches >= 2 else { return }
                parent?.changed(Double(recognizer.scale), moved(recognizer.location(in: view), in: view))
            default:
                if mode == .twoFingers { finish() }
            }
        }

        private func oneFinger(_ recognizer: UIGestureRecognizer, felt: Bool) {
            let view = recognizer.view
            switch recognizer.state {
            case .began:
                guard mode == .none else { return }
                startPoint = recognizer.location(in: view)
                mode = .oneFinger
                if felt { haptic.impactOccurred() }
                parent?.began(fraction(startPoint, in: view))
            case .changed:
                guard mode == .oneFinger else { return }
                parent?.changed(1, moved(recognizer.location(in: view), in: view))
            default:
                if mode == .oneFinger { finish() }
            }
        }

        @objc func press(_ recognizer: UILongPressGestureRecognizer) {
            // Once an overlay is picked, the plain drag does this.
            if panRecognizer?.isEnabled == true { return }
            oneFinger(recognizer, felt: true)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            oneFinger(recognizer, felt: false)
        }

        @objc func singleTap(_ recognizer: UITapGestureRecognizer) {
            guard mode == .none, recognizer.state == .ended else { return }
            parent?.tapped(fraction(recognizer.location(in: recognizer.view), in: recognizer.view))
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard mode == .none else { return }
            parent?.doubleTapped()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
