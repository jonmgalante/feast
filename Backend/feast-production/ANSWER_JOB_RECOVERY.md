# Ask Feast durable native steps (candidate, disabled)

This is an additive transport for ordinary native protocol 10 steps. The existing
`/v1/answer` endpoint, model selection, medium reasoning, instructions, tools,
provider body, privacy latch, 12-response/web-action limits, and sponsor accounting
remain in place. Historical Astra continuations remain Astra; ordinary new turns
retain the existing active Sol model. No production deployment, feature activation,
credential access, or paid/live provider testing was performed for this change.

## Wire contract

All operations use authenticated `POST /v1/answer-jobs`, content type
`application/json`, and `X-Feast-Agent-Protocol: 10`.

- Submit: `{version:1, op:"submit", request:<unchanged native v10 request>}`.
- Read, Stop, acknowledge: `{version:1, op:"status"|"cancel"|"ack", requestID, step}`.
- Response: `{version:1, requestID, step, state, expiresAt, result?, error?, retryAfterMs?}`.
- States: `queued`, `running`, `completed`, `failed`, `uncertain`, `cancelled`,
  `expired`, `acknowledged`. `result` is the ordinary v10 result with `budget`
  removed. `expiresAt` is Unix milliseconds. Early pending responses use a
  1,500 ms retry delay; a pending reply after a fully elapsed 20-second long-poll
  allows renewal after 100 ms. This avoids adding another polling interval to a
  long-running step while retaining backoff for early failures/notifications.

The key is authenticated grant identity + canonical request UUID + step. The
server hashes canonical JSON of the entire submitted payload, including local
result, continuation, turn, and web permission. Object-key ordering does not
change identity. Reusing a key with different content returns 409. Clients must
retain and resend the exact payload; they must not regenerate IDs, switch to
`/v1/answer`, or create a fresh request after an ambiguous submit.

Acceptance stores the payload, job and alarm in one SQLite transaction before
acknowledgment. Paid execution occurs only in the Durable Object alarm handler,
not HTTP or `waitUntil`. Submit/status can wait up to 20 seconds for that same
job and return as soon as it completes, avoiding a compulsory polling interval
on fast steps. Stop/ack do not wait for provider completion. A disconnected HTTP
request cannot cancel the alarm job. Concurrent/repeated alarms share one runner;
a persisted dispatch marker prevents redispatch after isolate loss.

## Interruption and side-effect matrix

| Interruption point | Recovery behavior |
| --- | --- |
| Before accepted transaction | Resubmit the identical key/payload. |
| Accepted, acknowledgment lost | Same key returns existing job; alarm runs it. |
| Input counting | May repeat this non-generation preflight; no paid generation exists. |
| Reservation RPC reply lost | Recover the identical recovery-keyed reservation; do not reserve twice. |
| Reserved, not dispatched | Continue once if still authorized; Stop/revocation releases only this undispatched hold. |
| Dispatched, no durable provider receipt | Terminal `uncertain`; keep accounting exposure. Never automatically replay the provider call. |
| Provider receipt persisted, not projected | Decode the stored receipt using the shared pure decoder; no provider transport. |
| Result + bill persisted, settlement reply lost | Retry identical ledger settlement idempotently; counters/usage increment once. |
| Completed, HTTP result lost | Retrieve the stored result without model work. |
| Stop before delayed submit | Cancellation tombstone rejects late work. |
| Stop during provider call | Hide the late result, close the root, and settle known usage; cannot undo provider charges. |
| Client local tool pending/unknown | Client rechecks current collection permission, identity and revision; an ambiguous mutation/authorization must safe-stop rather than replay. |
| Final delivery/ack lost | Repeated reads and ack are safe; client applies each step once. |

This server does not make the existing v9 authorization route durable and does
not authorize collection changes. It neither schedules phone tools nor turns a
recovered proposal into permission to edit. Client journal, consent, Stop,
generation fencing, local side-effect receipts and checkpoint cleanup remain
required. A new unrelated user question must not resume an older job.

## Authorization, retention and accounting

- Public submit/status/cancel/ack authenticate the current phone grant. The DO
  authenticates again and rechecks before dispatch and after foreground waiting
  before delivering content. Revocation blocks retrieval and new dispatch.
- Only a one-way credential hash is stored; bearer tokens and provider keys are
  not persisted. Jobs are grant-scoped. No payloads, responses or secrets are
  logged. Sponsor totals and other devices' holds never appear in job results.
- Prompt/request and raw provider receipt are removed on successful settlement;
  the delivered result is retained for at most 24 hours from acceptance, or
  removed earlier on ack/Stop. Every content read enforces expiry, and alarms
  clean up without waiting for a client. Platform/storage outages can delay
  physical deletion until execution/storage returns; expired content is not
  deliverable.
- At expiry/Stop, cleanup runs **before** ledger/fence RPCs. A pending received
  receipt becomes a compact verified usage bill (or uncertainty), then all user
  content is erased even if accounting is offline. Necessary small settlement
  metadata remains until accounting recovers. Do not delete unresolved bills.
- Compact job tombstones remain seven days from acceptance. Before pruning,
  the existing accounting ledger permanently closes the root. If that RPC is
  unavailable, keep the small tombstone and retry. Pruning cannot make an expired
  or acknowledged key payable again. Ledger charge records/root fences remain
  under the existing accounting retention policy, not the content TTL.
- Limits per grant: 4 active jobs, 64 content-bearing jobs and 1,024 compact jobs.
  Request size is 512,000 bytes; each stored content item is at most 600,000 bytes,
  chunked below the DO per-value limit. Provider receipts retain the existing
  65,536-byte bound; delivered native results retain the 400,000-byte bound.
  Capacity returns 429 rather than silently discarding deduplication evidence.
- Known provider usage is saved before settlement. Settlement keys include the
  exact operation/bill/frame digest; conflicts cannot mutate an existing charge.
  Unknown dispatch retains exposure and blocks same-turn attempts. There is no
  automated reconciliation or refund claim.
- Normal successful responses retain the final content-free performance
  counters/stages. A receipt recovered after a crash contains only measurements
  still durably available, not reconstructed provider/ledger timings. Compare
  foreground wall time and recovery wall time separately; do not claim an
  unmeasured latency improvement or compare partial timings as equivalent.

## Staged rollout and rollback

1. Review the code and run offline tests below. Deploying or activating requires
   separate authorization. The checked-in Wrangler file is a disabled scaffold,
   not a complete representation of current live configuration.
2. When deployment is separately approved, add SQLite DO class `AnswerJobs` with
   migration `answer-jobs-v1` and binding `ANSWER_JOBS`. Keep
   `ASK_FEAST_RECOVERY_ENABLED=false`. Preserve the existing ledger class,
   namespace, keys, migrations, secrets and live settings.
3. The client candidate uses a recovery-inclusive v6 permission scope and one
   added storage sentence in the existing consent UI. Do not migrate v5 grants.
   Before enabling, publish the matching policy update and reconcile App Store
   Connect disclosures with `docs/PRIVACY_MANIFEST_REVIEW.md`, including the new
   Performance Data declaration. Verify the shipped app asks for fresh consent.
   Check checkpoint protection and temporary-copy cleanup at the documented boundaries.
   ACK removes the server step copy; local checkpoints remain until turn/archive
   completion, and the mutation journal preserves Undo. Do not infer consent from
   a server capability or an older request.
4. Verify physical-iPhone lock, app background/termination, network switching,
   airplane mode, repeated Resume, Stop while waiting, fresh prompts, permission
   revocation, local mutation ambiguity, and collection revision changes. Run
   authorized foreground/recovery latency and answer-quality comparisons before
   broader activation. Offline tests do not prove actual provider reliability,
   background iOS behavior or live end-to-end speed.
5. Enable only when both app opt-in and the backend feature are ready. `/health`
   advertises `answerJobsVersion:1` only with the new flag/binding and all current
   native execution gates. Existing clients continue using `/v1/answer`.
6. Roll back by setting `ASK_FEAST_RECOVERY_ENABLED=false`; this stops new jobs
   and new dispatch. Preserve the class/binding, alarm code, current phone auth,
   and accounting availability so existing jobs can be read/cancelled/acked,
   already-paid receipts can settle, and cleanup can run. Never remove the DO
   migration/data or fall back to a fresh paid request for an unresolved job.
   Other native/live gates may also disable new execution; the pure saved-receipt
   decoder still performs no provider requests. If accounting is disabled,
   content cleanup continues and compact settlement/fence intents wait safely.

## Offline checks

From the repository root:

```sh
node --test Backend/feast-proxy/*.test.mjs Backend/feast-production/*.test.mjs
node Backend/feast-production/answer-jobs.runtime.mjs
git diff --check
```

The runtime test uses installed esbuild/Miniflare, temporary SQLite files and a
mock-only outbound service. It restarts workerd after durable acceptance and
before dispatch, verifies alarm-only execution/result replay, and exercises the
normal foreground wait path without an imposed polling delay. It makes zero
live provider calls. Unit tests inject crashes/lost RPC replies at reservation,
dispatch, receipt and settlement boundaries and cover cancellation, expiry during
accounting rollback, revocation, canonical payload conflicts, bounded storage,
provider-body parity and accounting idempotency. Physical-device and paid/live
benchmarks remain unperformed.
