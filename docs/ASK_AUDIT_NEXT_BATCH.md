# Ask audit next batches: proposed designs, not implemented

These are read-only follow-on plans to `ASK_AUDIT_REMEDIATION.md`. They do not
activate recovery, change live accounting, migrate user data or authorize release.
The first prepared batch leaves these blockers open.

## 1. Lossless action journal storage

### Existing constraints

The journal has a 200-entry and 8 MiB whole-file lifetime limit. `prepare` appends
in memory before `persist` rejects an over-limit archive, so a failed admission
can also leave the running engine holding an unpersistable state. Prevalidation
or transactional admission must prevent this independently of increasing capacity.
Unknown write outcomes must be reconciled, not blindly retried.

Chat deletion, age and current conflict do not establish unreachability:

- `latestAction(for:)` can return committed Undo records from any chat.
- Recovery checkpoints retain action IDs, completed-leaf receipts and operation IDs.
- `canReuseReceipt` and deleted-record provenance need before/after evidence.
- `intent` and `undo-intent` reconcile interrupted collection transactions.
- `dismissRecovery(in:)` changes presentation, not the receipt's authority.

### Proposed first storage repair

Use a local system-SQLite journal independent of the CloudKit collection store.
Store one complete record per existing action ID, preserving its order, proposal,
phases, snapshots, finding identity, chat/turn identity and recovery-operation
binding. Index action, turn, chat, target and unique recovery-operation key.
Load bounded pages/payloads on demand instead of rewriting the entire history.
Retain per-entry validation and resource bounds; this is not a larger global cap.

Proposed API boundaries:

- `loadAction(id)` and `lookupRecoveryOperation(key)`.
- Paged `receiptsForTurn` and `recoverableActionsForChat`.
- `latestUndoableAction(target)`.
- Transactional `insertPrepared(entry, expectedGeneration)`.
- Revision/phase-checked `transition(id, expectedRevision, expectedPhase, replacement)`.

Keep write-intent persistence before Core Data save and existing post-crash
reconciliation. Failed storage operations must not silently alter authoritative
caches or hide earlier receipts. Preserve local-only data handling and explicitly
review protection/backup behavior for the database, side files and migration copy.

For the first implementation, retain full durable payloads. Retirement means
removing inactive data from the working set, not deleting evidence. Do not expire
entries by time, chat deletion or presumed lack of interest. This does not resolve
the separate journal privacy/retention policy question.

### Migration and rollback

Serialize migration against mutation writers. Validate and fingerprint the exact
v1 bytes; copy every entry in a transaction; verify record equivalence and indexed
lookups; synchronize; atomically activate v2. Retain a verified migration backup.
The old authoritative path must carry an unsupported-version marker so old code
fails closed rather than reading stale receipts or creating an empty journal.
Interrupted migration must resume idempotently; divergent copies block mutations.
Rollback requires a v2-capable reader or disabled mutations, never restoring stale
JSON after v2 writes.

### Regression gate

- Actions 199/200/201/1,000 across restart, including the earliest reachable Undo.
- More than 8 MiB aggregate history without whole-history loading.
- Failed admission leaves previous receipts and Undo usable.
- Prepared previews, no-ops, dismissed/deleted chats, repeated tool requests.
- Exact recovery-operation replay and conflicting digest/turn/owner rejection.
- Crashes around intent persistence, collection commit, receipt and Undo transitions.
- Deleted-record provenance and chat deletion during running work.
- Missing/corrupt payload/index and disk-full/write/sync failures, without empty fallback.
- Interrupted/repeated migration and stale old-binary launch.
- Legacy identity preservation plus all default and recovery-compiled regressions.

Finite physical storage still requires a safe failure state: stop new mutations
without discarding existing evidence. Truly bounded total retention with unlimited
Undo/replay is impossible. Reclaiming meaningful history requires an explicit
retention decision, not an inferred consequence of deleting a chat.

## 2. Backend execution lifecycle and uncertainty isolation

### Safe patch sequence

1. Add expected-correct races and a disabled compatibility reader/schema. Keep
   existing global halts; generate a content-free read-only migration manifest.
2. Add native reservation/dispatch lifecycle across `native-accounting.mjs`,
   `native-conversation.mjs`, the ledger alarm and AnswerJobs adapter together.
3. Apply the same lifecycle to every staged caller, including conversation
   authorization, the agent broker and public research/extraction broker.
4. Only then isolate attributable staged uncertainty. Structural corruption,
   unattributed failures and unexplained existing halts remain globally blocking.
5. Keep migration/activation tooling separate, revision-checked and reviewed.

### Proposed additive contract

Keep the existing Durable Object namespace, canonical keys and historical billing
profiles. Add a versioned execution sidecar keyed by the existing physical request
ID. Do not normalize or recompute historical staged keys: `stageID()` hashes the
original root's casing.

The sidecar should bind protocol/owner/root/stage/optional native turn, immutable
profile and original hold, exact reservation intent including provider-body and
allocation digest, server timestamps/deadlines, execution phase, one-time claim,
settlement digest, terminal reason and revision.

Required invariants:

- Exact reservation replay returns the original allocation without new counters.
  Changed body, identity, profile or allocation conflicts.
- Reservation recovery is not dispatch permission. An atomic dispatch claim is
  granted once; a lost claim acknowledgment never permits a second provider call.
- Commit reservation and earliest alarm atomically. Expiry retains the complete
  recorded hold, releases only active execution capacity and closes the root.
- Native uncertainty preserves the existing same-human-turn fence. Do not invent
  turn identity for older staged protocols that lack it.
- Zero-cost cancellation needs atomic proof no dispatch claim existed; elapsed
  time is not such proof.
- Exact settlement replay is idempotent. Late verified usage reconciles once
  without reopening an expired/stopped root. Conflicting evidence fails closed.
- Deadline selection must cover measured provider/body/decode windows. A deadline
  is neither permission to retry nor proof upstream processing stopped.

### Legacy migration and rollback

Inventory canonical records, profiles, exposure, ownership/root/turn association,
pending executions, halt flags and validation failures. Do not infer age or
undispatched state for legacy rows without timestamps. Preserve v1 bytes; put
compatibility facts in additive metadata.

Classify every existing halt explicitly. A pending/uncertain row alone does not
explain a global halt. Migration must bind the reviewed revision and append an
immutable audit receipt. A legacy-halt acknowledgment must bind a classified halt
generation. Every later halt writer must create a new generation; old unversioned
writers cannot remain active during cutover.

Rollback must understand execution and cancellation claims, deadlines and holds.
Disabling the new feature must not disable settlement, fences or cleanup. No
reset endpoint, balance clearing or namespace replacement belongs in this repair.

### Sixteen-case race gate

1. Reservation commits but its acknowledgment is lost.
2. Reservation never commits.
3. Dispatch claim commits but its acknowledgment is lost.
4. Crashes immediately before/after claim and provider send.
5. Four expired executions release slots while every hold remains.
6. An uncertain staged/native root cannot continue.
7. The same native turn cannot retry under a different root.
8. Alarm/settlement race.
9. Duplicate settlement and alarm delivery.
10. Late bill settles once without reopening the root.
11. A global halt still permits valid in-flight settlement.
12. Classified legacy halt versus unexplained/corrupt halt.
13. Mixed historical Astra/Sol rates and v1 bytes remain unchanged.
14. Owned Stop, cancel-before-submit and cross-user fencing remain correct.
15. Existing AnswerJobs crash/receipt/expiry/rollback cases remain valid.
16. Interrupted/repeated migration preserves balances and fences.

The immediate next safe backend batch is tests plus the disabled compatibility
reader, not removing a halt or adding a timeout that discards accounting exposure.
