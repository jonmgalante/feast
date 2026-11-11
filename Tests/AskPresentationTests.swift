import Foundation
import CoreData
import CryptoKit

private struct PresentationProvider: AskFeastProvider {
    let label="Offline presentation fixture"
    var response=AskResponse(summary:"A useful answer",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:[],orderedIDs:[],sourcePolicy:"stored_only"))
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {response}
}
private actor PresentationGateProvider:AskFeastProvider {
    nonisolated let label="Offline pending message"
    private var gate:CheckedContinuation<Void,Never>?
    private var started=false
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {started=true;await withCheckedContinuation {gate=$0};return .init(summary:"Late response",candidates:[])}
    func hasStarted()->Bool {started}
    func release(){gate?.resume();gate=nil}
}
@MainActor enum AskPresentationTests {
    static func run(model:NSManagedObjectModel,directory:URL)async throws {
        try markdownProjection(directory:directory)
        try navigationLinks(directory:directory)
        try await historyTitles(directory:directory)
        let a=UUID().uuidString,b=UUID().uuidString,turn=UUID()
        let applied=AskCollectionAction(id:UUID(),title:"Update one",targetIDs:[a],entity:"place",operation:"update",state:.applied,undoable:true)
        let anotherField=AskCollectionAction(id:UUID(),title:"Another field",targetIDs:[a],entity:"place",operation:"update",state:.applied,undoable:true)
        let noChange=AskCollectionAction(id:UUID(),title:"Already correct",targetIDs:[b],entity:"place",operation:"update",state:.applied,undoable:false)
        let proposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[a,b],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Update these details")
        let record=AskOperationRecord.make(turn:turn,proposal:proposal,actions:[applied,anotherField,noChange],status:"partial",outcomes:[.init(id:a,state:"applied"),.init(id:b,state:"failed")])
        var response=AskResponse(summary:"status",candidates:[],paragraphs:[.init(id:"agent-message",spans:[.text("Saved.")],sourceIDs:[],operationStatus:true),.init(id:"reasoning",spans:[.text("A useful explanation with 16 places and $42.50.")],sourceIDs:[],citations:[.init(title:"Source",url:"https://example.org/source")])],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:[applied,anotherField,noChange],operationRecords:[record])
        let receiptRows=AskReceiptDetailRow.make([applied,anotherField,noChange])
        precondition(receiptRows.count==2 && receiptRows[0].actions.map(\.id)==[applied.id,anotherField.id])
        precondition(receiptRows[0].title(names:[a:"One place"])=="One place" && receiptRows[0].undoActions.count==2)
        precondition(receiptRows[1].undoActions.isEmpty)
        let multiTarget=AskCollectionAction(id:UUID(),title:"Update selected places",targetIDs:[a,b],entity:"place",operation:"update",state:.applied,undoable:true)
        let multiRows=AskReceiptDetailRow.make([multiTarget])
        precondition(multiRows.count==1 && multiRows[0].targetIDs==[a,b] && multiRows[0].undoActions.map(\.id)==[multiTarget.id])
        precondition(multiRows[0].title(names:[a:"First",b:"Second"])=="First, Second")
        let restoredRows=try JSONDecoder().decode([AskCollectionAction].self,from:JSONEncoder().encode([applied,anotherField,noChange]))
        precondition(AskReceiptDetailRow.make(restoredRows)==receiptRows)
        let group=AskOperationPresentation.make(response:response,turnID:turn)[0]
        precondition(group.changed==[a] && group.unchanged==[b] && group.attention==[b] && group.title(names:[:]).contains("1 incomplete"))
        precondition(response.substantiveParagraphs.map(\.id)==["reasoning"] && response.substantiveParagraphs[0].citations.count==1)
        var clarification=response;clarification.collectionActions=[]
        clarification.paragraphs=[.init(id:"agent-message",spans:[.text("Please specify one existing city and neighborhood.")],sourceIDs:[],operationStatus:false)]
        precondition(clarification.substantiveParagraphs.count==1)
        var legacyExplanation=response
        legacyExplanation.paragraphs=[.init(id:"agent-message",spans:[.text("A saved prefix was kept, but the remaining target could not be checked.")],sourceIDs:[])]
        precondition(legacyExplanation.legacyOperationParagraphs.count==1 && legacyExplanation.substantiveParagraphs.isEmpty)
        var repeated=record;repeated.status="applied"
        let merged=AskOperationRecord.merged([record],repeated)
        precondition(merged.count==1 && Set(merged[0].actionIDs).count==3)
        let decoded=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(response))
        precondition(AskOperationPresentation.make(response:decoded,turnID:turn)==[group])
        var unrelated=proposal;unrelated.targetIDs=[b]
        let second=AskOperationRecord.make(turn:UUID(),proposal:unrelated,actions:[],status:"unresolved",outcomes:[])
        precondition(AskOperationRecord.merged([record],second).count==2)
        response.operationRecords=[second];response.collectionActions=[]
        precondition(AskOperationPresentation.make(response:response,turnID:turn)[0].unresolved)
        var implicit=proposal;implicit.targetIDs=[]
        let c=UUID().uuidString,unrelatedTarget=UUID().uuidString
        let scoped=AskOperationRecord.make(turn:turn,proposal:implicit,actions:[applied],status:"partial",outcomes:[.init(id:a,state:"applied"),.init(id:b,state:"failed"),.init(id:c,state:"pending"),.init(id:unrelatedTarget,state:"failed")],effectiveTargetIDs:[a,b,c])
        response.collectionActions=[applied];response.operationRecords=[scoped]
        let scopedGroup=AskOperationPresentation.make(response:response,turnID:turn)[0]
        precondition(scopedGroup.changed==[a] && scopedGroup.attention==[b,c] && !scoped.targetIDs.contains(unrelatedTarget))
        let fieldOne=AskChangeProposal(entity:"place",operation:"update",targetIDs:[a],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"website",value:nil,values:nil,findingID:nil,source:"user")],instructionQuote:proposal.instructionQuote)
        let fieldTwo=AskChangeProposal(entity:"place",operation:"update",targetIDs:[a],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"instagram",value:nil,values:nil,findingID:nil,source:"user")],instructionQuote:proposal.instructionQuote)
        let failedField=AskOperationRecord.make(turn:turn,proposal:fieldOne,actions:[],status:"failed",outcomes:[.init(id:a,state:"failed")])
        let savedOtherField=AskOperationRecord.make(turn:turn,proposal:fieldTwo,actions:[applied],status:"applied",outcomes:[.init(id:a,state:"applied")])
        let combinedFields=AskOperationRecord.merged([failedField],savedOtherField)
        response.collectionActions=[applied];response.operationRecords=combinedFields
        precondition(AskOperationPresentation.make(response:response,turnID:turn)[0].attention==[a])
        let retrySameField=AskOperationRecord.make(turn:turn,proposal:fieldOne,actions:[anotherField],status:"applied",outcomes:[.init(id:a,state:"applied")])
        response.collectionActions=[applied,anotherField];response.operationRecords=AskOperationRecord.merged(combinedFields,retrySameField)
        precondition(AskOperationPresentation.make(response:response,turnID:turn)[0].attention.isEmpty)
        let groupedProposal=AskChangeProposal(entity:"place",operation:"update",targetIDs:[a],cityID:nil,sectionID:nil,mapMatchID:nil,changes:fieldOne.changes+fieldTwo.changes,instructionQuote:proposal.instructionQuote)
        let groupedFailure=AskOperationRecord.make(turn:turn,proposal:groupedProposal,actions:[],status:"failed",outcomes:[.init(id:a,state:"failed")])
        let savedOneField=AskOperationRecord.make(turn:turn,proposal:fieldOne,actions:[applied],status:"applied",outcomes:[.init(id:a,state:"applied")])
        let splitRecovery=AskOperationRecord.merged(AskOperationRecord.merged([groupedFailure],savedOneField),savedOtherField)
        response.operationRecords=splitRecovery;response.collectionActions=[applied]
        precondition(AskOperationPresentation.make(response:response,turnID:turn)[0].attention.isEmpty)
        let failedOtherField=AskOperationRecord.make(turn:turn,proposal:fieldTwo,actions:[],status:"failed",outcomes:[.init(id:a,state:"failed")])
        let groupedSuccess=AskOperationRecord.make(turn:turn,proposal:groupedProposal,actions:[applied],status:"applied",outcomes:[.init(id:a,state:"applied")])
        response.operationRecords=AskOperationRecord.merged(AskOperationRecord.merged([failedField],failedOtherField),groupedSuccess)
        precondition(AskOperationPresentation.make(response:response,turnID:turn)[0].attention.isEmpty)
        var committedConflict=applied;committedConflict.state = .conflict;committedConflict.undoable=false;committedConflict.committedChange=true
        response.collectionActions=[committedConflict];response.operationRecords=nil
        let historical=AskOperationPresentation.make(response:response,turnID:turn)[0]
        precondition(historical.changed==[a] && !historical.title(names:[:]).contains("No change saved") && historical.undoActions.isEmpty)
        print("PASS compact operation receipts count distinct changed records, retain no-op/partial/unresolved states, deduplicate authoritative IDs and preserve substantive text/citations across restoration")

        let index=AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata)
        let store=AskConversationStore(url:directory.appendingPathComponent("presentation-history.json"))
        let session=AskSession(index:index,provider:PresentationProvider())
        session.restoreHistory(from:store)
        let first=session.activeChatID,t1=Date(timeIntervalSinceReferenceDate:1000),t2=Date(timeIntervalSinceReferenceDate:2000),t3=Date(timeIntervalSinceReferenceDate:3000)
        session.activityNow={t1};session.input="Explain an ordinary restaurant question";session.run();while session.isLoading {await Task.yield()};session.flushHistory()
        precondition(session.chats.first(where:{$0.id==first})?.lastActivityAt==t1)
        precondition(session.newChat());let secondID=session.activeChatID
        session.activityNow={t2};session.input="Compare another ordinary dining question";session.run();while session.isLoading {await Task.yield()};session.flushHistory()
        let order=AskHistoryPresentation.ordered(session.chats).map(\.id)
        precondition(order.first==secondID)
        precondition(session.openChat(first));session.flushHistory();session.suspend()
        precondition(AskHistoryPresentation.ordered(session.chats).map(\.id)==order)
        precondition(session.renameChat(first,to:"Dining plans"));session.input="Unsent draft";session.flushHistory()
        precondition(AskHistoryPresentation.ordered(session.chats).map(\.id)==order && session.chats.first(where:{$0.id==first})?.lastActivityAt==t1)
        let restored=AskSession(index:index,provider:PresentationProvider());restored.restoreHistory(from:store);restored.flushHistory()
        precondition(AskHistoryPresentation.ordered(restored.chats).map(\.id)==order && restored.input=="Unsent draft")
        restored.activityNow={t3};restored.input="A new genuine conversation message";restored.run();while restored.isLoading {await Task.yield()};restored.flushHistory()
        precondition(AskHistoryPresentation.ordered(restored.chats).first?.id==first)
        let gated=PresentationGateProvider(),passive=AskSession(index:index,provider:gated)
        passive.restoreHistory(from:AskConversationStore(url:directory.appendingPathComponent("passive-inflight-history.json")))
        passive.activityNow={t1};passive.input="A pending user message";passive.run();while !(await gated.hasStarted()) {await Task.yield()}
        passive.activityNow={t2};passive.suspend()
        precondition(passive.chats[0].lastActivityAt==t1)
        await gated.release()
        let tied=restored.chats.map {chat->AskChatArchive in var value=chat;value.lastActivityAt=t1;return value}
        precondition(AskHistoryPresentation.ordered(tied).map(\.id)==tied.map(\.id).sorted {$0.uuidString<$1.uuidString})
        let oldData=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"conversation":["version":1,"draft":"","turns":[]]])
        let old=try JSONDecoder().decode(AskChatArchive.self,from:oldData)
        precondition(old.title=="New chat" && AskHistoryPresentation.date(old)=="Date unavailable")
        let previewResponse=AskResponse(summary:"",candidates:[],paragraphs:[.init(id:"explanation",spans:[.text("There are **6** places, with a $42.50 option. [Source](https://example.org)")],sourceIDs:[])],publicConversationText:"Public explanation")
        let previewTurn=AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Explain these options",fromOCR:false),response:previewResponse,status:.complete))
        let previewChat=AskChatArchive(id:UUID(),title:previewTurn.question,updatedAt:t1,conversation:.init(turns:[previewTurn]))
        let readablePreview=AskHistoryPresentation.preview(previewChat)
        precondition(readablePreview.contains("6") && readablePreview.contains("$42.50") && readablePreview.contains("Source") && !readablePreview.contains("**") && !readablePreview.contains("https://"))
        let privateResponse=AskResponse(summary:"Secret local note",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:["note"],orderedIDs:[],sourcePolicy:"local_only",privateSelection:true))
        let privateTurn=AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Show my secret local note",fromOCR:false),response:privateResponse,status:.complete))
        let privateChat=AskChatArchive(id:UUID(),title:privateTurn.question,updatedAt:t1,conversation:.init(turns:[privateTurn]))
        precondition(!AskHistoryPresentation.title(privateChat).contains("secret") && !AskHistoryPresentation.preview(privateChat).contains("Secret"))
        let badParent=directory.appendingPathComponent("not-a-history-directory");try Data("fixture".utf8).write(to:badParent)
        let unreadable=AskSession(index:index,provider:PresentationProvider());unreadable.restoreHistory(from:AskConversationStore(url:badParent.appendingPathComponent("history.json")))
        precondition(unreadable.chats.isEmpty && unreadable.error != nil && !unreadable.newChat(),"Unreadable startup must not adopt an invented empty archive")
        let parent=directory.appendingPathComponent("history-fails-after-load"),historyURL=parent.appendingPathComponent("history.json"),historyStore=AskConversationStore(url:historyURL)
        let unsaved=AskSession(index:index,provider:PresentationProvider());unsaved.restoreHistory(from:historyStore);unsaved.flushHistory()
        let priorBytes=try Data(contentsOf:historyURL),priorDate=unsaved.chats[0].updatedAt,kept=directory.appendingPathComponent("verified-earlier-history")
        try FileManager.default.moveItem(at:parent,to:kept);try Data("fixture write failure".utf8).write(to:parent)
        unsaved.activityNow={t3};unsaved.input="A genuine message whose history cannot persist";unsaved.run();while unsaved.isLoading {await Task.yield()}
        let retainedTurn=unsaved.turns.last!,unsavedDraft="Exact newer unsent draft e\u{301} 🧭  "
        unsaved.input=unsavedDraft;unsaved.flushHistory()
        precondition(Array(unsaved.chats[0].conversation.draft.utf8)==Array(unsavedDraft.utf8) && unsaved.chats[0].conversation.turns.last?.id==retainedTurn.id && unsaved.chats[0].conversation.turns.last?.response==retainedTurn.response)
        precondition(unsaved.historyWarning?.contains("not saved")==true && unsaved.unsavedHistoryChatIDs.contains(unsaved.activeChatID) && unsaved.chats[0].lastActivityAt==t3 && unsaved.chats[0].updatedAt==t3 && unsaved.turns.last?.status == .complete,"Newest genuine activity belongs to the exact returnable RAM chat, without a durability claim")
        let prior=try JSONDecoder().decode(AskChatLibrary.self,from:Data(contentsOf:kept.appendingPathComponent("history.json")))
        let retainedBytes=try Data(contentsOf:kept.appendingPathComponent("history.json"))
        precondition(retainedBytes==priorBytes && prior.chats[0].lastActivityAt==nil && prior.chats[0].updatedAt==priorDate,"Failed save never changes the prior durable activity/archive")
        print("PASS History genuine activity orders messages; passive open/flush/draft/rename/relaunch leave order unchanged; stable ties and missing legacy metadata remain truthful")

        var actions=[applied,AskCollectionAction(id:UUID(),title:"Second",targetIDs:[b],entity:"place",operation:"update",state:.applied,undoable:true)]
        let nativeResponse=AskResponse(summary:"Saved.",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"change",fields:[],orderedIDs:[a,b],sourcePolicy:"stored_only"),collectionActions:actions)
        let undoSession=AskSession(index:index,provider:PresentationProvider(response:nativeResponse));undoSession.restoreHistory(from:AskConversationStore(url:directory.appendingPathComponent("undo-activity.json")))
        undoSession.activityNow={t1};undoSession.input="Update these two saved places";undoSession.run();while undoSession.isLoading {await Task.yield()};undoSession.flushHistory()
        var calls:[UUID]=[]
        undoSession.collectionExecutor={id,_ in calls.append(id);if id==applied.id {throw AskChangeError.conflict};let i=actions.firstIndex(where:{$0.id==id})!;actions[i].state = .undone;actions[i].undoable=false;return actions[i]}
        undoSession.activityNow={t2};undoSession.undoCollectionOperation(turn:undoSession.turns[0].id,actionIDs:actions.map(\.id));undoSession.flushHistory()
        precondition(calls==[actions[1].id,applied.id] && undoSession.error != nil && undoSession.response?.collectionActions?.last?.state == .undone)
        precondition(undoSession.response?.undoFailures?[applied.id.uuidString]=="newer_edit")
        let afterUndo=AskOperationPresentation.make(response:undoSession.response!,turnID:undoSession.turns[0].id)[0]
        precondition(afterUndo.changed==[a] && afterUndo.undone==[b] && afterUndo.undoBlocked==[a])
        precondition(undoSession.chats[0].lastActivityAt==t2)
        undoSession.activityNow={t3};undoSession.applyCollectionAction(turn:undoSession.turns[0].id,actionID:actions[1].id,undo:true);undoSession.flushHistory()
        precondition(undoSession.chats[0].lastActivityAt==t2)
        print("PASS best-effort operation Undo uses reverse existing actions, stops at conflict, preserves earlier reversal and does not bump History on replay")
        try await persistentUndo(model:model,directory:directory)

    }
    private static func historyTitles(directory:URL)async throws {
        let dependency=UUID().uuidString
        let allowed=AskLocalIndex(records:[],visibleCityIDs:[dependency],visibleNoteIDs:[],scope:.savedMetadata)
        let denied=AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[],scope:.savedMetadata)
        let local=AskResponse(summary:"Local answer",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"query",fields:["note"],orderedIDs:[dependency],sourcePolicy:"local_only",privateSelection:true),historyRecordIDs:[dependency],retainsIndependentQuestion:false)
        let publicAnswer=AskResponse(summary:"Public answer",candidates:[],paragraphs:[.init(id:"public",spans:[.text("A useful public answer")],sourceIDs:[],historyRecordIDs:[])],publicConversationText:"A useful public answer",historyRecordIDs:[],retainsIndependentQuestion:true)
        func chat(_ question:String,response:AskResponse?=nil,at:TimeInterval=1000)->AskChatArchive {
            let turn=AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:question,fromOCR:false),response:response ?? local,status:.complete))
            return .init(id:UUID(),title:String(question.prefix(80)),updatedAt:Date(timeIntervalSinceReferenceDate:at),conversation:.init(turns:[turn]),lastActivityAt:Date(timeIntervalSinceReferenceDate:at))
        }
        var olderPrivateMarker=local;olderPrivateMarker.retainsIndependentQuestion=true
        let privateChat=chat("  Show\n my\t saved cafés\u{00A0}in London  ",response:olderPrivateMarker)
        let publicChat=chat("Find the best 3 coffee shops in soho London",response:publicAnswer,at:2000)
        var legacy=local;legacy.historyRecordIDs=nil;legacy.retainsIndependentQuestion=nil
        legacy.agentTask = .init(action:"query",fields:[],orderedIDs:[dependency],sourcePolicy:"stored_only",privateSelection:false)
        let legacyChat=chat("Explain LEGACY_PRIVATE_NOTE from my collection",response:legacy)
        var manual=privateChat;manual=AskChatArchive(id:UUID(),title:"My deliberate name",updatedAt:manual.updatedAt,conversation:manual.conversation)
        var clarification=local
        clarification.operationRecords=[.init(id:"clarification",entity:"place",operation:"update",actionIDs:[],targetIDs:[dependency],status:"needs_confirmation",outcomes:[])]
        let statusChat=chat("Update the saved places I selected",response:clarification)
        let empty=AskChatArchive(id:UUID(),title:"New chat",updatedAt:Date(),conversation:.init())
        let store=AskConversationStore(url:directory.appendingPathComponent("history-title-projection.json"))
        let library=AskChatLibrary(activeID:privateChat.id,chats:[privateChat,publicChat,legacyChat,manual,statusChat,empty])
        precondition(store.saveLibrary(library))
        let session=AskSession(index:allowed,provider:PresentationProvider());session.restoreHistory(from:store)
        let originalBytes=try Data(contentsOf:store.url)
        var access=allowed,reads=0
        session.refreshIndex={reads+=1;return access}
        let rows=session.historyRows()
        precondition(reads==1 && rows.first {$0.id==privateChat.id}?.title=="Show my saved cafés in London","Local titles must use the permitted request, not the public-provider projection")
        precondition(rows.first {$0.id==publicChat.id}?.title==publicChat.title)
        precondition(rows.first {$0.id==privateChat.id}?.visiblePreview==nil,"An exact meaningful duplicate belongs only in the title and its accessibility label")
        let longer=AskChatHistoryRow(id:UUID(),title:"Find coffee shops…",preview:"Find coffee shops with outdoor seating near the river",date:"Today")
        precondition(longer.visiblePreview==longer.preview && longer.accessibilityLabel.contains(longer.preview),"A distinct longer preview must not be removed by prefix or fuzzy matching")
        precondition(rows.first {$0.id==statusChat.id}?.visiblePreview=="Clarification needed")
        precondition(rows.first {$0.id==empty.id}?.title=="New chat" && rows.first {$0.id==empty.id}?.preview=="No messages yet")
        precondition(rows.first {$0.id==privateChat.id}?.accessibilityLabel.contains("Show my saved cafés in London")==true)
        access=denied
        let hidden=session.historyRows(),hiddenLocal=hidden.first {$0.id==privateChat.id}!
        precondition(reads==2 && hiddenLocal.title=="Collection conversation" && hiddenLocal.visiblePreview==nil)
        precondition(!hiddenLocal.accessibilityLabel.contains("cafés") && hiddenLocal.accessibilityLabel.components(separatedBy:"Collection conversation").count==2)
        precondition(!hidden.first {$0.id==legacyChat.id}!.accessibilityLabel.contains("LEGACY_PRIVATE_NOTE"))
        precondition(hidden.first {$0.id==manual.id}?.title==manual.title && hidden.first {$0.id==publicChat.id}?.title==publicChat.title)
        let unchangedBytes=try Data(contentsOf:store.url)
        precondition(rows.map(\.id)==hidden.map(\.id) && rows.map(\.id)==AskHistoryPresentation.ordered(library.chats).map(\.id) && originalBytes==unchangedBytes)
        session.refreshIndex={throw CocoaError(.fileReadUnknown)}
        precondition(session.historyRows().first {$0.id==privateChat.id}?.title=="Collection conversation","Failed permission refresh must fail closed")
        let long="Find a quiet café with vegan lunch options near the river in central London"
        let cleaned=AskHistoryPresentation.compact(long,limit:56)
        precondition(cleaned=="Find a quiet café with vegan lunch options near the…" && cleaned.count<=57)
        let grapheme="👨‍👩‍👧‍👦",noSpaces=String(repeating:grapheme,count:65)
        precondition(AskHistoryPresentation.compact(noSpaces,limit:56)==String(repeating:grapheme,count:56)+"…")
        let unicode="  Café e\u{301} 🍜\n\t東京  "
        precondition(AskHistoryPresentation.compact(unicode,limit:56)=="Café e\u{301} 🍜 東京")
        let blank=chat("  \n ",response:publicAnswer)
        precondition(AskHistoryPresentation.title(blank,presentedQuestion:blank.conversation.turns[0].question)=="New chat")
        var draft=empty;draft.conversation.draft="Unsent request"
        precondition(AskHistoryPresentation.preview(draft)=="Draft message")
        let legacyBytes=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"title":"New chat","conversation":["version":1,"draft":"","turns":[]]])
        let legacyEmpty=try JSONDecoder().decode(AskChatArchive.self,from:legacyBytes)
        precondition(legacyEmpty.hasCustomTitle==nil && AskHistoryPresentation.title(legacyEmpty)=="New chat")
        print("PASS meaningful local/public History titles, whitespace/word/Unicode boundaries, empty/draft fallbacks, useful statuses, permission refresh/revocation/legacy and older private-marker redaction, AX and read-only ordering")

        for name in ["New chat","Show my saved coffee shops in London","Weekend cafés 🍜"] {
            let initial=chat("Show my saved coffee shops in London")
            let renameStore=AskConversationStore(url:directory.appendingPathComponent("rename-"+UUID().uuidString+".json"))
            precondition(renameStore.saveLibrary(.init(activeID:initial.id,chats:[initial])))
            let renamed=AskSession(index:allowed,provider:PresentationProvider(response:local));renamed.restoreHistory(from:renameStore)
            precondition(renamed.renameChat(initial.id,to:name))
            renamed.input="A later request must not rename this chat";renamed.run();while renamed.isLoading {await Task.yield()};renamed.flushHistory()
            precondition(renamed.turns.count==2 && renamed.historyRows()[0].title==name && renamed.chats[0].hasCustomTitle==true)
            let reloaded=AskSession(index:denied,provider:PresentationProvider());reloaded.restoreHistory(from:AskConversationStore(url:renameStore.url));reloaded.flushHistory()
            precondition(reloaded.historyRows()[0].title==name && reloaded.chats[0].hasCustomTitle==true,"Manual names, including reserved/equal names, survive another send, reload and revoked source access")
            var pending=try AskConversationStore(url:renameStore.url).loadLibrary()
            pending.chats[0].conversation.draft=String(repeating:"oversized draft ",count:1000)
            let pendingStore=AskConversationStore(url:renameStore.url);_ = try pendingStore.loadLibrary()
            precondition(pendingStore.preserveLibrary(pending) == .pending)
            let fromPending=try AskConversationStore(url:renameStore.url).loadLibrary()
            precondition(fromPending.chats[0].hasCustomTitle==true && fromPending.chats[0].title==name)
            var canonical=fromPending;canonical.chats[0].conversation.draft="Small draft"
            precondition(pendingStore.preserveLibrary(canonical) == .canonical)
            let fromCanonical=try AskConversationStore(url:renameStore.url).loadLibrary()
            precondition(fromCanonical.chats[0].hasCustomTitle==true && fromCanonical.chats[0].title==name)
            let clearing=AskSession(index:allowed,provider:PresentationProvider(response:local));clearing.restoreHistory(from:AskConversationStore(url:renameStore.url))
            clearing.clearConversation()
            precondition(clearing.activeChatID != initial.id && clearing.turns.isEmpty && clearing.chats[0].hasCustomTitle==true && clearing.historyRows()[0].title==name)
            let afterClear=AskSession(index:allowed,provider:PresentationProvider(response:local));afterClear.restoreHistory(from:AskConversationStore(url:renameStore.url))
            afterClear.input=initial.conversation.turns[0].question;afterClear.run();while afterClear.isLoading {await Task.yield()};afterClear.flushHistory()
            afterClear.refreshIndex={denied}
            precondition(afterClear.turns.count==1 && afterClear.historyRows()[0].title==name && afterClear.chats[0].hasCustomTitle==true,"Clear, relaunch and a new first send must preserve explicit manual-title intent")
        }
        print("PASS explicit Rename protects New chat/exact-question/custom names through later sends, relaunch, revoked access, pending/canonical round trips and Clear/relaunch/send")
    }
    private static func navigationLinks(directory:URL)throws {
        let full="https://www.instagram.com/full_profile/?hl=en#menu"
        let bare="instagram.com/public_cafe"
        let source=AskWebCitation(title:"Menu",url:"https://example.org/menu?item=2&utm_source=citation#lunch")
        let requestURL=URL(string:"https://example.org/menu?item=2&utm_source=answer#lunch")!
        let savedID=UUID().uuidString
        let candidate=AskCandidate(id:UUID().uuidString,name:"Saved Café",city:"Test City",facts:[],sourceIDs:[],uncertainty:"",mapOptions:[],existingRecordID:savedID)
        let forged=AskPlaceReference.url(for:candidate)!.absoluteString
        let raw="🧑🏽‍🍳 **Profile**: [Visit Instagram](\(full))\n\(full)\n\(bare)\n[Domain profile](\(bare))\nwww.example.org/menu?q=one%20two#lunch\n@public_cafe @**cafe.name** @**www.example.org** **user**@instagram.com user@example.org\n`https://example.org/code`\n[Blocked label instagram.com/profile](javascript:alert)\n[Fake place](\(forged))"
        let paragraph=AskAnswerParagraph(id:"navigation",spans:[.text(raw)],sourceIDs:[])
        let rendered=AskMarkdownPresentation.inline(paragraph,candidates:[candidate])
        func link(_ label:String)->URL? {rendered[rendered.range(of:label)!].link}
        precondition(link("Visit Instagram")?.absoluteString==full)
        precondition(link(full)?.absoluteString==full)
        precondition(link(bare)?.absoluteString=="https://"+bare)
        precondition(link("Domain profile")?.absoluteString=="https://"+bare)
        precondition(link("www.example.org/menu?q=one%20two#lunch")?.absoluteString=="https://www.example.org/menu?q=one%20two#lunch")
        let linkedLabels=rendered.runs.filter {$0.link != nil}.map {String(rendered[$0.range].characters)}
        precondition(linkedLabels==["Visit Instagram",full,bare,"Domain profile","www.example.org/menu?q=one%20two#lunch"],"Only the five explicit navigation labels may be linked, including across formatted handles")
        for label in ["@public_cafe","cafe.name","@www.example.org","@instagram.com","user@example.org","https://example.org/code","Blocked label instagram.com/profile","Fake place"] {precondition(link(label)==nil,"Unexpected link: "+label)}
        precondition(AskAnswerLink.destination(for:URL(string:full)!,candidates:[]) == .web(URL(string:full)!))
        precondition(AskAnswerLink.destination(for:URL(string:bare)!,candidates:[]) == .web(URL(string:"https://"+bare)!))
        precondition(AskAnswerLink.destination(for:requestURL,candidates:[],citations:[source]) == .web(source.safeURL!))
        let different=URL(string:"https://example.org/menu?item=3#lunch")!
        precondition(AskAnswerLink.destination(for:different,candidates:[],citations:[source]) == .web(different))
        precondition(AskCitationLink.acceptedURL(for:different,citations:[source])==nil,"Ordinary navigation cannot imply citation evidence")
        precondition(AskAnswerLink.destination(for:AskPlaceReference.url(for:candidate)!,candidates:[candidate]) == .savedPlace(savedID))
        precondition(AskAnswerLink.destination(for:AskPlaceReference.url(for:candidate)!,candidates:[])==nil)
        for unsafe in ["http://example.org", "javascript:alert(1)", "data:text/html,test", "file:///private/tmp/test", "mailto:person@example.org", "//example.org/menu", "/menu", "@cafe.name", "https://name:secret@example.org", "https://example.org:8443", "https://localhost", "https://app.local", "https://app.internal", "https://127.0.0.1", "https://[::1]"] {
            precondition(AskAnswerLink.webURL(unsafe)==nil,"Unsafe normal navigation: "+unsafe)
            if let url=URL(string:unsafe) {precondition(AskAnswerLink.destination(for:url,candidates:[candidate])==nil)}
            let bad=AskMarkdownPresentation.inline("[Unsafe](\(unsafe))")
            precondition(bad.runs.allSatisfy {$0.link==nil},"Unsafe Markdown destination: "+unsafe)
        }
        for disguised in ["[www.example.org](http://evil.example)","[http://www.example.org](http://www.example.org)","http://www.example.org"] {
            precondition(AskMarkdownPresentation.inline(disguised).runs.allSatisfy {$0.link==nil})
        }
        let punctuation=AskMarkdownPresentation.inline("See (instagram.com/public_cafe), then **https://example.org/café?q=one%20two#menu**.")
        precondition(punctuation.runs.compactMap(\.link).map(\.absoluteString)==["https://instagram.com/public_cafe","https://example.org/caf%C3%A9?q=one%20two#menu"])
        let table=AskMarkdownPresentation.inline("| Site | Profile |\n|---|---|\n| Café | instagram.com/public_cafe |")
        precondition(table.runs.compactMap(\.link)==[URL(string:"https://"+bare)!])
        precondition(paragraph.citations.isEmpty && AskMarkdownPresentation.locallyLinkedSources(paragraph).isEmpty)
        let linkedSource=AskAnswerParagraph(id:"citation",spans:[.text("Lunch is served. [Official menu](\(source.url))")],sourceIDs:[],citations:[source])
        precondition(AskMarkdownPresentation.locallyLinkedSources(linkedSource)==[source.safeURL!])
        let rawSource=AskAnswerParagraph(id:"raw-source",spans:[.text("Lunch is served. "+source.url)],sourceIDs:[],citations:[source])
        precondition(AskMarkdownPresentation.locallyLinkedSources(rawSource).isEmpty,"Autolinking must not alter source-to-claim association")
        let response=AskResponse(summary:raw,candidates:[candidate],paragraphs:[paragraph],listedCandidateIDs:[],publicConversationText:raw)
        let turn=AskTurn(id:UUID(),request:.init(mode:.collection,text:"Show the restaurant links",fromOCR:false),response:response,status:.complete)
        var library=AskChatLibrary.empty();library.chats[0].conversation.turns=[AskArchivedTurn(turn)]
        let store=AskConversationStore(url:directory.appendingPathComponent("navigation-link-history.json"))
        precondition(store.saveLibrary(library))
        let restored=try store.loadLibrary().chats[0].conversation.turns[0].response
        precondition(restored==response && restored.paragraphs[0].citations.isEmpty)
        let replay=AskMarkdownPresentation.inline(restored.paragraphs[0],candidates:restored.candidates)
        precondition(replay==rendered && AskAnswerCopy.text(restored)==AskAnswerCopy.text(response))
        precondition(AskConversationProjection.messages([turn]).last?.text==raw,"Link rendering must not change outbound conversation bytes")
        print("PASS safe ordinary Markdown/plain/domain links share navigation resolution after archive reload; citations, queries, Unicode, saved references and unsafe/ambiguous destinations remain distinct")
    }
    private static func markdownProjection(directory:URL)throws {
        let a=UUID().uuidString,b=UUID().uuidString,savedID=UUID().uuidString
        let first=AskCandidate(id:a,name:"The Elk",city:"",facts:[],sourceIDs:[],uncertainty:"",mapOptions:[],existingRecordID:savedID)
        let literalName="A_* &amp; [Cafe](https://evil.example) `<b>` 🥐"
        let second=AskCandidate(id:b,name:literalName,city:"",facts:[],sourceIDs:[],uncertainty:"",mapOptions:[],existingRecordID:nil)
        let candidates=[first,second],marker="\u{E200}cite\u{E202}turn0search0\u{E201}"
        let multi="\u{E200}cite\u{E202}turn1view2\u{E202}turn12news3\u{E201}"
        let raw="1. **[[place:\(a)]]** — **128 Charles Street**\nA specialty coffee shop. "+marker
        var resolved:[AskCandidate]=[]
        let paragraph=AskConversationLoop.paragraph(raw,catalog:[],available:[a:first,b:second],candidates:&resolved,citations:[])
        let rendered=AskMarkdownPresentation.inline(paragraph,candidates:resolved)
        let visible="1. The Elk — 128 Charles Street\nA specialty coffee shop. "
        precondition(String(rendered.characters)==visible)
        let nameRange=rendered.range(of:first.name)!
        precondition(rendered[nameRange].link==AskPlaceReference.url(for:first) && rendered[nameRange].inlinePresentationIntent?.contains(.stronglyEmphasized)==true)
        precondition(rendered[rendered.range(of:"128 Charles Street")!].inlinePresentationIntent?.contains(.stronglyEmphasized)==true)
        // No annotations are required for display cleanup and none are invented.
        precondition(paragraph.citations.isEmpty && paragraph.spans.contains(.text("** — **128 Charles Street**\nA specialty coffee shop. "+marker)))
        let adjacent=AskAnswerParagraph(id:"styles",spans:[.text("**"),.place(a),.place(b),.text("** / *"),.place(a),.text(" and "),.place(b),.text("*")],sourceIDs:[])
        let styles=AskMarkdownPresentation.inline(adjacent,candidates:candidates)
        precondition(String(styles.characters)==first.name+literalName+" / "+first.name+" and "+literalName)
        precondition(styles.runs.contains {$0.inlinePresentationIntent?.contains([.emphasized,.stronglyEmphasized])==true && $0.link==AskPlaceReference.url(for:first)})
        precondition(styles.runs.filter {$0.link != nil}.allSatisfy {$0.link==AskPlaceReference.url(for:first)})
        let table=AskAnswerParagraph(id:"table",spans:[.text("| **"),.place(a),.text("** | Menu |\n|---|---|\n| A | $5 |\n| B | $7 |")],sourceIDs:[])
        let tableText=String(AskMarkdownPresentation.inline(table,candidates:candidates).characters)
        precondition(tableText=="The Elk: A\nMenu: $5\n\nThe Elk: B\nMenu: $7\n")
        let safeURL="https://example.org/source",forgedURL=AskPlaceReference.url(for:first)!.absoluteString
        let links=AskAnswerParagraph(id:"links",spans:[.text("[Forged](\(forgedURL)) [File](file:///private) [Relative](/local) [Source](\(safeURL)) ["),.place(a),.text("](https://evil.example) ["),.place(b),.text("](https://evil.example)")],sourceIDs:[])
        let linked=AskMarkdownPresentation.inline(links,candidates:candidates)
        precondition(linked[linked.range(of:"Forged")!].link==nil && linked[linked.range(of:"File")!].link==nil && linked[linked.range(of:"Relative")!].link==nil)
        precondition(linked[linked.range(of:"Source")!].link?.absoluteString==safeURL) // Navigation does not require or create citation evidence.
        let evidenced=AskMarkdownPresentation.inline(links,candidates:candidates,citations:[.init(title:"Source",url:safeURL)])
        precondition(evidenced[evidenced.range(of:"Source")!].link?.absoluteString==safeURL)
        precondition(linked[linked.range(of:first.name)!].link==AskPlaceReference.url(for:first))
        precondition(linked[linked.range(of:literalName)!].link==nil)
        let ordinary="👩🏽‍🍳 🥐 e\u{301} \u{E000} \u{F0000} turn0search0 FEASTPLACE0"
        precondition(AskMarkdownPresentation.visibleText(ordinary+marker+multi)==ordinary)
        for malformed in ["\u{E200}cite\u{E202}turn0search0", "cite\u{E202}turn0search0\u{E201}", "\u{E200}cite\u{E202}ordinary prose\u{E201}", "\u{E200}other\u{E202}turn0search0\u{E201}", "\u{E200}cite\u{E202}turn0search0\u{E202}\u{E201}"] {
            precondition(AskMarkdownPresentation.visibleText(malformed)==malformed)
        }
        let entityText="&#70;EASTPLACE0 &amp; **" // Decoded user text is not a saved reference.
        let entities=AskAnswerParagraph(id:"entities",spans:[.text(entityText),.place(a),.text("**")],sourceIDs:[])
        precondition(String(AskMarkdownPresentation.inline(entities,candidates:candidates).characters)=="FEASTPLACE0 & The Elk")
        precondition(String(AskMarkdownPresentation.inline("**Summary**"+marker).characters)=="Summary")
        precondition(AskAnswerCopy.text(.init(summary:"**Summary**"+marker,candidates:[]))=="Summary")

        let citation=AskWebCitation(title:"Official source",url:safeURL)
        let sourceID=SHA256.hash(data:Data(safeURL.utf8)).map {String(format:"%02x",$0)}.joined()
        let evidence=try AskNativeEvidence(version:1,blocks:[.init(id:"raw",text:raw,phase:"final_answer",observedAt:"2026-11-06T00:00:00Z",annotations:[.init(sourceURL:safeURL,title:citation.title,start:0,end:raw.utf8.count,indexUnit:"provider_unmapped")])],sources:[.init(id:sourceID,url:safeURL,title:citation.title,roles:["cited"])],actions:[]).checked()
        var cited=paragraph;cited.citations=[citation]
        let response=AskResponse(summary:raw,candidates:resolved,paragraphs:[cited],publicConversationText:raw,publicResearch:[.init(id:UUID(),originatingTurn:UUID(),query:"Coffee",result:.init(text:raw,citations:[citation],nativeEvidence:evidence))])
        let expectedCopy=visible+"\nOfficial source: "+safeURL
        precondition(AskAnswerCopy.text(response)==expectedCopy)
        let turn=AskTurn(id:UUID(),request:.init(mode:.collection,text:"Find a coffee shop",fromOCR:false),response:response,status:.complete)
        var library=AskChatLibrary.empty();library.chats[0].conversation.turns=[AskArchivedTurn(turn)]
        let store=AskConversationStore(url:directory.appendingPathComponent("presentation-markdown-history.json"))
        precondition(store.saveLibrary(library))
        let restored=try store.loadLibrary().chats[0],restoredResponse=restored.conversation.turns[0].response
        precondition(restoredResponse==response && restoredResponse.publicResearch?[0].result.nativeEvidence==evidence)
        precondition(restoredResponse.summary==raw && restoredResponse.publicConversationText==raw && restoredResponse.paragraphs==[cited])
        precondition(AskAnswerCopy.text(restoredResponse)==expectedCopy)
        precondition(AskHistoryPresentation.preview(restored)==AskHistoryPresentation.compact(visible,limit:120))
        precondition(AskConversationProjection.messages([turn]).last?.text==raw)
        print("PASS shared Ask presentation preserves cross-reference Markdown, literal names and trusted links; cleans only complete citation controls; Copy/History agree without altering stored raw evidence or offsets")
    }
    private static func persistentUndo(model:NSManagedObjectModel,directory:URL)async throws {
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        _ = try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:directory.appendingPathComponent("presentation-unseen-undo.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let repo=FeastRepository(context:context),city=try repo.createFeastList(named:"Chicago")
        let places=try ["Alinea","Soho House Chicago"].map {name in try repo.createSavedPlace(from:.init(applePlaceID:"offline-"+name,displayNameSnapshot:name,status:.wantToTry,placeType:.restaurant,cuisines:[],tags:["Keep "+name],note:nil,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil))}
        let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},visibleCities:{[city.id!]})
        let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:directory.appendingPathComponent("presentation-unseen-actions.json"))
        let question="Add Later this month to Alinea and Soho House Chicago",turn=UUID(),chat=UUID()
        var actions:[AskCollectionAction]=[]
        for place in places {
            let proposal=AskChangeProposal(entity:"place",operation:"append",targetIDs:[place.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:[.init(field:"tags",value:nil,values:["Later this month"],findingID:nil,source:"user")],instructionQuote:question)
            let grant=AskChangeGrant(question:question,entity:"place",operations:["append"],fields:["tags"],targetIDs:[place.id!.uuidString],allowsCreation:false,boundProposal:proposal)
            let ready=try engine.prepare(proposal,question:question,authorization:grant,findings:[],turnID:turn,chatID:chat)
            actions.append(try engine.apply(ready.id,authorization:grant))
        }
        let combined=AskChangeProposal(entity:"place",operation:"append",targetIDs:places.map {$0.id!.uuidString},cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:question)
        let operation=AskOperationRecord.make(turn:turn,proposal:combined,actions:actions,status:"applied",outcomes:places.map {.init(id:$0.id!.uuidString,state:"applied")})
        let response=AskResponse(summary:"Saved",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"change",fields:["tags"],orderedIDs:combined.targetIDs,sourcePolicy:"local_only",privateSelection:true),collectionActions:actions,operationRecords:[operation])
        let store=AskConversationStore(url:directory.appendingPathComponent("presentation-unseen-history.json"))
        let session=AskSession(index:try adapter.index(),provider:PresentationProvider(response:response));session.restoreHistory(from:store)
        session.input=question;session.run();while session.isLoading {await Task.yield()}
        context.refreshAllObjects();places[0].tags.append("Newer user edit");try context.save()
        session.collectionExecutor={id,undo in try engine.performExplicitAction(id,undo:undo)}
        session.collectionStatus={try engine.actionStatus($0)}
        session.undoCollectionOperation(turn:session.turns[0].id,actionIDs:actions.map(\.id));session.flushHistory()
        context.refreshAllObjects()
        precondition(places[0].tags.contains(FeastTag.normalizedDisplay("Later this month")!) && places[0].tags.contains(FeastTag.normalizedDisplay("Newer user edit")!) && places[0].tags.contains("Keep Alinea"))
        precondition(places[1].tags==["Keep Soho House Chicago"])
        let restored=AskSession(index:try adapter.index(),provider:PresentationProvider());restored.collectionStatus={try engine.actionStatus($0)};restored.restoreHistory(from:store)
        let group=AskOperationPresentation.make(response:restored.response!,turnID:restored.turns[0].id)[0]
        precondition(group.changed==[places[0].id!.uuidString] && group.undone==[places[1].id!.uuidString] && group.undoBlocked==[places[0].id!.uuidString])
        precondition(group.actions.first?.committedChange==true && restored.response?.undoFailures?[actions[0].id.uuidString]=="newer_edit")
        print("PASS unseen native SQLite bulk Undo preserves newer target edit, reverses safe target and restores truthful compact summary/Details plus per-action failure")
    }

}
