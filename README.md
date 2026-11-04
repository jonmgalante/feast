# Feast

Feast is an iPhone app for saving, organizing, and sharing places. It uses SwiftUI, Core Data, CloudKit, and Apple Maps. Ask Feast adds model-led conversation, public research, and validated collection actions.

## Source layout

- `Feast/`: application, persistence, sharing, Maps, and Ask Feast client.
- `Backend/feast-production/`: authenticated production request handling, research, phone activation, and usage accounting.
- `Backend/feast-owner-validation/`: restricted owner validation service.
- `Backend/feast-proxy/`: shared provider components, legacy compatibility, and development tests.
- `Tests/`: automated persistence, conversation, presentation, privacy, and action tests, with synthetic or public fixtures.

The existing bundle ID, CloudKit container, data model, stores, and sharing identities are preserved. AI access is separate from access to the saved collection. Provider credentials and device access secrets are supplied through secure runtime configuration, never through this repository. Nonsecret service names, endpoints, deployment identifiers, and signing identity metadata remain in source where required by the existing application and release tooling; they do not authorize access.

## Local verification

Run the client suite on a Mac with Xcode:

```sh
zsh Tests/run-persistence-tests.sh
```

By default, it uses disposable test stores. Leave `FEAST_UPGRADE_COPY_DIR` unset for the automated suite. No live collection or paid provider request is required.

Run backend unit tests with Node.js:

```sh
node --test Backend/feast-proxy/*.test.mjs Backend/feast-production/*.test.mjs
```

The locked development dependencies in `Backend/feast-proxy/package-lock.json` support Wrangler bundling and optional local runtime tests. Runtime scripts require their documented local packets; they are not the default unit-test command.

Build without installing or signing:

```sh
xcodebuild -project Feast.xcodeproj -scheme Feast -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Feast.xcodeproj -scheme Feast -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

## Release boundaries

The Wrangler files are disabled scaffolds, not a description of the live configuration. Do not use them to overwrite existing service settings. Deployment helpers intentionally require reviewed artifacts and exact configuration checks; historical hash/version pins must be reviewed against the intended release before use. Source preparation does not publish a backend, activate invitations, upload a build, or change provider spending settings.

This release snapshot includes the application, backend, build configuration, and tests. Historical development screenshots, real-session receipts, usage reports, and working notes are deliberately excluded from the public source. Existing local development history is retained separately. No test evidence is represented as proof of a completed App Store submission or a physical-device upgrade.
