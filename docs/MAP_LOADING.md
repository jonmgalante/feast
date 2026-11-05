# Saved map loading (local candidate)

This change is confined to map presentation, Apple lookup scheduling, and temporary
reuse in saved-place detail. It does not change the Core Data model, CloudKit
container, stores, sharing, saved coordinates, Ask Feast, access, or accounting.

## Behavior and boundaries

- Fresh All Cities map requests a one-shot location only when permission already
  exists. Nearby remains the explicit permission entry point. Saved city/return
  viewports take precedence. Pan start and newer Nearby requests invalidate late
  camera results. Adding, expiring, or resolving pins never frames the camera.
- Active saved filters apply before requests. An explicitly selected city loads
  its eligible records. All Cities uses temporary Apple city-center hints to
  prioritize nearby eligible cities. A nearby hint starts its place work without
  waiting for all other hints. No place-level whole-library sweep runs on open.
- Known locations are drawn only within a padded viewport. MapKit clusters them;
  coincident pins or clusters at close zoom open an exact-record selection list.
- Unknown coordinates cannot honestly be spatially filtered. City labels/hints
  are approximate and can be ambiguous or include outlying records. Unknown
  records stay saved and are described as not loaded, never as nonexistent.
  Wide All Cities views defer new unknown locations until zoomed in/selected.
- All Cities may need one city-hint request per eligible city. This is not a
  complete persistent spatial index. A large number of cities is a remaining
  first-stage limitation; explicit city selection avoids that work.

## Scheduling and temporary reuse

One app-process map/detail service permits at most three active requests, joins
identical requests, and cancels the underlying operation when its last subscriber
leaves. Successful calls have no artificial inter-request delay. Throttling and
service failures reduce concurrency to one and apply shared exponential cooldown;
only the failed request retries, at most three attempts. Offline failures do not
retry automatically. Six healthy completions permit a gradual increase back to
three. Each native item/search request has a 20-second cancellation deadline.
Failures stop further batch dispatch; completed successes remain usable.

Apple-derived matches and city hints live only in RAM, for five minutes from
retrieval, capped at 2,048 entries; reads do not extend expiry. Visible entries are
preferred over distant entries on eviction. Backgrounding clears entries and
subscribers. Views read the shared entries rather than retaining a second result
cache. Timed eviction refreshes active demand without canceling unrelated work.
A bounded, same-TTL record of successful requested IDs prevents capacity churn;
it contains no coordinates. Capacity-deferred results have an explicit reload
message and Retry control. Collections exceeding capacity do not have guaranteed
complete simultaneous pin coverage. No disk cache or coordinate migration exists.

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

## Local validation recorded 2026-11-05

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
