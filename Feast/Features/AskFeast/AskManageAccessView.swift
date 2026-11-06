import SwiftUI

struct AskManageAccessView: View {
    let configuration: AskHostedConfiguration
    @StateObject private var model=AskAccessManagement()
    @State private var label=""
    @State private var discard=false
    @State private var revoking:AskAccessEntry?
    var body: some View {
        Form {
            if let pending=model.pending {
                Section("Pending operation") {
                    if let entry=model.confirmed,entry.id==pending.id,pending.kind=="invite" {
                        Text(entry.label).font(.headline)
                        if entry.state=="invited",let code=pending.invitation {
                            Text("Single-use invitation. Anyone with this code can claim access on one device. Share it privately.")
                            ShareLink("Share invitation code",item:code).frame(minHeight:44)
                            Text("Redeem by \(Date(timeIntervalSince1970:entry.expiresAt/1000).formatted(date:.abbreviated,time:.shortened)). Activated access lasts until revoked.")
                        } else {Text("Invitation is \(entry.state). No unused code is available to share.")}
                        Button("Done with invitation"){model.finishInvitation()}.disabled(model.working)
                    } else {
                        Text("An operation is waiting to be verified. Retry checks the same invitation or revocation.")
                        Button("Retry pending operation"){Task{await model.retry(configuration:configuration)}}.disabled(model.working)
                    }
                }
                if model.canDiscardPending {Button("Clear pending operation"){discard=true}.disabled(model.working)}
            } else {
                Section {
                    TextField("Name, for example Juliet",text:$label).autocorrectionDisabled()
                    Button("Create invitation") {Task{await model.create(label:label,configuration:configuration)}}
                        .disabled(model.working || label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                } header:{Text("Invite a member")} footer:{Text("This label helps you recognize access; it doesn't verify someone's identity. Invitations expire after 24 hours. Each code activates one device, with access until revoked.")}
            }
            Section("Access") {
                ForEach(model.entries) {entry in
                    VStack(alignment:.leading,spacing:8) {
                        Text(entry.label).font(.headline)
                        Text("\(entry.role.capitalized) · \(entry.state.capitalized)").foregroundStyle(.secondary)
                        Text("ID \(entry.id.uuidString.lowercased().suffix(12)) · Created \(Date(timeIntervalSince1970:entry.createdAt/1000).formatted(date:.abbreviated,time:.shortened))").font(.caption).textSelection(.enabled)
                        if entry.role=="member",entry.state != "revoked" {
                            Button("Revoke access",role:.destructive){revoking=entry}.disabled(model.working)
                        }
                    }.padding(.vertical,4)
                }
                Button("Refresh access"){Task{await model.refresh(configuration:configuration)}}.disabled(model.working)
            }
            if model.working {ProgressView("Checking access…")}
            if let message=model.message {Section{Text(message).foregroundStyle(.secondary)}}
            Section {Text("If you lose this owner phone, recover access through your existing Cloudflare administration. Owner replacement is managed there so an invitation cannot grant owner authority.")}
        }.navigationTitle("Manage Access").navigationBarTitleDisplayMode(.inline)
        .task{await model.refresh(configuration:configuration)}
        .alert("Clear local pending operation?",isPresented:$discard) {
            Button("Clear",role:.destructive){model.discardRejectedPending()}
            Button("Cancel",role:.cancel){}
        } message:{Text("This removes the pending copy from this phone. It does not revoke access already shown in the refreshed directory; revoke that entry separately if needed.")}
        .confirmationDialog("Revoke access?",isPresented:Binding(get:{revoking != nil},set:{if !$0{revoking=nil}}),titleVisibility:.visible) {
            Button("Revoke access",role:.destructive){if let e=revoking{Task{await model.revoke(e,configuration:configuration)}};revoking=nil}
            Button("Cancel",role:.cancel){revoking=nil}
        } message:{Text("This stops future Ask Feast requests for \(revoking?.label ?? "this device") (ID \(revoking?.id.uuidString.lowercased().suffix(12) ?? "")). A request already underway may finish. Saved places and CloudKit sharing are unaffected.")}
    }
}
