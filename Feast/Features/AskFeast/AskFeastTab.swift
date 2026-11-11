import SwiftUI
import CoreData
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

struct AskSelectedImage: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 8 * 1_024 * 1_024 else { throw AskError.imageLimit }
            return Self(data: try Data(contentsOf: received.file, options: .mappedIfSafe))
        }
    }
}

struct AskFeastTab: View {
    @Environment(\.persistenceController) private var persistenceController
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: AskFeastTabState
    @AppStorage(AskPrivacy.onlineKey) private var onlineAllowed = false
    @State private var onlineConfigured = false
    @State private var accessPresentation = AskAccessPresentation()
    private var phoneActivationAvailable:Bool {
        AskProductionAccess.configuration(info:Bundle.main.infoDictionary ?? [:]) != nil &&
        !(AskOwnerValidationAccess.configuration(info:Bundle.main.infoDictionary ?? [:]) != nil && AskOwnerValidationAccess.credentialAvailable)
    }
    var realContext: NSManagedObjectContext? = nil
    var body: some View {
        NavigationStack {
            Group {
                if state.savedCollection != nil, let session = state.session {
                    AskSavedCollectionPanel(state: state, session: session,showHistory:{accessPresentation.present(.history)},invitationRequired:phoneActivationAvailable && !AskProductionAccess.credentialAvailable,enterInvitation:{accessPresentation.present(.access)})
                } else if let error = state.error {
                    ContentUnavailableView("Ask Feast", systemImage: "exclamationmark.triangle", description: Text(error))
                } else { ProgressView("Preparing Ask Feast") }
            }
            .safeAreaInset(edge:.top,spacing:0) {
                if accessPresentation.showsActivationConfirmation {
                    HStack(spacing:FeastTheme.Spacing.small) {
                        Label("Ask Feast activated. You’re ready to ask.",systemImage:"checkmark.circle")
                            .font(.subheadline).frame(maxWidth:.infinity,alignment:.leading)
                            .accessibilityIdentifier("ask.activation.confirmation")
                        Button {accessPresentation.dismissConfirmation()} label: {Image(systemName:"xmark").frame(minWidth:44,minHeight:44)}
                            .accessibilityLabel("Dismiss activation confirmation")
                    }
                    .padding(.horizontal,FeastTheme.Spacing.large)
                    .background(FeastTheme.AdaptiveColors.surfaceBackground)
                }
            }
            .navigationTitle("Ask Feast").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button("History",systemImage:"clock.arrow.circlepath") { accessPresentation.present(.history) }.accessibilityIdentifier("ask.history") }
                ToolbarItem(placement:.topBarTrailing) { Button("New chat",systemImage:"square.and.pencil") { _ = state.session?.newChat() }.accessibilityIdentifier("ask.newChat") }
                ToolbarItem(placement: .principal) { Text("Ask Feast").font(FeastTheme.Typography.listTitle).foregroundStyle(FeastTheme.AdaptiveColors.primaryText) }
            }
            .toolbarBackground(FeastTheme.AdaptiveColors.groupedBackground, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
        }
        .sheet(item:$accessPresentation.sheet,onDismiss:{
            if accessPresentation.didDismissSheet() == .access {
                onlineConfigured=AskProductionAccess.credentialAvailable
                if !onlineConfigured {accessPresentation.dismissConfirmation();state.disableOnline()}
            }
        }) { sheet in
            switch sheet {
            case .history:
                if let session = state.session {
                    AskChatHistoryView(session:session,onlineConfigured:onlineConfigured,accessAvailable:phoneActivationAvailable,showAccess:{accessPresentation.present(.access)})
                }
            case .access:
                if let configuration=AskProductionAccess.configuration(info:Bundle.main.infoDictionary ?? [:]) {
                    AskActivationView(configuration:configuration,onActivated:{ newActivation in
                        let connected=state.connectActivatedPhone(configuration)
                        if connected {onlineConfigured=true}
                        return accessPresentation.connected(connected,newActivation:newActivation)
                    })
                }
            }
        }
        .foregroundStyle(FeastTheme.AdaptiveColors.primaryText)
        .tint(FeastTheme.AdaptiveColors.utilityAction)
        .task(id:onlineAllowed) {
            if !onlineAllowed { state.disableOnline() }
            guard let context = realContext else { state.markUnavailable(); return }
            let adapter = AskSavedCollection(context: context, canUpdate:{persistenceController?.canUpdateSavedPlace($0) ?? false},canMutate:{entity,id,operation in persistenceController?.canPerformAskChange(entity,id:id,operation:operation) ?? false},repository:{FeastRepository(context:$0,persistenceController:persistenceController)},canRecoverStore:{persistenceController?.canRecoverAskStore($0) ?? false}, visibleCities: {
                let fetch = NSFetchRequest<NSDictionary>(entityName: "FeastList")
                fetch.resultType = .dictionaryResultType; fetch.propertiesToFetch = ["id"]; fetch.includesPendingChanges = false
                return Set(try context.fetch(fetch).compactMap { $0["id"] as? UUID })
            })
            var provider: any AskFeastProvider = AskUnavailableProvider()
            var endpoint: URL?
            if let configuration = AskProductionAccess.configuration(info:Bundle.main.infoDictionary ?? [:]), AskProductionAccess.credentialAvailable {
                provider = state.productionProvider(configuration:configuration); endpoint = configuration.endpoint
            }
#if targetEnvironment(simulator)
            if let configuration=AskOwnerValidationAccess.configuration(info:Bundle.main.infoDictionary ?? [:]),AskOwnerValidationAccess.credentialAvailable {
                provider=state.productionProvider(configuration:configuration);endpoint=configuration.endpoint
            }
#endif
#if DEBUG && targetEnvironment(simulator)
            if AskHostedSimulator.savedPlaces && !AskHostedSimulator.synthetic {
                provider = state.hostedProvider(scope: .savedMetadata, token: { try AskHostedSimulator.token() }, send: { try await AskHostedHTTP().send($0) })
            }
#endif
            onlineConfigured = provider is AskHostedProvider
            state.prepareSavedCollection(adapter, provider: provider)
            if provider is AskHostedProvider { await state.refreshHostedCapabilities(endpoint:endpoint) }
        }
    }
}
struct AskConversationAnswer: View {
    let turnID: UUID
    let response: AskResponse
    let sources: [AskSource]
    let savedIn: [AskSavedCandidateKey: String]
    let savedRecordIDs: [AskSavedCandidateKey: String]
    let expandSources: Bool
    let openSaved: (String) -> Void
    let review: (AskCandidate) -> Void
    var fieldAction: (UUID,AskFieldActionMode) -> Void = {_,_ in}
    var collectionAction:(UUID,Bool)->Void = {_,_ in}
    @State private var reviewingChange:AskCollectionAction?
    @State private var expandedOperations=Set<String>()
    var collectionUndo: ([UUID])->Void = {_ in}
    var recordNames:[String:String] = [:]
    var recordLocations:[String:String] = [:]
    var actionsDisabled = false
    var isSample = false
    var availableRecordIDs: Set<String>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
            ForEach(operations) { operation in operationReceipt(operation) }
            ForEach(response.fieldActions ?? [],id: \.finding.id) { action in
                if let candidate=response.candidates.first(where:{$0.id==action.finding.recordID}),let profile=URL(string:action.finding.value) {
                    VStack(alignment:.leading,spacing:FeastTheme.Spacing.small) {
                        Button(candidate.name) {openSaved(action.finding.recordID)}.font(FeastTheme.Typography.body).accessibilityLabel("Open "+candidate.name+" in Feast, "+(recordLocations[candidate.id] ?? candidate.city))
                        if let location=recordLocations[candidate.id],!location.isEmpty {Text(location).font(FeastTheme.Typography.caption).foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)}
                        Link("@"+profile.lastPathComponent+" ↗",destination:profile).accessibilityLabel("Open Instagram @"+profile.lastPathComponent)
                        switch action.outcome {
                        case .ready,.failed,.undone:
                            Button("Save Instagram") {fieldAction(action.finding.id,.save)}.disabled(actionsDisabled)
                            if action.outcome == .failed {Text("Couldn’t save. Try again.").font(FeastTheme.Typography.caption)}
                        case .saved:
                            HStack {Text("Saved");Button("Undo") {fieldAction(action.finding.id,.undo)}.disabled(actionsDisabled)}
                        case .alreadySaved: Text("Saved")
                        case .conflict: Button("Replace existing Instagram…") {fieldAction(action.finding.id,.replace)}.disabled(actionsDisabled)
                        case .unavailable: Text("This place changed. Open it to review.")
                        }
                        if action.finding.evidenceURL != action.finding.value,let source=URL(string:action.finding.evidenceURL) {
                            Link("Source",destination:source).font(FeastTheme.Typography.caption).accessibilityLabel("Source for "+candidate.name+" Instagram")
                        }
                    }
                }
            }
            if response.paragraphs.isEmpty && (response.fieldActions ?? []).isEmpty && operations.isEmpty {
                Text(String(AskMarkdownPresentation.inline(response.summary).characters)).font(FeastTheme.Typography.body)
            }
            ForEach(response.substantiveParagraphs.filter { paragraph in !((response.fieldActions ?? []).isEmpty == false && paragraph.representedField == "instagram") }) { paragraph in
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
                    Text(attributed(paragraph)).font(FeastTheme.Typography.body)
                        .accessibilityHint(paragraph.spans.compactMap {span->String? in if case .place(let id)=span {return recordLocations[id]};return nil}.joined(separator:"; "))
                        .accessibilityAddTraits(paragraph.id=="library-city-heading" ? .isHeader : [])
                        .textSelection(.enabled)
                        .accessibilityActions {
                            ForEach(paragraph.citations, id: \.url) { citation in
                                Button("Open source: " + citation.title) { if let url = citation.safeURL { UIApplication.shared.open(url) } }
                            }
                        }
                        .tint(FeastTheme.AdaptiveColors.utilityAction)
                        .environment(\.openURL, OpenURLAction { url in
                            if let accepted=AskCitationLink.acceptedURL(for:url,citations:response.paragraphs.flatMap(\.citations)) { return .systemAction(accepted) }
                            guard let candidate = AskPlaceReference.candidate(for: url, in: response.candidates),
                                  let id = candidate.existingRecordID else { return .discarded }
                            openSaved(id)
                            return .handled
                        })
                    if isSample && !paragraph.sourceIDs.isEmpty {
                        AskSourceDetails(sources: sources.filter { paragraph.sourceIDs.contains($0.id) }, expanded: expandSources)
                    }
                }
            }
            if !isSample && !disclosedSources.isEmpty {
                AskSourceDetails(sources: disclosedSources, expanded: expandSources)
            }
            if let listedCityHeading {Text(listedCityHeading).font(FeastTheme.Typography.body).accessibilityAddTraits(.isHeader)}
            ForEach(listedCandidates) { candidate in
                AskCompactPlaceRow(candidate: candidate,
                    sources: sources.filter { candidate.sourceIDs.contains($0.id) },
                    savedIn: savedIn[.init(turnID: turnID, candidateID: candidate.id)],
                    savedRecordID: savedRecordIDs[.init(turnID: turnID, candidateID: candidate.id)],
                    openSaved: openSaved, review: { review(candidate) }, isSample: isSample,cityContext:listedCityHeading)
            }
        }.foregroundStyle(FeastTheme.AdaptiveColors.primaryText)
        .alert("Apply this change?",isPresented:Binding(get:{reviewingChange != nil},set:{if !$0 {reviewingChange=nil}})) {
            Button("Cancel",role:.cancel) {reviewingChange=nil}
            Button("Apply",role:reviewingChange?.operation=="delete" ? .destructive : nil) {if let action=reviewingChange {collectionAction(action.id,false)};reviewingChange=nil}
        } message: {Text(reviewingChange?.detail ?? reviewingChange?.title ?? "")}
        .accessibilityAction(named: Text("Copy answer")) { UIPasteboard.general.string = plainAnswer }
        .contextMenu {
            Button("Copy answer", systemImage: "doc.on.doc") { UIPasteboard.general.string = plainAnswer }
        }
    }
    private var operations:[AskOperationPresentation] {AskOperationPresentation.make(response:response,turnID:turnID)}
    private var names:[String:String] {recordNames.merging(Dictionary(response.candidates.map {($0.id,$0.name)},uniquingKeysWith:{$1}),uniquingKeysWith:{current,_ in current})}
    @ViewBuilder private func receiptControls(_ operation:AskOperationPresentation)->some View {
            if operation.viewIDs.count==1,let id=operation.viewIDs.first,availableRecordIDs?.contains(id) != false {
                Button("View") {openSaved(id)}.accessibilityLabel("View "+(names[id] ?? "saved place")).frame(minWidth:44)
            }
            Button {if !expandedOperations.insert(operation.id).inserted {expandedOperations.remove(operation.id)}} label: {
                HStack(spacing:4) {Text("Details");Image(systemName:expandedOperations.contains(operation.id) ? "chevron.up" : "chevron.down").font(.caption2)}
            }.accessibilityLabel("Details for "+operation.title(names:names)).accessibilityValue(expandedOperations.contains(operation.id) ? "Expanded" : "Collapsed").frame(minWidth:44)
            if !operation.undoActions.isEmpty {
                Button("Undo") {collectionUndo(operation.undoActions.map(\.id))}.disabled(actionsDisabled).frame(minWidth:44)
                    .accessibilityLabel("Undo this operation for \(Set(operation.undoActions.flatMap(\.targetIDs)).count) saved records")
                    .accessibilityHint("Reverses only this operation’s completed changes. Stops if a newer edit prevents reversal.")
            }
    }
    @ViewBuilder private func receiptActions(_ operation:AskOperationPresentation)->some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:FeastTheme.Spacing.medium) {receiptControls(operation)}.fixedSize()
            VStack(alignment:.leading,spacing:0) {receiptControls(operation)}
        }.buttonStyle(FeastInlineActionButtonStyle(adaptive:true))
    }
    @ViewBuilder private func detailControls(_ row:AskReceiptDetailRow)->some View {
                ForEach(row.targetIDs,id:\.self) {id in
                    if row.actions.first?.entity=="place",availableRecordIDs?.contains(id)==true {
                        Button(row.targetIDs.count==1 ? "View" : "View "+(names[id] ?? "place")) {openSaved(id)}.accessibilityLabel("View "+(names[id] ?? "saved place")).frame(minWidth:44)
                    }
                }
                if !row.undoActions.isEmpty {
                    Button("Undo") {collectionUndo(row.undoActions.map(\.id))}.disabled(actionsDisabled).frame(minWidth:44)
                        .accessibilityLabel("Undo changes to "+row.title(names:names))
                        .accessibilityHint("Only the changes listed for these records will be reversed; stops if a newer edit blocks reversal.")
                }
    }
    @ViewBuilder private func operationReceipt(_ operation:AskOperationPresentation)->some View {
        VStack(alignment:.leading,spacing:FeastTheme.Spacing.xSmall) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:FeastTheme.Spacing.medium) {
                    Text(operation.title(names:names)).font(FeastTheme.Typography.body).fixedSize()
                    receiptActions(operation).fixedSize()
                }
                VStack(alignment:.leading,spacing:0) {
                    Text(operation.title(names:names)).font(FeastTheme.Typography.body).fixedSize(horizontal:false,vertical:true)
                    receiptActions(operation)
                }
            }
            if expandedOperations.contains(operation.id) {
                VStack(alignment:.leading,spacing:FeastTheme.Spacing.medium) {
                    ForEach(AskReceiptDetailRow.make(operation.actions)) {row in
                        VStack(alignment:.leading,spacing:FeastTheme.Spacing.xSmall) {
                            Text(row.title(names:names)).font(FeastTheme.Typography.body.weight(.semibold))
                            Text(row.actions.map(actionLabel).reduce(into:[String]()){if !$0.contains($1){$0.append($1)}}.joined(separator:" · ")).font(FeastTheme.Typography.caption).foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)
                            if !operation.attention.isDisjoint(with:row.targetIDs) {Text("Some changes are incomplete. Review before continuing.").font(FeastTheme.Typography.caption)}
                            ForEach(row.actions) {action in
                                if let failure=response.undoFailures?[action.id.uuidString] {Text(failure=="newer_edit" ? "A newer edit blocked Undo. Your newer changes were kept." : "Undo couldn’t finish. Review the current record before trying again.").font(FeastTheme.Typography.caption)}
                            }
                            ViewThatFits(in:.horizontal) {
                                HStack(spacing:FeastTheme.Spacing.medium) {detailControls(row)}.fixedSize()
                                VStack(alignment:.leading,spacing:0) {detailControls(row)}
                            }.buttonStyle(FeastInlineActionButtonStyle(adaptive:true))
                            ForEach(row.actions.filter {$0.state == .ready || $0.state == .needsConfirmation}) {action in
                                Button(row.actions.count==1 ? "Review change" : "Review "+action.title) {reviewingChange=action}.disabled(actionsDisabled).buttonStyle(FeastInlineActionButtonStyle(adaptive:true))
                            }
                            let details=row.actions.compactMap(\.detail).filter {!$0.isEmpty}
                            if !details.isEmpty {
                                DisclosureGroup {ForEach(Array(details.enumerated()),id:\.offset) {_,detail in Text(detail).font(FeastTheme.Typography.caption).textSelection(.enabled)}} label: {
                                    Text("Changes").frame(minHeight:44).accessibilityLabel("Change details for "+row.title(names:names))
                                }.font(FeastTheme.Typography.caption)
                            }
                        }
                    }
                    let covered=Set(operation.actions.flatMap(\.targetIDs))
                    ForEach(operation.attention.subtracting(covered).sorted(),id:\.self) {id in
                        VStack(alignment:.leading) {
                            Text((names[id] ?? "A selected record")+": incomplete. Review before continuing.").font(FeastTheme.Typography.caption)
                            if operation.record.entity=="place",availableRecordIDs?.contains(id)==true {Button("View "+(names[id] ?? "saved place")) {openSaved(id)}.buttonStyle(FeastInlineActionButtonStyle(adaptive:true))}
                        }
                    }
                    if !response.legacyOperationParagraphs.isEmpty {
                        DisclosureGroup {ForEach(response.legacyOperationParagraphs) {paragraph in Text(attributed(paragraph)).font(FeastTheme.Typography.caption).textSelection(.enabled)}} label: {
                            Text("Earlier response").frame(minHeight:44)
                        }.font(FeastTheme.Typography.caption)
                    }
                    if operation.unresolved {Text("The outcome is unresolved. Review the current records before retrying; some changes may have completed.").font(FeastTheme.Typography.caption)}
                    if operation.undoActions.count>1 {Text("Undo reverses these completed changes one at a time. If a newer edit blocks it, remaining changes stay saved.").font(FeastTheme.Typography.caption)}
                }.padding(.leading,FeastTheme.Spacing.small).padding(.top,FeastTheme.Spacing.small)
            }
        }
    }
    private func actionLabel(_ action:AskCollectionAction)->String {
        switch action.state {
        case .applied:return action.wasChanged ? "Saved" : "Unchanged"
        case .undone:return "Undone"
        case .ready,.needsConfirmation:return "Needs review"
        case .conflict:return action.wasChanged ? "Saved earlier; a newer edit prevents reversal" : "A newer edit prevents this change"
        case .unavailable:return "Unavailable or unresolved; review the current record"
        case .failed:return "Failed; no successful result is recorded"
        }
    }
    private var disclosedSources: [AskSource] { AskSourcePresentation.disclosedSources(response: response, sources: sources, availableIDs: availableRecordIDs) }
    private var plainAnswer: String { AskAnswerCopy.text(response) }
    private var listedCityHeading:String? {
        let cities=Set(listedCandidates.map(\.city))
        return listedCandidates.count>1 && cities.count==1 && cities.first?.isEmpty==false ? cities.first : nil
    }
    private var listedCandidates: [AskCandidate] {
        guard let ids = response.listedCandidateIDs else { return response.candidates }
        return ids.compactMap { id in response.candidates.first { $0.id == id } }
    }
    private func attributed(_ paragraph: AskAnswerParagraph) -> AttributedString {
        var result = AskMarkdownPresentation.inline(paragraph,candidates:response.candidates,citations:response.paragraphs.flatMap(\.citations))
        let allCitations = response.paragraphs.flatMap(\.citations).reduce(into: [AskWebCitation]()) { result, citation in
            if !result.contains(where: { $0.url == citation.url }) { result.append(citation) }
        }
        let locallyLinked=AskMarkdownPresentation.locallyLinkedSources(paragraph,researchPool:AskMarkdownPresentation.hasResearchPoolProvenance(paragraph,in:response))
        for citation in paragraph.citations {
            guard let url = citation.safeURL, !locallyLinked.contains(url), let index = allCitations.firstIndex(where: { $0.url == citation.url }) else { continue }
            var link = AttributedString(" [\(index+1)]")
            link.link = url
            result.append(link)
        }
        return result
    }
}

private struct AskCompactPlaceRow: View {
    let candidate: AskCandidate
    let sources: [AskSource]
    let savedIn: String?
    let savedRecordID: String?
    let openSaved: (String) -> Void
    let review: () -> Void
    var isSample = false
    var cityContext:String? = nil
    private var location: String {
        candidate.facts.first { $0.kind == .neighborhood }?.value ?? (cityContext==candidate.city ? "" : candidate.city)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
            Text(candidate.existingRecordID != nil || savedIn != nil ? "Saved place" : "Not saved")
                .font(FeastTheme.Typography.caption)
                .foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)
            if let id = candidate.existingRecordID {
                Button(candidate.name) { openSaved(id) }.buttonStyle(FeastInlineActionButtonStyle(adaptive: true)).accessibilityLabel("Open "+candidate.name+", "+candidate.city+", "+location)
            } else { Text(candidate.name).font(FeastTheme.Typography.rowTitle) }
            if !location.isEmpty { Text(location).font(FeastTheme.Typography.rowMetadata).foregroundStyle(FeastTheme.AdaptiveColors.secondaryText) }
            if let savedIn {
                Text("Saved to " + savedIn).font(FeastTheme.Typography.rowMetadata)
                if let id = savedRecordID {
                    Button("View saved place") { openSaved(id) }.buttonStyle(FeastInlineActionButtonStyle(adaptive: true))
                }
            } else if candidate.existingRecordID == nil {
                Button { review() } label: {
                    Text("Save").frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }.buttonStyle(FeastInlineActionButtonStyle(adaptive: true))
                    .accessibilityLabel("Review saving " + candidate.name)
            }
            AskSourceDetails(sources: sources)
        }
        .padding(.vertical, FeastTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(FeastTheme.AdaptiveColors.dividerBorder).frame(height: 1) }
    }
}

private struct AskSourceDetails: View {
    let sources: [AskSource]
    @State private var expanded: Bool
    init(sources: [AskSource], expanded: Bool = false) { self.sources = AskSourcePresentation.visible(sources); _expanded = State(initialValue: expanded) }
    private var origin: String {
        let kinds = Set(sources.map { $0.kind.rawValue })
        if kinds == [AskSourceKind.savedMetadata.rawValue] { return "Saved details" }
        if kinds == [AskSourceKind.selectedScreenshot.rawValue] { return "Attached screenshot" }
        if kinds == [AskSourceKind.savedNote.rawValue] { return "Saved notes" }
        if kinds == [AskSourceKind.webFixture.rawValue] { return "Web sources" }
        if kinds == [AskSourceKind.localOCR.rawValue] { return "Local OCR" }
        if kinds == [AskSourceKind.pastedText.rawValue] { return "Supplied text" }
        return "Sources"
    }
    var body: some View {
        if !sources.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
                            Text(source.author).font(FeastTheme.Typography.rowMetadata.weight(.semibold))
                            Text(source.excerpt).font(FeastTheme.Typography.rowMetadata)
                            Text(source.title).font(FeastTheme.Typography.caption)
                            if let dates = AskSourcePresentation.dates(source) { Text(dates).font(FeastTheme.Typography.caption) }
                            if let url = source.url { Text(url).font(FeastTheme.Typography.caption).textSelection(.enabled) }
                        }
                    }
                }.foregroundStyle(FeastTheme.AdaptiveColors.primaryText).padding(.vertical, FeastTheme.Spacing.small)
            } label: {
                Text(origin + " · \(sources.count) \(sources.count == 1 ? "source" : "sources")")
                    .font(FeastTheme.Typography.caption).foregroundStyle(FeastTheme.AdaptiveColors.utilityAction)
            }.frame(minHeight: 44)
        }
    }
}


private struct AskChatHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AskSession
    let onlineConfigured:Bool
    let accessAvailable:Bool
    let showAccess:()->Void
    @State private var renaming:UUID?
    @State private var title = ""
    @State private var deleting:UUID?
    @State private var showingRename = false
    @State private var showingDelete = false
    private var orderedChats:[AskChatArchive] { AskHistoryPresentation.ordered(session.chats) }
    var body: some View {
        NavigationStack {
            historyList
                .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.principal) {Text("History").font(FeastTheme.Typography.listTitle).foregroundStyle(FeastTheme.AdaptiveColors.primaryText)}
                    ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } }
                }
                .alert("Rename chat",isPresented:$showingRename) {
                    TextField("Chat name",text:$title)
                    Button("Save") { if let id=renaming { _ = session.renameChat(id,to:title) };renaming=nil }
                    Button("Cancel",role:.cancel) { renaming=nil }
                }
                .confirmationDialog("Delete this chat?",isPresented:$showingDelete,titleVisibility:.visible) {
                    Button("Delete chat",role:.destructive) { if let id=deleting { _ = session.deleteChat(id) };deleting=nil }
                    Button("Cancel",role:.cancel) { deleting=nil }
                } message: { Text("Your saved restaurants won’t be changed.") }
                .onAppear { session.flushHistory() }
        }
    }
    private var historyList: some View {
        List {
            Section {
                NavigationLink { AskPrivacyView(onlineConfigured:onlineConfigured) } label: { Label("Settings",systemImage:"gearshape") }
                if accessAvailable {
                    Button(action:showAccess) {Label("Ask Feast access",systemImage:"key")}
                        .accessibilityIdentifier("ask.activate")
                }
            }
            ForEach(orderedChats) { chat in historyRow(chat) }
            if let error = session.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func historyRow(_ chat:AskChatArchive) -> some View {
        Button {
            if chat.id == session.activeChatID || session.openChat(chat.id) { dismiss() }
        } label: {
            HStack {
                VStack(alignment:.leading,spacing:FeastTheme.Spacing.xSmall) {
                    Text(AskHistoryPresentation.title(chat)).foregroundStyle(.primary).lineLimit(2)
                    Text(AskHistoryPresentation.date(chat)).font(.caption).foregroundStyle(.secondary)
                    Text(AskHistoryPresentation.preview(chat)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if chat.id == session.activeChatID { Image(systemName:"checkmark").accessibilityLabel("Current chat") }
            }
        }
        .accessibilityLabel(AskHistoryPresentation.title(chat)+", "+AskHistoryPresentation.date(chat)+". "+AskHistoryPresentation.preview(chat))
        .accessibilityHint("Open this saved conversation")
        .accessibilityActions {
            Button("Rename chat") {title=chat.title;renaming=chat.id;showingRename=true}
            Button("Delete chat") {deleting=chat.id;showingDelete=true}
        }
        .contextMenu {
            Button("Rename",systemImage:"pencil") { title=chat.title;renaming=chat.id;showingRename=true }
            Button("Delete chat",systemImage:"trash",role:.destructive) { deleting=chat.id;showingDelete=true }
        }
        .swipeActions {
            Button("Delete",role:.destructive) { deleting=chat.id;showingDelete=true }
            Button("Rename") { title=chat.title;renaming=chat.id;showingRename=true }
        }
    }
}
