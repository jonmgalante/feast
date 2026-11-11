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

## Reviewed journal error truthfulness correction

Integrated as `d866f5ad8ba6bd5733fc37108bf6e6c9c79bae73`. The generic journal
failure no longer says "Nothing was changed" when a busy or corrupt journal
prevents verifying an already committed action. It asks the user to check the
collection before retrying. This changes one production sentence only; storage,
locking, mutation, permissions, Undo and recovery behavior are unchanged.

The unchanged expected-correct tests first produced 31 wording/propagation
failures, including an actual second process holding the lock after the collection
save. The corrected immutable source passed 354 focused default-mode checkpoints,
exit 0, including prior receipt/value preservation and `AskSession` propagation.
Independent exact-source/evidence review passed. Evidence is
`/tmp/feast-journal-error-green.72HSUA`; the journal store hash remains `d9d6dec4`.
Full combined default/recovery gates still follow the remaining work below.

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

## Reviewed local file-metadata privacy declaration

Integrated as `42271976fefc9fa4d2a47781d9b19fea1e6ddbaa`. Existing history migration
and journal backup verification already read file modification metadata inside
Application Support. Apple classifies that API under FileTimestamp; the narrowly
applicable app-container reason C617.1 was missing. The pending navigation
candidate's descriptor-based size/type reads use the same category.

Only that manifest block was added. All prior API and collected-data declarations
remain unchanged, with no new runtime read, collection, tracking or permission.
The strict checker first rejected the old manifest, then passed with 18 negative
fixtures. An unsigned Debug build and exact bundled-manifest parity passed.
Independent review reran the checker, original rejection and bundle comparison,
and verified the official API documentation and exact source snapshot. Evidence
is `/tmp/feast-file-metadata-privacy.erBewu`; Release/recovery bundle parity still
belongs to the final combined gate. See `PRIVACY_MANIFEST_REVIEW.md`.

## Reviewed bounded accounting index

Integrated as `95311f6bfedfd60be0cc616e789f509b56bce90c` (source
`79d658373745c31c6f24769ecd142ead47146160`). The 17-file index-only commit preserves
the accepted history protocol and exact-material recovery. Every official writer
maintains the revision-pinned canonical index; preparation uses a complete immutable
snapshot, followed by bounded scan/build and all-node verification before atomic
activation. Partial stages are never authoritative, corrupt active indexes never
fall back to an incomplete scan, and no-op replays leave whole stored maps unchanged.

The corrected standalone freeze passed 416 Node tests, 65/27 Python tests, four
mock-only SQLite/workerd lifecycle/recovery runtimes and two resource-bound runs.
Independent review passed 26 focused tests, accounting/claim race probes and the
original count/ack tamper probes with clean positive controls. All 17 committed
files matched the reviewed source manifest before and after integration.

The immutable **combined index + retained-history protocol** gate at `95311f6`
then passed 423 Node tests, 65/27 Python tests and all six mocked runtimes, with
all source hashes unchanged. Its 10,000-row build used 846 resumable steps, at most
269 ms per measured step, 2,641,007 bytes read, 2,660,506 bytes written and 767 value
operations. The near-128-KiB-row case also passed. These are local observations,
not a production latency guarantee. Evidence:
`/tmp/feast-index-protocol-integration.bdwOeG`.

Bounded hot paths rely on validated official-writer maintenance and touched-record
proofs. Arbitrary untouched/out-of-band corruption requires the independent full
immutable audit; hashes do not prove operational inventory completeness or writer
quiescence. See `Backend/feast-production/ACCOUNTING_INDEX.md`.

The separate historical direct-ID correction below closes the identity boundary
found during index review. No live index, migration, ledger or provider was used
or activated.

## Reviewed historical direct accounting compatibility

Integrated as `f6a100ac3bb4ceaae037758bb5af1cc4fe9c6f00` (source
`57350b715bdeee048d08a24519108a216164f950`). Authentic old V1/V2 direct producers
accepted 36-character IDs outside strict UUID syntax. The compatibility reader
recognizes only their exact historical grammar, profiles, owner/fingerprint and
truly absent managed linkage. Current native/staged/managed admission remains
strict; canonical physical keys, per-record holds, charges and exact-key replay
are never merged or rewritten. Only the secondary ownership index groups case
aliases, using 72-hex ASCII paths that preserve distinct hyphen positions.

The versioned offline policy rejects stale plans and refuses reinterpretation of
an already active incompatible index, even with flags OFF. Complete inventory,
writer quiescence and source-deployment preflight remain operational requirements,
not facts established by local hashes. See
`Backend/feast-production/HISTORICAL_ACCOUNTING_IDENTITY.md`.

All eight committed files matched the independently reviewed freeze. Standalone
verification passed 429 Node tests, 65/27 Python tests, four mock-only lifecycle/
recovery runtimes and both resource-bound runs. Independent review passed 39
focused tests and additional physical-case, ownership, sidecar and active-policy
probes. Evidence: `/tmp/feast-legacy-id-freeze-UNPfN5`.

The first combined gate passed 435/436 Node tests. The remaining old Stop race
oracle inferred authenticated response completion from 15 event-loop turns.
Controlled authentication delay and parallel traces reproduced false failures
before the local transaction, or after cancellation was already committed. This
was a test synchronization defect, not a reproduced production lock regression.
A separately reviewed one-hunk test correction, integrated as `8e63a14` (source
`d6357f6`), requires actual Stop/status completion, persisted cancellation and zero
provider/count calls while the unrelated RPC is still held. Its deadlock guard
fails when the original transaction-lock defect is deliberately reintroduced.
No production code changed in that correction; the original failed log remains.

The immutable combined **protocol + lifecycle + index + legacy compatibility**
gate at `8e63a147154a7585f7c9a4ed91b7815ae1454784` then passed **436 Node tests,
65/27 Python tests and all six mocked SQLite/workerd runtime/resource gates**,
with source hashes unchanged. The 10,000-row run used 934 resumable steps, at most
111 ms per measured step, 1,570,601 bytes read, 1,594,840 bytes written and 982 value
operations. The near-128-KiB-row case passed too. These are local measurements,
not a production latency guarantee. Evidence:
`/tmp/feast-legacy-protocol-final-fdmrf43l`. No service, data, flag or deployment
was changed.

## Continuing implementation, not yet integrated or verified

### Answer/history branch: `fix/ask-audit-answers`

- Retain independent native list sections with separate query/page/membership and
  occurrence provenance. Do not merge unrelated lists into the last query scope.
- Preserve unaffected dialogue when one saved reference becomes inaccessible;
  never return revoked/private content through remaining fragments.
- Make retained long-answer tails retrievable through bounded, truthful context.

### History navigation branch: `fix/ask-audit-navigation`

- Permit non-destructive navigation when current in-memory history cannot save,
  preserving the full chat and draft rather than silently dropping/truncating them.
- One authoritative pending library, exact-revision reconciliation and explicit
  Clear/Delete recovery barriers remain under implementation review and fault tests.
- The pending materialized library has an explicit 16 MiB total resource budget.
  Above that budget or on actual storage failure, exact RAM navigation remains
  available with a persistent unsaved warning, not a restart-durability promise.
  Existing canonical limits remain unchanged; no automatic deletion or truncation.

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
