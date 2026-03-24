# Feast v1 Build Plan

This document converts the locked Feast v1 product spec into implementation phases. It is a sequencing guide, not permission to build everything at once.

## Phase 0: Project Alignment
- Confirm the app target remains Feast and is iPhone-only.
- Keep the codebase on SwiftUI and Apple frameworks only.
- Do not add third-party dependencies.
- Establish semantic theme tokens for the Stone + Saffron palette.
- Keep the architecture simple and readable.
- Do not start CloudKit or import implementation in this phase.

## Phase 1: Domain And App Shell
- Define shared product language in code:
  - `FeastList`
  - `ListSection`
  - `SavedPlace`
  - `SavedPlaceStatus`
  - supporting enums for `placeType`, cuisine, and tags only if needed by the requested feature
- Create the two-tab shell only when explicitly requested:
  - Cities
  - Map
- Ensure naming avoids conflicts with SwiftUI `List`.

## Phase 2: Core Data Foundation
- Add the Core Data stack for local persistence.
- Model only the current locked entities:
  - `FeastList`
  - `ListSection`
  - `SavedPlace`
- Keep `FeastList` as the model backing a City in the UI.
- Keep `ListSection` as the model backing a Neighborhood in the UI.
- Support exactly one neighborhood level under a city in the app layer.
- Keep neighborhood data in `ListSection`, not `SavedPlace`.
- Persist the locked `SavedPlace` fields only unless a later prompt expands the spec.
- Add timestamps needed for sorting, recency, and auditing.

## Phase 3: Cities Experience
- Build city browsing around top-level cities such as `NYC`, `London`, and `Philadelphia`.
- Support geographic grouping through neighborhoods.
- Present the typical hierarchy:
  - `City (FeastList) > Neighborhood (ListSection) > Place`
- Support creating and editing city structure within the locked hierarchy rules.
- Keep sharing UI out until explicitly requested.

## Phase 4: Saved Place Management
- Add the place-add flow from the Cities tab.
- Require every saved place to originate from an Apple Maps match.
- Do not allow manual or freeform place creation.
- Support editing the locked `SavedPlace` content fields.
- Support the locked statuses:
  - Want to try
  - Just opened
  - Been
  - Love
  - Regulars

## Phase 5: Map Experience
- Add the Map tab as a combined saved + explore surface.
- Support adding places from the Map tab using Apple Maps / MapKit only.
- Reflect saved places on the map using city and neighborhood context.
- Keep the map experience aligned with the same place source-of-truth rules as Cities.

## Phase 6: Search And Filter
- Add cross-city search.
- Add filters for:
  - city
  - status
  - place type
  - cuisine
- Keep the first pass focused on the locked baseline only.

## Phase 7: Sharing And Sync
- This phase is deferred until explicitly requested.
- When requested, use CloudKit only.
- The shareable unit is a `FeastList`, surfaced as a City in the UI.
- Preserve the locked role behavior:
  - Owner and Editor can both edit city content.
  - Only Owner manages sharing.
  - Only Owner can delete the entire shared city.

## Phase 8: Import From Notes
- This phase is deferred until explicitly requested.
- Entry points:
  - Cities tab overflow menu
  - Empty-state CTA for first-time users or zero-place state
- Import sources:
  - pasted content from Apple Notes
  - Markdown file exported from Apple Notes
- Keep import parsing and mapping isolated from the core domain model.

## Explicit Non-Goals For Early Passes
- No app account system
- No non-Apple map provider
- No manual place creation
- No trash or Recently Deleted implementation
- No speculative persistence entities beyond the locked v1 models
- No CloudKit implementation until explicitly requested
- No import implementation until explicitly requested

## Delivery Rule For Future Prompts
- Build only the feature the user asks for next, plus the minimum supporting code needed to make that feature coherent.
