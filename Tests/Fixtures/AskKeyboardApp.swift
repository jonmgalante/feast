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
    static var fixtureAccess = true
    static var collectionPlace: SavedPlace?
    static var last=""
    static var fittingMinimumOffset: CGFloat = 0
    static var fittingMaximumOffset: CGFloat = 0
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
        let place=SavedPlace(context:context)
        place.id=UUID();place.applePlaceID="synthetic-keyboard-place";place.displayNameSnapshot="Synthetic Cafe";place.feastList=city
        place.status=PlaceStatus.wantToTry.rawValue;place.placeType=PlaceType.cafe.rawValue;place.createdAt=Date();place.updatedAt=Date();try context.save()
        collectionPlace=place
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},visibleCities:{fixtureAccess ? [city.id!] : []})
        var collectionAction: AskCollectionAction?
        // Same journal location used by the real state wiring, inside this disposable app identity.
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let testEngine=AskCollectionChangeEngine(adapter:adapter,journalURL:support.appendingPathComponent("AskFeast/collection-actions-v1.json"))
        if ProcessInfo.processInfo.arguments.contains("-collectionAction") {
            let id=place.id!.uuidString
            let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[id],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"name",value:"Updated synthetic cafe",values:nil,findingID:nil)],instructionQuote:"Rename this synthetic cafe")
            let grant=AskChangeGrant(question:proposal.instructionQuote,entity:"place",operations:["update"],fields:["name"],targetIDs:[id],allowsCreation:false,boundProposal:proposal)
            let ready=try testEngine.prepare(proposal,question:proposal.instructionQuote,authorization:grant,findings:[])
            collectionAction=try testEngine.apply(ready.id,authorization:grant)
        }
        let paragraphs=(0..<3).map {n in AskAnswerParagraph(id:"p\(n)",spans:[.text("Synthetic answer paragraph \(n). Keep selection, copying, and normal transcript scrolling working. This is disposable fixture text, not a real place or query.")],sourceIDs:[])}

        let requestedCount=ProcessInfo.processInfo.arguments.first {$0.hasPrefix("-turnCount=")}.flatMap {Int($0.dropFirst("-turnCount=".count))} ?? 24
        let count=ProcessInfo.processInfo.arguments.contains("-empty") ? 0 : requestedCount
        let turns=(0..<count).map {n in
            let tail=AskAnswerParagraph(id:"tail",spans:[.text("ANSWER TAIL \(n)")],sourceIDs:[])
            var response=AskResponse(summary:"Synthetic answer",candidates:[],paragraphs:paragraphs+[tail])
            if n == count-1,let collectionAction {response.collectionActions=[collectionAction];response.usesLocalCatalog=true}
            if ProcessInfo.processInfo.arguments.contains("-projection") { response.historyRecordIDs=[place.id!.uuidString] }
            return AskArchivedTurn(AskTurn(id:UUID(),request:.init(mode:.discovery,text:"Synthetic question \(n)",fromOCR:false),response:response,status:.complete))
        }
        var draft=ProcessInfo.processInfo.arguments.contains("-longDraft") ? (1...18).map {"Draft line \($0): preserve multiline editing."}.joined(separator:"\n") : "Unsent synthetic draft"
        if ProcessInfo.processInfo.arguments.contains("-wrappedDraft") { draft=String(repeating:"The native editor keeps wrapped text intact. ",count:12) }
        if ProcessInfo.processInfo.arguments.contains("-emptyDraft") { draft="" }
        if let argument=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("-draftLines=")}),let lines=Int(argument.dropFirst("-draftLines=".count)) {
            draft=(1...lines).map {"Line \($0)"}.joined(separator:"\n")
        }
        let chat=AskChatArchive(id:UUID(),title:"Keyboard long chat",updatedAt:Date(),conversation:.init(draft:draft,turns:turns))
        let other=AskChatArchive(id:UUID(),title:"Other synthetic chat",updatedAt:Date().addingTimeInterval(-10),conversation:.init(draft:"Other preserved draft",turns:ProcessInfo.processInfo.arguments.contains("-equalCount") ? Array(turns.reversed()) : Array(turns.prefix(2))))
        guard let store=AskConversationStore.applicationStore(),store.saveLibrary(.init(activeID:chat.id,chats:[chat,other])) else {throw AskError.invalidEvidence}
        state.prepareSavedCollection(adapter,provider:OfflineKeyboardProvider())
        guard let session=state.session else {throw AskError.invalidEvidence}
        _=session.replaceProviderWhenIdle(OfflineKeyboardProvider())
        log("PREPARED count=\(count) draft=\(draft.debugDescription)")
    }
    static var dynamicTypeSize: DynamicTypeSize {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-accessibility") { return .accessibility3 }
        let sizes: [String: DynamicTypeSize] = [
            "xSmall": .xSmall, "small": .small, "medium": .medium, "large": .large,
            "xLarge": .xLarge, "xxLarge": .xxLarge, "xxxLarge": .xxxLarge
        ]
        let requested = arguments.first { $0.hasPrefix("-size=") }.map { String($0.dropFirst(6)) }
        return requested.flatMap { sizes[$0] } ?? .large
    }
    static func snapshot(_ state:AskFeastTabState,tab:Int) -> String {
        var editorMetrics = "unavailable"
        var lines=["tab=\(tab) chat=\(state.session?.activeChatID.uuidString ?? "nil") turns=\(state.session?.turns.count ?? -1) loading=\(state.session?.isLoading ?? false) input=\(state.session?.input.debugDescription ?? "nil")"]
        func walk(_ view:UIView) {
            if let scroll=view as? UIScrollView {
                var info="\(type(of:scroll)) frame=\(scroll.convert(scroll.bounds,to:nil)) offset=\(scroll.contentOffset) size=\(scroll.contentSize) enabled=\(scroll.isScrollEnabled) dismiss=\(scroll.keyboardDismissMode.rawValue) pan=\(scroll.panGestureRecognizer.state.rawValue) first=\(scroll.isFirstResponder)"
                if let text=scroll as? UITextView {
                    let contentHeight = text.contentSize.height + text.adjustedContentInset.top + text.adjustedContentInset.bottom
                    let overflow = contentHeight > text.bounds.height + 0.01
                    if !overflow {
                        fittingMinimumOffset = min(fittingMinimumOffset, text.contentOffset.y)
                        fittingMaximumOffset = max(fittingMaximumOffset, text.contentOffset.y)
                    }
                    editorMetrics = "overflow=\(overflow) scrolling=\(text.isScrollEnabled) indicator=\(text.showsVerticalScrollIndicator) viewport=\(text.bounds.height) content=\(contentHeight) offset=\(text.contentOffset.y) minFit=\(fittingMinimumOffset) maxFit=\(fittingMaximumOffset) bounce=\(text.bounces) alwaysBounce=\(text.alwaysBounceVertical)"
                    info += " selection=\(text.selectedRange) \(editorMetrics)"
                }
                lines.append(info)
            } else if view is UITextField {lines.append("TEXTFIELD \(type(of:view)) first=\(view.isFirstResponder)")}
            for child in view.subviews {walk(child)}
        }
        for window in UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).flatMap(\.windows) {walk(window)}
        let result=lines.joined(separator:"\n")
        if result != last {last=result;log(result)}
        return editorMetrics
    }
}
struct KeyboardRoot:View {
    @StateObject private var state=AskFeastTabState()
    @State private var ready=false
    @State private var tab=2
    @State private var editorMetrics="unavailable"
    @State private var access = true
    @State private var collectionName = ""
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
        // Test-only observable geometry. No editor delegate or gesture is replaced.
        .overlay(alignment: .topLeading) {
            VStack {
                Text(collectionName).accessibilityIdentifier("qa.collectionName")
                Text(editorMetrics).accessibilityIdentifier("qa.editorMetrics")
            }.font(.system(size: 1)).foregroundStyle(.clear)
                .frame(width: 1, height: 1).allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.arguments.contains("-projection") {
                Button(access ? "Hide synthetic saved details" : "Restore synthetic saved details") {
                    access.toggle();KeyboardQA.fixtureAccess=access;try? state.refreshSavedCollection()
                }.padding(.top,100).font(.caption).accessibilityIdentifier("qa.access")
            }
        }
        .environment(\.dynamicTypeSize,KeyboardQA.dynamicTypeSize)
        .environment(\.managedObjectContext,KeyboardQA.persistence.viewContext)
        .environment(\.persistenceController,KeyboardQA.persistence)
        .task {
            do {try KeyboardQA.prepare(state);ready=true} catch {KeyboardQA.log("HARNESS_ERROR \(error)")}
            while !Task.isCancelled {
                let metrics=KeyboardQA.snapshot(state,tab:tab)
                if metrics != editorMetrics {editorMetrics=metrics}
                let name=KeyboardQA.collectionPlace?.displayNameSnapshot ?? ""
                if name != collectionName {collectionName=name}
                try? await Task.sleep(for:.milliseconds(150))
            }
        }
    }
}
@main struct FeastApp:App {var body:some Scene {WindowGroup {KeyboardRoot()}}}
