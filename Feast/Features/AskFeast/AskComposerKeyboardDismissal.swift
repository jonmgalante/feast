import SwiftUI
import UIKit

/// Dismiss from a short editor, or the top of a longer draft, without taking
/// downward scrolling away from a draft that still has earlier text to reveal.
struct AskComposerKeyboardDismissal: UIGestureRecognizerRepresentable {
    var dismiss: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let gesture = UISwipeGestureRecognizer()
        gesture.direction = .down
        gesture.numberOfTouchesRequired = 1
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = context.coordinator
        return gesture
    }
    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        guard recognizer.state == .recognized, context.coordinator.canComplete else { return }
        dismiss()
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var editor: UITextView?
        private var eligibleAtStart = false
        private var startedAt: TimeInterval = 0

        // A hold belongs to native caret/selection handling, including gestures
        // installed on the text view's internal interaction subviews.
        var canComplete: Bool {
            eligibleAtStart && CACurrentMediaTime() - startedAt < 0.5 && editor.map(Self.canDismiss) == true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            editor = nil
            while let current = view {
                if let text = current as? UITextView { editor = text; break }
                view = current.superview
            }
            startedAt = CACurrentMediaTime()
            eligibleAtStart = editor.map(Self.canDismiss) ?? false
            return eligibleAtStart
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            canComplete
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer === editor?.panGestureRecognizer
        }
        private static func canDismiss(_ editor: UITextView) -> Bool {
            guard editor.isFirstResponder, !UIAccessibility.isVoiceOverRunning, editor.markedTextRange == nil,
                  editor.selectedRange.length == 0,
                  editor.contentOffset.y <= -editor.adjustedContentInset.top + 1 else { return false }
            return !(editor.gestureRecognizers ?? []).contains {
                $0 is UILongPressGestureRecognizer && ($0.state == .began || $0.state == .changed)
            }
        }
    }
}
