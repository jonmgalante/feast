# Ask action journal v2: local implementation protocol

This is isolated source preparation, not permission to migrate a live store or release.

## Data and query contract

Use system SQLite in a sibling `collection-actions-v1.json.journal-v2` directory,
separate from Core Data / CloudKit. Preserve complete per-action JSON payloads:
IDs, insertion sequence, proposals, snapshots, finding identities, recovery key
and digest, turn/chat, phases and dismissed flags. No automatic retirement,
expiry, deletion, chat-based erasure or retention claim. The existing facade stays
stable. The store queries IDs in pages of 64 and loads one bounded action at a
time without a history cache. Immutable content-addressed snapshot blobs and
ordered before/after/Undo references replace the old cumulative envelope.
The existing 1,000-image-per-phase bound remains. Metadata and newly captured
before/after evidence each have an 8 MiB bound. Undo's bound is derived from the
exact before images plus worst-case encoding for restored updatedAt timestamps,
including previously absent dates. Metadata phase growth is preflighted before
admission/collection save. An admitted edit does not consume its own Undo space
merely by retaining before and after. Aggregate history has no lifetime ceiling.

Indexes cover unique action ID, unique recovery key, turn, chat and target.
Checksums and duplicated indexed metadata are verified on payload reads.
Canonical lightweight headers bind IDs/revisions, every indexed field, ordered
targets and snapshot references, and payload lengths/digests. Instance,
generation and entry count are separately sealed; cached opens also verify the
instance against the activation marker. All headers are
streamed and verified before negative index lookups can be trusted on opening or
external data-version changes. Whole-history payload decoding is not required.
Structural SQLite integrity, required indexes, row/target counts and foreign keys
are checked at the same boundaries. A missing DB/marker,
missing indexed evidence or corrupt payload never creates an empty replacement.

## Two-store mutation protocol

A nonblocking local file lock serializes migration and the entire intent / Core Data save /
receipt sequence, including intent reconciliation and view-context merge. A
contending/suspended process causes prompt safe failure, not an unbounded UI
wait. Process death releases the lock. SQLite uses DELETE rollback
journal mode, FULL synchronous and fullfsync. Each phase replacement compares the
persisted revision and previous phase, publishing no authoritative memory cache.
Insert prevalidation precedes any store creation. Prepare failure cannot append
to working state or make earlier actions unwritable. Unknown SQLite commit
outcomes reopen SQLite, validate the exact candidate/revision, synchronize it, and otherwise
stop without blindly retrying. Durable intents remain reconcilable when a final
receipt write fails; no post-save failure may say the collection was unchanged.
Existing `processPendingChanges` before the durable deletion intent stays.

## Migration and activation

Under the writer lock, read and validate the exact bounded v1 bytes. Write an
immutable migration manifest binding an instance UUID, SHA-256 and entry count.
Create a byte-for-byte verified, synchronized, write-protected v1 backup, never
rewrite it. Create schema and import all records in one SQLite transaction, then
verify payload equivalence, order and recovery lookups. Synchronize the database
and parent directory. Recheck the source fingerprint immediately before an
atomic, synchronized replacement of the old JSON path with a version-2 marker.
The marker is the activation point and causes v1 readers to fail closed.
Opening an already visible marker re-establishes file/directory synchronization
before accepting a mutation, including after rename-success/sync-failure.

A restart can resume a known incomplete migration, including a rolled-back empty
SQLite schema, but only with the matching original source and manifest. A stale
v1 replacement, changed source, unknown orphan DB, missing activated DB or
divergent evidence blocks operations. A staged database must have generation 0;
once v2 mutations exist it cannot be imported again. Current engines check the
marker and database identity before each operation. An already-running old
binary does not honor the new lock and must not run concurrently during cutover;
a later overwritten marker is detected and never treated as authority to reset.
Rollback requires a v2-aware reader or disabled mutations, never stale JSON.

## Protection, backups and limits

Preserve legacy Application Support backup inclusion. Do not exclude the new DB,
marker or migration backup independently. Apply iOS complete-until-first-user-
authentication protection to the directory and all created files. DELETE mode
avoids permanent WAL/SHM; directory protection covers temporary rollback journals
and recovery sidecars. A partially restored/missing component fails closed;
never manufacture a fresh journal from an orphan marker. OS/device backup and
restore need physical-device acceptance; local tests cannot prove those APIs.

Chat deletion currently dismisses recovery presentation, not Undo/receipt/replay
or deleted-record provenance authority. This repair deliberately preserves that
meaning and full evidence. Actual erasure versus indefinite Undo/replay remains
a separate consequential privacy/retention product decision. Finite device
storage still stops new writes safely without deleting old receipts.

## Integration and compatibility manifest

- `AskCollectionChangeEngine` initializer and all caller-facing methods keep the
  same signatures. `journalURL` still names the old path, now an unsupported-v1
  activation marker. Callers must not treat that path as a mutable receipt file.
- The new `AskActionJournal` is a local system-SQLite implementation, not a new
  Core Data entity, CloudKit collection, server dependency or recovery feature.
  No model/project/entitlement/service configuration changes are required.
- `AskChangeEntry` and `AskChangeArchive` are module-internal rather than private
  so storage and legacy fixture helpers can share the original Codable contract.
  SQLite revision is explicitly excluded from that JSON contract.
- Existing tests that simulated old crashes or removed finding bindings now use
  `AskJournalTestSupport.legacyCopy` to produce a **new** v1 fixture and exercise
  migration. They no longer overwrite an active v2 marker or bypass checksums.
  The prepared-unbound finding refusal, committed legacy replay/Undo, creation
  intent recovery and deleted duplicate-graph assertions are unchanged.
- `Tests/run-persistence-tests.sh` compiles the new store/tests. It supports
  `FEAST_TEST_RECOVERY=1` for the separate recovery-compiled gate. The harness
  supports `FEAST_JOURNAL_ONLY=1` for targeted journal checks and an internal
  child-process mode used only with synthetic stores. Always unset
  `FEAST_UPGRADE_COPY_DIR` for these tests.
- Conversation/archive/recovery callers and history deletion UI remain separate
  integration work. Dismissal still changes presentation only. No cleanup API is
  added and no receipt IDs, recovery bindings or globally reachable Undo expire.

## Verified local gate

Baseline `3c078b00570541d6b7267abdb95de155a1b279cb` was frozen with
expected-correct behavioral tests before implementation. It admitted actions
199/200 but failed action 201; aggregate history failed at action 43 in the
large-payload fixture; an oversized failed prepare poisoned the next valid
admission. Those are behavioral red results, not missing-new-API failures.

The final compiled source was frozen and hash-verified before and after checks:

- `AskActionJournal.swift` SHA-256:
  `d9d6dec486f4055bccc20177168ffc1ab581d85ad4f4c0d51b32d3546df3f1f8`.
- `AskCollectionChanges.swift` SHA-256:
  `ac1e357528f30b1a2493edc0369be381c3c43982dea1782122858862ac22683c`.
- Focused journal gate: **303 passing journal checkpoints**.
- Full default Swift suite: **550 passing checkpoints**, exit 0.
- Full recovery-compiled Swift suite: **551 passing checkpoints**, exit 0.
- Unsigned Debug simulator, Release device and recovery-inclusive Release device
  builds all succeeded. Nothing was installed or uploaded.
- Privacy validation passed 14 negative cases and built-app parity for all three
  builds. Backend source/configuration was unchanged; no backend deployment was run.

Full test-binary invocations were serialized using a shared temporary flock
because unrelated suites use `UserDefaults.standard`; compilation could remain
parallel. `FEAST_UPGRADE_COPY_DIR` was unset in every run. Tests used disposable
SQLite collection/journal stores and mocked transports, including actual
SQLITE_FULL and killed second-process boundaries before/after collection commit.

Coverage includes 1,000 durable actions, more than 8 MiB of retained snapshot
payloads, earliest Undo after restart, failed prepare/phase admission without
poisoning, no-ops, interrupted/repeated populated and empty migrations, stale v1
launch, exact/conflicting replay bindings, deleted-chat fences, missing/corrupt
payloads/references/indexes, constant-count metadata corruption, write/sync faults,
unknown commit acknowledgments, and stale revisions. Large inverse cases include
six preserved 500 KB notes and a valid near-8 MiB migrated deletion with 250 absent
timestamps. Exact-bound metadata survives commit, dismissal and Undo.

Independent read-only review signed off this exact source. Separate component
probes reran the previously failing cached-instance corruption and dismissed-Undo
metadata cases and passed. This is a bounded journal signoff, not release approval.

Local evidence is deliberately ignored, not committed:

- `Tests/Evidence/journal-v2/red-source`, `red-source.sha256`, `red.log`.
- `final-source`, `final-source.sha256`, `final-focused.log`, `final-default.log`,
  `final-recovery.log`, and `precommit-manifest-verification.txt` in that directory.
- `final-build-{debug,release,recovery}.log` and matching
  `final-privacy-{debug,release,recovery}.log`.
- `independent-final-review/` retains the component probe source and log.
- `commit-source.sha256` records the source plus this evidence-only documentation
  update. Production and test files remain byte-identical to the tested snapshot.

On the shared Mac, the focused 1,000-action restart plus indexed lookup took
0.221 seconds and decoded one payload. Ten alternating-engine commits took
3.16 seconds. Full-run timings varied under concurrent compilation. These are
local diagnostics, not physical-device latency guarantees. SQLite integrity and
lightweight header checks stream retained metadata on open/external changes;
there is no claim of constant-time startup or unlimited physical storage.

Physical-device data protection/backup restore, actual power-loss durability,
CloudKit permission transitions and production rollout still need separate
acceptance. Indefinite retention versus actual erasure remains a separate privacy
policy decision. No automatic evidence deletion or expiry is implemented.
