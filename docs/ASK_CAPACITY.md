# Ask Feast bounded large-query update

## Scope

The existing ordinary direct native conversation path has one fixed expanded capacity contract. There are no user-selectable capacity modes or general old-version capacity profiles. The app and service must be released together. Legacy protocols, validation pilots, and already-created recovery jobs retain their independent historical limits.

| Limit | Ordinary direct native path |
| --- | ---: |
| Counted model input, each response | 98,304 tokens |
| Decoded continuation | 786,432 bytes |
| Encoded continuation | 1,048,576 bytes |
| Request and reply | 2,097,152 bytes each |
| Successful provider response decoder | 1,048,576 bytes |
| Local per-turn retry context | 8,388,608 bytes |

The active model/reasoning, 8,192-token output allowance, 12-response/web-action limits, 200-record pages and mutation targets, evidence/source constraints, existing timeouts, archive limits, permissions, sharing, conflict checks, and Undo are unchanged. Saved collection models and data are not migrated or rewritten. Recovery remains disabled.

## Read-query support

A health-advertised `collectionQueryVersion: 2` marker enables only the new query semantics. It is not a capacity selection. The app captures native transport and query support together before constructing the local executor and model loop. The native request fingerprint binds the marker for the whole attempt. Old services receive no unsupported marker; requests without it and recovery jobs keep the earlier query schema. A dormant local recovery store does not disable query support when the actual route is direct.

- An explicit nonempty field selection returns only the requested optional fields, retaining mandatory identity fields. Empty selections preserve the established operation-specific defaults; selecting only `name` requests identity-only rows. A requested missing value is JSON `null`; an unrequested field is omitted. Unsupported or unavailable fields are not represented as known missing.
- `fieldPresence` is a typed, read-only predicate for stored `instagram` or `website`. `missing` means nil or whitespace-only; a malformed but nonblank saved URL is still `present`. It does not claim public availability, reachability, or URL validity.
- Filtering precedes totals/pagination. Displayed ordinal selection remains anchored to the original ordered IDs, not re-numbered after the new filter.
- Snapshot fingerprints bind the query, membership, order, requested values, and relevant raw filter values. Changed data or a changed query cannot silently append an incompatible page.
- Neither the marker nor a filter grants write authority or expands mutation limits.

## Failure and storage safety

Accumulated frame size and item count are checked after adding a local tool result, before another count/reservation/generation, and again after provider output. Deterministic capacity stops are not service outages and do not suggest an identical retry. If earlier results exist, an always-visible unfinished-answer explanation precedes them. Applied edit receipts and Undo survive.

Historical accounting rates and estimate profiles are unchanged. Known usage is settled even when output cannot be retained; an oversized/unreadable provider response after dispatch remains uncertain and fenced against blind replay. The expanded ceilings are not a dollar-spending cap.

Retry contexts use bounded durable writes and protected, backup-excluded files. Bulky duplicate context may be released only after a verified archive save covering it, or explicit chat deletion. Small attempt identities, roots, and unresolved safety state remain. Late callbacks cannot restore deleted context. Archive save failures preserve retry context.

## Verification and rollout

Run the full offline suites and both unsigned app builds from README. Synthetic cases must cover the 157-place collection with exactly 41 missing Instagram values, the displayed second result, more than 200 matches, field omission/null semantics, stale pages, limit and limit-plus-one boundaries, UTF-8/JSON escaping, known/unknown usage, retries, deletion, and archive failure. Mock-provider tests do not establish live provider quality or physical-iPhone responsiveness.

Before deployment, review the actual live configuration using the existing authorized release workflow. The checked-in Wrangler files are disabled scaffolds, not safe replacements for live configuration. Existing deployment helpers contain historical hash/version/migration allowlists; they must not be made to pass by removing the AnswerJobs class, binding, migration history, alarms, cleanup, or accounting. This source change does not itself deploy either service, upload TestFlight, enable recovery, or run paid/live-data tests.

Install the matching app update before relying on the expanded service. Verify the production and owner routes intended for use, keep recovery off, then perform an authorized bounded end-to-end question on the phone. Preserve readers/accounting for any already-issued expanded continuations during rollback; do not roll back to a decoder that would discard them or automatically restart uncertain work.
