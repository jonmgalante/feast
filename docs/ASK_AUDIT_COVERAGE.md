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

## Verified additional journal milestone

Integrated as `bddb81c` (reviewed source commit `e3bf9e04f86bb31bcb366ad866318c7990cfac50`).
The indexed local journal removes the artificial 200-entry/8 MiB whole-history
lifetime ceiling without deleting receipts, Undo or replay evidence. Segmented
snapshots preserve near-limit inverse writes; transactional admission, phase CAS,
nonblocking process locking and v1 migration retain the existing authority.

Final source passed 303 focused journal checkpoints, 550 default and 551
recovery-compiled checkpoints, three unsigned builds and privacy parity. The
independent reviewer reran the last two corruption/capacity probes against the
exact final hashes. Integration changed no production bytes from that snapshot.
See `ASK_JOURNAL_V2.md` for migration, backup, rollback, evidence and limitations.

This is a scoped code milestone, not a live migration or release approval.
Physical-device protection/backup restore and actual power-loss behavior remain
separate acceptance checks. A forthcoming history-permission proof is a separate
reviewed engine change, not covered by this journal signoff. Retention versus
erasure remains a product decision; existing retention semantics are unchanged.

## Reviewed additional answer milestone

Integrated as `51f61a5` and `17d140e` (reviewed source commits `ddcee653` and
`e387ab70`). Empty or visually empty synthesis cannot complete a bookkeeping-only
answer; visible native Maps choices, lists/counts/actions and negative lookup
results remain usable. Invisible final text no longer erases a truthful native
fallback. Unverified URL text no longer advertises an unsupported tap action.
Large **nonordinal** aggregate checkpoint membership uses the same save/restore
validation without relaxing ordered-selection, mutation or 8 MiB bounds.

The exact immutable milestone passed 251 default and 252 recovery-compiled
checkpoints with serialized runtimes. Independent source/evidence review approved
this bounded scope. Production and retention-test hashes match after integration;
only test-runner entry points were combined with the journal suite. An interim
immutable combined gate at `17d140e` passed **554 default / 555 recovery** checkpoints,
both exit 0 with serialized runtimes and a verified post-run source manifest.
Evidence is `/tmp/feast-integration-journal-answers.f6FEhZ`. The final full combined
build/review gate still follows the remaining implementation below.

## Continuing implementation, not yet integrated or verified

### Accounting branch: `fix/ask-audit-accounting`

- Idempotent reservation recovery separated from one-time dispatch ownership.
- Durable deadlines release active execution capacity without discarding holds.
- Root/native-turn fences survive lost acknowledgments, crashes and late usage.
- Isolate attributable staged uncertainty only after every caller is compatible;
  corruption, unattributed uncertainty and unexplained legacy halts stay fail-closed.
- Reviewed, revision-checked legacy inventory/migration and compatible rollback.
- New queued jobs retain exact dispatch/count material. Historical jobs lacking
  that proof require content-free preflight and verified drain/compatible handling
  before source deployment, not merely before activation. This is still under review.
- Historical-scan scaling without skipping records or trusting unverifiable totals.

### Answer/history branch: `fix/ask-audit-answers`

- Retain independent native list sections with separate query/page/membership and
  occurrence provenance. Do not merge unrelated lists into the last query scope.
- Preserve unaffected dialogue when one saved reference becomes inaccessible;
  never return revoked/private content through remaining fragments.
- Make retained long-answer tails retrievable through bounded, truthful context.
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
