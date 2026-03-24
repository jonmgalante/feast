# Feast Agent Guide

## Purpose
- This repository is for Feast v1.
- Preserve the locked product spec below unless the user explicitly changes it.
- Do not silently reinterpret or broaden the spec.

## Product Identity
- App name: Feast
- Platform: iPhone only
- UI stack: SwiftUI
- Persistence: Core Data
- Cloud sync and sharing: CloudKit
- Maps stack: Apple Maps / MapKit only
- No app account in v1

## Core UX Structure
- Feast v1 has exactly two main tabs: Cities and Map.
- The Map tab is both saved and explore.
- The add flow must work from both Cities and Map.
- The shareable unit is a `FeastList`, surfaced in the UI as a City.
- Cities are the top-level buckets in the product.
- Neighborhoods live directly inside a city and are stored in `ListSection`.
- The product and UI support exactly one neighborhood level under a city.
- Typical structure: `City (FeastList) > Neighborhood (ListSection) > Place`
- Neighborhood belongs in `ListSection`, not `SavedPlace`.

## Sharing Rules
- User-visible roles in v1: Owner and Editor
- Owner and Editor both have full content-editing power over city content.
- Only Owner manages sharing.
- Only Owner can delete the entire shared city.

## Place Creation Rules
- Every saved place must come from an Apple Maps match.
- No freeform or manual place creation in v1.
- Use MapKit-backed place selection only.

## Persisted Models
- Keep the core persisted models limited to:
  - `FeastList`
  - `ListSection`
  - `SavedPlace`
- Use code names that avoid collision with SwiftUI `List`; prefer `FeastList`.

### `SavedPlace` Fields Locked For v1
- `applePlaceID`
- `displayNameSnapshot`
- `status`
- `placeType`
- `cuisines` (multiple values)
- `tags` (multiple values)
- `note`
- `skipNote`
- `instagramURL`
- `listID`
- `sectionID`
- timestamps

### Locked Statuses
- Want to try
- Just opened
- Been
- Love
- Regulars

## Search And Filter Baseline
- Search across cities
- Filters by city, status, place type, cuisine

## Import Rules
- Import strategy is locked but is not part of the first coding pass.
- Entry points:
  - Cities tab overflow menu: Import from Notes
  - Empty-state CTA for first-time users or zero-place state
- Primary import: paste from Apple Notes
- Secondary import: Markdown file exported from Apple Notes
- Do not implement import unless explicitly requested.

## Deferred / Undecided
- Recently Deleted / Trash is undecided.
- Do not implement trash, soft delete, or recovery UX unless the user explicitly decides it.
- Keep CloudKit-specific implementation work out until explicitly requested.

## Visual System
- Locked palette direction: Stone + Saffron
- Base palette:
  - saffron `#D0A11E`
  - blue slate `#435A72`
  - stone `#ECE7DF`
  - sage gray `#748274`
  - charcoal `#22272B`
- Use semantic theme tokens instead of hard-coded view colors.

## Engineering Rules
- Use SwiftUI and Apple frameworks only.
- No third-party dependencies.
- Keep code modular and production-quality, but avoid overengineering.
- Prefer simple, readable architecture.
- Keep CloudKit-specific work out until explicitly requested.
- Keep import work out until explicitly requested.
- If a later prompt asks for a feature, implement only that feature and the minimum supporting code required.

## Change Control
- Before changing product behavior, verify whether the spec above already decides it.
- If the requested change conflicts with this file, do not choose a new direction silently.
- Prefer small, reviewable diffs.
- Prefer editing existing files over creating new ones unless a new file is clearly warranted.
