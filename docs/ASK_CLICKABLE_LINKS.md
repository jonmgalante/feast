# Ask answer navigation links

This is a client-only presentation/navigation fix. Backend source, service
configuration, model requests, permission projection, mutation authorization,
research evidence, and the production recovery-off setting are unchanged.

## Behavior

- Safe HTTPS destinations remain clickable without needing citation evidence.
  Markdown links, plain HTTPS addresses, and explicit scheme-less public domains
  share the existing web-URL safety gate. Bare domains receive HTTPS.
- Foundation Markdown assigns implicit HTTP attributes to `www` addresses. Only
  an exact displayed `www` domain matching that attribute may be upgraded to
  HTTPS. HTTP text and destinations hidden behind a different label stay blocked.
- Plain-link detection and implicit `www` promotion share a whole-text boundary
  check. Ambiguous `@handles`, including formatted `@**www.example.org**`, are not
  converted into sites. Code, rejected-link labels, relative paths, credentials,
  ports, non-HTTPS schemes, and local/IP destinations retain the existing fence.
- App-created saved-place spans still override surrounding Markdown destinations.
  Model-supplied internal navigation URLs remain stripped. A saved link must
  resolve to one accepted saved candidate; it never grants mutation authority.
- Exact query strings and fragments are retained. The existing narrowly defined
  citation tracking-parameter match remains available for actual cited sources.
  A normal clickable link does not add a citation, create a source-to-claim
  association, or verify a saved field. Citation association uses the original
  citation-only presentation path, without new autolinking.
- Summary-only answers and ordinary paragraphs use the same navigation resolver.
  Only active link runs are underlined, making dark-mode links discoverable while
  preserving the existing adaptive palette. Copy, archive and outbound history
  text are unchanged; rendering itself performs no fetch or model request.

## Regression coverage

`AskPresentationTests` covers normal Markdown/plain/domain links, the parser's
implicit `www` behavior, exact linked-label membership, Unicode and query/fragment
retention, unsafe and misleading destinations, formatted handles/emails, code,
tables, forged internal links, valid saved references, citation separation, and
actual conversation-store save/reopen without rewriting raw response content.
`AskAnswerRetentionTests` now requires safe uncited stored links to remain
clickable while keeping unsafe links inert and citation/internal checks intact.
The new positive stored-link expectation fails against the pre-fix source.

Run the complete combined candidate gates:

```sh
env -u FEAST_UPGRADE_COPY_DIR -u FEAST_AUDIT_ANSWER_CASE -u FEAST_TEST_RECOVERY zsh Tests/run-persistence-tests.sh
env -u FEAST_UPGRADE_COPY_DIR -u FEAST_AUDIT_ANSWER_CASE FEAST_TEST_RECOVERY=1 zsh Tests/run-persistence-tests.sh
node --test Backend/feast-proxy/*.test.mjs Backend/feast-production/*.test.mjs
zsh Tests/run-ask-release-send-tests.sh
python3 Tests/check-privacy-manifest.py --app /path/to/final/Feast.app
```

The recovery-compiled test variant is a synthetic regression mode, not a change
to the shipped feature flag. Release first-send checks use a dedicated simulator,
local transport and synthetic stores. Physical-device behavior, live Safari/site
loading, real service calls and TestFlight processing require separate evidence.
