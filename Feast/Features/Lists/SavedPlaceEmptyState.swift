import SwiftUI

/// Saved-content explanations shared by list and map; never a discovery handoff.
struct SavedPlaceEmptyState: View {
    @EnvironmentObject private var browse: SavedPlaceBrowseState
    let reason: SavedPlaceEmptyReason
    let scopeName: String
    var addPlace: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: reason == .emptyScope ? "mappin.and.ellipse" : "magnifyingglass")
        } description: {
            Text(message).foregroundStyle(FeastTheme.Colors.secondaryText)
        } actions: {
            switch reason {
            case .emptyScope:
                if let addPlace { Button("Search Apple Maps", action: addPlace).buttonStyle(FeastQuietChipButtonStyle()) }
            case .filtersHideMatches:
                Button("Clear Filters") { browse.filters.clearFiltersKeepingScopeAndQuery() }
                    .buttonStyle(FeastQuietChipButtonStyle())
            case .queryHasNoMatches:
                Button("Clear Search") { browse.filters.queryText = "" }
                    .buttonStyle(FeastQuietChipButtonStyle())
            case .hasMatches:
                EmptyView()
            }
        }
        .foregroundStyle(FeastTheme.Colors.primaryText)
    }
    private var title: String {
        switch reason {
        case .emptyScope: "No Saved Places Yet"
        case .filtersHideMatches: "Filters Are Hiding Places"
        case .queryHasNoMatches: "No Search Matches"
        case .hasMatches: ""
        }
    }
    private var message: String {
        switch reason {
        case .emptyScope:
            scopeName == "All Cities" ? "Choose a city and add your first place from Apple Maps." : "Add your first place in \(scopeName) from Apple Maps."
        case .filtersHideMatches:
            browse.filters.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No saved places in \(scopeName) fit these filters."
                : "Your search has saved matches in \(scopeName), but the filters hide them."
        case .queryHasNoMatches:
            browse.filters.hasContentFilters
                ? "No saved places in \(scopeName) match this search. Clearing filters alone won’t reveal results."
                : "No saved places in \(scopeName) match this search. Try another name, neighborhood or note."
        case .hasMatches: ""
        }
    }
}
