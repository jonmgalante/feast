import SwiftUI

private struct BrowseScrollScopeKey: EnvironmentKey { static let defaultValue = "directory" }
extension EnvironmentValues {
    var browseScrollScope: String {
        get { self[BrowseScrollScopeKey.self] }
        set { self[BrowseScrollScopeKey.self] = newValue }
    }
}
private struct BrowseRowPosition: Equatable { let id: String; let frame: CGRect }
private struct BrowseRowPositions: PreferenceKey {
    static var defaultValue: [BrowseRowPosition] = []
    static func reduce(value: inout [BrowseRowPosition], nextValue: () -> [BrowseRowPosition]) { value += nextValue() }
}
private struct BrowseRowAnchor: ViewModifier {
    @Environment(\.browseScrollScope) private var scope
    let id: String
    func body(content: Content) -> some View {
        content.id(id).background {
            GeometryReader { geometry in
                Color.clear.preference(key: BrowseRowPositions.self, value: [BrowseRowPosition(id: id, frame: geometry.frame(in: .named(scope)))])
            }
        }
    }
}
private struct RememberBrowseScroll: ViewModifier {
    @EnvironmentObject private var browse: SavedPlaceBrowseState
    @State private var restored = false
    @State private var visible = false
    let scope: String
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .coordinateSpace(name: scope)
                .environment(\.browseScrollScope, scope)
                .onAppear { visible = true }
                .onDisappear { visible = false }
                .onPreferenceChange(BrowseRowPositions.self) { positions in
                    guard visible, !positions.isEmpty else { return }
                    if !restored {
                        restored = true
                        if let anchor = browse.scrollAnchors[scope] {
                            proxy.scrollTo(anchor, anchor: .top)
                            return
                        }
                    }
                    if let top = positions.filter({ $0.frame.maxY > 0 }).min(by: { $0.frame.minY < $1.frame.minY }) {
                        browse.scrollAnchors[scope] = top.id
                    }
                }
        }
    }
}
extension View {
    func browseRowAnchor(_ id: String) -> some View { modifier(BrowseRowAnchor(id: id)) }
    func rememberBrowseScroll(_ scope: String) -> some View { modifier(RememberBrowseScroll(scope: scope)) }
}
