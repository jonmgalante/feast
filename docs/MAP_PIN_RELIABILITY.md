# Pre-release map reliability and Ask opening copy

Local change on top of owner-access candidate `b47a24d`; no deployment, installation,
CloudKit schema changes, record edits or provider calls are needed for the offline checks.

## Confirmed findings versus unknowns

The previous saved-pin loop made back-to-back identifier lookups, treated all errors
alike, cleared pins at the start of each pass and left underlying MapKit requests running
when SwiftUI cancelled an obsolete city task. Its first partial result also prevented
later recovered pins from expanding the automatic camera fit. Those are code findings.
No captured Sugar Bear failure establishes which of them caused its reported missing
pins. An invalid/retired Apple place ID and an Apple service failure remain possible.

## Bounded correction

- One serial lane for saved-pin requests, with 300 ms spacing after each response.
  This is conservative app pacing, not an asserted Apple quota or guarantee against throttling.
- Maximum three attempts per location for transient failures. Throttling uses 5/10 second
  retry waits and retains a 20 second cooldown after exhaustion. Other transient failures
  back off 1/2 seconds, retaining a 4 second cooldown after exhaustion. Offline stops
  promptly. Persistent service failures pause the remaining batch rather than hammering it.
- Known not-found/missing/invalid coordinates remain retryable and do not remove records.
  Unrecognized errors remain temporary service failures, never evidence that a place vanished.
- Retry preserves successful pins and resolves missing ones. Counts remain tied to saved
  records; a lookup failure cannot silently remove or rewrite a place or its Apple ID.
- Underlying identifier requests cancel with obsolete work. Generation checks prevent
  late results and old queued tasks from publishing or populating the current cache.
- Automatic camera fitting includes newly recovered pins only when there is no saved
  manual viewport and the user is not currently moving the camera.
- In-memory success data is limited to the current map scope; it is cleared on leaving
  the map or backgrounding. Navigation retains only the saved record ID. No coordinates
  or fetched MapKit metadata are added to files, preferences, Core Data or CloudKit.

Apple's current [Developer Program License Agreement, Attachment 6 §2.5](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
restricts Map Data caching to temporary, limited use and requires deletion afterward.
This implementation does not assume permission for permanent coordinate caching.
The SDK's public `MKMapItemRequest.cancel()` and `MKError` classifications are used;
no private GeoServices fields or undocumented retry-after values are required.

## Opening copy

- Heading: **What sounds good?**
- Supporting text: **Find somewhere new, explore your saved places, or keep them organized.**
- Placeholder: **Ask Feast…**

Both existing composer implementations use the same requested placeholder. The separate
invitation card, consent, history, input draft and action behavior are preserved.

## Acceptance and remaining device check

Offline tests cover serial pacing, concurrent duplicate requests, scope cleanup,
throttle backoff/exhaustion, offline and server failures, missing/invalid coordinates,
unknown errors, cancelled city switches, retained partial successes, and the actual
MapKit callback adapter using fake callbacks (including synchronous cancellation and
late/duplicate completion). Existing persistence, sharing and Ask regression tests remain.

No live MapKit lookup, physical-device pin inspection, gesture test or native layout test
is claimed. After an approved build installation: open a populated city, verify saved
count versus pins; retry a partial result; switch cities while loading; pan before loading
finishes; background/return; open a pin and return. Confirm saved records and shared-city
contents are unchanged. Apple outages or genuinely unavailable IDs may still leave pins
unresolved; the app should show that accurately and allow retry without guessing locations.

Final offline result: 159 Swift test groups passed, including seven focused map groups.
Debug simulator and unsigned iPhone Release builds passed for 1.1 (9). Independent
review passed after correcting unknown-error classification, active-pan camera guarding,
cancellation callback ordering and retained navigation metadata. The callback adapter
also preserves explicit MainActor/Sendable isolation. No backend files changed in this pass.
