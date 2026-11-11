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
        let unsaved=AskSession(index:index,provider:PresentationProvider());unsaved.restoreHistory(from:AskConversationStore(url:badParent.appendingPathComponent("history.json")))
        let untouchedDate=unsaved.chats[0].updatedAt
        unsaved.activityNow={t3};unsaved.input="A genuine message whose history cannot persist";unsaved.run();while unsaved.isLoading {await Task.yield()};unsaved.flushHistory()
        precondition(unsaved.error != nil && unsaved.chats[0].lastActivityAt==nil && unsaved.chats[0].updatedAt==untouchedDate)
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
        precondition(linked[linked.range(of:"Source")!].link==nil) // Safe syntax without source evidence is not a working link.
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
