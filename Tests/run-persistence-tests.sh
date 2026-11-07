#!/bin/zsh
set -eu
cd "${0:A:h}/.."
work=$(mktemp -d /tmp/feast-safety-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
xcrun momc Feast/Persistence/FeastDataModel.xcdatamodeld "$work/FeastDataModel.momd"
xcrun swiftc -D FEAST_TESTS -parse-as-library -module-cache-path "$work/cache" -o "$work/tests" \
  Feast/Persistence/ManagedObjects/*.swift Feast/Models/FeastTag.swift \
  Feast/Core/Theme/StatusBadgePalette.swift Tests/StatusBadgeTests.swift \
  Feast/Models/PlaceType.swift Feast/Models/PlaceStatus.swift \
  Tests/Fixtures/ApplePlacesFixtures.swift Feast/Services/PlaceReviewDraft.swift Feast/Services/PlaceSaveDestination.swift Feast/Models/ApplePlaceMatch.swift Feast/Services/NearbyLocationService.swift Tests/NearbyLocationTests.swift Feast/Services/PlaceSearchContext.swift Feast/Services/SavedMapPlan.swift Feast/Services/MapPlaceLookup.swift Tests/MapPlaceLookupTests.swift \
  Feast/Features/Import/NotesImportParser.swift Feast/Features/Import/NotesImportReviewSupport.swift \
  Feast/Services/InstagramWebsiteParser.swift Feast/Services/InstagramWebsiteClient.swift Feast/Services/AskPinnedWebsiteClient.swift Tests/InstagramAutofillTests.swift Tests/AskPinnedWebsiteTests.swift \
  Feast/Features/Lists/SavedPlaceBrowseState.swift Feast/Features/Lists/CityFilteredPlaceGroups.swift Tests/CityFilteredPlaceGroupsTests.swift Tests/BrowsingConsistencyTests.swift Tests/EmptyStateTests.swift \
  Feast/Features/AskFeast/AskConversationProtocol.swift Feast/Features/AskFeast/AskConversationLoop.swift Feast/Features/AskFeast/AskAgentProvider.swift Feast/Features/AskFeast/AskAgentExecutor.swift Feast/Features/AskFeast/AskAgentLoop.swift Feast/Features/AskFeast/AskAgentProtocol.swift Feast/Features/AskFeast/AskCollectionChanges.swift Feast/Features/AskFeast/AskFieldActions.swift Feast/Features/AskFeast/AskPrivacy.swift Feast/Features/AskFeast/AskLibraryTools.swift Feast/Features/AskFeast/AskBusinessLookup.swift Tests/Fixtures/AskEvaluationContract.swift Feast/Features/AskFeast/AskResearchPilot.swift Tests/AskResearchPilotTests.swift Feast/Features/AskFeast/AskPerformance.swift Feast/Features/AskFeast/AskConversationStore.swift Feast/Features/AskFeast/AskQueryPlan.swift Feast/Features/AskFeast/AskFeastContracts.swift Feast/Features/AskFeast/AskPresentation.swift Feast/Features/AskFeast/AskHostedProvider.swift Feast/Features/AskFeast/AskSavedCollection.swift Feast/Features/AskFeast/AskScreenshotPreparation.swift Tests/Fixtures/AskFeastFixtures.swift Tests/Fixtures/AskMockProvider.swift \
  Feast/Features/AskFeast/AskFeastTabState.swift Tests/Fixtures/AskPrototypeSandbox.swift Feast/Features/AskFeast/AskLocalOCR.swift Tests/AskFeastPrototypeTests.swift Tests/AskLibraryToolsTests.swift Tests/AskFieldActionTests.swift Tests/AskCollectionChangeTests.swift Tests/AskConversationPersistenceTests.swift Tests/AskConversationLoopTests.swift Tests/AskAgentLoopTests.swift Tests/AskAgentExecutorTests.swift Tests/AskCollectionContextTests.swift Tests/AskBusinessLookupTests.swift Tests/AskConversationUpgradeTests.swift Tests/AskUXSafetyTests.swift Tests/AskPresentationTests.swift Tests/AskPerformanceTests.swift Tests/AskNativeResearchTests.swift \
  Feast/Features/AskFeast/AskAccessManagement.swift Feast/Features/AskFeast/AskPhoneActivation.swift Tests/AskPhoneActivationTests.swift Tests/AskAccessManagementTests.swift \
  Feast/Persistence/PlaceExport.swift Feast/Persistence/FeastRepository.swift Tests/PersistenceTestSupport.swift Tests/RealStoreUpgradeCheck.swift Tests/PersistenceSafetyTests.swift
if [[ -n "${FEAST_UPGRADE_COPY_DIR:-}" ]]; then
  "$work/tests" "$work/FeastDataModel.momd" "$FEAST_UPGRADE_COPY_DIR" --verify-real-copy
else
  "$work/tests" "$work/FeastDataModel.momd" "$work"
fi
