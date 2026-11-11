# Ask Feast audit remediation: first bounded batch

Baseline: `41229acfabb080559904c41a07f1db25f0b082f6`.

This document describes the first batch only. Current accepted follow-on milestones
and remaining integration gates are tracked in `ASK_AUDIT_COVERAGE.md`.

This is local source preparation, not a release approval. Build 22 remains held.
No live collection, ledger, credentials, provider calls, service configuration,
recovery activation, TestFlight upload, or deployment is part of this batch.

## Prepared repairs

### Query identity and display

- Native query membership stays unique and separate from displayed occurrences.
  Grouping can repeat a place under multiple cuisines without changing what an
  ordinal means. Consecutive pages retain those repeated rows rather than
  deduplicating them.
- Local-only `displayOrder` metadata carries occurrence order through conversation
  state, archive and recovery. External task projections do not upload it.
  Membership and ordering always come from the same authoritative task/context.
- Ordinals resolve before status, other predicates, or explicit ID narrowing.
  Explicit synthesized subsets cannot fall back to a larger native query order.
- Old grouped archives without reliable occurrence provenance retain their data
  and membership, but require a fresh list before positional reads or edits.
- Neighborhood predicates are honored; unsupported non-place filter/grouping
  combinations are rejected instead of returning a false complete result.
- Stored website and Instagram text participate in search. Search fingerprints
  include relevant raw link values without broadening returned field projection.

### Mutation and Undo safety

- Research findings are filtered before executor construction and rechecked
  before authorization/commit against name, city, website and Apple Maps ID.
  Identity changes during authorization invalidate the write.
- Prepared researched-link journal entries bind the identity used to authorize
  them. Old unbound previews fail closed; committed receipts and Undo remain
  backward compatible.
- Exact successful researched-website writes may rebase same-identity supporting
  findings, preserving idempotent replay without accepting unrelated drift.
- Changed, normalized persisted fields obey reader bounds in UTF-16 units.
  Append checks the complete resulting note/tag/cuisine field. No truncation is
  performed. Unchanged legacy oversize data remains lossless and editable.
- Undo checks current and restored-parent access, same-store relationships and
  newly introduced Maps collisions and changed-name collisions atomically.
  Unchanged legacy nested/duplicate data, including valid deleted graphs, remains
  lossless. Deleted-neighborhood name restoration retains its original behavior;
  this batch does not invent collision provenance absent from older journals.
- Collection changes materialize Core Data cascade/nullify effects before writing
  the durable intent and collecting merge notifications. A city deletion must
  not commit without a usable receipt, and neighborhood deletion must retain
  working Undo. These additional failures also reproduced on the original baseline.

### Session persistence

- Empty collections no longer veto model-led requests before the planner. Consent,
  activation, screenshot capability and collection-read-error gates remain.
- Admission and archive eligibility count completed, failed and stopped non-image
  turns consistently. Answer Again uses the same boundary.
- A historical failed turn no longer hides unrelated current composer errors.
- An interrupted-request fallback draft records its originating turn. Successful
  late completion clears only that fallback, never newer user input.
- Response acceptance and archive structural bounds distinguish native query rows
  from bounded, validated extra mentions/findings. The 2,400 native-row and 8 MiB
  archive boundaries are unchanged; no accepted row is silently discarded.

### Backend and tooling

- Cross-protocol root ownership is checked atomically before Stop closes a root.
  This covers native, staged, direct-v2, v1 and case aliases.
- Unknown-job cancellation uses bounded durable ownership-claim metadata before
  a cancellation tombstone. Lost acknowledgments retry idempotently; unrelated
  owned Stop/status remains responsive during a slow ledger request.
- The exact reviewed recovery-OFF scaffold/current production schema is accepted
  by deployment helpers. Unreviewed flags, migrations, namespace changes or
  activation remain rejected. No helper was used to deploy anything.
- The new cancellation-claim metadata requires a claim-aware rollback target or
  a quiesced, verified drain. See `Backend/feast-production/ANSWER_JOB_RECOVERY.md`.

## Compatibility and rollback limits

The compatibility tests cover upgrading old archives/journals without losing their
meaning. They do not establish arbitrary app downgrade compatibility. Older app
binaries ignore occurrence-order and finding-identity metadata, and their archive
validator may reject newly accepted full native lists plus extra mentions. Use a
tested, compatible rollback build; preserve history/journal files rather than
clearing them to make an older reader open. Backend rollback must also understand
the new cancellation claims or follow the verified-drain procedure above.

## Verification

The original audit failures were first reproduced against an immutable baseline
with expected-correct regressions. Independent review then identified and corrected
additional narrowing, pagination, archive compatibility and replay regressions.
Tests use disposable SQLite stores and mocked transports, not a live library or
paid provider.

Verified on the final immutable source corresponding to app commit
`15ea9b390ae63101daf37ea6b508bd1c9abedb02`:

- Full Swift persistence/Ask suite: **247 passing checkpoints** in default mode.
- The same full suite compiled with `FEAST_DURABLE_RECOVERY`: **248 passing checkpoints**.
- All Node backend tests: **335 passed, zero failures/skips**.
- Production helper Python tests: **65 passed**; proxy helper tests: **27 passed**.
- Real SQLite/workerd restart integration passed with a mock-only outbound
  provider and zero live provider calls.
- Unsigned Debug simulator, Release device, and recovery-inclusive Release device
  builds all succeeded. No app was installed or uploaded.
- Privacy validation passed its 14 negative cases and built-app parity for both
  device Release variants.
- Frozen source hashes were verified after the runs. The original audited
  checkout remains clean; project/model files and recovery configuration are unchanged.

Independent reviews covered query/display authority, mutation/Undo compatibility,
backend ownership and lifecycle admission. The independent wrong-target probe
first reproduced selection outside an authoritative synthesized subset, then
verified rejection of that write and successful modification of the correct target.
Cascade/section deletion failures reproduced on the original baseline and passed
after the pending-change bookkeeping correction. The added intent-reconciliation
case simulates an interrupted journal phase; it is not a real killed-process or
power-loss test.

The app source engine hash at this gate is
`2b85d997df997d69661d7fe15475f01451ef5acd1db52431d550ec0120048a06`.
Backend commits are `5b5c289`, `6299514` and `b0b5757`. All are local preparation,
not deployed changes. Passing this bounded gate is not release approval.

## Still open: not repaired by this batch

Release remains blocked while the following higher-risk work is prepared.
Proposed implementation boundaries and regression gates are recorded separately
in `ASK_AUDIT_NEXT_BATCH.md`; they are not implemented by this batch:

1. **Action journal lifetime:** the 200-entry/8 MiB ceilings still need durable
   retirement or segmentation preserving unresolved receipts, replay fences and
   reachable Undo. Do not raise the cap or delete receipt history as a shortcut.
2. **Global uncertainty isolation:** one ambiguous staged authorization can still
   halt unrelated users. Structural corruption must continue to fail closed.
3. **Lost reservation acknowledgments:** committed reservations can still exhaust
   active concurrency. Repair needs additive execution ownership, a one-time
   dispatch claim, durable deadlines and full retained accounting exposure.
   Legacy halt/pending migration requires reviewed attribution and a
   revision-checked manifest, not automatic reset or inferred timestamps.

Other audited items remain separate: independent multi-list display sections;
permission-aware per-fragment conversation retention; blank-synthesis rejection;
unsupported-link styling; retained long-answer retrieval; complete aggregate
recovery membership; a non-destructive navigation escape for already-unsavable
in-memory history; historical accounting-scan scaling; and journal retention/
privacy design.

Keep full permitted-collection access, existing model/tool capability, permissions,
conflict checks, Stop, receipts and Undo. Do not remove safeguards to mask any of
these failures. Physical-device lifecycle, actual CloudKit permission transitions,
live-provider quality/latency, and production migration/deployment need separate
acceptance and authorization after the remaining blockers are resolved.
