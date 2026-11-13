# Ask keyboard regression checks

Run `Tests/run-ask-keyboard-tests.sh` on a Mac with Xcode and an installed iOS simulator runtime. `FEAST_SIM_RUNTIME` can select an already-installed runtime; `FEAST_TEST_CONFIGURATION` defaults to Debug.

The runner copies the current app sources, uses a unique app identity and a new disposable simulator, and removes live Ask/CloudKit configuration. It uses only synthetic chats, an in-memory collection and a local provider. It leaves the real app, user data and release project unchanged. Logs, screenshots and the XCTest result bundle remain in the printed temporary directory; only the runner's own simulator is deleted.

## Behavior under test

- Transcript drags retain native interactive keyboard dismissal, including empty chats and long transcripts at the bottom, middle and top. No custom transcript focus-clearing callback is installed.
- The original multiline `TextField` and accessibility `TextEditor` are unchanged. A discrete downward gesture clears their existing focus binding after 24 points of predominantly downward movement; iOS animates dismissal. This is not finger-following interactive dismissal and has no minimum flick velocity or whole-gesture deadline.
- The same recognizer on the existing background shapes covers blank inner padding, outer padding and space between controls. It is not attached over the buttons. No dismissal button, custom editor, manual keyboard offset or layout change is introduced.
- A gesture inside overflowing text that starts below the top remains native scrolling, including when that stroke reaches the top. A new downward stroke at the top can dismiss; blank composer space can dismiss at any draft scroll position.
- Editor holds, nonempty selections, marked-text composition and VoiceOver do not trigger the custom dismissal. Blank-space drags can begin after a stationary pause.
- Horizontal/upward drags, small movements, long-press caret movement and selections remain native editor interactions. Tests verify a nonempty selection before checking the selection guard.
- Both the ordinary multiline input and the large-Dynamic-Type editor are covered.
- Empty inputs fit at all seven ordinary Dynamic Type sizes. One/five-line drafts fit, six-line drafts overflow, and deleting back to five lines or empty clears overflow. Test-only UIKit geometry verifies the actual native content fits without disabling scrolling or its indicator preference.
- Drafts survive dismissal, History round trips and chat switching. A successful New chat clears focus without erasing the previous chat's draft.
- Blank-space dismissal preserves the draft without sending it. Send/Stop and synthetic screenshot controls have separate touch regressions. The active-answer/new-draft case remains subject to the baseline limitation below.
- Transcript context menus continue to work.

The suite asserts keyboard state, draft values and native overflow geometry. The synthetic app also logs the editor's first-responder state, scroll offset and selection range for investigation.

## Known baseline limitation

On the iOS 26.1 simulator, `testDismissalDoesNotCancelAnswerOrSendDraft` has timed out waiting for the app to become idle when refocusing the editor during an answer. This also reproduces with unmodified build30 (`8a6ba794`) and its original fixture. Do not count that scenario as passing coverage; verify it separately on a physical phone before release.

## Complementary checks

Run `Tests/run-persistence-tests.sh` and `Tests/run-ask-release-send-tests.sh` for client/session persistence and Release first-send regressions.

Before a release, smoke-test on a physical phone: ordinary and long input swipes, long transcript dismissal, caret/selection handles, answer links, VoiceOver navigation, an IME composing marked text, and an attached screenshot. Simulator large text is not equivalent to testing VoiceOver. The editor retains system editing gestures; the discrete dismissal recognizer must still be checked alongside those interactions on a physical device. Simulator results do not verify physical swipe feel.
