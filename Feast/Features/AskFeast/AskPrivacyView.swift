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
                    Text("Your saved places remain in Feast and your configured iCloud stores. Ask only reads them. It never saves, edits or deletes a place without the normal review and Save flow.")
                    Text("Only an image you choose and send is uploaded. Its location and camera metadata are stripped first. Images are not kept in conversation history.")
                    Text("Your location is used for the map when you allow it. It is not automatically included in Ask requests.")
                }
                Section("Processing and storage") {
                    Text("Public lookups use only the business name, city and requested facts. Saved notes, statuses and chat history aren’t sent to public search.")
                    Text("Online services process the questions and details you send. Feast requests no OpenAI response storage, but provider retention rules and account settings still apply. The backend records access identifiers and usage to enforce spending limits.")
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
