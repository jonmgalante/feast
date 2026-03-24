import SwiftUI
import UIKit

struct BrandWordmarkView: View {
    var body: some View {
        Group {
            if let wordmarkImage = UIImage(named: "FeastWordmark") {
                Image(uiImage: wordmarkImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 30)
                    .accessibilityLabel("Feast")
            } else {
                Text("Feast")
                    .font(.system(size: 32, weight: .regular, design: .serif))
                    .tracking(-0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .accessibilityLabel("Feast")
            }
        }
        .foregroundStyle(FeastTheme.Colors.primaryText)
        .accessibilityAddTraits(.isHeader)
    }
}
