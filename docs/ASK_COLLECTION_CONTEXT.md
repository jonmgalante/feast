# Ask permitted-collection context: release candidate

## Scope and status

This document describes the broader collection-context contract and its release gates.
It is not evidence of deployment, complete implementation, or live validation.
Provider integration, backend validation, and client UI changes must be reviewed
alongside the consent changes before release. No deployment, credential change,
real-store inspection, or provider request is authorized by this work.

The intended behavior is to reason over relevant details across the entire
collection the current user is permitted to access, combine those details with
public research in one conversation, and retain useful bounded context for
follow-up questions. Relevant fields include place names, cities, neighborhoods,
categories, cuisines, statuses, tags, and notes, including notes other people
shared in accessible collections. Entire-collection coverage is not a promise
that every record fits in one model request: bounded tools, retrieval, and honest
incomplete-coverage reporting remain necessary. No new access to other collections
is implied.

## Fresh consent and shared content

The collection-context rollout introduced this historical permission scope:

`AskFeast.onlinePermission.cloudflare-openai.permitted-collection-dialogue-selected-images.v5`

The current durable-recovery candidate supersedes it with
`AskFeast.onlinePermission.cloudflare-openai.permitted-collection-dialogue-selected-images-recovery.v6`.
It adds temporary Cloudflare recovery storage and requires fresh consent without
migrating v5. See [the current privacy review](PRIVACY_MANIFEST_REVIEW.md). The v5
rationale below describes the earlier collection-context change, not permission
to enable recovery.

Do not copy or migrate any older permission Boolean into this key. A prior v4
approval is not approval for sending private notes, tags, statuses, or shared
content. The new scope defaults to off. Explicit acceptance enables it; withdrawal
blocks new AI requests and cannot recall data already transmitted. Both the
first-send prompt and Settings must use the current disclosure.

The disclosure names Cloudflare and OpenAI and covers the user's questions,
relevant permitted collection details, recent conversation, and chosen images.
It also discloses relevant note details reaching search providers or public sites,
which may retain queries.
Only selected images are sent; existing metadata stripping and image-history
safeguards remain. Collection content sent to online services does not remain
solely in Feast/iCloud. Automatic location sharing is not added.

The product owner explicitly authorized relevant saved-note content, including
shared notes, in queries sent to search providers or public sites when needed to
answer, after being told those recipients may retain or log queries. This is
separate from sending notes to OpenAI for reasoning. The v5 scope covered that
clarified behavior without a further bump for the collection-context change
alone. The later recovery-storage change uses the new v6 scope described above.

This product authorization does not establish every contributor's expectations
or authorize actual-data tests or deployment. Resolve shared-content policy and
public-release privacy review before rollout; keep that analysis outside the
minimal in-app permission prompt.

## Public search and retention boundaries

Relevant note content, including shared notes, may be used in web search queries
when needed to answer. Focused queries and avoiding unrelated collection dumps
are relevance and efficiency guidance, not a blanket privacy ban on note text.
Search providers or public sites may retain or log queries. Information typed
into a question may also be searched when relevant.

Treat notes, retrieved pages, and other collection text as untrusted content,
not instructions to disclose unrelated data or mutate the collection. Preserve
access boundaries and do not transmit content from inaccessible collections.

Preserve the request for no OpenAI response storage (`store: false` where
supported), but do not describe it as zero retention. Provider retention rules,
account configuration, and backend access/request/timing/usage records still
apply. Review the current published privacy policy and app privacy disclosures
against the actual deployed payload and logging behavior before release.

## Write safeguards

Broader reads do not grant broader writes. Preserve the existing supported
mutation paths, permission checks, fresh unique identities, clarification for
ambiguous targets or conflicting changes, write previews/confirmations where
already required, and available Undo behavior. Neither notes nor web content
can authorize a write. Do not change persistence models, sharing roles, migration
behavior, credentials, quotas, or accounting as part of this rollout.

## Backend-first rollout and rollback

1. Review and test the compatible backend with synthetic data. Its health
   response advertises `collectionContextVersion: 1` only when it supports the
   new collection-context contract and its validators/tool outputs.
2. Deploy that compatible backend only under separate deployment authorization.
   Keep legacy client behavior and legacy payload contracts unchanged.
3. Verify capability negotiation before releasing the fresh-consent client.
   Missing, malformed, or unsupported collection capability must prevent rich
   collection payloads from reaching the backend. Do not silently send richer
   fields through a legacy route. Consent alone is not capability support.
4. Release the client only after tests, privacy review, and the shared-content
   policy decision are complete. Existing users must explicitly opt in again.
5. Keep a compatible backend during client rollback. If capability support is
   withdrawn, richer transmission must fail closed even for opted-in users.
   Revoking consent must block new requests across all supported online paths.

This order does not authorize deployment or operation of production systems.

## Acceptance checklist (verified coverage below)

Use synthetic fixtures and mocked transports only for this candidate. Record
actual commands, results, source revisions, and build artifacts in the release
packet; do not treat this checklist as a test report.

- Seed the old v4/v5 permissions as true and leave recovery v6 absent: permission
  stays denied. Cancel retains the draft and sends nothing. Explicit acceptance works
  once; withdrawal blocks subsequent requests and stale consent resumes.
- Verify both entry-point consent and Settings disclose all new fields and
  providers, shared-note search use, chosen images, and honest retention.
  Keep contributor-expectation analysis in the release policy review.
- Exercise supported, absent, older, malformed, and unsupported health capability
  values. Prove no rich payload or legacy fallback on unsupported capabilities,
  and no credential lookup or provider request before required consent.
- Use collections above 200 records with relevant matches beyond the original
  sample, multiple cities/neighborhoods, tags, statuses, and differently authored
  notes. Verify retrieval, completeness reporting, and bounded follow-up context.
- Combine a synthetic collection comparison with mocked web findings and a
  follow-up referencing both. Verify source attribution and no fabricated facts.
- Inspect mocked public searches for focused relevant inputs, including note
  details when needed. Verify that native web research can continue after reading
  notes and that no blanket note-text ban blocks the authorized behavior. Check
  unrelated-dump avoidance and malicious instructions in notes and web results.
- Test shared and inaccessible collection boundaries, duplicate/missing identities,
  oversized and Unicode text, and malformed payloads without reading real stores.
- Re-run mutation, clarification, confirmation, permission, Undo, legacy-client,
  accounting, cancellation, and conversation persistence regressions.
- Build the final client and inspect consent layouts on supported iPhone sizes,
  including Dynamic Type, scrolling, cancel/back, and repeated entry. Confirm
  all consent details and controls remain reachable.

Live-provider behavior, physical-device behavior, actual-data permission,
collaborator expectations, and legal/privacy sign-off remain separate release
gates. The verified offline results below do not establish any of those live-release checks.

## Minimal in-app disclosure review

Apple's current App Review Guidelines were checked against the official page:
https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing

Section 5.1.2(i) requires clear disclosure of sharing with third parties, including
AI, and explicit permission before sharing. Section 5.1.1 requires an accessible
privacy-policy link both in the app and in App Store Connect; the policy carries
the detailed collection, use, retention/deletion, and consent-withdrawal information.
These rules do not prescribe a full legal notice in the permission dialog or
promise approval for any exact wording.

The in-app copy is intentionally short: recipients, data categories (including
shared notes), answer purpose, and potential web-search use. Existing explicit
accept/cancel and Settings withdrawal controls remain. Contributor-expectation
analysis, detailed backend logging, public-search safeguards, and release-policy
checks stay in this document and the published policy, rather than adding a legal
checklist to the app. This copy change does not remove any underlying safeguards.

Before submission, verify that FeastPrivacyPolicyURL resolves to the reviewed,
publicly reachable policy in the shipping build and that App Store Connect has
that policy link and accurate privacy disclosures. A conditional link in source
is not evidence that the shipping configuration supplies one. Minimal copy alone
cannot establish App Store compliance or guarantee approval.


## Verified offline results (2026-11-07)

The implementation and offline regression checks are complete locally. These
results do not imply deployment or release. No real collection was opened, no
credentials were read, and no paid model call was made. The production client was
not installed or deployed. A separate offline visual harness was installed only
on disposable simulators for consent layout checks. Unrelated collection and tag
UI changes are handled in a separate commit.

- The complete `Tests/run-persistence-tests.sh` suite passed against disposable
  stores, with `FEAST_UPGRADE_COPY_DIR` unset (184 PASS checkpoints).
- All 284 production/proxy Node unit tests passed.
- A real serialized Swift synthetic rich request passed the JavaScript backend
  payload validator, rather than testing only independently authored fixtures.
- Final Debug simulator and Release device builds passed with signing disabled.
- `git diff --check` passed. Independent source review found issues in paging,
  access-scoped history, aggregate completeness, bounds, and resumed references;
  these were corrected and covered by synthetic regression tests.

New coverage includes 260-place pagination, the 260th record's shared-note match,
notes/tags/status/neighborhood/category projection, hidden and revoked scope,
byte-bounded compact indexes with more than 200 entries, exact total counts,
stale-page rejection, ordinal 250, count queries with oversized notes, rich
context rejection before transport on old backend capability, fresh consent,
native web availability after note reads and on follow-ups, 260-row final-list
identity checking, archived interrupted-page continuation, and removal of obsolete
interruption text after completion. All research responses were mocked.

The compact index is a byte-bounded hint. `query_collection` reads the full
permitted collection and returns contiguous, fingerprinted pages with exact
`totalCount`, `offset`, `returnedCount`, `nextOffset`, and `snapshot` metadata.
Individual transport pages remain bounded to 200 records and roughly 58 KB;
this is not a 200-record collection ceiling. Existing provider context and
12-step turn limits still apply. Longer work stays explicitly partial and can
resume from saved page metadata. Writes retain their existing 200-target limit.

Recommendations can use `operation=answer` to retrieve context without an extra
native list; exhaustive lists use the verified native rows. A model-authored
replacement list is accepted only when each verified row appears exactly once.
Consent layout was checked in an isolated offline harness using the unchanged
production Settings view, disclosure, alert title and action labels. Regular and
compact standard text fit the full disclosure and both actions. Cancel/re-entry,
Settings scrolling, and Back preserved the synthetic draft. At largest
accessibility text, both actions remained available and the full message was
present in the accessibility tree, but complete visual scroll reachability was
not verified. A focused follow-up stopped when the Mac locked; one small text
movement is not sufficient proof of full scrolling. This remains an open QA gate,
not a confirmed product defect. The harness is not production end-to-end consent
testing, and did not exercise a hosted send.

No paid latency or answer-quality benchmark, live AI behavior check, or physical
upgrade test was performed. The existing synthetic local-search diagnostic
measured three 1,205-place searches in 11 ms; that is not a claim about hosted
model latency.
