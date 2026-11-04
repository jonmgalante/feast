import Foundation

/// Opaque text/fill pairs keep contrast independent of the row underneath.
nonisolated enum StatusBadgePalette {
    struct Colors {
        let lightFill: UInt32
        let lightText: UInt32
        let darkFill: UInt32
        let darkText: UInt32
    }

    static func colors(for status: PlaceStatus) -> Colors {
        switch status {
        case .wantToTry: // Warm sand
            Colors(lightFill: 0xF2E6D3, lightText: 0x705125, darkFill: 0x3C3224, darkText: 0xE6C99C)
        case .justOpened: // Pale sky blue
            Colors(lightFill: 0xDFEDF7, lightText: 0x315A78, darkFill: 0x253746, darkText: 0xB2D3EB)
        case .been: // Soft sage
            Colors(lightFill: 0xE3ECE2, lightText: 0x3F6147, darkFill: 0x2C3A2F, darkText: 0xBBD6BB)
        case .love: // Dusty rose
            Colors(lightFill: 0xF3E2E6, lightText: 0x824657, darkFill: 0x432D35, darkText: 0xEDB9C7)
        case .regulars: // Muted lavender
            Colors(lightFill: 0xEAE4F3, lightText: 0x61497F, darkFill: 0x352E44, darkText: 0xD4C0EA)
        }
    }
}
