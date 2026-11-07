# Privacy manifest reconciliation

Reviewed 2026-11-07 against source baseline `d600907c196dbc74016fc462efbd083569a1023c`.
Scope: the production iPhone app and its enabled Ask request paths. This review
changes the bundled manifest only, with an offline regression check. It does not
verify deployed settings, certify legal compliance, publish App Store Connect
answers, or authorize provider requests. No real collection, credential, or
retained cloud record was inspected.

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
`possibleValues` were retrieved on the review date. Apple defines collection by
access beyond real-time request service, not merely by a database write in app
code. Optional online consent does not exempt ongoing primary-feature collection.
Identity linkage includes a device; hashing a persistent identity is not proof of
unlinkability. App Functionality includes authentication, security and operation.
Product Personalization includes recommendations customized to the user. These
purposes are not interchangeable with behavioral Analytics.

## Type / purpose / linkage matrix

Each listed type uses the `NSPrivacyCollectedDataType` prefix in the manifest.
All eight are **linked to the user** and **not used for tracking**.

| Type | Purposes | Evidence and rationale |
| --- | --- | --- |
| Name | App Functionality | The owner invitation form explicitly requests a name to identify a member; the submitted label is retained with grant ID and creator ID. `AskManageAccessView.swift:29-32`, `AskAccessManagement.swift:90-98`, `phone-access.mjs:113-127`. Labels are not identity-verified, but a name-specific field cannot be treated as only generic user content. |
| OtherUserContent | App Functionality; Product Personalization | Questions, recent conversation, permitted saved/shared notes, tags, statuses and collection context produce answers and preference-informed recommendations. `AskPrivacy.swift:13-20`, `AskAgentProvider.swift:41-70`, `AskLibraryTools.swift:3-41`, `native-research.mjs:95-100`, `conversation.mjs:120-127`. Provider content retention is described below. |
| SearchHistory | App Functionality; Product Personalization | Current and recent in-app research questions, retained web queries and follow-up context are transmitted for search and tailored suggestions. `AskLibraryTools.swift:16-41`, `native-research.mjs:95-108`, `conversation.mjs:209-215`. This is not a claim that the app uploads browser history. Relevant note/preference context can inform searches (`conversation.mjs:122`). Provider retention makes a local-only search-history exemption unsupported. |
| UserID | App Functionality | Grant IDs identify authorized actors and owner/member roles. `userHash` is deterministically derived from grant ID and reused in durable request/turn records. `phone-access.mjs:11-14,92-102,126-134`; `public-handler.mjs:18-28`; `native-accounting.mjs:24-53`. No separate sign-up or real-name account is needed for this assigned access identity. |
| DeviceID | App Functionality | Random device and activation IDs, credential hashes, and the grant receipt persist for authentication, duplicate prevention and revocation. `AskPhoneActivation.swift:62-84`; `phone-access.mjs:76-94`. They remain mapped to the actor and are not anonymous just because randomly generated or hashed. |
| ProductInteraction | App Functionality | Durable request roots, turn/step records, response counts and web-action counts record use of online Ask and enforce replay/concurrency/recovery rules. `native-accounting.mjs:28-53,57-69`; `reconciled-accounting.mjs:84-97,125-151`. These are functional records, not evidence of a behavioral analytics service. |
| OtherUsageData | App Functionality | Per-request model/token consumption and provider usage-cost accounting are retained with `userHash`. This covers resource consumption, distinct from the request/turn interactions above. `native-accounting.mjs:63-76`; `reconciled-accounting.mjs:144-151`; `production-ledger.mjs:40-47`. Provider expense records are not a user's purchase history or payment details. |
| OtherDiagnosticData | App Functionality | Retained pending/uncertain/rejected states, provider status/error codes, and bounded lookup diagnostic codes support technical recovery and service reliability. `native-accounting.mjs:57-68`; `reconciled-accounting.mjs:65-82,144-161`; `public-business.mjs:38-40`. Request IDs allow linkage back to user records. |

Swift references are under `Feast/Features/AskFeast/`; JavaScript references are
under `Backend/feast-production/`. Line numbers refer to the reviewed baseline.
Content/search requests are authenticated as the device's actor before provider
dispatch. Neither payload projection nor the backend establishes irreversible
unlinking before collection. Do not set linked=false merely because OpenAI is
not explicitly sent Feast's `userHash`. No advertising, ad measurement or
cross-company tracking use is supported by the inspected code or current policy.
No Analytics purpose is added without evidence of behavioral analysis beyond
service operation and usage accounting.

## Retention evidence and limits

The [published Feast policy](https://jonmgalante.github.io/feast-site/privacy/)
was fetched successfully and says “Last updated: November 7, 2026.” It covers v5
collection/shared-note context, search recipients, persistent access/accounting
records, disabled image uploads, and provider retention.

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
The inspected paths have no automatic expiry. Request fingerprints and frame
digests are not raw transcripts, but remain associated with request/user IDs.
The content/search declarations also account for provider retention rather than
pretending that absence of a Feast transcript table proves no collection.

## Exclusions and exact unresolved questions

- **Performance Data remains unresolved, not declared by inference.** Ordinary
  `PerformanceMeasurements` is request-local (`performance.mjs:1-20`); receipts
  and timings are stored locally (`AskConversationProtocol.swift:5-74`). The
  owner-only pilot persists elapsed time (`pilot-accounting.mjs:54-59`), but
  ordinary public requests cannot reach it (`public-handler.mjs:25-26`). The
  published policy mentions backend timing retention, while checked-in Wrangler
  observability settings are disabled scaffolding, not live evidence. Before
  public submission, confirm: **Does the deployed public app service or a service
  provider retain user/device/request-linked duration or other performance data
  beyond request completion? Which fields, retention period and purpose?** If yes,
  add PerformanceData with the evidenced linkage/purposes and update this check.
  If not, reconcile the policy's broad timing wording separately.
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
`python3 Tests/check-privacy-manifest.py`. The check validates the eight reviewed
entries, exact TN3184 keys, Boolean linkage/tracking, purposes, duplicate rejection,
unchanged required-reason APIs, and synchronized target resource membership.
Ten in-memory negative cases ensure it rejects invalid/unreviewed declarations.
It reads no app stores or credentials and makes no network requests.

For the final built app or archive, run
`python3 Tests/check-privacy-manifest.py --app /path/to/Feast.app`.
This separately verifies that the actual bundle contains the reviewed manifest.
Source target membership alone is not evidence of final archive inclusion.
