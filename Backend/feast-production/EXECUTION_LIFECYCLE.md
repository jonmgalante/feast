# Offline execution lifecycle candidate

This is source preparation, **not release approval**. All production/recovery
flags and deployment files remain unchanged and OFF. No live ledger was read,
changed, reset, migrated or replaced. No credentials or paid provider were used.

## Contract

`production-validation-v2:execution:v1:<physical requestID>` is additive metadata.
The canonical request remains the sole accounting hold/usage record. The sidecar
binds its owner, original-cased root, stage, optional native human turn, immutable
profile/full original hold, reservation/body/allocation digests, intent-field
set, server deadline, phase, one-shot claim, settlement digest and revision.
Historical staged IDs are **not** recomputed with lowercased roots. Native IDs
retain their preexisting normalization.

Reservation and earliest alarm commit in one storage transaction. Exact reserve
replay returns the original allocation and explicitly grants no dispatch.
Only an atomic claim returns `dispatchGranted`. A repeated claim never grants it,
even if the first acknowledgment was lost. Every production native/staged caller
uses the claim before provider send. AnswerJobs persists `claiming` before the
ledger RPC, and neither `claiming`, `claimed` nor `dispatched` restarts send again.
Stop/revocation after a claim but before send retains uncertainty rather than
persisting an impossible zero-cost cancellation. Cached recovery verifies the
original payload/model/fingerprint/allocation and persists versioned exact
provider/count bytes in the bounded, TTL-erased job-content store before any
reservation. A midnight/template change resumes the originally accepted bytes,
not a new prompt under an old digest. The final send rehashes actual bytes.
Token counts are cached only for an identical count body. Historical jobs that
retain a generation-body proof but lack a count-body digest safely re-count.
The actual recovery producers at `bc6f920` through audited `41229ac` and base
`3c078b0` store no generation-body proof in reserved/reserving jobs. Acceptance
`createdAt` does not prove execution-time UTC date after a queued delay. Authentic
pre-proof rows are therefore paused intact before any recovery reservation RPC,
not silently reinterpreted or marked uncertain because of this upgrade. Their
original phase, payload, count, intent and full hold remain readable. Status
keeps the existing queued/running state; operationally these jobs are PAUSED, not
making progress. Polling does not schedule a retry loop. Stop, original TTL,
known receipts and fencing remain usable. Partial/corrupt managed proofs are
not classified as legacy. Tests run the genuine old source producer, including
lost reserve ACK and received receipt, and verify original-processor readability
**before cutover only**. This is not permission to run an old ledger after cutover.

Expiry changes execution capacity, not billing evidence. It retains the complete
original hold, closes the root and closes an unknown native human turn. A late
verified bill settles once without reopening those fences. Proven undispatched
cancellation requires an atomic absent-claim check. Known zero-charge rejection
or proven undispatched cancellation closes the root but does not invent a
permanent uncertain-human-turn fence. Unattributed failures, corruption and
unexplained historical halts remain globally blocking.

The candidate window is 5 minutes for one-call native/staged execution. The
compatible v6/v7 saved broker retains its one original aggregate reservation and
historical rates/bounds, with up to three monotonic child claims binding exact
provider bodies and prior verified usage prefixes. Its window is 10 minutes.
Input-count failures before a child claim cancel a proven-zero envelope or
settle only already verified generations, without mislabeling the count failure
as a generation rejection. New direct requests use an additive inflight lock;
explicitly classified legacy pointers and their original bytes remain intact.

Both windows exceed configured 90-second provider and 20-second token-count
windows with bounded decode/ledger margin. They are not evidence that upstream
processing stopped. Production latency measurement/acceptance remains required.

## OFF and rollback

Pristine OFF keeps legacy admission behavior, subject to the pre-deployment
recovery preflight below; it does not promise to execute proofless outstanding
old recovery jobs under a new template. A valid durable cutover receipt is
required before new managed admissions. After cutover, OFF pauses new admissions
and claims, never falls back to an old unclaimed writer. Exact reservation
recovery, verified settlement, uncertainty, Stop/fences, status and alarms remain
available. Legacy cached AnswerJobs cannot use a legacy reservation as new
provider authorization after cutover. Known old receipts can still settle.

Rollback must understand both the earlier bounded cancellation-claim metadata
and these lifecycle/migration fields. The safe operational pause is OFF on a
compatible binary. A pre-cutover binary is not a valid live rollback target.
No namespace replacement, reset endpoint, balance clearing or age-based release
is provided.

## Required recovery preflight before source deployment

The ordering is **reviewed preflight/drain, then source deployment, then reviewed
ledger migration, then separately authorized activation**. A flag left OFF is
not enough: a newly deployed AnswerJobs alarm can process old stored jobs.

The core migration validator, not merely the CLI, requires `plan.recovery`:
- `kind: "never-enabled"`, version 1, namespace `answer-jobs-v1`, exact 32-hex
  namespace ID, 40-hex producer source revision, and SHA-256 evidence and writer
  quiescence revision digests. This is an explicit reviewed operational
  attestation, never inferred from OFF or an empty partial export.
- `kind: "drained"`, version 1, with the exact content-free artifact and its
  SHA-256 `artifactDigest` produced by the preflight tool below. Every object and
  page must be declared complete; no active job, unknown format, outstanding
  cancellation claim, pending receipt/fence or proofless reserve intent is ready.

There is no `compatible-processor` bypass. A pre-cutover processor may drain
old work, but all results must be verified before producing the drained report.
After managed cutover, every writer must obey claims/indexing; old binaries are
not a rollback path. Evidence of actual deployment is not established by these
local tests, and no live inventory has been performed.

```
node Backend/feast-production/tools/answer-jobs-preflight-offline.mjs COMPLETE_QUIESCED_JOBS_SNAPSHOT.json
```

The local snapshot contains version 1, namespace/namespaceID/sourceRevision,
quiescenceRevision/evidenceDigest, `writersQuiesced: true`,
`namespaceComplete: true`, exact `objectCount`, and `objects` with a stable hashed
`id`, `complete: true`, `nextCursor: null` and full `[key,value]` `entries`.
The tool never contacts a service or rewrites the snapshot. It emits only job
phase/category and digests, with exit 3 for an unsafe active inventory. The
completeness and quiescence attestations require operational review; a local
file cannot prove absence of omitted remote objects. The immutable migration
receipt binds the disposition, complete artifact and reviewed revisions.

## Offline migration workflow

The only supplied migration tool accepts local JSON snapshots. It has no network,
credential, Wrangler or live-apply capability:

```
node Backend/feast-production/tools/execution-migration-offline.mjs inventory SNAPSHOT.json
node Backend/feast-production/tools/execution-migration-offline.mjs apply SNAPSHOT.json REVIEWED_PLAN.json NEW_SNAPSHOT.json
```

Snapshot format is `{ "version": 1, "entries": [["physical key", value], ...] }`.
Only the existing production-validation v1/v2 prefixes are accepted. Inventory
exposes metadata/digests, never prompts, provider bodies or unknown record fields.
The original snapshot and reviewed plan are untouched; output uses exclusive
creation and restrictive file mode. This local artifact is not authorization to
write it into a live Durable Object.

A plan binds the exact inventory revision and declares verified writer quiescence.
Every old pending/uncertain record needs an explicit classification:
`attributed-uncertain` retains canonical bytes/full exposure and fences the root
(and known native turn), while releasing only active execution capacity;
`retain-active` preserves the existing active lock. No timestamp is guessed.
Every halt must be classified. `unexplained` stays blocking. An explicitly
`attributed-uncertainty` halt acknowledgment must name its classified records,
reviewed evidence digest and exact halt generation. A pending row alone is not
an explanation. Every surviving current v1/v2 halt writer increments a new
generation, so an older acknowledgment cannot consume a later halt.

The commit atomically writes additive compatibility metadata, fences, immutable
bounded receipt chunks and the monotonic cutover marker. Exact replay is
idempotent; revision drift, linkage/casing mismatch, unknown ownership, missing
classification, corrupt receipt or conflicting aliases fail closed. Existing
canonical records and v1 counters are not rewritten. Activation requires separate
verification of the actual legacy classifications, all-writer quiescence and a
compatible rollback, plus explicit deployment authorization.

## Verification and remaining work

Tests use disposable transactional fixtures and mock-only workerd/SQLite. The
initial 16-case gate was added before implementation: 16 red. The replay and
alarm assertions exposed existing behavior; new claim, alarm and migration API
assertions were contract-absence reds, not 16 separately reproduced incidents.
The old audit harness is untouched. Four compatible direct-envelope tests were
also red before that implementation.

The accepted lifecycle milestone alone does **not** fix historical-scan scaling.
Its complete compatibility reader remains the authority until a separately
verified additive indexed checkpoint is installed. The offline index candidate
is described in `ACCOUNTING_INDEX.md`: full immutable-snapshot semantic
preparation/audit, bounded revision-pinned bootstrap, all-writer transactional
proof/aggregate updates, and no history truncation or unknown-hold release.
Index review and operational cutover authorization are separate from lifecycle
signoff. No live migration or deployment is implied by either candidate.
