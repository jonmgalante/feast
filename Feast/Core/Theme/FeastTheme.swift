import SwiftUI

enum FeastTheme {
    enum Palette {
        static let saffron = Color(hex: 0xD0A11E)
        static let blueSlate = Color(hex: 0x435A72)
        static let stone = Color(hex: 0xECE7DF)
        static let sageGray = Color(hex: 0x748274)
        static let charcoal = Color(hex: 0x22272B)
    }

    enum Colors {
        static let primaryAccent = Palette.saffron
        static let secondaryAccent = Palette.blueSlate
        static let appBackground = Palette.stone
        static let groupedSurface = Palette.stone
        static let secondaryNeutral = Palette.sageGray
        static let primaryText = Palette.charcoal
        static let divider = Palette.sageGray.opacity(0.18)
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    enum CornerRadius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let screenTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let sectionTitle = Font.system(.headline, design: .rounded).weight(.semibold)
        static let body = Font.system(.body, design: .rounded)
        static let supporting = Font.system(.subheadline, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded)
        static let eyebrow = Font.system(.footnote, design: .rounded).weight(.semibold)
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex & 0xFF0000) >> 16) / 255,
            green: Double((hex & 0x00FF00) >> 8) / 255,
            blue: Double(hex & 0x0000FF) / 255,
            opacity: opacity
        )
    }
}
