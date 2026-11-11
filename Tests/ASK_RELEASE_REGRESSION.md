# Ask Feast first-send Release regression

Run from a Mac with Xcode and an installed iOS simulator runtime:

```sh
zsh Tests/run-ask-release-send-tests.sh
```

The runner copies the **current working-tree** app and project, including uncommitted changes, into a new temporary directory. It replaces only that copy's app entry with `Fixtures/AskReleaseSendApp.swift`, strips production Ask/CloudKit configuration, disables signing entitlements and recovery, and builds the real Release configuration. It creates a dedicated uniquely named simulator and bundle ID, never reuses an existing simulator, and deletes only the device it created. Logs, copied source, build products and stage evidence remain at the printed artifact path.

Three fresh-install cases exercise the actual `AskSavedCollectionPanel`, `AskSession`, `AskAgentProvider` and hosted-provider transport path:

- Offline synthetic transport: settles to a failed turn and retains that exact turn through history reload.
- Synthetic successful answer: verifies completed status, expected answer text, permission-projected text, actual panel `answerViewObserved` diagnostics, and durable history reload.
- The same successful path with 2,000 synthetic saved places.

The fixture waits two seconds for initial presentation, then observes the turn for a fixed 12-second settling window before its assertions. The runner allows 60 seconds overall for app launch and those checks. Each case must reach the fake transport and verified completion within that overall deadline. A crash, timeout, unsettled turn, missing render observation, changed answer, or history failure fails the runner. Core Data is explicitly in-memory and local; conversation/retry files exist only in the fresh synthetic app sandbox. Credentials are fabricated constants and all hosted responses come from an injected local closure. No live backend, CloudKit, account, real collection, or real Maps lookup is used.

This is a Release app smoke test with programmatic session submission and actual panel rendering, **not** XCTest tapping the Send button. Model output and network failures are synthetic. History reload recreates an `AskSession` from the persisted conversation; it is not a process-relaunch test. It does not replace a physical-device check or visual/accessibility review.

To verify that the same harness detects the original build-23 failure:

```sh
zsh Tests/run-ask-release-send-tests.sh --source-ref e2bd66cad440 --expect-original-crash
```

This uses archived application/project source but the current identical fixture. Passing the red check requires an `EXC_BAD_ACCESS` report for this run's unique bundle containing both `URLRequest.httpBody.getter` and `AskAgentProvider.privacyCheckedRemote.getter`, with no transport marker. A timeout alone is not accepted. The matching report is copied to the artifact directory. Ordinary green mode always fails a crash.

Optional `FEAST_SIM_RUNTIME` and `FEAST_SIM_DEVICE_TYPE` select an installed compatible iOS runtime and device type. No runtime is downloaded. The default device type is iPhone 17 Pro.

## Privacy fence unit regression

`AskHistoryDispatchTests.swift` is included in the normal persistence suite and exercises the **actual** `AskHostedProvider.sendWithHistoryAccessCheck` method. A throwing task-local fence permits exactly status/cancel/ack cleanup operations, blocks submit/unknown/missing/malformed/no-body requests before transport, and verifies ordinary behavior with a nil fence or disabled copied-provider flag. All transport calls are synthetic. Existing retained-channel cases additionally revoke access during credential acquisition and before Maps/authorization follow-up calls.

```sh
env -u FEAST_UPGRADE_COPY_DIR zsh Tests/run-persistence-tests.sh
env -u FEAST_UPGRADE_COPY_DIR FEAST_TEST_RECOVERY=1 zsh Tests/run-persistence-tests.sh
```

Keep real-store upgrade inputs and any test-selection environment variables unset when validating the complete synthetic suites. Host tests do not use the Release app's actor-isolation/compiler configuration; run the Release simulator smoke as well.
