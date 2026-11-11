import SwiftUI

struct AskPrivacyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AskPrivacy.onlineKey) private var onlineAllowed = false
    var onlineConfigured = false
    var body: some View {
        Form {
                Section {
                    if onlineConfigured || onlineAllowed {
                        Toggle("Allow online AI",isOn:$onlineAllowed)
                    } else { Text("Online answers aren’t configured on this device. Saved-place lists and filters still work.") }
                    Text(AskPrivacy.disclosure).font(FeastTheme.Typography.formHelper).foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)
                } header: { Text("Online answers") } footer: {
                    Text("Saved-place lists and filters work without online AI. Turning this off prevents new AI requests; it cannot recall a request already sent.").foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)
                }
                .listRowBackground(FeastTheme.AdaptiveColors.surfaceBackground)
                .listRowSeparatorTint(FeastTheme.AdaptiveColors.dividerBorder)
                Section("Privacy") {
                    Text("Only images you choose are sent. Image location and camera metadata are removed. Your device location is not automatically sent to Ask.")
                    Text("Feast requests no OpenAI response storage. Provider retention rules still apply.")
                    Link("OpenAI data controls",destination:URL(string:"https://platform.openai.com/docs/guides/your-data")!).foregroundStyle(FeastTheme.AdaptiveColors.utilityAction)
                    Link("Cloudflare privacy policy",destination:URL(string:"https://www.cloudflare.com/privacypolicy/")!).foregroundStyle(FeastTheme.AdaptiveColors.utilityAction)
                    if let url = publicURL("FeastPrivacyPolicyURL") { Link("Feast privacy policy",destination:url).foregroundStyle(FeastTheme.AdaptiveColors.utilityAction) }
                    if let url = publicURL("FeastSupportURL") { Link("Feast support",destination:url).foregroundStyle(FeastTheme.AdaptiveColors.utilityAction) }
                }
                .listRowBackground(FeastTheme.AdaptiveColors.surfaceBackground)
                .listRowSeparatorTint(FeastTheme.AdaptiveColors.dividerBorder)
            }
            .fontDesign(.rounded)
            .foregroundStyle(FeastTheme.AdaptiveColors.primaryText)
            .tint(FeastTheme.AdaptiveColors.utilityAction)
            .scrollContentBackground(.hidden)
            .background(FeastTheme.AdaptiveColors.groupedBackground)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.principal) {Text("Settings").font(FeastTheme.Typography.listTitle).foregroundStyle(FeastTheme.AdaptiveColors.primaryText)}}
            .toolbarBackground(FeastTheme.AdaptiveColors.groupedBackground,for:.navigationBar)
            .toolbarColorScheme(colorScheme,for:.navigationBar)

    }
    private func publicURL(_ key:String) -> URL? {
        AskPublicLinks.url(key)
    }
}
