# Privacy manifest reconciliation

Initial review: 2026-11-07 against source baseline `d600907c196dbc74016fc462efbd083569a1023c`.
Updated 2026-11-09 for the local durable-recovery candidate based on `9a39ab3`.
Updated 2026-11-11 for the existing local file-metadata API declaration omission.
Scope: the production iPhone app and the proposed enabled Ask recovery path.
Recovery remains disabled; its new Performance Data declaration prepares the
bundled manifest for that rollout and does not claim it is currently deployed.
This review does not verify deployed settings, certify legal compliance, publish
App Store Connect answers, or authorize provider requests. No real collection,
credential, or retained cloud record was inspected.

## Classification rules and sources

Apple requires collected types, linkage, tracking and purposes in the manifest;
required-reason API entries are a separate declaration. A collected-data entry
has exactly four keys. The manifest must be bundled as a resource.

- [Apple: Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Apple: TN3184](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)
- [Apple: Describing data use](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
- [Apple: collected-type values](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
- [Apple: purpose values](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes)
- [Apple: App privacy details](https://developer.apple.com/app-store/app-privacy-details/)

Official Apple pages, their linked Markdown, and the documentation JSON's
`possibleValues` were retrieved on the initial review date. Apple defines collection by
access beyond real-time request service, not merely by a database write in app
code. Optional online consent does not exempt ongoing primary-feature collection.
Identity linkage includes a device; hashing a persistent identity is not proof of
unlinkability. App Functionality includes authentication, security and operation.
Product Personalization includes recommendations customized to the user. These
purposes are not interchangeable with behavioral Analytics.

## Required-reason API correction: local file metadata

The original conversation migration reads `contentModificationDateKey` to retain
its saved date (`AskConversationStore.loadLibrary`). The accepted action journal
also reads that key to verify its local migration backup (`AskActionJournal`).
Those calls already require `NSPrivacyAccessedAPICategoryFileTimestamp`; this is
not merely a dependency introduced by the pending navigation repair. That repair
also uses `fstat`/`lstat` for bounded regular-file size/type checks.

Apple's [required API category table](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
was verified from its live documentation JSON on 2026-11-11. It lists all three
APIs. The narrowly applicable reason is **C617.1**, covering metadata access within
the app's own containers. Production paths are the app's history/journal files and
migration backups, not arbitrary system files or document-picker access.

The declaration corrects the bundled API-use record. It adds no file reads,
transmission, fingerprinting, collection category, tracking, or new permission.
Existing UserDefaults/SystemBootTime reasons and all nine collected-data entries
remain byte-for-byte unchanged. No App Store Connect answers are changed.
The strict checker now also rejects a missing/duplicate file-metadata category,
a document-picker reason, or an additional unreviewed reason. Final built-bundle
parity remains required; a source-only manifest is not a submission guarantee.

## Type / purpose / linkage matrix

Each listed type uses the `NSPrivacyCollectedDataType` prefix in the manifest.
All nine are **linked to the user** and **not used for tracking**.

| Type | Purposes | Evidence and rationale |
| --- | --- | --- |
| Name | App Functionality | The owner invitation form explicitly requests a name to identify a member; the submitted label is retained with grant ID and creator ID. `AskManageAccessView.swift:29-32`, `AskAccessManagement.swift:90-98`, `phone-access.mjs:113-127`. Labels are not identity-verified, but a name-specific field cannot be treated as only generic user content. |
| OtherUserContent | App Functionality; Product Personalization | Questions, recent conversation, permitted saved/shared notes, tags, statuses and collection context produce answers and preference-informed recommendations. `AskPrivacy.swift:13-20`, `AskAgentProvider.swift:41-70`, `AskLibraryTools.swift:3-41`, `native-research.mjs:95-100`, `conversation.mjs:120-127`. Provider content retention is described below. |
| SearchHistory | App Functionality; Product Personalization | Current and recent in-app research questions, retained web queries and follow-up context are transmitted for search and tailored suggestions. `AskLibraryTools.swift:16-41`, `native-research.mjs:95-108`, `conversation.mjs:209-215`. This is not a claim that the app uploads browser history. Relevant note/preference context can inform searches (`conversation.mjs:122`). Provider retention makes a local-only search-history exemption unsupported. |
| UserID | App Functionality | Grant IDs identify authorized actors and owner/member roles. `userHash` is deterministically derived from grant ID and reused in durable request/turn records. `phone-access.mjs:11-14,92-102,126-134`; `public-handler.mjs:18-28`; `native-accounting.mjs:24-53`. No separate sign-up or real-name account is needed for this assigned access identity. |
| DeviceID | App Functionality | Random device and activation IDs, credential hashes, and the grant receipt persist for authentication, duplicate prevention and revocation. `AskPhoneActivation.swift:62-84`; `phone-access.mjs:76-94`. They remain mapped to the actor and are not anonymous just because randomly generated or hashed. |
| ProductInteraction | App Functionality | Durable request roots, turn/step records, response counts and web-action counts record use of online Ask and enforce replay/concurrency/recovery rules. `native-accounting.mjs:28-53,57-69`; `reconciled-accounting.mjs:84-97,125-151`. These are functional records, not evidence of a behavioral analytics service. |
| OtherUsageData | App Functionality | Per-request model/token consumption and provider usage-cost accounting are retained with `userHash`. This covers resource consumption, distinct from the request/turn interactions above. `native-accounting.mjs:63-76`; `reconciled-accounting.mjs:144-151`; `production-ledger.mjs:40-47`. Provider expense records are not a user's purchase history or payment details. |
| PerformanceData | App Functionality | Enabled recovery retains native reply stage durations, call counts and counters in grant/request-scoped jobs until acknowledgment, Stop or content expiry. `native-conversation.mjs` attaches `metrics.snapshot()`; `answer-jobs.mjs` stores the final reply, keyed by `userHash`, request and step. These are not anonymous merely because the measurements contain no prompt text. The purpose is service operation/recovery, not behavioral analytics. |
| OtherDiagnosticData | App Functionality | Retained pending/uncertain/rejected states, provider status/error codes, and bounded lookup diagnostic codes support technical recovery and service reliability. `native-accounting.mjs:57-68`; `reconciled-accounting.mjs:65-82,144-161`; `public-business.mjs:38-40`. Request IDs allow linkage back to user records. |

Swift references are under `Feast/Features/AskFeast/`; JavaScript references are
under `Backend/feast-production/`. Existing line numbers refer to the original
reviewed baseline; the recovery row names its current source functions.
Content/search requests are authenticated as the device's actor before provider
dispatch. Neither payload projection nor the backend establishes irreversible
unlinking before collection. Do not set linked=false merely because OpenAI is
not explicitly sent Feast's `userHash`. No advertising, ad measurement or
cross-company tracking use is supported by the inspected code or current policy.
No Analytics purpose is added without evidence of behavioral analysis beyond
service operation and usage accounting.

## Retention evidence and limits

The [Feast policy](https://jonmgalante.github.io/feast-site/privacy/) was fetched
during the initial review and said “Last updated: November 7, 2026.” Its local
source was rechecked offline on November 9; no current publication was fetched.
It covers v5 collection/shared-note context, search recipients, persistent
access/accounting records, disabled image uploads and provider retention. It
still needs a recovery-storage update before this feature is enabled. No policy
publication is represented by this local manifest change.

The [current OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)
state that standard abuse-monitoring logs can contain prompts/responses and are
normally retained up to 30 days, with specified longer-retention exceptions.
`store:false` in `native-research.mjs:100` and `conversation.mjs:175,203,213`
disables response storage, not all abuse monitoring, caching or third-party
retention. This review uses the documented standard policy, consistent with
Feast's published policy; it did not verify project-specific ZDR/MAM controls or
training-sharing settings. Do not claim such controls from source alone.

The backend explicitly persists access, identity, replay, usage and diagnostic
records in Durable Objects. Revocation retains records rather than deleting them.
Those existing metadata/accounting paths have no automatic expiry. Request
fingerprints and frame digests are not raw transcripts, but remain associated
with request/user IDs. The content/search declarations also account for provider
retention rather than pretending that absence of a Feast transcript table proves
no collection.

The new recovery path separately retains request data, provider receipts and
answers on Cloudflare. Each accepted step has a 24-hour recovery window. Prompt
and raw receipt are removed after settlement; the answer is removed earlier on
acknowledgment or Stop, or on expiry. Expired content cannot be returned. Storage
or platform outages may delay physical cleanup until the service can run again;
the in-app sentence therefore describes a recovery window, not a guaranteed
physical-deletion deadline. Compact duplicate-prevention records normally remain
seven days, longer if necessary to finish accounting/fencing. Existing accounting
records are separate, as are OpenAI/search-provider retention practices.

The recovery-inclusive v6 consent must not migrate a previous v5 grant. It uses
the existing permission prompt and Settings toggle, with one added sentence.
Neither the disclosure nor the feature promises every question can finish while
the app is closed: local phone tool steps can still wait for foreground activity.

## Exclusions and exact unresolved questions

- **Performance Data is now source-proven for enabled recovery.** Its declaration
  covers the persisted request-linked timings above. Other deployed diagnostics,
  logging and observability settings have not been inspected. Confirm their
  fields, retention and purposes before public submission; update declarations
  if those practices add a different purpose or data type. The checked-in
  Wrangler file remains disabled scaffolding, not live configuration evidence.
- **Provider controls:** confirm the production OpenAI project's actual retention
  and data-sharing configuration, and whether providers use app data for any
  purpose beyond the stated functionality/security/personalization. The standard
  retention basis above is not account-settings verification. No unverified
  zero-retention exemption is taken.
- **Photos or Videos:** omitted for this release. Production health hardcodes
  `selectedScreenshotEnabled:false` (`public-handler.mjs:9`); the production
  provider rejects attachments (`AskHostedProvider.swift:120-123`) and the agent
  routes attachments out of its online path (`AskAgentProvider.swift:39-40`).
  Re-review before enabling uploads; dormant selection code is not collection.
- **Location:** no automatic device location was added to Ask. Saved business
  names/cities are collection context, not automatically the user's current
  location. Do not infer a location declaration from place coordinates alone.
  Any new off-device location flow, including retained IP-derived location, needs
  a separate review of actual collection and purposes.
- **Browsing history, advertising, purchases, crash data and every possible
  sensitive free-text topic:** no category is added solely because arbitrary
  notes could mention it, a user might open a source link, or a platform feature
  exists. Reassess if a dedicated collection/use path is introduced. This is not
  a claim that every service's undocumented logging is absent.
- The manifest does not update App Store Connect privacy answers. Compare those
  answers with this matrix and any resolved operational questions before public
  submission. Generate/review Xcode's archive privacy report separately.

## Offline validation

Run `plutil -lint Feast/PrivacyInfo.xcprivacy` and
`python3 Tests/check-privacy-manifest.py`. The check validates the nine reviewed
entries, exact TN3184 keys, Boolean linkage/tracking, purposes, duplicate rejection,
the three exact reviewed required-reason API entries, and synchronized target resource membership.
Eighteen in-memory negative cases ensure it rejects invalid/unreviewed declarations.
It reads no app stores or credentials and makes no network requests.

For the final built app or archive, run
`python3 Tests/check-privacy-manifest.py --app /path/to/Feast.app`.
This separately verifies that the actual bundle contains the reviewed manifest.
Source target membership alone is not evidence of final archive inclusion.
