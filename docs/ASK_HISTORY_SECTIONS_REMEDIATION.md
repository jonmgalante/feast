# Ask history and independent result sections

This is local source preparation, not release or recovery-activation approval.
The action journal/proof dependency and separately reviewed backend retained-history
negotiation are prerequisites. Navigation/storage overflow is a separate patch.

## Local section authority

- Each native query retains its entity, normalized query identity, snapshot,
  complete query membership, page progress, rendered membership and occurrence
  order. Only consecutive pages of the same query and snapshot concatenate.
- Query membership is unique. Display occurrences may repeat a place across
  cuisines. Supplemental findings and prose mentions are separate from both.
  The existing 2,400 native-row boundary is not charged for bounded extra mentions.
- Independent lists remain separate visible sections through Session, archives
  and recovery. Interleaved pages stay contiguous beneath their own heading, and
  replacing one section's first page preserves other sections in their original order. Count/detail/Maps support does not erase earlier native lists.
  Internal answer reads do not manufacture a visible native list.
- Multiple visible sections do not share one ordinal order. Model-supplied UUIDs,
  names, section numbers or replacement-list metadata do not resolve an ambiguous
  human reference. A current explicit name remains independently selectable.
- A literal current-user `Section N` may select the exact numbered section in the
  immediately preceding completed collection answer. Its archived complete
  membership and occurrence order travel together. Conflicting, negated,
  out-of-range and older-answer references require clarification. Missing/revoked
  members never shift an ordinal to a different place. Hidden section headings
  retain their original number with a generic unavailable-details label; surviving
  sections never slide into that number. The shortcut accepts one bounded literal
  current-target command (for example `Show the first place in Section 2` or
  `Mark the first place in Section 1 Love`), optionally qualified by the current,
  latest or last answer. Unrecognized source clauses require clarification, not
  a guess from a temporal-word blacklist. A quoted span containing a Section N reference cannot be
  silently erased to select another unquoted section; such mixed references
  clarify. Ordinary quoted note values and independently named businesses retain
  their separate scoped paths. Successful changes
  invalidate earlier native snapshots in direct, conversational and pending-confirmation
  paths; no-op changes do not destroy valid reads. An internal answer query retains
  its membership when the visible list is replaced by equivalent synthesis, without
  becoming a displayed section or gaining ordinal authority.
- Reference words that happen to be saved names (for example First, Those, All,
  Section 1, Those Cafes or All Cafes) do not override ambiguous human grammar. Explicit quoted/named
  targets still work, as do ordinary names such as First Watch and explicit
  plural category scopes such as all cafes.
- Section/provenance metadata stays local. It is not a new model target grant,
  catalog upload or permission to use private fields in public research.

## History privacy and access

New answers retain local dependencies per native paragraph. Model synthesis and
auxiliary research, findings, Maps choices and action details conservatively keep
their originating dependencies. Independent human preferences and permitted
native fragments survive unrelated removal or permission revocation. Projection
happens before provider/executor construction, and access is rechecked before
later provider steps, after awaited replies, and immediately before contextual
transport or Maps dispatch. A separate approved-public history projection protects
older v6 conversation endpoints without promoting rich local text or changing their wire schema. A revoked dependency cannot escape through side channels.

UI, Copy and sources use a freshly permission-filtered presentation. One access
snapshot is used per whole-history projection, not one collection fetch per turn.
History rows receive only display values with fresh permission-filtered previews;
visual labels, accessibility and Rename use the same safe display title. The
existing original-archive automatic/manual title classification, title generation
and manual names are unchanged. An automatic title and human-question fallback
are hidden when their legacy source request is denied by fresh provenance, even
if an old archive omitted its private-selection flag. No first-request-title
feature is included.
The stored archive is not rewritten or truncated by redaction. A generic action
receipt/Undo affordance may remain without its old title, detail, question or
values. Showing deleted before-images requires the journal's fresh exact-outcome
and current original-store/parent authority proof, never merely `applied` status.

Legacy archives lack per-fragment proof. Their approved projection remains under
conservative whole-history dependencies for private/rich material. Raw legacy
paragraphs are not promoted to outbound-safe text.

### Auxiliary context and retry boundaries

Retained Maps choices, research, pending reviews, findings and public references
carry the dependencies of their originating response. Only keys for items still
present after filtering participate in fresh access checks. A public result does
not become independent merely because its destination is public. Those checks
also run between steps and when accepted recovery state is restored, including
when the source record is outside the bounded prompt catalog.

The initial history suffix and `read_conversation` use one indexed projection.
Bounded, explicitly labeled auxiliary-data chunks use spare indexed assistant
entries first, leaving every prior answer prefix untouched. At the 200-message
boundary, only auxiliary overflow is combined in the last added entry. A legacy
checkpoint already containing 200 messages retains overflow after its last
assistant message instead of removing a turn. Marker-absent clients explicitly
report any unreachable excerpt remainder rather than false completeness;
negotiated clients can page the retained text. Original answer and auxiliary
bytes remain local. The 200-message and 2,000-unit wire limits stay unchanged. Captured
actual HostedProvider direct, legacy-v9, and durable request bodies are checked
by the real backend validators in the offline Swift suite.

Compact retry checkpoints preserve originating dependencies before the next
provider step. Pre-upgrade compact checkpoints lacking that proof remain on
disk but cannot provide outbound auxiliary data, even when their surviving task
membership is empty. Redaction does not erase the checkpoint. Session's existing
injectable attempt store is propagated through provider work, ensuring retries,
read checkpoints and transport registration use the same persistence boundary.

## Bounded retained text and compatibility

Initial model history is bounded and explicitly labeled as an excerpt. A negotiated
`retainedHistoryVersion: 1` enables `read_conversation` paging with UTF-16 offsets.
Offsets advance at actual Unicode scalar boundaries, including very long combining
sequences. Old endpoints keep their old schema and cannot be given a false paging
promise. Direct and durable modes negotiate independently; a recovery checkpoint
pins the accepted capability instead of changing it on resume.

The exact combined index is frozen in the loop's request before dispatch and
kept unchanged on accepted recovery. Only that checkpoint request stores full
retained history. Redundant user
and executor request copies omit it, preserving the existing 16 MiB checkpoint
and 8 MiB executor-snapshot limits. A real archived history above 7 MiB is used to
exercise lost-ack restart and tail retrieval without re-submitting accepted work.

Legacy compatibility has two deliberately different outcomes:

1. An old full `publicConversationText` is an explicitly approved projection.
   Its exact retained text can be paged without clipping it a second time.
2. The old collection writer already clipped `collectionConversationText` to
   1,700 UTF-16 units. Missing provenance is not permission to upload other raw
   local paragraphs. Retrieval explicitly reports that limitation and does not
   report the omitted historical content as complete. The original local answer
   stays unchanged. Fresh authorized reads can inspect current saved information,
   but cannot pretend to reconstruct the omitted past answer.

## Offline regression evidence

Expected-correct tests cover actual Session/Loop/executor and archive/reload paths,
not only helper outputs: disjoint lists, mixed supporting output, independent
205-row pagination, repeated section labels, named/scoped/ambiguous writes,
wrong-target proposals, revoked/missing members, grouped occurrence recovery,
extra mentions, own deletion/Undo versus revoked parent access, fragment and
auxiliary-channel privacy, bounded tail retrieval, Unicode offsets and near-limit
recovery. Default and recovery-compiled full-suite acceptance must be collected
from the exact frozen source before integration.

The two `Tests/Fixtures/AskLegacy*History.json` files were serialized by the actual
old Session/Loop implementation using a disposable SQLite collection and mocked
transport. They contain synthetic data only. The old writer's Loop SHA-256 was
`73284a3cc2bf795d5d784047d2fe97caf1231f0c45d5a79fcbdcb1bb2354bf12`.
The public fixture retains 2,046 characters; the rich fixture retains 1,700 in its
approved history projection while retaining its original local paragraph.

No live provider, user library, credentials, deployment, configuration, recovery
flag, TestFlight or on-device operation is part of these tests. Physical-device
lifecycle, real CloudKit revocation and combined integration remain separate gates.

## Follow-up: local History titles and Ask appearance (2026-11-11)

The earlier History paragraph describes the prior privacy-remediation baseline.
This follow-up adds local first-request display titles and a scoped appearance
update; it does not change provider prompts, generate summaries, or add network
work.

- History uses the first request from its fresh permission-filtered local
  projection, collapses whitespace, and truncates at a word boundary within the
  existing compact-title budget. Rows show at most two title lines. Empty chats
  retain their existing fallback. A preview is hidden only when it exactly equals
  the displayed title; longer/different previews and useful status text remain.
- Row labels, accessibility and Rename use the same safe display title. The
  existing one-access-snapshot and verified deleted-record proof are retained.
  History additionally rejects a private-selection request with a revoked
  dependency even if an older response carries an independent-question marker.
  Public independent requests and other transcript projections are unchanged.
- Explicit Rename now persists an optional `hasCustomTitle` marker through
  canonical/pending storage, subsequent sends, recovery and Clear. This preserves
  deliberate names such as `New chat` or a name equal to the first request.
  Absence remains backward-compatible: older archives still use the existing
  title heuristic. An old deliberate name identical to an automatic title cannot
  be distinguished retrospectively without provenance that was never stored.
  No archive rewrite, history reorder or truncation is performed for display.
- History, Settings (`AskPrivacyView`), activation/access, and owner Manage Access
  use the existing adaptive Feast surface, text, divider and utility tokens plus
  rounded typography. Utility actions are blue slate in light appearance and
  the existing adaptive stone in dark appearance. Native disabled controls,
  active toggle state and destructive red Revoke remain distinct. Authorization,
  action closures, links, tasks and navigation behavior are unchanged.

Validation of the final product/test source passed:

- Full synthetic persistence suites in default and recovery-enabled builds, plus
  the focused existing whole-library History privacy regression. The runner used
  the repository's compiler/source list, retained disposable artifacts and ran
  the focused case before the complete suite. Full runs had no real-store input
  or test-selection environment override.
- Added title tests cover local/public requests, whitespace and Unicode,
  word-boundary truncation, empty/draft chats, exact duplicate versus longer
  previews, useful statuses, permission refresh/revocation and legacy provenance,
  accessibility, and read-only archive/order preservation. Manual-title tests
  include Rename to `New chat` and the exact first request, later sends/relaunch,
  denied access, pending/canonical round trips, and Clear/relaunch/send. Existing
  interrupted-Clear and pending-store fault tests also assert the manual marker.
- Backend suite: 436 passed, zero failures. Backend source is unchanged.
- Debug iOS-simulator and unsigned Release iPhoneOS builds succeeded. The
  repository's actual Release-app first-send harness passed its offline, answer,
  and 2,000-synthetic-place cases using its injected local transport.
- Synthetic iPhone 17 Pro / iOS 26.1 screenshots were inspected in light/dark and
  normal/accessibility3 text sizes, including Settings, inactive access, owner
  access, and Manage Access. The large-text fixture applies its environment
  inside presented sheets as well as standalone roots. Native control colors,
  disabled Activate/Create invitation, active toggle, red Revoke, wrapping and
  two-line History titles were checked.
- Interactive synthetic checks passed History → Settings → Back; Rename Cancel;
  Delete confirmation dismissal with all four rows/order retained; History →
  Access → Close; and owner Access → Manage → Revoke confirmation dismissal →
  Back, with the synthetic member still Active. No destructive change was
  confirmed. `git diff --check` passed.

These are local synthetic checks, not physical-device, VoiceOver interaction,
live account/activation, real CloudKit revocation, deployment or TestFlight
verification. Live service configuration was stripped from UI and Release-smoke
fixtures; the real collection and unrelated simulator data were not used.
