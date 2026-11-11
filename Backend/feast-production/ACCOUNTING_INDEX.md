# Indexed accounting cutover: offline candidate

This separate milestone follows reviewed lifecycle commit `d815d3b`. It is not
release, deployment, or activation approval. No live ledger, provider,
credentials, or user data are used by its tests or tooling. The existing
lifecycle migration, AnswerJobs pre-deployment preflight, and reviewed recovery
disposition remain prerequisites. No historical accounting/profile reader is
removed. Canonical records, old rates, unknown holds, and physical ID casing
remain unchanged.

## Assurance boundary

The index replaces repeated full-history reads with a verified checkpoint,
trusted all-writer transactions, and authenticated membership/absence proofs
for each touched canonical record and root/turn lookup. A missing or corrupt
active checkpoint, receipt, required branch/leaf, or touched record fails
closed. There is no fallback to an unindexed admission writer after cutover.

A bounded hot request does **not** inspect every unrelated historical byte.
Arbitrary out-of-band corruption of an untouched row is discoverable by the
independent full semantic audit, not promised detectable by every status call.
The audit runs against an explicitly immutable, complete local snapshot and
recomputes all balances, root/turn membership, active IDs, and canonical record
proofs. There is no production full-scan audit HTTP route. The offline CLI emits
the exact snapshot digest so a result cannot silently be applied to a later
export. Complete export, writer quiescence, namespace identity, source provenance,
and never-enabled declarations require reviewed operational evidence. Hashes
alone do not establish those facts.

## Schema, proof, and writer contract

All index records are additive under
`production-validation-v2:accounting-index:v1:`. The common writer control is
`production-validation-v2:accounting-writer-revision:v1`. The canonical record
trie commits every V1/V2 key/value except the index prefix, writer control, and
lifecycle cutover marker. The latter controls are pinned separately, avoiding
recursive hashes. Unknown retained fields are included in the record digest.

Three deterministic compressed radix tries prove canonical physical keys,
normalized root ownership/completeness, and owner/native-turn unsettled counts.
Physical IDs are never renamed. Branches have at most 256 children and depths
are limited by 32/64 hexadecimal path characters. Insertion and deletion order
produce the same root, including unary-branch compression. Aggregate safe
integers preserve all historical, charged, pending, and active-slot values.
The active managed-ID set is bounded by the existing four-execution limit.

`ProductionLedger` wraps every official storage transaction:

- V1 reserve, complete, uncertainty, total/inflight, and halt generation.
- V2 legacy, native, staged, and compatible v6/v7 direct admission, one-shot
  claims, known rejection, cancellation, uncertainty, partial/late settlement.
- Recovery's ledger calls, native-turn/root updates, Stop and replay fences,
  deadlines/alarms, diagnostic updates, and every global halt writer.
- Research-pilot controls conservatively advance the common revision. Their
  separate control prefix is not part of accounting totals or the canonical
  V1/V2 trie; all paid pilot calls still use covered native accounting rows.
- Phone-access state lives in a separate object and is outside accounting.
- Offline lifecycle migration uses the raw storage path but explicitly advances
  the same revision. A new canonical migration is refused once index staging
  or authority exists. An exact existing receipt reread is read-only.

Before activation, changed accounting/pilot values advance the common revision.
After activation, canonical proofs, derived totals/membership, active IDs, and
revision change in the same transaction. Exact no-op Stop/reservation/uncertainty/
settlement replays do not churn revisions. Missing/stale proof controls never
mean zero balance or unknown ownership. Raw audit reads are read-only; no raw
canonical repair/reset endpoint is supplied.

## Bounded staged bootstrap

1. `prepareAccountingIndexPlan` performs full semantic validation on the complete
   immutable snapshot, including lifecycle receipt chunks, owner/turn links,
   historical usage, every unknown hold, and reviewed legacy classifications.
   No pending/uncertain legacy row is silently skipped or guessed expired.
   It emits a version-2 plan containing schema/policy version and hash, reviewed
   source revision/evidence digest, canonical record root/count, separately
   pinned writer revision and lifecycle marker digest, root/turn roots, every
   accounting total, and active managed IDs. Its canonical revision digest binds
   record root/count plus both controls. Policy binding includes implicit rates,
   token/tool limits, and exact historical rounding expressions. The source Git
   revision is reviewed provenance, not runtime-authenticated Git identity;
   source-policy compatibility must be reviewed on subsequent code changes.
2. `beginAccountingIndex` saves only non-authoritative staging state, scoped by
   the exact plan digest. It does not run a hidden full semantic scan. A competing
   plan at the same writer revision cannot replace a live stage. A stale stage
   may be superseded only by another fully prepared/reviewed plan.
3. Each `advanceAccountingIndex({token, step})` transaction pins both controls
   and policy, scans a bounded sorted V1 or V2 page, and updates staged proofs.
   Only actually processed keys advance the cursor. A partially consumed fetched
   page is revisited; each range terminates on an explicit empty result. Index
   metadata is excluded by its exact prefix, never by a history age/count cap.
   Every canonical row contributes to the expected record proof. Omitted pages,
   changed values, or inconsistent semantic totals cannot reach ready state.
4. A separate bounded DFS traverses every reachable proof node. Path/depth/hash,
   kind, child count, stack, and value limits are checked. The depth-bounded stack
   avoids an unbounded frontier. Ready state is sealed at its exact step. Only
   the immediately preceding exact step can return its saved receipt on lost
   ACK; skipped/reordered/stale requests fail without advancing.
5. `activateAccountingIndex` is constant work: compare the live writer revision,
   lifecycle marker, schema/policy, all roots/counts/totals/active IDs, and sealed
   completed traversal; atomically publish immutable receipt, checkpoint, and
   additive cutover fields. It preserves pending rows and full holds, including
   overdue work, and schedules the earliest original active deadline. Expiry is
   a later ordinary lifecycle action, never inferred during bootstrap.

Interruption before activation leaves non-authoritative staging only. An
activation failure rolls back all authority writes. OFF still pauses new
provider admission/claims but allows settlement, uncertainty, Stop, alarms,
and cleanup. It never authorizes an old writer. Rollback must understand both
lifecycle and index metadata; pre-cutover binaries are not valid live writers.
No staging-GC/reset API is provided: stale scopes remain inert until a separately
reviewed cleanup exists, so stale cleanup cannot delete a newly active tree.

### Resource limits and evidence

An advance transaction processes at most 64 source rows or traversal operations.
Source processing stops at 512 KiB, before another row would exceed that budget.
A page fetch can read 64 values; a single JSON-encoded value is limited to
128 KiB. Total metered reads and writes are each limited to 16 MiB, with at most
10,000 value operations. Source processing also stops at conservative intermediate
resource margins. Limits are refusals, never permission to omit a record. A valid
near-128 KiB row fits a step. Begin and activation use fixed-size metadata and
at most four active executions, not history-sized lists/receipt reconstruction.

Returned `work` metrics count value reads/writes and operations before the final
bounded staging checkpoint write. The transaction's enforced limits include that
write; add at most one operation and 128 KiB to those reported figures. Keys,
engine overhead, and offline full preparation/audit are not represented as CPU
budgets. A per-step measured wall time is evidence, not an arbitrary hardware SLA.

Mock-only local SQLite/workerd measured the staged implementation with restart,
exact-step retry, and forced atomic activation failure:

- 10,000 historical rows: 846 steps; observed maximum 134 ms wall per step,
  2,627,021 read bytes, 2,646,304 write bytes, and 769 value operations.
  Whole harness: 14.31 s wall / 13.49 s process CPU.
- 70 near-128 KiB rows (120,000-byte retained field): 26 steps; observed maximum
  443 ms wall, 7,704,783 read bytes, 38,939 write bytes, and 96 value operations.
  Whole harness: 1.94 s wall / 1.20 s process CPU.

Those are development measurements; the frozen review package carries the
fresh exact-source rerun logs. The earlier one-transaction 10,000-row prototype
(8.48 s wall / 7.92 s CPU for the whole harness) is not the operational path.
`buildAccountingIndex` only loops the staged API for **local snapshot tools/tests**.
No one-RPC runtime loop or weaker prototype plan is accepted. Offline audit and
preparation are intentionally complete and can take memory/time proportional to
all retained history. They are not run inside an operational request.

## Offline CLI and gates

`tools/execution-migration-offline.mjs` supports `index-plan`, `index-begin`,
`index-step`, `index-activate`, `index-status`, and `audit`; local-only `index`
convenience requires the same full plan. Every write emits a new exclusive-created
artifact, never overwrites the source/reviewed plan, and performs no network or
credential access. `audit` emits the immutable input digest. These are offline
preparations, not authorization or an adapter for a live migration.

Tests cover large-history differential balances/replays, V1 bytes, mixed-case
ownership, every official writer family, no-op full-map equality, legacy receipt
validation without quadratic scans, missing/omitted/corrupt staging, revision
and policy drift, overflow, competing plans, skipped steps, interrupted scanning
and activation, near-max-size rows, overdue alarms, active corruption/no fallback,
late settlement/full unknown exposure, and OFF maintenance. An explicit test
shows untouched raw corruption may leave bounded status successful while the
independent full audit rejects it. Review includes those assurance limits.

The first new index/staging reds were missing-contract tests, not separate
reproduced historical incidents. The original full-suite failures were three
V1 tests whose minimal storage mock omitted the actual DO `list` API, plus two
byte-equality assertions that included the new revision despite creating a new
Stop fence or V2 reserve+settlement. Those assertions now require the exact
revision increments and retain all other historical equality checks. A separate
expected-correct repeated-Stop red exposed genuine prototype revision churn;
its fix preserves full-map equality for all tested replay paths. No assertion
was weakened to hide canonical changes.
