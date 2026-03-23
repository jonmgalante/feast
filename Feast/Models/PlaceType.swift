import Foundation

enum PlaceType: String, CaseIterable, Identifiable {
    case restaurant = "Restaurant"
    case cafe = "Cafe"
    case bar = "Bar"
    case bakery = "Bakery"
    case dessert = "Dessert"
    case market = "Market"
    case other = "Other"

    var id: String { rawValue }
}
