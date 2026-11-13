import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// A discrete dismissal, not an interactive keyboard driver. The existing focus
/// binding and iOS still own the keyboard/composer animation and all text editing.
struct AskComposerKeyboardDismissal: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var protectsEditor = true
    var dismiss: () -> Void

    func makeUIGestureRecognizer(context: Context) -> DownwardSwipe {
        let gesture = DownwardSwipe()
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.isEnabled = isEnabled
        gesture.protectsEditor = protectsEditor
        return gesture
    }
    func updateUIGestureRecognizer(_ gesture: DownwardSwipe, context: Context) {
        gesture.isEnabled = isEnabled
        gesture.protectsEditor = protectsEditor
    }
    func handleUIGestureRecognizerAction(_ gesture: DownwardSwipe, context: Context) {
        if gesture.state == .recognized { dismiss() }
    }

    final class DownwardSwipe: UIGestureRecognizer {
        var protectsEditor = true
        private weak var touch: UITouch?
        private weak var editor: UITextView?
        private var origin = CGPoint.zero
        private var startedAt: TimeInterval = 0
        private var hasMoved = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touch == nil, touches.count == 1, let first = touches.first,
                  !UIAccessibility.isVoiceOverRunning else { state = .failed; return }
            touch = first
            origin = first.location(in: nil)
            startedAt = first.timestamp
            if protectsEditor {
                var view = first.view
                while let current = view {
                    if let text = current as? UITextView { editor = text; break }
                    view = current.superview
                }
                guard let editor, canDismissEditor else { state = .failed; return }
                // Decide at touch-down: a downward scroll that reveals earlier
                // draft text must not turn into a dismissal when it reaches top.
                let overflows = editor.contentSize.height + editor.adjustedContentInset.top + editor.adjustedContentInset.bottom > editor.bounds.height + 1
                if overflows && editor.contentOffset.y > -editor.adjustedContentInset.top + 1 { state = .failed }
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible, let touch else { return }
            let point = touch.location(in: nil)
            let dx = point.x - origin.x, dy = point.y - origin.y
            if !hasMoved && max(abs(dx), abs(dy)) > 6 {
                // A stationary hold belongs to caret/selection, but once a drag
                // starts there is no flick-speed requirement or total deadline.
                guard !protectsEditor || touch.timestamp - startedAt < 0.45 else { state = .failed; return }
                hasMoved = true
            }
            if dy < -10 || abs(dx) > max(16, dy * 1.3) { state = .failed; return }
            guard !protectsEditor || canDismissEditor else { state = .failed; return }
            if dy >= 24 && dy > abs(dx) * 1.2 { state = .recognized }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible { state = .failed }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible { state = .failed }
        }
        override func reset() {
            super.reset()
            touch = nil; editor = nil; hasMoved = false
        }
        // Observe alongside the editor's own scrolling; never replace or block it.
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            preventingGestureRecognizer !== editor?.panGestureRecognizer
        }
        private var canDismissEditor: Bool {
            guard let editor, editor.isFirstResponder, editor.markedTextRange == nil,
                  editor.selectedRange.length == 0 else { return false }
            return !(editor.gestureRecognizers ?? []).contains {
                $0 is UILongPressGestureRecognizer && ($0.state == .began || $0.state == .changed)
            }
        }
    }
}
