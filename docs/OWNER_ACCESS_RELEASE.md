# Owner access candidate — offline only

Baseline: 7605423 / TestFlight 1.1 (8). Local candidate: 1.1 (9), not uploaded. This candidate adds no CloudKit schema,
collection migration, startup cleanup exception, model, accounting or quota change.

## Contract and acceptance matrix

- Existing activation response stays v1 with the exact old fields. The authenticated
  status response adds `role`; missing/invalid owner configuration never promotes a member.
- Owner is only a static `PHONE_INVITATIONS_JSON` grant selected by
  `PHONE_OWNER_GRANT_ID`. No client endpoint can create/promote/transfer an owner.
- Management is `/v1/access/manage`, authenticated by the existing phone bearer.
  A separate phone-access Durable Object reauthenticates and authorizes inside each
  transaction. No management route reaches the AI provider or accounting object.
- List exposes labels, IDs, dates, role and status, never invitation/device hashes.
- Invite creates members only, 24-hour redemption, one device per code. Active
  credentials remain valid until revocation. There is no per-member usage quota.
- Invitations are bearer secrets, not verified email identities or hardware-bound
  invitations. Whoever receives a code first can redeem it. Labels are for recognition.
- The app creates the code, keeps pending work in device-only Keychain before dispatch,
  and sends only its hash. A verified response enables the user-operated share sheet.
  It never emails or sends codes automatically. No server copy of the raw code exists.
- Repeated requests have identical immutable invite ID/label/hash/creator. Revocation
  is monotonic and idempotent. Tombstones stay. Unknown outcomes require exact retry.
  A definitive rejection can be explicitly cleared. After owner replacement, a fresh
  owner-authorized directory is required before discarding the old local pending copy.
- Owner cannot revoke itself in-app. Revocation stops future admission, not a provider
  request already underway. It does not delete collection data or CloudKit sharing.
- Capacity: 256 historical app-issued invitations plus up to 64 configured grants.
  Full history fails closed; no automated deletion/reset or silent reuse.
- UI checks: owner/member distinction, single-use code display only after confirmation,
  duplicate labels distinguished by stable ID/date, dynamic text, meaningful controls.
- No-access card preserves existing opening copy and history, replaces the composer
  with Request access / Enter invitation code. Existing credential + AI consent off
  retains the normal separate consent flow. A service error doesn't remove access.
  Access requests use the existing public support email and a static editable message,
  no saved data, chat, identifiers, codes or credentials. Native Mail/alternate mailto
  require the user to send; failed handoff exposes the email with a Copy action.

Offline verification must cover old-client receipts, owner/member privilege attacks,
revoked/stale owner, static/dynamic collisions, malformed/oversized bodies, durable
restart/retry, creation/revocation/redemption races, pending Keychain faults, owner
replacement preserving members, recovery without erasing ledger/holds, and no AI calls.
Live activation, physical UI, delivery and actual recovery are not claimed by mocks.

## Deployment and private owner bootstrap (approval required)

1. Review candidate code and tests, package exact hashes, and capture current versions
   and configuration. Publish compatible production code with phone access still OFF.
   Keep owner simulator service, accounting namespace, secrets and ledger unchanged.
   Upload a matching signed app through the approved release process only when approved.
2. Obtain per-action consent for Jon's owner credential and the exact device. Create
   one high-entropy invitation privately; publish only its hash and fresh grant UUID,
   createdAt, 24-hour expiresAt, revoked=false into the configured grant list. Set
   PHONE_OWNER_GRANT_ID to that static grant, and PHONE_ACCESS_ENABLED=true. Preserve
   other entries/settings. Never publish a bootstrap invitation in chat, logs, source,
   screenshots, URL parameters or command arguments. User enters the code themselves.
3. Verify free activation/status/list endpoints and owner UI, no paid AI test. Keep
   AI data-sharing consent separate. Each invitation/revocation is a deliberate owner
   action with clear scope. No Juliet/reviewer credential is implied by Jon's bootstrap.
4. Activation sends code, random access/device IDs and device-credential hash to
   Cloudflare. Owner management sends chosen labels and invitation hashes to Cloudflare;
   neither management nor the access-request email uses OpenAI. Add this precise access
   management statement to reviewed privacy disclosures before publication if needed.

## Lost/replaced owner phone

Use existing authenticated Cloudflare administration, never an in-app recovery secret.
With explicit approval create a NEW static owner grant/one-use invitation, revoke the
old owner grant, and change PHONE_OWNER_GRANT_ID together in one reviewed configuration
version. Never modify/reuse old grant identity/hash. Preserve all other static grants,
managed members, revocation tombstones, activation records, namespace and ledger.
The old phone loses owner and AI access; existing members remain authorized. Redeem
on the replacement phone and verify free status/list. The new phone Keychain is separate
and does not sync or restore the old owner credential. Do not change Apple/iCloud identity.
If only owner authority should be suspended immediately, disabling the owner designation
blocks management without deleting members; revoking old grant also denies its AI access.

## Rollback

Prefer leaving this compatible backend and disabling owner management by removing
PHONE_OWNER_GRANT_ID. Disable PHONE_ACCESS_ENABLED only for a deliberate all-phone stop;
owner simulator remains separate. Reverting to the old app retains ordinary member
access, while managed members need this additive backend to authenticate. Do not roll
back backend to old code after issuing dynamic invitations; that would disable them.
Do not reset access records, accounting, CloudKit or device data as rollback.

## Remaining approval gates

Publication/signing/upload/install; real owner bootstrap/configuration and secret
handoff; any invitation/revocation performed by the agent; any paid AI acceptance;
App Review submission. This implementation itself performs none of these actions.

## Offline candidate verification — 5 November 2026

- 186 production and 87 proxy backend tests passed (273 total).
- Real offline workerd/SQLite covered durable restart, owner operations, activation,
  revocation and an unchanged accounting hold, with outbound provider calls forbidden.
- 152 Swift test groups passed, including pending-operation replay, storage failures,
  owner replacement, request-email contents and existing persistence regressions.
- Debug simulator and unsigned Release iPhone builds succeeded as 1.1 (9), bundle
  `com.jongalante.Feast`. No candidate installation or upload was performed.
- Independent security review found no remaining blocker in the reviewed code.

Physical-device Mail/share controls, accessibility and large-text layout, real Keychain
storage, bootstrap and lost-phone recovery remain to be exercised after the relevant
release and credential approvals. Automated tests do not establish those native flows.
