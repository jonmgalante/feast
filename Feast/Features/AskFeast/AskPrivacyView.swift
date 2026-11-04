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
                Section("Your collection") {
                    Text("Your saved places stay in Feast and your configured iCloud stores. Ask can read permitted details and make supported changes when you instruct it or use a Save action. It asks when a target or conflicting change needs clarification. Available Undo actions are shown after a change is saved.")
                    Text("Where image sending is available, only an image you choose and send is uploaded. Its location and camera metadata are stripped first. Images are not kept in conversation history.")
                    Text("Your location is used for the map when you allow it. It is not automatically included in Ask requests.")
                }
                Section("Processing and storage") {
                    Text("For web research, OpenAI can create searches from your question and the permitted public context described above. Those search queries are sent to search services, and relevant public pages may be retrieved. Feast excludes saved notes, tags, statuses and unselected photos from this context. Information you type into a question may be included in a search when relevant.")
                    Text("Online services process the questions and details you send. Feast requests no OpenAI response storage, but provider retention rules and account settings still apply.")
                    Text("Feast’s backend records access identifiers, request identifiers, timing and usage information to authenticate requests, prevent duplicate work and track provider usage. Spending is managed through the provider account. Access can be revoked separately for each approved device.")
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
