// Isolated, synthetic-only UI harness. No real collection, credentials or network.
import SwiftUI
import CoreData
import UIKit

private struct OfflineKeyboardProvider: AskFeastProvider {
    let label = "Offline keyboard test"
    func answer(_ request:AskRequest,tools:AskReadTools) async throws -> AskResponse {
        try await Task.sleep(for:.seconds(ProcessInfo.processInfo.arguments.contains("-slowAnswer") ? 20 : 6))
        return .init(summary:"Synthetic answer complete. The keyboard gesture did not send or cancel anything.",candidates:[])
    }
}
@MainActor enum KeyboardQA {
    static let persistence=PersistenceController(inMemory:true,cloudKitSyncConfiguration:nil)
    static let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    static var last=""
    static func log(_ value:String) {
        let file=directory.appendingPathComponent("keyboard.log")
        let line="\(Date().timeIntervalSince1970) \(value)\n"
        if let handle=try? FileHandle(forWritingTo:file) {try? handle.seekToEnd();try? handle.write(contentsOf:Data(line.utf8));try? handle.close()}
        else {try? Data(line.utf8).write(to:file)}
    }
    static func prepare(_ state:AskFeastTabState) throws {
        AskPrivacy.accept()
        let context=persistence.viewContext
        let city=FeastList(context:context);city.id=UUID();city.name="Synthetic City";city.createdAt=Date();city.updatedAt=Date();try context.save()
        let paragraphs=(0..<3).map {n in AskAnswerParagraph(id:"p\(n)",spans:[.text("Synthetic answer paragraph \(n). Keep selection, copying, and normal transcript scrolling working. This is disposable fixture text, not a real place or query.")],sourceIDs:[])}
        let response=AskResponse(summary:"Synthetic answer",candidates:[],paragraphs:paragraphs)
        let count=ProcessInfo.processInfo.arguments.contains("-empty") ? 0 : 24
        let turns=(0..<count).map {n in AskArchivedTurn(AskTurn(id:UUID(),request:.init(mode:.discovery,text:"Synthetic question \(n)",fromOCR:false),response:response,status:.complete))}
        let draft=ProcessInfo.processInfo.arguments.contains("-longDraft") ? (1...18).map {"Draft line \($0): preserve multiline editing."}.joined(separator:"\n") : "Unsent synthetic draft"
        let chat=AskChatArchive(id:UUID(),title:"Keyboard long chat",updatedAt:Date(),conversation:.init(draft:draft,turns:turns))
        let other=AskChatArchive(id:UUID(),title:"Other synthetic chat",updatedAt:Date().addingTimeInterval(-10),conversation:.init(draft:"Other preserved draft",turns:Array(turns.prefix(2))))
        guard let store=AskConversationStore.applicationStore(),store.saveLibrary(.init(activeID:chat.id,chats:[chat,other])) else {throw AskError.invalidEvidence}
        let adapter=AskSavedCollection(context:context,visibleCities:{[city.id!]})
        state.prepareSavedCollection(adapter,provider:OfflineKeyboardProvider())
        guard let session=state.session else {throw AskError.invalidEvidence}
        _=session.replaceProviderWhenIdle(OfflineKeyboardProvider())
        log("PREPARED count=\(count) draft=\(draft.debugDescription)")
    }
    static func snapshot(_ state:AskFeastTabState,tab:Int) {
        var lines=["tab=\(tab) chat=\(state.session?.activeChatID.uuidString ?? "nil") turns=\(state.session?.turns.count ?? -1) loading=\(state.session?.isLoading ?? false) input=\(state.session?.input.debugDescription ?? "nil")"]
        func walk(_ view:UIView) {
            if let scroll=view as? UIScrollView {
                var info="\(type(of:scroll)) frame=\(scroll.convert(scroll.bounds,to:nil)) offset=\(scroll.contentOffset) size=\(scroll.contentSize) enabled=\(scroll.isScrollEnabled) dismiss=\(scroll.keyboardDismissMode.rawValue) pan=\(scroll.panGestureRecognizer.state.rawValue) first=\(scroll.isFirstResponder)"
                if let text=scroll as? UITextView {info+=" selection=\(text.selectedRange)"}
                lines.append(info)
            } else if view is UITextField {lines.append("TEXTFIELD \(type(of:view)) first=\(view.isFirstResponder)")}
            for child in view.subviews {walk(child)}
        }
        for window in UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).flatMap(\.windows) {walk(window)}
        let result=lines.joined(separator:"\n")
        if result != last {last=result;log(result)}
    }
}
struct KeyboardRoot:View {
    @StateObject private var state=AskFeastTabState()
    @State private var ready=false
    @State private var tab=2
    var body:some View {
        Group {
            if ready {
                TabView(selection:$tab) {
                    Text("Synthetic Cities tab").tabItem {Label("Cities",systemImage:"building.2")}.tag(0)
                    Text("Synthetic Map tab").tabItem {Label("Map",systemImage:"map")}.tag(1)
                    AskFeastTab(state:state,realContext:KeyboardQA.persistence.viewContext).tabItem {Label("Ask Feast",systemImage:"bubble.left")}.tag(2)
                }.onChange(of:tab) {_,value in state.selectionChanged(to:value)}
            } else {Text("Preparing keyboard QA")}
        }
        .environment(\.dynamicTypeSize,ProcessInfo.processInfo.arguments.contains("-accessibility") ? .accessibility3 : .large)
        .environment(\.managedObjectContext,KeyboardQA.persistence.viewContext)
        .environment(\.persistenceController,KeyboardQA.persistence)
        .task {
            do {try KeyboardQA.prepare(state);ready=true} catch {KeyboardQA.log("HARNESS_ERROR \(error)")}
            while !Task.isCancelled {KeyboardQA.snapshot(state,tab:tab);try? await Task.sleep(for:.milliseconds(150))}
        }
    }
}
@main struct FeastApp:App {var body:some Scene {WindowGroup {KeyboardRoot()}}}
