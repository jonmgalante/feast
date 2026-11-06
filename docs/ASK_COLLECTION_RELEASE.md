# Ask collection repair — offline candidate

This change removes the 200-place limit from the on-device metadata read and local
evidence index. It changes no persisted collection models, CloudKit sharing,
migrations, credentials, accounting, or model selection. No deployment, upload,
phone operation, paid model call, or real-store test is included in this work.

## Collection and response behavior

- Local queries examine the complete visible collection. Counts and groups retain
  their full membership on device. Aggregate membership has no displayed order;
  a request such as “the second one” requires an actual displayed list.
- Answers still display at most 200 places. Larger lists and details that exceed
  the existing display budget explicitly ask for a narrower request; they do not
  present a prefix as an exhaustive result. Count/group presentation limits remain.
- Missing identities, blank/oversized names, oversized metadata, and every row
  sharing a duplicate UUID are excluded from Ask's usable catalog. Their stored
  rows are unchanged and remain in the raw total. Unverifiable exhaustive queries
  report incomplete coverage. A separately proven city or explicit identity scope
  can still be complete. Duplicate or malformed parent cities are also withheld.
- Public discovery can reach the planner with an incomplete catalog. Public
  context contains only the existing approved name/city/cuisine fields, never
  private filters, notes, tags, statuses, or privately selected membership.
- Mutations still require fresh unique identities. The existing Undo journal limit
  of 1,000 snapshot objects is now checked before preparing a cascade, preventing
  a large city deletion from creating a journal that could not reload safely.

## Wire compatibility and coordinated rollout

`AskSemanticContext.indexComplete` is an optional Boolean. Absence retains the old
meaning, a complete index. The new client omits it for complete catalogs and sends
`false` for bounded or malformed catalogs. The index remains at most 200 records;
its encoding plus recent-question allowance is bounded to approximately 24 KB.
The independently bounded city projection is at most 200 entries and 8 KB.

The proxy library-intent validator and production agent/conversation validators
accept the optional field. All production planning paths pass `catalogComplete`
to the model and instruct it to use local tools for exhaustive results and omitted
records. The older server-side saved-answer synthesis path refuses to synthesize
an exhaustive answer from an incomplete sample. Public aggregate tool results can
carry exact safe-integer counts without transmitting their membership; the
200-record transport and mutation bounds remain in place.

The new optional `AskAgentTask.selectionIDs` is local chat state for aggregate
membership. `externalProjection` always omits it. Older archived chats still load;
rolling back to an older app may require repeating an aggregate query to restore
its follow-up scope.

Deploy the reviewed compatible backend before releasing the new client. An older
backend rejects the added `indexComplete:false` field. Keep the compatible backend
if the client is rolled back. This is an additive code release; do not reset
namespaces, revoke access, renew credentials, change secrets, or alter quotas as
part of this repair.

## Offline acceptance coverage

The invoked synthetic Swift suite covers the 200/201/1,205 boundaries, exact counts,
scoped records outside the uploaded sample, explicit list limits, malformed and
duplicate rows/parents, private-data exclusion, aggregate persistence and restart,
ordinal refusal, and cascade refusal before a journal or collection write. It
also passes an actual generated Swift payload to the local JavaScript validators.
Unicode metadata and long city catalogs exercise byte and UTF-16 limits.

Backend tests cover optional-field compatibility, invalid coverage flags,
UTF-16 boundary checks, duplicate IDs with different letter case, exact aggregates
above 10,000, unchanged record/mutation limits, and refusal of server synthesis
from an incomplete index. The local conversation runtime fixture checks a public
conversation with `indexComplete:false` through the owner RPC and production
worker with mocked outbound service and temporary SQLite accounting.

Final test/build logs and exact source/bundle hashes belong in the reviewed release
packet. These offline checks do not establish live service, physical-device, or
paid-provider behavior.
