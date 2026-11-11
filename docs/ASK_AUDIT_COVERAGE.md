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
separate acceptance checks. The separate history-permission proof below is not covered by the original
journal signoff. Retention versus erasure remains a product decision; existing
retention semantics are unchanged.

## Reviewed deleted-history authority proof

Integrated as `e31eb81` (source `b69c7ea`). An exact committed-deletion or
undone-creation graph remains a prerequisite. Deleted IDs then receive read proof
individually only with fresh original-store and parent authority, or the narrowly
verified same-receipt owned-city graph. A revoked parent cannot be reauthorized
by a stale receipt, while another permitted city in the same batch stays usable.
Mutation, Undo, replay and journal storage semantics are unchanged.

Independent exact-source review passed, along with 50 focused proof checks,
600 default / 601 recovery checkpoints and an unsigned Debug build. The engine
hash is `f06c50465e1ec5f95b48081f8ddf467adc0c794fb60b29bc8a3ec2f0dec57d08`.
Consumer UI and history projection integration remains in the answer lane.
See `ASK_DELETED_HISTORY_PROOF.md`.

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

## Reviewed accounting lifecycle milestone

Integrated as `30b811d` (source `d815d3becb9c5514dd4233c9cc1364f838d4bfac`). Exact
reservation recovery is separate from one-shot dispatch claims. Durable deadlines
release active execution capacity without erasing holds; root/known native-turn
fences and exact late settlement survive uncertainty. Attributable failures can
be isolated only under the validated all-caller cutover contract; corruption and
unexplained halts remain blocking. Historical keys, profiles and canonical bytes
are preserved.

New queued jobs persist bounded exact provider/count material before reservation
and resume those original bytes across date/template changes. Authentic old jobs
without that proof pause with their original state, payload, hold and TTL intact;
Stop, expiry and known received receipts remain supported. Core migration requires
reviewed never-enabled evidence or a complete drained recovery inventory. Preflight
and drain must precede **source deployment**, not merely flag activation. Current
OFF flags or a matching digest do not prove operational completeness/quiescence.

The frozen milestone passed 388 Node tests, 65 production and 27 proxy Python
tests, and four mocked real SQLite/workerd runs. Independent review reran 100
focused tests plus four positive resume probes and approved this source scope.
All 78 committed backend files were independently matched to the reviewed manifest
before and after integration. Evidence is `/tmp/feast-lifecycle-final-bI2Tqo`;
production manifest SHA-256 is
`5f3cbf6703e27a44fcff6dd1f5cd19a8ce3e9e64f4be49b2b89554c7b821d72e`.
See `Backend/feast-production/EXECUTION_LIFECYCLE.md` for the offline contract.

Historical-scan scaling is deliberately **not** claimed by this milestone. No live
ledger, queued job, provider, migration, deployment or recovery flag was touched.

## Reviewed retained-history protocol integration

Integrated as `c8c0af8` and `9571933` (candidate `d649c40` / `a6288a6`, based on
answer-protocol source `342a418`). Negotiated `retainedHistoryVersion=1` adds a
bounded single-message UTF-16 `textOffset` option. Direct and durable capabilities
are advertised separately. Absent-marker schemas and Astra/Sol bodies/fingerprints
remain unchanged; changing the marker cannot dispatch the same root/step again.

The combined protocol/lifecycle freeze passed 395 Node tests, 65/27 Python tests
and four real mock-only SQLite/workerd runs. A negotiated reserved job resumed
its exact original provider/count material across runtime restart, midnight and
a changed tool-description implementation. Independent review reran 97 focused
tests and four recovery probes, including malformed marker and privacy-latch
checks. The entire integrated tree matched the frozen manifest before this
status-only documentation update. Evidence: `/tmp/feast-protocol-managed-final.IRqSb8`.

This approves backend integration only. App-side permission projection, legacy
history compatibility, independent sections and navigation remain below. No live
capability or deployment was activated.

## Continuing implementation, not yet integrated or verified

### Accounting scaling branch: `fix/ask-audit-accounting`

- Historical-scan scaling without skipping records or trusting unverifiable totals.
- Every writer must update validated aggregates, ownership and replay fences.
- Revision-pinned bootstrap/activation and full audit need realistic runtime
  resource checks and resumable staging if one-shot work cannot finish safely.
- Independent review and final combined capability/body-binding gates remain.

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
