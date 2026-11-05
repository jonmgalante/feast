import SwiftUI
import MessageUI

struct AskInvitationCard: View {
    let enterCode:()->Void
    @Environment(\.openURL) private var openURL
    @State private var showingMail=false
    @State private var showingFallback=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Ask Feast is available by invitation.").font(.headline)
            Text("Request access to get recommendations, research places, and ask questions about your collection.")
            ViewThatFits(in:.horizontal) {
                HStack {requestButton;codeButton}
                VStack(alignment:.leading){requestButton;codeButton}
            }
            Text("You can keep browsing your saved places in Cities and Map.").font(.footnote).foregroundStyle(.secondary)
            if showingFallback {
                Text("Email \(AskAccessRequest.address) to request access.").textSelection(.enabled)
                Button("Copy support email"){UIPasteboard.general.string=AskAccessRequest.address}.frame(minHeight:44)
            }
        }.padding().background(FeastTheme.Colors.accentSelection.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
        .sheet(isPresented:$showingMail){AskAccessMailComposer()}
    }
    private var requestButton:some View {Button("Request access") {
        if MFMailComposeViewController.canSendMail(){showingMail=true}
        else {openURL(AskAccessRequest.url){accepted in if !accepted {showingFallback=true}}}
    }.frame(minHeight:44)}
    private var codeButton:some View {Button("Enter invitation code",action:enterCode).frame(minHeight:44)}
}
private struct AskAccessMailComposer:UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator()->Coordinator{Coordinator(dismiss:dismiss)}
    func makeUIViewController(context:Context)->MFMailComposeViewController {
        let controller=MFMailComposeViewController();controller.mailComposeDelegate=context.coordinator
        controller.setToRecipients([AskAccessRequest.address]);controller.setSubject(AskAccessRequest.subject)
        controller.setMessageBody(AskAccessRequest.body,isHTML:false);return controller
    }
    func updateUIViewController(_ controller:MFMailComposeViewController,context:Context){}
    final class Coordinator:NSObject,MFMailComposeViewControllerDelegate {
        let dismiss:DismissAction
        init(dismiss:DismissAction){self.dismiss=dismiss}
        func mailComposeController(_ controller:MFMailComposeViewController,didFinishWith result:MFMailComposeResult,error:Error?){dismiss()}
    }
}
