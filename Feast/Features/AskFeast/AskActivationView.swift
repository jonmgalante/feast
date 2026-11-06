import SwiftUI

struct AskActivationView: View {
    let configuration:AskHostedConfiguration
    let onActivated:(_ newActivation:Bool)->Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var activation=AskPhoneActivation()
    @State private var code=""
    @State private var connectionMessage:String?
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    if activation.activated {
                        Label(activation.verifiedRole == nil ? "Access saved on this device" : "Ask Feast access is active",systemImage:activation.verifiedRole == nil ? "key" : "checkmark.circle")
                        if let role=activation.verifiedRole {Text(role == .owner ? "Owner access verified" : "Member access verified").foregroundStyle(.secondary)}
                        Button("Continue") { connect() }.disabled(activation.working)
                        if activation.isOwner {NavigationLink("Manage Access"){AskManageAccessView(configuration:configuration)}}
                        Button(activation.working ? "Checking access…" : "Check access") {connectionMessage=nil;Task{await activation.checkAccess(configuration:configuration)}}.disabled(activation.working)
                    } else {
                        Text("Enter the code you received for this device. Your cities, saved places and sharing stay as they are.")
                        if !activation.hasPending {
                            SecureField("Activation code",text:$code).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                                .accessibilityIdentifier("ask.activation.code")
                        } else { Text("An earlier activation is waiting to be checked. Retry checks the same device and code.") }
                        Button(activation.working ? "Activating…" : activation.hasPending ? "Retry activation" : "Activate") {
                            Task {await activation.activate(code:code,configuration:configuration);code="";if activation.didActivate {connect()}}
                        }.disabled(activation.working || (!activation.hasPending && code.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty))
                         .accessibilityIdentifier("ask.activation.submit")
                    }
                    if let message=connectionMessage ?? activation.message {Text(message).foregroundStyle(.secondary)}
                } header: {Text(activation.activated ? "This device" : "Activate Ask Feast")} footer: {
                    Text("Activation sends the code and a device access identifier to Feast’s Cloudflare service. It does not send your collection or grant permission to send AI requests. You’ll review that permission before your first online question.")
                    if let support=AskPublicLinks.url("FeastSupportURL") {
                        Link("Feast support",destination:support).frame(minHeight:44,alignment:.leading)
                    }
                }
            }.navigationTitle("Ask Feast access").navigationBarTitleDisplayMode(.inline)
             .task {if activation.activated {await activation.checkAccess(configuration:configuration)}}
             .toolbar {ToolbarItem(placement:.cancellationAction){Button("Close"){dismiss()}}}
        }
    }
    private func connect(){if onActivated(activation.didActivate){dismiss()}else{connectionMessage="Access is ready. Wait for the current request to finish, then tap Continue."}}
}
