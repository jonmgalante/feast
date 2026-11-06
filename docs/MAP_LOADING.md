# Saved map loading

This change is confined to map presentation, Apple lookup scheduling, and temporary
reuse in saved-place detail. It does not change the Core Data model, CloudKit
container, stores, sharing, saved coordinates, Ask Feast, access, or accounting.

## Behavior and boundaries

- First ordinary Map-tab entry requests the same one-shot location as Nearby,
  including the normal When In Use permission prompt. The attempt is consumed once
  per browse session, before requesting permission. Inherited city and content
  filters remain unchanged. Remembered map/return viewports take precedence;
  subsequent explicit city selection keeps its city camera behavior. A denied or
  failed first request quietly falls back to city/current context. Explicit Nearby
  retains its existing error explanation. Pan start and newer Nearby requests
  invalidate late camera results. Adding, expiring, or resolving pins never frames
  the camera.
- Active saved filters apply before requests. An explicitly selected city loads
  its eligible records. All Cities resolves an exact saved Apple place ID per
  eligible city as a temporary anchor, including at wide zoom. A nearby anchor
  starts its place work without waiting for all other anchors. No place-level
  whole-library sweep runs on open. Camera requests use the same filtered IDs
  and invalidate pending results when the eligible identity changes.
- Known locations are drawn only within a padded viewport. MapKit clusters them;
  coincident pins or clusters at close zoom open an exact-record selection list.
- Unknown coordinates cannot honestly be spatially filtered. A saved-place
  anchor is a demand hint, not a geographic boundary; outlying records can still
  need explicit city selection. Wide All Cities views load city anchors and defer
  the remaining unknown places until zoomed in or selected.
- All Cities needs one successful saved-place request per eligible city. It tries
  up to three stable candidates only when earlier candidates are unavailable. If
  all three fail, explicit city selection still attempts the remaining records.
  This is not a complete persistent spatial index; many cities remain a bounded-
  concurrency first-stage cost. Cached points near the viewport take precedence.
- The header is a compact city picker with Search and Filters controls. Routine
  loading counts and explanatory copy are removed. A small spinner appears only
  after 400 ms of loading; actual requests begin immediately. The floating Retry
  control is removed, with no replacement failure text. Detail navigation restores
  its own bar and pauses map demand while pushed. Native grouping and pin delivery
  remain unchanged from build 1.1 (12); no annotation batching is introduced.

## Scheduling and temporary reuse

One app-process map/detail service permits at most three active requests, joins
identical requests, and cancels the underlying operation when its last subscriber
leaves. Successful calls have no artificial inter-request delay. Throttling and
service failures reduce concurrency to one and apply shared exponential cooldown;
only the failed request retries, at most three attempts. The lookup service does
not immediately retry offline failures. Six healthy completions permit a gradual increase back to
three. Each native item/search request has a 20-second cancellation deadline.
Failures stop further batch dispatch; completed successes remain usable.

While the Map root is active, a passive network-path observer detects an
offline-to-online transition. After that path remains available for one second,
one recovery pass can resume current demand that failed for connectivity. This
settling period applies only to connection recovery, never normal successful pin
delivery. Duplicate online callbacks do nothing, rapid transitions coalesce, and a
later distinct outage can recover again. Existing provider concurrency and shared
cooldown still apply. There is no periodic retry loop. Recovery neither clears
successful entries nor changes the camera, filters, or grouping. Recently
unavailable IDs are excluded from this recovery pass using bounded, temporary
ID-only metadata; this does not mark or change saved records. Observation and
pending transition work stop on tab/detail exit or backgrounding. Network-path
availability is not a guarantee that Apple Maps is reachable, so recovery can
still fail quietly.

Apple-derived matches and their city anchors live only in RAM, for five minutes from
retrieval, capped at 2,048 entries; reads do not extend expiry. Visible entries are
preferred over distant entries on eviction. Backgrounding clears entries and
subscribers. Views read the shared entries rather than retaining a second result
cache. Timed eviction refreshes active demand without canceling unrelated work.
A bounded, same-TTL record of successful requested IDs prevents capacity churn;
it contains no coordinates. This memo also prevents an evicted city anchor from
being fetched on every pan. Connectivity recovery does not reset this memo or
force capacity-deferred results to reload. Collections exceeding capacity do not
have guaranteed complete simultaneous pin coverage. No disk cache or coordinate
migration exists.

This implements a conservative temporary, limited performance cache under
[Apple Developer Program License Agreement, Schedule 6 §2.5](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/).
Apple does not prescribe or preapprove this five-minute/2,048-entry choice. Apple
Maps remains the provider and displayed renderer. Camera viewport memory is
navigation context, not a saved-place coordinate database.

## Measurement and acceptance

Local OSLog categories `SavedMapLookup` and `SavedMapLoad` record only elapsed
milliseconds, request/error outcome categories, active counts, planned/completed
counts and visible counts. They do not record names, IDs, coordinates, notes,
queries, raw errors, or send telemetry to a backend. Provider timings are separate
from whole map-load timing. These are measurements to collect on a candidate
phone build, not proof of a speed gain from offline tests.

Acceptance checks:

- Existing baseline full Swift suite; full updated suite repeated after fixes.
- 284/1,500-place fixtures: bounded requests/cache, filter/city selection before
  lookup, repeat identity independent of note timestamps/order, successful reuse.
- Duplicate subscribers, cancel one/all/queued, native deadline/late callback,
  background, physical expiry (including provider completion winning timer race),
  canonical identity, capacity pressure, cooldown, offline/service failures.
- Wrapped viewport/date-line handling, stale camera scope/revision/background,
  silent denied location, coincident clusters with reachable individual records.
- Debug and Release builds; independent Astra extra-high review.
- Native renderer harness uses the actual `SavedPinsMap` source in an isolated,
  separately identified simulator app with no saved-data store or CloudKit.
  This supplements—not replaces—full candidate navigation/physical-phone QA.

Before release: install a reviewed candidate only through the approved release
flow; verify initial/returned city camera, pan during delayed location, filters,
map/detail return, partial failures, background/foreground, dynamic type and actual
Apple latency/error distribution on the test phone. Do not claim physical-device
performance or all 284 real saved records were checked from synthetic fixtures.

Rollback is the preceding source/build. No data restoration or migration is
required because this change writes no saved collection data.

## Initial map candidate validation recorded 2026-11-05

- Baseline `fe03eeed7f0ad12d229026088fc7f29ac1cc9da0`: 159 offline Swift test
  groups passed. The corrected candidate passed 164 groups, then passed all 164
  again on the final repeat; both runs exited zero.
- Final Debug and Release simulator builds succeeded with signing disabled.
  Independent Astra extra-high source review found no remaining source blockers.
  The only later source edits were an accurate cluster accessibility instruction
  (explore, since activation can either zoom or open a list) and formatting.
- An isolated iOS 26.1 simulator harness compiled the actual `SavedPinsMap`
  renderer. It displayed 284 and 1,500 synthetic records in native clusters;
  adding record 1,501 retained the camera. Selecting a coincident cluster returned
  all 501 member IDs. Explicit movement to London removed the New York fixture
  pins, and returning restored the expected viewport and pins.
- These records repeat three fixture coordinates. They verify rendering and
  selection at scale, not real-place lookup latency, geographic coverage of the
  user's collection, or the full app's navigation and cluster-list presentation.
  Automated drag input did not produce a verifiable pan; native gesture behavior
  remains a hands-on acceptance check. Full-app Dynamic Type also remains open.
- At this validation checkpoint, the test phone remained on build 1.1 (9). No candidate phone installation, upload,
  deployment, credential creation, or collection-data change occurred.

Local evidence is in the sibling `map-redesign-evidence` directory, outside the
repository: full baseline/candidate/repeat logs, final Debug/Release logs, the
temporary renderer harness, and three simulator screenshots. The renderer harness
has a separate bundle identifier and no persistence, CloudKit, or account access.


## Build 10 feedback follow-up

The user screenshots show populated New York pins and an empty London UK view
with All Cities selected. The London viewport is within the existing regional
loading threshold. Build 10 used the first result of an unscoped free-text city
search as the gate for further place requests. An ambiguous or wrong-city result
can silently exclude London UK and can also position a selected-city camera away
from its loaded records. The historic provider response on the phone is unknown;
a London Ontario fixture reproduces this class of failure, not that exact event.

The follow-up removes name-based city searches, uses exact saved-place anchors,
and simplifies the map chrome. No collection model, persistence, CloudKit,
sharing, Ask, release identity, or build-number files change. The successful
build 10 release is the baseline. These fixes are included in TestFlight 1.1 (11),
available to the existing internal Feast Testers group on 5 November 2026.

Follow-up validation:

- Initial implementation: 167 Swift test groups passed. After independent review
  fixes for filtered camera requests and evicted-anchor churn: all 168 groups
  passed, exit zero. Final Debug and Release simulator builds passed with signing
  disabled.
- Independent Astra extra-high re-review found both findings corrected and no
  remaining source blockers.
- A separate full-app simulator wrapper runs the exact production `MapRootView`,
  `MapPlaceLookup`, and `SavedMapPlan` sources (SHA-256 identity recorded outside
  the repo). It substitutes only a 284-place provider fixture, in-memory store,
  startup wrapper and QA viewport controls. CloudKit and production service
  configuration are disabled in that temporary app; its bundle ID is distinct.
- Cold All Cities: one NYC, one London and one Paris anchor, three calls total.
  Moving the actual MKMapView to NYC loaded all 152 NYC fixtures (154 cumulative
  calls). Moving to the reported London region while All Cities remained selected
  loaded all 100 London fixtures (253 cumulative calls), visually clustered as 100.
  These viewport changes used QA buttons through the real map delegate, not
  native drag input. The compact header and absent top navigation bar were
  visually inspected.
- After the Mac was unlocked, native pin selection opened a saved-place profile
  with Back and Save visible. Both actions returned to the same London camera
  with pins intact and the map navigation bar hidden. Save acted only on the
  in-memory synthetic record.
- Injected offline failure exposed Retry at the lower left, without a top bar.
  Repeated observations produced no automatic request loop. Restoring the fixture
  provider and tapping Retry loaded all 100 London records at the same camera
  center (51.53, -0.10). Retry remained readable and separate from Nearby and
  attribution at the largest tested accessibility text size.
- The larger accessibility sizes exposed wrapping Search/Filters labels and an
  empty-state card overlapping the header. The follow-up stacks those controls
  and places the header plus empty-state content in one bounded scroll area.
  Final native rendering showed readable labels and separated content. Clear
  Search was activated successfully through its native accessibility control,
  restoring city loading and the delayed map-level spinner. Normal-size layout
  is unchanged. Independent Astra extra-high review found no layout blockers.
- During a three-second delayed-provider fixture, changing the query after
  150 ms cancelled four pending requests; cache and annotation counts stayed zero
  and the overview camera stayed unchanged. Clearing search resumed London demand;
  returning the fixture provider to normal produced 100 London pins.
- Actual touch gestures remain inconclusive: repeated native CUA drag attempts
  did not move the map, and native scroll input did not visibly scroll the long
  empty-state area. Tap, city selection, cluster zoom, programmatic viewport
  changes through the real delegate, and accessibility activation worked. Do not
  treat these as verification of finger-drag, touch scrolling, or pan-versus-late-
  location behavior; those still need hands-on acceptance testing.
- This is simulator evidence with synthetic locations, not verification of the
  phone's real London IDs, live Apple latency, or the complete real collection.
  No phone installation, upload, push, deployment or credential action occurred
  during this local feedback validation.

Build 11 release verification:

- Release source commit: `1f88fe0ae0ef3201a3739d34e6f70f7148cb91bd`.
- All 168 client regression groups passed again; the signed iPhone archive passed.
- The final distribution package preserved build 10's signed entitlements,
  Production CloudKit configuration, certificate, provisioning profile and compiled
  Core Data model files. Map QA fixtures and controls were absent.
- App Store Connect confirmed build 1.1 (11) as Testing in the existing internal
  group. No agent phone installation or launch, owner activation, backend deployment,
  or App Review submission was performed.

Private local evidence is in the sibling `map-feedback-evidence` directory:
provider/request runtime log, tests/build logs, source-identity comparison,
validation manifest, synthetic wrapper and screenshots of overview/London,
detail/back return, offline/online Retry, and accessibility layouts. User-provided
screenshots remain outside the public repository.

## Nearby and quiet recovery validation recorded 2026-11-06

- Local candidate only, relative to the build 1.1 (12) working-tree snapshot.
  All 177 Swift regression groups passed, exit zero. The unsigned production
  iPhone Release build and isolated simulator QA build succeeded. Independent
  Astra extra-high review found no remaining blocking source finding.
- `SavedMapPlan.swift`, including the native renderer and clustering, is byte
  identical to build 12. Existing Ask/backend work, persistence, models, CloudKit,
  app identity and project configuration are unchanged by this task.
- Exact production Map root, browse state, lookup, location and renderer sources
  ran in a separate simulator wrapper with 284 in-memory synthetic places. First
  Cities-to-Map entry, without tapping Nearby, displayed the normal location
  prompt and centered on simulated London after authorization. Inherited London
  context did not suppress the prompt. Denying it, and launching again with
  permission already denied, quietly retained London and loaded its places.
- Injected connection restoration loaded 79 missing London places, taking the
  displayed total from 20 to 99. The 80 additional provider calls included one
  unavailable place; already loaded places were retained without refetching.
  Camera center stayed fixed. Repeated offline/online events and duplicate online
  callbacks caused no further calls after the available places had loaded.
- Explicit Paris selection, native cluster selection, detail/back and tab return
  retained the expected camera. Changing simulated location to New York while on
  Cities did not recenter the returned Paris map. Cache expiry during this longer
  check refreshed Paris demand normally; this is evidence of camera preservation,
  not a claim that tab return never issues a request.
- No Retry control or replacement failure text appeared. Connection events were
  injected into the production recovery state machine; simulator UI checks used
  a zero settling delay, while unit tests cover settling and cancellation. These
  checks do not establish live Apple service latency or physical-device behavior.
  Native drag input remained inconclusive. Pan-versus-delayed-location and
  accessibility-only camera movement still require hands-on device acceptance.
- No phone installation, upload, deployment or real saved-data mutation occurred.
  Logs, source hashes, review, fixture wrapper and screenshots are in the sibling
  `map-nearby-quiet-recovery-evidence` directory.
