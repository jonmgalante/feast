# Ask audit coverage and integration gates

This is a tracking index, not a release approval. Original audit baseline:
`41229acfabb080559904c41a07f1db25f0b082f6`. First verified batch source:
`15ea9b390ae63101daf37ea6b508bd1c9abedb02`, backend commits listed in
`ASK_AUDIT_REMEDIATION.md`. All work remains local and recovery remains OFF.

## Verified first batch

- Display occurrence order, grouped pagination, explicit subsets and pre-filter
  ordinal resolution; legacy grouped references fail closed rather than guess.
- Fresh researched-link identity at authorization/commit and exact replay.
- Final normalized write bounds without rewriting unrelated legacy values.
- Undo current/restored-parent ACL, store, collision and ancestry safety while
  preserving valid legacy graph restoration.
- Additional baseline cascade/nullification bookkeeping failure that prevented
  truthful deletion receipts/Undo.
- Empty-library planner admission; completed/failed/stopped turn admission;
  current composer errors; fallback-draft provenance; full native lists with
  bounded extra mentions archive consistently.
- Neighborhood predicates, unsupported non-place combinations and stored-link search.
- Cross-user/cross-protocol cancellation ownership; bounded cancellation claims.
- Exact reviewed recovery-OFF deployment-helper schemas.

Final first-batch gate: 247/248 Swift checkpoints, 335 Node tests, 65+27 Python
tests, mock-only SQLite/workerd restart, three unsigned builds and built privacy
parity. See the remediation document for compatibility and review limits.

## Continuing implementation, not yet integrated or verified

### Lossless journal branch: `fix/ask-audit-journal`

- Remove the artificial 200-entry/8 MiB *whole-history* lifetime limit via indexed,
  bounded-loading storage, not a larger cap or deleted receipts.
- Make failed preparation/phase persistence transactional and recoverable.
- Ensure a near-limit action advertised as Undoable remains representable when
  its undo-after proof is recorded; avoid a new per-entry duplication ceiling.
- Preserve every Undo/replay/deleted-record/intent identity through v1 migration,
  interruption and compatible rollback.
- Make file protection and backup/restore behavior explicit without silently
  reducing existing recoverability. Retention policy is separate from capacity.

### Accounting branch: `fix/ask-audit-accounting`

- Idempotent reservation recovery separated from one-time dispatch ownership.
- Durable deadlines release active execution capacity without discarding holds.
- Root/native-turn fences survive lost acknowledgments, crashes and late usage.
- Isolate attributable staged uncertainty only after every caller is compatible;
  corruption, unattributed uncertainty and unexplained legacy halts stay fail-closed.
- Reviewed, revision-checked legacy inventory/migration and compatible rollback.
- Historical-scan scaling without skipping records or trusting unverifiable totals.

### Answer/history branch: `fix/ask-audit-answers`

- Retain independent native list sections with separate query/page/membership and
  occurrence provenance. Do not merge unrelated lists into the last query scope.
- Preserve unaffected dialogue when one saved reference becomes inaccessible;
  never return revoked/private content through remaining fragments.
- Reject blank synthesis that has not actually answered via a rendered result.
- Resolve the styled-but-inert uncited link affordance safely.
- Make retained long-answer tails retrievable through bounded, truthful context.
- Align large aggregate checkpoint save/restore without a new collection cap.
- Permit non-destructive navigation when current in-memory history cannot save,
  preserving the full chat and draft rather than silently dropping/truncating them.

## Required integration gate

Each candidate starts from the verified first batch. Expected-correct failures,
compatibility fixtures and independent review precede integration. The combined
source must then pass the full default/recovery-compiled Swift suites, complete
backend/helper tests, applicable mocked runtime crash/race tests, unsigned builds
and privacy parity. Source is frozen during compilation.

No existing audit probe's "pass" is assumed to mean a repair: several original
probes intentionally asserted buggy behavior. Physical-device lifecycle, actual
CloudKit permission transitions, live-provider performance, live legacy-state
classification and deployment acceptance remain separate, explicitly authorized
release gates. No cap removal, automatic reset, data deletion, discarded charge,
permission weakening or activation can substitute for those gates.
