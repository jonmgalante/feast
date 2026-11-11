# Unsavable-history navigation repair

Scope: preserve an already-visible chat/draft when the canonical local history
cannot accept it. This is not a larger canonical limit, automatic deletion, retry,
request-admission change, journal-retention change or release approval.

## Protocol

- Canonical JSON remains 8 MiB, at most 50 chats and 100 turns per chat. A new chat
  is still refused at 50; selecting another existing chat must remain possible.
- A sibling `pending-history-v1` directory holds an exact preservation-only
  library when canonical encoding/validation cannot accept the current snapshot.
  Each archived turn is an independently checksummed JSON payload of at most
  8 MiB; an exact UTF-8 draft is independently bounded to 8 MiB. The complete
  materialized pending library is bounded to 16 MiB of referenced payload bytes,
  at most 5,000 turn references and 50 drafts. Manifest data is bounded to 1 MiB
  and checked (declared totals plus actual file sizes) before any payload decode.
  These are preservation resource limits, not additional canonical admission. There is no whole-chat 8 MiB limit; pending payload files are decoded one piece at a time.
  The Session still materializes its selected library in RAM; no lazy UI claim.
- A payload/draft outside the pending representation's bounds stays exact in RAM.
  Disk-full/path/write/sync/corruption/conflict failures do the same. Navigation
  may retain it for this app session, with a sticky “not saved; keep the app open”
  warning. It must never claim restart durability. Unknown canonical content is
  never overwritten. An unreadable library at startup remains blocked rather
  than adopting an empty replacement.
- Pending load is preservation only. It cannot make oversized draft text a valid
  request or authorize a model replay or collection write. Turn IDs, order,
  response/source/receipt content and draft bytes are retained exactly.
- A nonblocking local writer lock covers compare/read/write/sync. Each write
  compares the expected canonical fingerprint and pending revision. Another
  instance's divergent update fails closed, retaining current RAM and files.
- New pending revision: write immutable content-addressed payloads,
  verify checksums and exact decoded value, sync files/directories, then atomically
  activate its checksummed manifest. A failed/unknown activation is not reported
  durable until the visible candidate and sync are verified.
- Returning to canonical: first activate the exact candidate pending revision,
  binding both prior canonical and prospective canonical digest; write and sync
  canonical bytes; verify exact candidate equivalence; retire only that matching
  pending revision through a synced canonical-state marker. A restart recognizes
  old-versus-new canonical digest without applying an older sidecar over newer
  data. Unknown divergence is an error, never a preferred-copy guess.
- Replaced pending payloads can be removed only after a verified equivalent
  successor or an explicit durable chat deletion/clear. Unactivated orphan data
  from failed writes is not inferred authoritative or silently purged. An
  uncertain cleanup does not authorize checkpoint release or false erasure.
- All history files, lock, manifest and pending-payload directories preserve
  current chat backup exclusion and iOS completeUntilFirstUserAuthentication.
  This intentionally differs from the separately reviewed action journal, which
  remains included in backups. No external service or CloudKit store is used.

## Session semantics

A failed ordinary persistence attempt keeps the latest exact snapshot in the
in-memory chat library, so New/Open can return to it. A separately published
history warning survives resets and request errors. Deletion/clear require a
verified durable replacement; real disk failure refuses destructive navigation.
Quiescing recovery work must not remove its checkpoint before that replacement.
Explicit Clear needs an atomic durable identity/epoch barrier, so a crash before
checkpoint/journal cleanup cannot resurrect cleared content. The approved bounded
barrier is a fresh chat ID at the same position/title. Old-ID tasks, checkpoints
and journal receipts are never rebound to the replacement ID. No stop/cancel
that could scrub checkpoint payload occurs before the synchronous durable commit.
Retry payload compaction and completed-recovery deletion use exact durable
canonical or pending readback, never a navigation-success boolean. Snapshot no
longer prefixes the draft. Canonical send/turn/chat admission stays unchanged.

## Expected-correct tests first

The original structural repros were already repaired; they are not relabeled as
new red evidence. `AskLargeHistoryFixture` generates a real accepted native answer
through Session -> Loop -> paged queries over a disposable SQLite collection of
200 notes (3,500 characters each). Repeated accepted archived turns with unique
IDs fill canonical history just below 8 MiB; an actual next turn crosses it.
Tests independently cover this byte cap, making the actual storage parent a file,
and an oversized existing draft. Frozen baseline and later green artifacts stay
outside version control under `Tests/Evidence/navigation/`.

Pending follow-on matrix: matching-revision retirement, unknown commits at each
activation boundary, stale writer/sidecar, corrupt/missing payload, restart and
repeat, canonical at 50 chats, delete/clear while pending or disk-failed, sticky
warning, exact retry/recovery preservation and protection/backup metadata.

## Explicit limits and warning semantics

The 16 MiB limit is the total referenced serialized payload budget for pending
history, not a segment size, literal resident-memory ceiling or physical storage
impossibility. Swift objects require additional memory. It deliberately bounds
the current eager Session representation; this repair does not introduce a lazy
history API or promise unlimited durable retention. Above it, the exact newest
state stays accessible in RAM through New/Open, with a generic “not saved;
keep the app open” warning and affected-chat UUIDs for History-row status. Send/100-turn/50-chat rules remain unchanged.

When possible, a small checksummed local notice records that newer changes were
not saved, tied to the older durable revision. It contains only an opaque revision/status marker, not raw chat titles or lost
message/draft payloads. A legacy labels field is decoded for compatibility but
is never displayed; new notices leave it empty. A restart shows only earlier durable history and warns
about the missing newer state. An imported notice survives navigation/autosave
until explicitly dismissed; saving an older restored snapshot is not recovery
of lost RAM. The originating live store can clear its own notice only after
saving its current candidate. True filesystem failure may also prevent writing
the notice, so the live warning never promises restart recovery.

Explicit Delete/Clear carries removed chat IDs in the durable pending plan before
any known canonical baseline is redacted. Other overflow chats keep their newest
pending state across that old/new canonical digest transition. Unknown/divergent
canonical bytes are never erased. Cleanup failures are visible; this is not a
secure-erasure claim. Failed/unactivated orphan payloads are not automatically
purged by age or inferred irrelevance.

The legacy `save`/`saveLibrary` helpers remain canonical-only fixture APIs;
product Session writes use `preserveLibrary`. Pending decoding is preservation,
not request validation. Existing old binaries do not understand pending history;
launching an older writer is unsupported. A current reader detects divergent
canonical bytes rather than silently merging, overwriting or adopting an empty
archive. The action journal's storage/retention/backup policy is untouched.

## Reviewed crash refinements

A visible-but-unverified Clear/Delete is different from an unchanged pre-write
failure. The store keeps one in-memory operation identity, bound to one live
Session writer UUID and the exact visible token produced by that operation.
That same Session may save its entire newest RAM library against that exact
owned old/new canonical-plus-manifest token. This supersedes the unacknowledged
removal rather than discarding newer draft bytes or accepted late responses.
It works after pending activation, canonical rename, retirement, partial payload
cleanup and marker removal. No capability survives restart or follows a chat ID;
foreign tokens and a new Session writer still fail the old writer closed. A
restart adopts the verified visible authority, never an inferred old baseline.
Live warnings explicitly say the removal outcome is unverified until resolution.
Checkpoint/journal/retry cleanup does not run for an unverified outcome.

Obsolete payload cleanup is a non-authoritative list of exact digest/size refs in
the sealed root. It cannot serve as fallback history or contain an active ref.
The plan is capped at 10,100 unique refs / 32 MiB referenced bytes, also subject
to the existing 1 MiB root envelope. The active materialization budget remains
16 MiB. Each save, including catch reconciliation, inspects at most 32 obsolete
files and reads at most 8 MiB of obsolete payload bytes. A fresh descriptor-size
check must equal the declared size before a bounded read, followed by another
size check and exact checksum verification. Grown or replaced files are not read
past their declared budget or removed. After directory sync, a sealed progress revision carries the remainder;
failed sync retains the full prior obligation. Failed/divergent refs rotate
behind unvisited refs in the sealed queue, so they cannot starve eligible later
cleanup across saves/restarts. Cleanup failure/debt remains
visible across newer saves and restart. Only an exact clean canonical marker can
be removed after cleanup and sync. Nonowned, divergent, unactivated orphan and
action-journal data are never inferred obsolete. Bookkeeping admission failure
retains prior authority plus current RAM instead of dropping the obligation.

The whole authoritative-library decode/encode equality guard is retained. The
candidate's already-created exact encoding is reused; New/Open commit current
screen and selection together instead of saving the whole library twice.
Own-token-only finalization is not used: independent readback and whole-library
equality remain required before durability is acknowledged.

Warnings and status notices contain no raw chat titles or stored title
projections. Permission can change after a projection is saved. Live RAM-only
chats are associated by UUID with a generic “Not saved” History-row/VoiceOver
status; exact manual/generated titles remain in the protected chat itself.
Imported historical loss notices cannot be replaced by a new owned failure and
then silently cleared by a later successful save. Their acknowledgment stays
explicit. After an explicit removal's committed old-ID barrier, restart can
finish only the exact fingerprint-verified legacy migration-copy cleanup;
changed legacy bytes remain untouched with a warning.

A separate, independently reviewed optimization replaces only five redundant
`state().token` equality rechecks with fresh bounded file reads and identical
full-file SHA-256 comparisons. It returns no token and adopts no new state.
Initial authority reads, activation/canonical acknowledgments, maintenance
successor reads, the whole-library equality guard, metadata bounds, payload
verification and synchronization all remain. This is distinct from the rejected
own-token-only finalization proposal.


## Authority-file loss boundary

Malformed `current.json`, a present root with a missing/corrupt referenced payload,
foreign canonical bytes and non-ENOENT read/protection errors fail closed. This
is not blanket detection of every missing history file. If an external tool
selectively deletes an **acknowledged active** pending `current.json` while leaving
older canonical history in place, a fresh reader can load that older canonical
history without a warning. Partial filesystem deletion/rollback and old-binary
writers are unsupported. The current running writer's token comparison rejects
that change. No supported acknowledged write/cleanup path was found to remove an
active root: only a verified canonical marker with no remaining debt is removed.
App collection import/export does not handle these chat files, and chat storage
retains its existing backup-excluded policy.

This is distinct from an **unacknowledged** first activation lost after failed
synchronization/crash. That live outcome is explicitly RAM-only; neither newest
restart recovery nor a durable loss notice is promised when storage cannot sync.
The synthetic external-deletion probe is retained as boundary evidence, not a
fixed regression. A second activation witness could detect some selective loss,
but would add legitimate pre-activation/retirement ambiguity, upgrade and recovery
requirements; no witness or orphan-file inference was added in this repair.

## Compatibility and integration manifest

- Session writes use `preserveLibrary`; `commitChats` still means verified whole
  candidate durability, not merely successful navigation. Legacy `save`,
  `saveLibrary`, `load` and `clear` remain canonical fixture helpers, not a new
  product bypass of authority checks.
- The old presentation failure fixture created an ENOTDIR path before startup.
  It now separately proves unreadable startup refuses an invented empty library,
  then induces a real write failure after a valid load and checks exact RAM
  turns/draft/activity plus unchanged prior durable bytes.
- The old UX Clear fixture reused one Store across multiple Sessions, then cleared
  from a stale owner. It now proves that stale Clear cannot change canonical
  bytes, then tests the original debounce-invalidating Clear on the current owner.
  Image nonretention and corrupt/legacy compatibility-helper assertions remain.
- A removed chat's exact unarchived running recovery turn IDs are captured before
  cleanup destroys their chat binding. Only those retry contexts are fenced and
  cleaned after verified removal. Accounting roots and collection receipts/Undo
  remain; another active chat's task/checkpoint is unchanged. No external replay
  was needed or demonstrated by this cleanup regression.
- Imported lost-RAM explanations, current unsaved state and cleanup obligations
  are composed rather than masking one another. Only explicit dismissal removes
  an imported loss explanation. Passive New/Open cannot attribute a captured
  activity timestamp to the selected chat.
- A recovered answer accepted for a nonselected chat adds its actual origin ID
  to the failed whole-library save's History/VoiceOver status. The same save
  still captures the selected chat's exact unflushed draft. A verified later
  whole-library commit is required before either unsaved status can clear.
- A failure in the removed chat's separate recovery/journal cleanup remains a
  live-session warning through autosave and New/Open. Saving current history
  does not prove that cleanup finished. History shows the same composed warning
  as the composer, including while its Delete sheet remains open, and retains
  existing request errors because it does not show inline failed turns. This does not
  change cleanup policy or introduce a restart-persistent cleanup queue.
- The shared `AskLargeHistoryFixture.swift` remains byte-identical to the answer
  lane (SHA-256 `9b35c8cd86b00e15b8f6cfd4f787d8e9ee3fa9ed62f5e2072a19381ac75063e2`).
  Union the test runner with the answer/history tests during integration. The
  generic `Not saved` badge/AX suffix is additive to the answer lane's safe
  History-row projection; it does not read raw titles for a notice.
- Privacy prerequisite `4227197` (locally `d1f4dcf`) declares C617.1 for existing
  migration modification-date access and new descriptor metadata access. Neutral
  journal wording prerequisite `d866f5a` (locally `b4990e5`) is also included.
  Both are already accepted separately; integration must not replay them.
- Action-journal storage remains SHA-256
  `d9d6dec486f4055bccc20177168ffc1ab581d85ad4f4c0d51b32d3546df3f1f8`.
  No live stores, credentials, provider calls, installs, recovery activation,
  deployment or release were used for these checks.

## Current local verification and remaining acceptance gates

On 2026-11-11, the final reviewed application and test sources passed both full
offline suites: default reported 955 PASS lines and recovery-enabled reported
1,030, with compiler and runtime exit status 0 in each configuration. Both used
new disposable stores, with `FEAST_UPGRADE_COPY_DIR` unset, under a process-local
deny-network sandbox whose loopback probe returned EPERM. The retained red/green
tests cover the nonselected completed answer's unsaved status, exact background
answer and selected draft preservation, live recovery/journal cleanup-warning
retention, and unchanged failed-turn error visibility in History. They do not
claim that every preexisting cleanup error persists through navigation or restart.

The same Mac run measured ordinary one-turn draft/New/Open operations at about
13–15 ms. Near the 16-MiB pending budget, synchronous MainActor operations took
about 350–839 ms; the 9,500-reference cleanup-debt fixture took about 248–293 ms
per save. These are diagnostics, not physical-device responsiveness acceptance.
Large-history interaction on a physical iPhone remains an explicit unresolved
acceptance gate. No unverified performance shortcut was applied.

The integrated source still requires its unsigned Debug, Release and
recovery-enabled Release app builds and privacy-parity checks. Older successful
builds are not evidence for the latest warning-display changes. This lane does
not establish release readiness or authorize an upload.
