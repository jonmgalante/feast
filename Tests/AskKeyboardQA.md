# Ask keyboard regression checks

Run `Tests/run-ask-keyboard-tests.sh` on a Mac with Xcode and an installed iOS simulator runtime. `FEAST_SIM_RUNTIME` can select an already-installed runtime; `FEAST_TEST_CONFIGURATION` defaults to Debug.

The runner copies the current app sources, uses a unique app identity and a new disposable simulator, and removes live Ask/CloudKit configuration. It uses only synthetic chats, an in-memory collection and a local provider. It leaves the real app, user data and release project unchanged. Logs, screenshots and the XCTest result bundle remain in the printed temporary directory; only the runner's own simulator is deleted.

## Behavior under test

- A transcript drag clears keyboard focus immediately, including empty chats and long transcripts at the bottom, middle and top. Taps and programmatic scrolling do not clear focus through that callback.
- A quick downward swipe in the input dismisses the keyboard. An overflowing draft keeps normal downward scrolling until its own text is already at the top. There is no new button.
- The input recognizer leaves horizontal/upward drags, long-press caret movement and existing selections to the editor. It declines marked-text composition and VoiceOver touches.
- Both the ordinary multiline input and the large-Dynamic-Type editor are covered.
- Drafts survive dismissal, History round trips and chat switching. A successful New chat clears focus without erasing the previous chat's draft.
- Dismissal neither cancels an answer already in progress nor sends a newly typed draft.
- Transcript context menus continue to work.

The suite asserts keyboard state and draft values. The synthetic app also logs the editor's first-responder state, scroll offset and selection range for investigation.

## Complementary checks

Run `Tests/run-persistence-tests.sh` and `Tests/run-ask-release-send-tests.sh` for client/session persistence and Release first-send regressions.

Before a release, smoke-test on a physical phone: ordinary and long input swipes, long transcript dismissal, caret/selection handles, answer links, VoiceOver navigation, an IME composing marked text, and an attached screenshot. Simulator large text is not equivalent to testing VoiceOver. The swipe recognizer is deliberately disabled during VoiceOver and marked-text composition rather than taking over those interactions.
