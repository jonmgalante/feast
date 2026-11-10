# Saved-library export and restore

`Export Library` writes `Feast-places-v2.json`. `Import Library` offers **From Notes** and **From Feast Backup**. The backup flow accepts v1 and v2, previews the file, and writes only after **Restore private copies**. Notes import and its direct empty-state entry remain unchanged. Back returns to the source chooser; Close or successful completion dismisses the whole import sheet.

## What is preserved

The archive includes every raw attribute and to-one relationship in `FeastList`, `ListSection`, and `SavedPlace`. Inverse relationships are reconstructed. Nil and empty values, unknown status/type strings, raw cuisine/tag storage, notes and legacy skip notes, links, Apple Place IDs, timestamps, identical names, empty groups, uncategorized records, and legacy parent links are not normalized or deduplicated.

Version 2 also includes informational per-record private/shared/unknown source and locally available city sharing metadata: share/zone identifiers, owner record identifier, current-user role/permission, public permission, and visible participant record identifiers/roles/permissions/acceptance. Failed or unavailable metadata is marked unavailable, not assumed unshared. Participant visibility can be incomplete. Contact details and invitation URLs are not exported.

This is the saved library currently available on the device, not proof of the latest iCloud state. It excludes Ask Feast conversations, settings, credentials, caches, and recovery checkpoints. The JSON may contain private notes and is **not password-encrypted**. Temporary export files retain the existing file protection and cleanup behavior.

## Restore boundaries

- Restore adds separate private copies in the explicitly selected private/local store. It never merges, deletes, overwrites, invites participants, recreates shares, changes ownership, or trusts archived permissions.
- UUIDs are deliberately remapped. The original export remains the record of the original IDs and sharing provenance. Imported objects participate in the destination app's normal private-store sync; that is not shared-city restoration.
- Legacy nested neighborhoods remain lossless in storage and appear as flat display paths in city browsing and place assignment. Restored nonempty legacy skip notes are readable separately in place detail. Records without a city remain lossless but are not shown in city browsing; the preview warns about this. Keep the original export.
- Retry identity is derived from the complete raw graph, ignoring export date, array order, format version, and provenance. Reimporting that graph while all mapped records remain is a no-op, even after those copies were edited. If only some remain, import rejects without changing anything. A different graph creates a different private copy. After all its restored records have deliberately been removed, the original file can be imported again.
- Idempotency is based on the locally loaded stores. It does not promise deduplication of simultaneous imports on multiple devices before iCloud delivers their changes.

## Safety and implementation

Input is limited to 32 MiB, 100,000 total records, 1 MiB per text field, and parent depth 128. Duplicate IDs within an entity, missing/cross-city references, cycles, invalid dates, unknown format versions, and malformed JSON are rejected. Files are read incrementally with the same hard byte cap even if they change while reading. Preview parsing runs off the main actor; canceled/stale reads cannot publish a preview.

The application must finish its existing startup preparation before importing. A dirty editing context is rejected without saving or discarding its draft. Production imports use a dedicated private-queue context, assign every new object to one destination store, and save in one transaction. Failure rolls back only that worker's inserts. A successful save merges inserted object IDs into the view context without resetting unrelated drafts. UI restore attempts are serialized; the final action locks dismissal until completion. Interrupted transactions are either absent or complete, and retry detection does not depend on a separately written receipt.

Mapped IDs use SHA-256 of a canonical raw graph plus entity/source ID in a reserved `FEA57B01` UUIDv8 namespace (RFC variant, 90 remaining hash bits). Full mapped-ID uniqueness and conflicts across loaded entity/store boundaries are checked before writing. The two existing legacy normalizations skip only this precise namespace, so restored parent links and skip notes survive a later new-store migration replay. Original/random IDs continue to follow the old migration behavior. No Core Data model, store identity, CloudKit schema, or release configuration changes are required.

## Verification

`env -u FEAST_UPGRADE_COPY_DIR zsh Tests/run-persistence-tests.sh` includes `LibraryArchiveTests`, using disposable SQLite coordinators without the app's CloudKit controller. Coverage includes full raw-field/relationship disk round-trip and reopen, ordinary startup and new-store migration replay, preexisting records, v1, duplicate names/Apple IDs/empty groups, malformed/bounded input, failure/cancel/retry/conflicts, async import, and a 10,000-place synthetic import.

Unsigned Debug simulator and Release device builds validate application integration without launching Feast. These checks do not substitute for physical-device UI/file-provider/iCloud QA. No test should launch the normal app against a real library merely to check this feature.
