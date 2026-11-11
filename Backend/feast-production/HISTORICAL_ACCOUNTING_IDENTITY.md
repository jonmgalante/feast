# Historical direct accounting identities

This is a separate compatibility correction after the scoped indexed-accounting
milestone (`79d6583`), not permission to deploy or activate either one. All work
and fixtures are offline. No live history is assumed to contain only UUIDs.

## Authentic producer boundary

The initial V1 producer (`984b56c0`) and audited `41229ac` accept exactly 36 ASCII
letters/digits/hyphens, case-insensitively, in `/reserve`. The initial reconciled
V2 producer (`d6d03f7`) and audited source accept exactly 36 hex letters/digits/
hyphens for direct profiles. Neither regex requires UUID hyphen positions. Both
validate and persist owner and fingerprint digests and preserve request-ID case
in the physical storage key. Their actual reserve/settlement routes can produce
valid charged rows such as `z` repeated 36 times (V1), `a` repeated 36 times (V2),
or different arrangements of 32 hex characters and four hyphens.

Earlier lifecycle inventory rejected such legitimate records before an index
could be prepared. The fix reads the original accepted domain. It does not
change admission, rename a key, merge reservations, reprice a profile, invent
usage, expire an unknown hold, or skip a historical record.

`historical-accounting-identity.mjs` accepts a non-UUID physical ID only when:

- It satisfies that physical namespace's exact historical direct grammar.
- Owner and fingerprint digests are valid.
- V1 has no profile field, as in its real producer. V2 explicitly uses `saved`,
  historical `public`, or a known `PUBLIC_PROFILES` profile. Native and staged
  profiles are never inferred to be direct merely because linkage is absent.
- `executionVersion`, `rootRequestID`, `nativeTurnID`, and `stageIndex` are truly
  absent via `Object.hasOwn`. Null or undefined properties do not count as absent.
- Existing complete accounting validation still accepts the hold, state, usage,
  profile and immutable migration evidence. Pending/uncertain records still need
  explicit reviewed classification; the original full exposure is retained.

Classified sidecars also remain bound to the exact physical request-key suffix,
the canonical root (or that suffix), and the canonical native turn (or null).
Changing sidecar request/root together or inventing a native turn cannot pass
full preparation or audit. No canonical data is rewritten by these checks.

UUID-shaped historical records retain their previous validation path. New
native, staged and lifecycle-managed direct requests remain UUID-strict. No
legacy reservation receives managed dispatch authority through this reader.
The original retry-fence endpoint also accepted standalone hex/hyphen36 roots;
those existing fences are preserved without inventing reservations or charges.

## Physical identity versus ownership aliasing

Canonical record proofs hash the **exact physical storage key**, including case.
Every physical record independently contributes its original hold/charge and
keeps its own settlement/replay identity. Two case variants are not one request.

Only the secondary ownership aggregate groups lowercased root aliases. This
preserves the pre-existing full-scan `attemptOwnershipBatch` contract: it compares
lowercased physical/root IDs but pushes every matching accounting row, and rejects
conflicting owners. Grouping does not supply reservation or settlement authority.

Owner proof paths encode every lowercase ASCII character as one two-digit hex
byte: 36 characters become 72 hex digits. Different hyphen positions therefore
remain distinct; UUID-style hyphen stripping would be unsafe for the old direct
domain. Case aliases intentionally share an ownership node whose link/record/
unsettled counts include all physical members. Exact record proofs and native
turn proofs remain 64-hex SHA-256 paths. All root-node, branch, DFS and frame
bounds use the revised 72-character limit; the depth-bounded stack remains safe.

## Versioned offline plan boundary

The source policy is `feast-index-staged-v2`, binding the explicit
`lowercase-ascii36-v1` encoding. Old UUID-stripping plans cannot begin or resume
under this policy. An old non-authoritative stage remains inert and is never
reinterpreted. A separately prepared/reviewed current-policy plan can supersede
an explicitly stale stage; its old scope is retained and all canonical history
is rescanned. A competing valid current-policy plan cannot replace a live stage,
and malformed stage metadata still fails closed.

This work has not deployed or activated an index. A prior active index using a
different policy is **not** silently upgraded or read with the new encoding.
Pre-deployment inventory must verify the actual marker/policy and stop for a
separately reviewed upgrade if such authority exists. Turning a flag OFF is not
proof of absence and never enables an old-writer fallback or index reset.

## Regression evidence

Tests archive and execute the authentic `41229ac` ledger producers against
isolated transactional storage. Simultaneous normal-UUID, uppercase, trailing-
hyphen and leading-hyphen records retain four physical rows, four independent
bills, all historical holds, unchanged replay outcomes and owner counts 2/1/1.
Additional letter-only, all-digit and all-hyphen historical IDs are covered.
Cross-namespace/case owner conflicts reject without overwriting either record.

The matrix includes pending and uncertainty holds, known rejection and V2
undispatched cancellation, retained-active late settlement, original inflight
bytes, every historical direct profile, null/undefined linkage, missing owner/
fingerprint, disguised native/stage profiles, strict new managed admission,
standalone original retry fences, and old-policy plan/stage rejection. The
initial positive compatibility tests reproduced the old inventory restriction;
the new version/staging tests specify the new reviewed plan contract. They are
not all separate pre-existing production incidents. No provider call occurs.
