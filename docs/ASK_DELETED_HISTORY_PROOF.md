# Fresh read proof for deleted-history fragments

This separate follow-on depends on the reviewed lossless journal. It does not
change storage format, retention, actionStatus, replay identity, mutation grants
or Undo authorization. No live store/recovery/release action is part of it.

`recoveryDeletedRecordIDs(forTurn:includingActionIDs:)` keeps its signature.
It first requires the existing exact committed-deletion or undone-creation graph
outcome. Record absence and an applied status alone are never read authority.
Then each removed ID must have current authority for its original parent/store:

- The original store must be known, present, writable and currently recoverable.
- A surviving original city must be unique across stores, currently visible,
  in that exact store and currently mutable. Applicable surviving neighborhood
  ancestry must still have the same city/store and current authority.
- A missing city is not a fallback. The narrow exception is the receipt's own
  whole owned-city deletion or undone-city creation: the removed original root
  must be present in that same-store graph, required original neighborhood
  relationships must close within it, and current city/entity create authority
  must still permit recovery. This keeps legitimate whole-city Undo usable.

Outcome ambiguity grants no IDs. Current permissions filter independent IDs only
after the whole outcome is proved, so revoking one city does not hide another
permitted fragment. Actual fetch/visibility errors throw before a proof returns;
no positive grant is cached. A combined title/detail fragment must satisfy all
of its dependencies in the history consumer.

An empty/denied read-proof result must not delete a receipt or make an applied
state authoritative for reading private details. The history/UI lane separately
keeps a generic non-sensitive receipt and existing Undo affordance, with exact
mutation checks still performed when the user invokes it.

Tests use disposable SQLite collections and the actual engine. They cover live
and restarted revocation, missing/ambiguous/cross-store parents, moved/revoked
neighborhoods, missing/read-only stores, mixed-city fragments, whole-city graphs,
legacy unknown parents/stores, section nullification and Undo-create symmetry.
The prior engine's expected-correct red failures are retained separately from
frozen green results under ignored `Tests/Evidence/deleted-proof/`.

## Frozen verification

- Exact candidate engine SHA-256: `f06c50465e1ec5f95b48081f8ddf467adc0c794fb60b29bc8a3ec2f0dec57d08`.
- Journal source remains `d9d6dec486f4055bccc20177168ffc1ab581d85ad4f4c0d51b32d3546df3f1f8`.
- Expected-correct tests against the pre-patch engine fail on stale authority;
  immutable `red-source` and `red.log` retain that evidence. The initial mixed
  fixture demanded all-or-none permission filtering; the final explicit product
  decision instead preserves independently permitted IDs, and tests require it.
- Final focused run: 50 deleted-read-proof checks (69 PASS lines including the
  common Map lookup prelude), exit 0. Full default: 600 PASS; recovery-compiled:
  601 PASS, both exit 0. Runtime binaries were serialized on the shared local
  test lock, always with `FEAST_UPGRADE_COPY_DIR` unset.
- Unsigned Debug simulator build succeeded against the same frozen source.
  No app was installed. Original journal Release/device gates remain separately
  documented; combined history UI and release acceptance are not implied here.
- Independent collection-actions reviewer approved the exact `f06c5046` source,
  unchanged journal hash, read-proof matrix and red/green evidence. No scoped
  source blocker remained.

Local artifacts (ignored, not committed): `Tests/Evidence/deleted-proof/` contains
`final-source`, `final-source.sha256`, `final-focused.log`, `final-default.log`,
`final-recovery.log` and `final-build-debug.log`. Documentation-only verification
notes were added after that source freeze. These tests use disposable SQLite
stores, synthetic legacy fixtures and no provider or production access.
