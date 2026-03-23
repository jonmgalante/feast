import Foundation

enum PlaceStatus: String, CaseIterable, Identifiable {
    case wantToTry = "Want to try"
    case justOpened = "Just opened"
    case been = "Been"
    case love = "Love"
    case regulars = "Regulars"

    var id: String { rawValue }
}
