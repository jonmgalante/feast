import SwiftUI
import UIKit

enum FeastTheme {
    enum Palette {
        static let saffron = Color(hex: 0xD0A11E)
        static let blueSlate = Color(hex: 0x435A72)
        static let stone = Color(hex: 0xECE7DF)
        static let warmStoneWash = Color(hex: 0xF1ECE4)
        static let warmStoneSurface = Color(hex: 0xF7F2EA)
        static let sageGray = Color(hex: 0x748274)
        static let charcoal = Color(hex: 0x22272B)
    }

    enum Colors {
        static let appBackground = Palette.stone
        static let groupedBackground = Palette.warmStoneWash
        static let surfaceBackground = Palette.warmStoneSurface

        static let primaryText = Palette.charcoal
        static let secondaryText = Color(hex: 0x536253)
        static let tertiaryText = Palette.blueSlate

        static let primaryActionFill = Palette.saffron
        static let primaryActionLabel = Palette.charcoal
        static let secondaryAction = Palette.blueSlate
        static let accentSelection = Palette.saffron
        static let dividerBorder = Palette.sageGray.opacity(0.28)
        static let mapPinTint = Palette.saffron
    }

    /// Shared Feast surfaces and text for screens that follow system appearance.
    /// Existing fixed-stone screens keep their established Colors unchanged.
    enum AdaptiveColors {
        private static func adaptive(_ light: Color, dark: UIColor) -> Color {
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : UIColor(light) })
        }
        static let groupedBackground = adaptive(Colors.groupedBackground, dark: .systemGroupedBackground)
        static let surfaceBackground = adaptive(Colors.surfaceBackground, dark: .secondarySystemGroupedBackground)
        static let primaryText = adaptive(Colors.primaryText, dark: UIColor(Palette.warmStoneSurface))
        static let secondaryText = adaptive(Colors.secondaryText, dark: UIColor(Palette.stone).withAlphaComponent(0.75))
        static let utilityAction = adaptive(Colors.secondaryAction, dark: UIColor(Palette.stone))
        static let dividerBorder = adaptive(Colors.dividerBorder, dark: UIColor(Palette.sageGray).withAlphaComponent(0.5))
    }

    enum TabBar {
        // SwiftUI selection and UIKit appearance must resolve the same app tint.
        static let selectedColor = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(Colors.primaryText) }
        static let selectedTint = Color(uiColor: selectedColor)
    }

    enum StatusBadges {
        static func colors(for status: PlaceStatus, dark: Bool) -> (fill: Color, text: Color) {
            let palette = StatusBadgePalette.colors(for: status)
            return (Color(hex: dark ? palette.darkFill : palette.lightFill),
                    Color(hex: dark ? palette.darkText : palette.lightText))
        }
    }

    enum Chrome {
        static let navigationBackground = Palette.stone.opacity(0.92)
        static let tabBarBackground = Palette.stone.opacity(0.95)
        static let floatingBarBackground = Palette.stone.opacity(0.9)
        static let mapOverlayTint = Palette.warmStoneSurface.opacity(0.78)
        static let mapOverlayShadow = Palette.charcoal.opacity(0.08)
        static let utilityAction = Colors.secondaryAction
        static let primaryAction = Colors.primaryText
        static let quietIcon = Colors.secondaryText
    }

    enum InputField {
        static let background = Colors.surfaceBackground
        static let border = Colors.dividerBorder
        static let text = Colors.primaryText
        static let prompt = Colors.secondaryText
        static let selection = Colors.accentSelection
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
        static let listTitle = Font.system(.headline, design: .rounded).weight(.semibold)
        static let rowTitle = Font.system(.subheadline, design: .rounded).weight(.semibold)
        static let rowMetadata = Font.system(.footnote, design: .rounded)
        static let rowUtility = Font.system(.footnote, design: .rounded).weight(.medium)
        static let sectionHeader = Font.system(.subheadline, design: .rounded).weight(.semibold)
        static let sectionLabel = Font.system(.caption, design: .rounded).weight(.semibold)
        static let formTitle = Font.system(.title3, design: .rounded).weight(.semibold)
        static let formFieldLabel = Font.system(.caption, design: .rounded).weight(.semibold)
        static let formHelper = Font.system(.footnote, design: .rounded)
        static let body = Font.system(.body, design: .rounded)
        static let supporting = Font.system(.subheadline, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded)
        static let eyebrow = Font.system(.footnote, design: .rounded).weight(.semibold)
    }

    static func applyAppearance() {
        let primaryText = UIColor(Palette.charcoal)
        let secondaryText = UIColor(Colors.secondaryText)
        let secondaryAction = UIColor(Palette.blueSlate)
        let navigationBackground = UIColor(Palette.stone).withAlphaComponent(0.92)
        let tabBarBackground = UIColor(Palette.stone).withAlphaComponent(0.95)
        let divider = UIColor(Palette.sageGray).withAlphaComponent(0.16)

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithDefaultBackground()
        navigationAppearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterial)
        navigationAppearance.backgroundColor = navigationBackground
        navigationAppearance.shadowColor = divider
        navigationAppearance.titleTextAttributes = [
            .foregroundColor: primaryText
        ]
        navigationAppearance.largeTitleTextAttributes = [
            .foregroundColor: primaryText
        ]

        let plainButtonAppearance = UIBarButtonItemAppearance(style: .plain)
        plainButtonAppearance.normal.titleTextAttributes = [
            .foregroundColor: secondaryAction,
            .font: UIFont.systemFont(ofSize: 17, weight: .regular)
        ]
        plainButtonAppearance.highlighted.titleTextAttributes = [
            .foregroundColor: secondaryAction.withAlphaComponent(0.7),
            .font: UIFont.systemFont(ofSize: 17, weight: .regular)
        ]
        plainButtonAppearance.disabled.titleTextAttributes = [
            .foregroundColor: secondaryText.withAlphaComponent(0.45),
            .font: UIFont.systemFont(ofSize: 17, weight: .regular)
        ]

        let prominentButtonAppearance = UIBarButtonItemAppearance(
            style: {
                if #available(iOS 26.0, *) {
                    return .prominent
                }

                return .done
            }()
        )
        prominentButtonAppearance.normal.titleTextAttributes = [
            .foregroundColor: primaryText,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        prominentButtonAppearance.highlighted.titleTextAttributes = [
            .foregroundColor: primaryText.withAlphaComponent(0.74),
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        prominentButtonAppearance.disabled.titleTextAttributes = [
            .foregroundColor: secondaryText.withAlphaComponent(0.45),
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]

        navigationAppearance.buttonAppearance = plainButtonAppearance
        navigationAppearance.backButtonAppearance = plainButtonAppearance
        if #available(iOS 26.0, *) {
            navigationAppearance.prominentButtonAppearance = prominentButtonAppearance
        } else {
            navigationAppearance.doneButtonAppearance = prominentButtonAppearance
        }

        let navigationBarAppearance = UINavigationBar.appearance()
        navigationBarAppearance.standardAppearance = navigationAppearance
        navigationBarAppearance.scrollEdgeAppearance = navigationAppearance
        navigationBarAppearance.compactAppearance = navigationAppearance
        navigationBarAppearance.tintColor = secondaryAction

        // Native tab labels/icons need contrast on the system's dark tab surface.
        // Preserve Feast's existing light colors and native typography.
        let selectedTabColor = TabBar.selectedColor
        let unselectedTabColor = UIColor { $0.userInterfaceStyle == .dark ? .lightGray : secondaryText }
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        tabBarAppearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterial)
        tabBarAppearance.backgroundColor = tabBarBackground
        tabBarAppearance.shadowColor = divider

        for itemAppearance in [
            tabBarAppearance.stackedLayoutAppearance,
            tabBarAppearance.inlineLayoutAppearance,
            tabBarAppearance.compactInlineLayoutAppearance
        ] {
            itemAppearance.normal.iconColor = unselectedTabColor
            itemAppearance.normal.titleTextAttributes = [
                .foregroundColor: unselectedTabColor,
                .font: UIFont.systemFont(ofSize: 10, weight: .medium)
            ]
            itemAppearance.selected.iconColor = selectedTabColor
            itemAppearance.selected.titleTextAttributes = [
                .foregroundColor: selectedTabColor,
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold)
            ]
        }

        let tabBarProxy = UITabBar.appearance()
        tabBarProxy.standardAppearance = tabBarAppearance
        tabBarProxy.scrollEdgeAppearance = tabBarAppearance
        tabBarProxy.tintColor = selectedTabColor
        tabBarProxy.unselectedItemTintColor = unselectedTabColor

        UISearchBar.appearance().tintColor = secondaryAction
        // Search chrome sits on Feast's fixed light stone surfaces in either appearance.
        UISearchTextField.appearance().textColor = primaryText
        UISearchTextField.appearance().tintColor = secondaryAction
    }
}

struct FeastProminentButtonStyle: ButtonStyle {
    enum Size {
        case regular
        case compactBottomBar

        var minHeight: CGFloat {
            switch self {
            case .regular:
                return 50
            case .compactBottomBar:
                return 46
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .regular:
                return FeastTheme.Spacing.small
            case .compactBottomBar:
                return FeastTheme.Spacing.xSmall
            }
        }
    }

    @Environment(\.isEnabled) private var isEnabled
    private let size: Size

    init(size: Size = .regular) {
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FeastTheme.Typography.body.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.88)
            .frame(minHeight: size.minHeight)
            .padding(.horizontal, FeastTheme.Spacing.large)
            .padding(.vertical, size.verticalPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .fill(fillColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .stroke(
                    foregroundColor.opacity(0.06),
                    lineWidth: 1
                )
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        FeastTheme.Colors.surfaceBackground
    }

    private func fillColor(isPressed: Bool) -> Color {
        let baseOpacity = isEnabled ? 1.0 : 0.45
        let pressedOpacity = isPressed ? 0.88 : 1.0
        return FeastTheme.Palette.blueSlate.opacity(baseOpacity * pressedOpacity)
    }
}

struct FeastInlineActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var adaptive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FeastTheme.Typography.supporting.weight(.semibold))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        let baseOpacity = isEnabled ? 1.0 : 0.45
        let pressedOpacity = isPressed ? 0.72 : 1.0
        return (adaptive ? FeastTheme.AdaptiveColors.utilityAction : FeastTheme.Colors.secondaryAction).opacity(baseOpacity * pressedOpacity)
    }
}

struct FeastQuietChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FeastTheme.Typography.rowUtility)
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, FeastTheme.Spacing.medium)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .background {
                Capsule(style: .continuous)
                    .fill(FeastTheme.Colors.surfaceBackground.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(FeastTheme.Colors.dividerBorder.opacity(0.9), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        let baseColor = isEnabled ? FeastTheme.Colors.secondaryAction : FeastTheme.Colors.secondaryText
        return baseColor.opacity(isPressed ? 0.74 : 1)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        let baseOpacity = isEnabled ? 0.92 : 0.62
        return isPressed ? baseOpacity * 0.9 : baseOpacity
    }
}

struct FeastToolbarSymbol: View {
    let systemName: String
    var isEmphasized = false

    var body: some View {
        Image(systemName: systemName)
            .feastUtilitySymbol(isEmphasized: isEmphasized)
    }
}

struct FeastToolbarActionCluster<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(FeastTheme.Colors.surfaceBackground.opacity(0.92))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(FeastTheme.Colors.dividerBorder.opacity(0.9), lineWidth: 1)
        }
        .shadow(
            color: FeastTheme.Chrome.mapOverlayShadow.opacity(0.45),
            radius: 10,
            x: 0,
            y: 4
        )
    }
}

extension View {
    func feastScrollableChrome() -> some View {
        modifier(FeastScrollableChromeModifier())
    }

    func feastSectionSurface() -> some View {
        modifier(FeastSectionSurfaceModifier())
    }

    func feastCardSurface(cornerRadius: CGFloat = FeastTheme.CornerRadius.large) -> some View {
        modifier(FeastCardSurfaceModifier(cornerRadius: cornerRadius))
    }

    func feastInputField() -> some View {
        modifier(FeastInputFieldModifier())
    }

    func feastFieldSurface(minHeight: CGFloat? = nil) -> some View {
        modifier(FeastFieldSurfaceModifier(minHeight: minHeight))
    }

    func feastMapOverlayCard(cornerRadius: CGFloat = FeastTheme.CornerRadius.large) -> some View {
        modifier(FeastMapOverlayCardModifier(cornerRadius: cornerRadius))
    }

    func feastUtilitySymbol(isEmphasized: Bool = false) -> some View {
        modifier(FeastUtilitySymbolModifier(isEmphasized: isEmphasized))
    }

    func feastBottomBarChrome() -> some View {
        modifier(FeastBottomBarChromeModifier())
    }
}

struct FeastFormSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(FeastTheme.Typography.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(FeastTheme.Colors.secondaryText)

            if let subtitle {
                Text(subtitle)
                    .font(FeastTheme.Typography.rowUtility)
                    .foregroundStyle(FeastTheme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
    }
}

struct FeastFormGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FeastTheme.Spacing.large)
        .background {
            RoundedRectangle(
                cornerRadius: FeastTheme.CornerRadius.medium,
                style: .continuous
            )
            .fill(FeastTheme.Colors.surfaceBackground)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: FeastTheme.CornerRadius.medium,
                style: .continuous
            )
            .stroke(FeastTheme.Colors.dividerBorder, lineWidth: 1)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: FeastTheme.CornerRadius.medium,
                style: .continuous
            )
        )
        .listRowInsets(
            EdgeInsets(
                top: 6,
                leading: FeastTheme.Spacing.large,
                bottom: 6,
                trailing: FeastTheme.Spacing.large
            )
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

struct FeastFormField<Content: View>: View {
    let title: String
    var helper: String?
    var helperColor: Color = FeastTheme.Colors.tertiaryText
    private let content: Content

    init(
        title: String,
        helper: String? = nil,
        helperColor: Color = FeastTheme.Colors.secondaryText,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.helper = helper
        self.helperColor = helperColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
            Text(title)
                .font(FeastTheme.Typography.formFieldLabel)
                .foregroundStyle(FeastTheme.Colors.secondaryText)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if let helper {
                Text(helper)
                    .font(FeastTheme.Typography.formHelper)
                    .foregroundStyle(helperColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FeastMultilineTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.InputField.prompt)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(FeastTheme.Typography.supporting)
                .foregroundStyle(FeastTheme.InputField.text)
                .tint(FeastTheme.InputField.selection)
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .frame(
                    minWidth: nil,
                    idealWidth: nil,
                    maxWidth: .infinity,
                    minHeight: editorMinHeight,
                    idealHeight: nil,
                    maxHeight: nil,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .feastFieldSurface(minHeight: minHeight)
    }

    private var editorMinHeight: CGFloat {
        max(minHeight - 20, 0)
    }
}

struct FeastSingleLineTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var textInputAutocapitalization: TextInputAutocapitalization = .sentences
    var autocorrectionDisabled = false

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(FeastTheme.Typography.supporting)
                    .foregroundStyle(FeastTheme.InputField.prompt)
                    .allowsHitTesting(false)
            }

            TextField("", text: $text)
                .font(FeastTheme.Typography.supporting)
                .foregroundStyle(FeastTheme.InputField.text)
                .tint(FeastTheme.InputField.selection)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(textInputAutocapitalization)
                .autocorrectionDisabled(autocorrectionDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .feastFieldSurface()
    }
}

struct FeastFieldInlineAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(FeastInlineActionButtonStyle())
    }
}

struct FeastFormDivider: View {
    var body: some View {
        Rectangle()
            .fill(FeastTheme.Colors.dividerBorder)
            .frame(height: 1)
            .padding(.vertical, FeastTheme.Spacing.medium)
    }
}

private struct FeastScrollableChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(FeastTheme.Colors.primaryText)
            .toolbarColorScheme(.light, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .background(FeastTheme.Colors.groupedBackground.ignoresSafeArea())
            .listRowSeparatorTint(FeastTheme.Colors.dividerBorder)
    }
}

private struct FeastSectionSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(FeastTheme.Colors.surfaceBackground)
    }
}

private struct FeastCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(FeastTheme.Colors.surfaceBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(FeastTheme.Colors.dividerBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct FeastInputFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(FeastTheme.InputField.text)
            .tint(FeastTheme.InputField.selection)
            .listRowBackground(FeastTheme.InputField.background)
    }
}

private struct FeastFieldSurfaceModifier: ViewModifier {
    let minHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .font(FeastTheme.Typography.supporting)
            .foregroundStyle(FeastTheme.InputField.text)
            .tint(FeastTheme.InputField.selection)
            .padding(.horizontal, FeastTheme.Spacing.medium)
            .padding(.vertical, 10)
            .frame(
                minWidth: nil,
                idealWidth: nil,
                maxWidth: .infinity,
                minHeight: minHeight,
                idealHeight: nil,
                maxHeight: nil,
                alignment: .topLeading
            )
            .background {
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .fill(FeastTheme.InputField.background)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .stroke(FeastTheme.InputField.border, lineWidth: 1)
            }
    }
}

private struct FeastMapOverlayCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(FeastTheme.Chrome.mapOverlayTint)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(FeastTheme.Colors.dividerBorder.opacity(0.92), lineWidth: 1)
            }
            .shadow(
                color: FeastTheme.Chrome.mapOverlayShadow,
                radius: 18,
                x: 0,
                y: 10
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct FeastUtilitySymbolModifier: ViewModifier {
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isEmphasized ? FeastTheme.Colors.primaryText : FeastTheme.Chrome.utilityAction)
    }
}

private struct FeastBottomBarChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, FeastTheme.Spacing.large)
            .padding(.top, FeastTheme.Spacing.small)
            .padding(.bottom, FeastTheme.Spacing.xSmall)
            .background {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(FeastTheme.Colors.dividerBorder.opacity(0.55))
                        .frame(height: 1)

                    FeastTheme.Chrome.floatingBarBackground
                }
                .ignoresSafeArea(edges: .bottom)
            }
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
