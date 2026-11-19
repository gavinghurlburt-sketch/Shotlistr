import SwiftUI
import UIKit

/// The timeline's touch handling, done with UIKit's gesture recognizers so it feels like a
/// normal iPhone scroll:
/// - Swipe sideways: the timeline moves, and keeps gliding after you let go.
/// - Press and hold a clip: a haptic tap, the clip pops loose, and then it follows your finger.
/// - Drag from a clip's end: trims it (no hold needed).
/// - Tap: pick a clip (or let go of it on empty space).
/// - Pinch: zoom.
struct LaneTouches: UIViewRepresentable {
    /// A hold landed here. Return true if it lifted a clip.
    var lift: @MainActor (CGPoint) -> Bool
    /// The lifted clip's finger has moved this far sideways since the hold.
    var liftMoved: @MainActor (CGFloat) -> Void
    /// A sideways drag started here. Return true if it grabbed a clip's end to trim it
    /// (then the drag trims instead of scrolling, and `liftMoved` / `dropped` follow).
    var trimBegan: @MainActor (CGPoint) -> Bool
    var dropped: @MainActor () -> Void
    var swipeBegan: @MainActor () -> Void
    /// Total sideways travel since the swipe began, glide included.
    var swipeMoved: @MainActor (CGFloat) -> Void
    var swipeEnded: @MainActor () -> Void
    var tapped: @MainActor (CGPoint) -> Void
    var pinchBegan: @MainActor () -> Void
    var pinched: @MainActor (CGFloat) -> Void
    var pinchEnded: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.parent = self

        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 10

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: press)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))

        for recognizer in [press, pan, tap, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        coordinator.panRecognizer = pan
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stopGlide()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: LaneTouches?
        weak var panRecognizer: UIPanGestureRecognizer?

        private var lifted = false
        private var pressStart: CGPoint = .zero
        private var swiping = false
        /// This drag grabbed a clip's end, so it trims rather than scrolls.
        private var trimming = false
        /// Where the latest finger came down. A pan only starts after the finger has moved a
        /// little, so this is the honest "where did the drag start" for grabbing a clip's end.
        private var touchDown: CGPoint?
        private var glide: CADisplayLink?
        private var glideOffset: CGFloat = 0
        private var glideVelocity: CGFloat = 0
        private var lastFrame: CFTimeInterval = 0
        /// A touch that only stopped a glide shouldn't also count as a tap.
        private var caughtGlide = false
        private let pop = UIImpactFeedbackGenerator(style: .medium)
        private let drop = UIImpactFeedbackGenerator(style: .light)

        // MARK: Hold to lift

        @objc func press(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                caughtGlide = false
                pressStart = point
                guard !trimming else { return }   // already trimming this clip's end
                lifted = parent?.lift(point) ?? false
                if lifted {
                    pop.impactOccurred()
                    drop.prepare()
                }
            case .changed:
                if lifted { parent?.liftMoved(point.x - pressStart.x) }
            case .ended, .cancelled, .failed:
                if lifted {
                    lifted = false
                    drop.impactOccurred()
                    parent?.dropped()
                }
            default:
                break
            }
        }

        // MARK: Swipe and glide

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let shift = recognizer.translation(in: recognizer.view)
            let travel = shift.x
            if trimming {
                switch recognizer.state {
                case .changed:
                    parent?.liftMoved(travel)
                case .ended, .cancelled, .failed:
                    trimming = false
                    drop.impactOccurred()
                    parent?.dropped()
                default:
                    break
                }
                return
            }
            switch recognizer.state {
            case .began:
                stopGlide()
                caughtGlide = false
                // Where the finger first landed (the pan only begins after it has moved a little).
                let location = recognizer.location(in: recognizer.view)
                let start = touchDown ?? CGPoint(x: location.x - shift.x, y: location.y - shift.y)
                if parent?.trimBegan(start) == true {
                    trimming = true
                    drop.impactOccurred(intensity: 0.6)
                    drop.prepare()
                    parent?.liftMoved(travel)
                    return
                }
                swiping = true
                parent?.swipeBegan()
                parent?.swipeMoved(travel)
            case .changed:
                parent?.swipeMoved(travel)
            case .ended:
                startGlide(from: travel, velocity: recognizer.velocity(in: recognizer.view).x)
            case .cancelled, .failed:
                finishSwipe()
            default:
                break
            }
        }

        private func startGlide(from travel: CGFloat, velocity: CGFloat) {
            guard abs(velocity) > 80 else {
                finishSwipe()
                return
            }
            glideOffset = travel
            glideVelocity = velocity
            lastFrame = 0
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            glide = link
        }

        @objc private func step(_ link: CADisplayLink) {
            let elapsed = lastFrame == 0 ? 1.0 / 60 : link.timestamp - lastFrame
            lastFrame = link.timestamp
            glideOffset += glideVelocity * CGFloat(elapsed)
            // Slows like an iPhone scroll view (0.998 per millisecond).
            glideVelocity *= CGFloat(pow(0.998, elapsed * 1000))
            parent?.swipeMoved(glideOffset)
            if abs(glideVelocity) < 20 { finishSwipe() }
        }

        func stopGlide() {
            guard glide != nil else { return }
            finishSwipe()
        }

        private func finishSwipe() {
            glide?.invalidate()
            glide = nil
            lastFrame = 0
            if swiping {
                swiping = false
                parent?.swipeEnded()
            }
        }

        // MARK: Tap and pinch

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            if caughtGlide {
                caughtGlide = false
                return
            }
            parent?.tapped(recognizer.location(in: recognizer.view))
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                caughtGlide = false
                // Two fingers: stop any swipe the first finger started.
                if let pan = panRecognizer {
                    pan.isEnabled = false
                    pan.isEnabled = true
                }
                finishSwipe()
                parent?.pinchBegan()
                parent?.pinched(recognizer.scale)
            case .changed:
                parent?.pinched(recognizer.scale)
            case .ended, .cancelled, .failed:
                parent?.pinchEnded()
            default:
                break
            }
        }

        // MARK: Who gets the touch

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if recognizer is UILongPressGestureRecognizer { pop.prepare() }   // so the tap lands right on time
            if recognizer === panRecognizer { touchDown = touch.location(in: recognizer.view) }
            // A new touch catches a gliding timeline, like a scroll view.
            if glide != nil {
                caughtGlide = true
                stopGlide()
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === panRecognizer, let pan = panRecognizer else { return true }
            // No scrolling while a clip is lifted, and only sideways swipes move the timeline
            // (up and down still scrolls the layers).
            if lifted { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) >= abs(velocity.y)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
