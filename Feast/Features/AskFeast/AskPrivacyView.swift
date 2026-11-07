import SwiftUI

struct AskPrivacyView: View {
    @AppStorage(AskPrivacy.onlineKey) private var onlineAllowed = false
    var onlineConfigured = false
    var body: some View {
        Form {
                Section {
                    if onlineConfigured || onlineAllowed {
                        Toggle("Allow online AI",isOn:$onlineAllowed)
                    } else { Text("Online answers aren’t configured on this device. Saved-place lists and filters still work.") }
                    Text(AskPrivacy.disclosure).font(.footnote)
                } header: { Text("Online answers") } footer: {
                    Text("Saved-place lists and filters work without online AI. Turning this off prevents new AI requests; it cannot recall a request already sent.")
                }
                Section("Privacy") {
                    Text("Only images you choose are sent. Image location and camera metadata are removed. Your device location is not automatically sent to Ask.")
                    Text("Feast requests no OpenAI response storage. Provider retention rules still apply.")
                    Link("OpenAI data controls",destination:URL(string:"https://platform.openai.com/docs/guides/your-data")!)
                    Link("Cloudflare privacy policy",destination:URL(string:"https://www.cloudflare.com/privacypolicy/")!)
                    if let url = publicURL("FeastPrivacyPolicyURL") { Link("Feast privacy policy",destination:url) }
                    if let url = publicURL("FeastSupportURL") { Link("Feast support",destination:url) }
                }
            }
            .navigationTitle("Settings")

    }
    private func publicURL(_ key:String) -> URL? {
        AskPublicLinks.url(key)
    }
}
