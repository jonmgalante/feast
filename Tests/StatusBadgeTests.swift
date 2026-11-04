import Foundation

nonisolated enum StatusBadgeTests {
    static func run() {
        func luminance(_ rgb: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((rgb >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        func contrast(_ fill: UInt32, _ text: UInt32) -> Double {
            let a = luminance(fill), b = luminance(text)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        var lightFills: Set<UInt32> = [], darkFills: Set<UInt32> = []
        for status in PlaceStatus.allCases {
            let colors = StatusBadgePalette.colors(for: status)
            let light = contrast(colors.lightFill, colors.lightText)
            let dark = contrast(colors.darkFill, colors.darkText)
            precondition(light >= 4.5 && dark >= 4.5)
            lightFills.insert(colors.lightFill); darkFills.insert(colors.darkFill)
            print("CONTRAST \(status.rawValue): light \(String(format: "%.2f", light)):1; dark \(String(format: "%.2f", dark)):1")
        }
        precondition(lightFills.count == 5 && darkFills.count == 5)
        print("PASS all five status badge palettes have distinct light/dark fills and text contrast above 4.5:1")
    }
}
