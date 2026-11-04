import SwiftUI
import PhotosUI
import CoreData

/// Uses the existing collection directly. No seed data, imports, automatic saves or photo scanning.
struct AskSavedCollectionPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var state: AskFeastTabState
    @ObservedObject var session: AskSession
    var showHistory:()->Void = {}
    @State private var photo: PhotosPickerItem?
    @State private var photoTask: Task<Void, Never>?
    @State private var readingPhoto = false
    @State private var inputError: String?
    @State private var selectedPlace: SavedPlace?
    @State private var saveRoute: AskSaveDestination?
    @State private var showingConsent = false
    @State private var replacement: (turn:UUID,finding:UUID)?
    @State private var showingReplacement = false
    @FocusState private var focused: Bool

    @ViewBuilder private func mapChoices(_ turn:AskTurn)->some View {
        ForEach(turn.response?.mapChoices ?? []) {choice in
            let existing=state.availablePersonalPlaces.first(where:{$0.applePlaceID==choice.applePlaceID})
            Button {
                if let existing {openPlace(existing.id)}
                else {session.chooseMapChoice(turnID:turn.id,choiceID:choice.id)}
            } label: {
                VStack(alignment:.leading,spacing:FeastTheme.Spacing.xSmall) {
                    Text(choice.name).font(FeastTheme.Typography.body)
                    if !choice.address.isEmpty {Text(choice.address).font(FeastTheme.Typography.caption).foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)}
                    if existing != nil {Text("Already saved · View in Feast").font(FeastTheme.Typography.caption)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(FeastTheme.Spacing.medium)
            }.buttonStyle(.bordered).disabled(session.isLoading || !session.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                .accessibilityLabel((existing==nil ? "Choose " : "Open saved ")+choice.name+", "+choice.address)
                .accessibilityHint(existing==nil ? "Continue this request using this Apple Maps match." : "View this saved place in Feast.")
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FeastTheme.Spacing.large) {
                        if session.turns.isEmpty {
                            VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                                Text("Where would you like to eat?").font(FeastTheme.Typography.listTitle)
                                Text(state.collectionCount == 0 ? "No saved places are available on this device. Add places in Cities to ask about them." : "Ask about your saved places.")
                                    .foregroundStyle(FeastTheme.AdaptiveColors.secondaryText)
                            }.padding(.top, FeastTheme.Spacing.xxLarge)
                        }
                        ForEach(session.turns) { turn in
                            VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
                                Text(turn.request.text.isEmpty ? "Screenshot" : turn.request.text)
                                    .padding(FeastTheme.Spacing.medium)
                                    .background(FeastTheme.Colors.accentSelection.opacity(0.12), in: RoundedRectangle(cornerRadius: FeastTheme.CornerRadius.medium))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                if turn.request.attachment != nil { Label("Attached screenshot", systemImage: "photo").font(FeastTheme.Typography.caption) }
                                if let response = turn.response {
                                    AskConversationAnswer(turnID: turn.id, response: response, sources: turn.sources,
                                        savedIn: [:], savedRecordIDs: [:], expandSources: false, openSaved: openPlace,
                                        review: { _ in }, fieldAction: { id,mode in
                                            if mode == .replace {replacement=(turn.id,id);showingReplacement=true}
                                            else {session.applyFieldAction(turn:turn.id,findingID:id,mode:mode);try? state.refreshSavedCollection()}
                                        }, collectionAction:{id,undo in session.applyCollectionAction(turn:turn.id,actionID:id,undo:undo);try? state.refreshSavedCollection()}, collectionUndo:{ids in session.undoCollectionOperation(turn:turn.id,actionIDs:ids);try? state.refreshSavedCollection()}, recordNames:Dictionary(state.availablePersonalPlaces.map {($0.id,$0.name)},uniquingKeysWith:{$1}), recordLocations:Dictionary(state.availablePersonalPlaces.map {($0.id,[$0.city,$0.neighborhood].filter {!$0.isEmpty}.joined(separator:", "))},uniquingKeysWith:{$1}), actionsDisabled:session.isLoading, isSample: false, availableRecordIDs: state.availableRecordIDs)
                                        .onAppear { session.markRendered(turn.id) }
                                .onChange(of:session.answerRevisions[turn.id]) {_,_ in session.markRendered(turn.id)}
                                }
                                if let response = turn.response {
                                    mapChoices(turn)
                                    ForEach(response.webPlaces.filter { web in response.paragraphs.flatMap(\.citations).contains { $0.url == web.sourceURL } }, id: \.sourceURL) { place in
                                        if let record = AskSavedDiscoveryMatch.unique(place, in: state.availablePersonalPlaces) {
                                            Button("View \(place.name) in Feast") { openPlace(record.id) }.font(FeastTheme.Typography.caption)
                                        } else {
                                            Button("Save \(place.name) to Feast") { openSave(place) }
                                                .font(FeastTheme.Typography.caption).accessibilityHint("Choose an Apple Maps match and destination city. Nothing is saved automatically.")
                                        }
                                    }
                                }
                                switch turn.status {
                                case .loading: ProgressView(session.progressLabel).accessibilityLabel(session.progressLabel)
                                case .failed(let message): retry(message, id: turn.id)
                                case .stopped: retry("Stopped. A request already sent may still finish on the service.", id: turn.id)
                                case .complete: EmptyView()
                                }
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(FeastTheme.Spacing.large)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.activeChatID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.isLoading) { _, loading in if !loading { proxy.scrollTo("bottom", anchor: .bottom) } }
                composer
            }
        }
        .background(FeastTheme.AdaptiveColors.groupedBackground)
        .onChange(of: session.isLoading) { _, loading in
            if !loading && UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: session.turns.last?.status == .complete ? "Answer ready" : "Request stopped or couldn’t finish")
            }

        }
        .alert("Replace saved Instagram?",isPresented:$showingReplacement) {
            Button("Replace") {if let replacement {session.applyFieldAction(turn:replacement.turn,findingID:replacement.finding,mode:.replace);try? state.refreshSavedCollection()};replacement=nil}
            Button("Cancel",role:.cancel) {replacement=nil}
        } message: {Text(replacementMessage)}
        .alert("Use online AI?",isPresented:$showingConsent) {
            Button("Allow and send") {
                guard let ticket = session.prepareConsentSend() else { return }
                AskPrivacy.accept()
                Task { await state.refreshHostedCapabilities(); session.resumeAfterConsent(ticket) }
            }
            Button("Cancel",role:.cancel) { session.dismissConsent() }
        } message: { Text(AskPrivacy.disclosure + " You can turn this off in History → Settings.") }
        .onChange(of:session.needsOnlineConsent) { _,value in showingConsent=value }
        .onChange(of:session.activeChatID) { _,_ in photoTask?.cancel();photo=nil;readingPhoto=false;inputError=nil;saveRoute=nil;selectedPlace=nil;replacement=nil;showingReplacement=false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.suspend() } else { try? state.refreshSavedCollection() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: state.savedCollection?.context)) { _ in try? state.refreshSavedCollection() }
        .onChange(of: photo) { _, item in loadSelected(item) }
        .onDisappear { photoTask?.cancel(); readingPhoto = false; photo = nil; session.suspend() }
        .sheet(item: $saveRoute, onDismiss: { try? state.refreshSavedCollection() }) { route in
            NavigationStack { AddPlaceView(initialSearchQuery: route.place.name, discoveryRegion: route.place.region) }
                .environment(\.managedObjectContext, route.context)
        }
        .sheet(item: $selectedPlace) { place in NavigationStack { SavedPlaceDetailView(savedPlace: place) } }
    }
    private var replacementMessage:String {
        guard let replacement,let turn=session.turns.first(where:{$0.id==replacement.turn}),
              let action=turn.response?.fieldActions?.first(where:{$0.finding.id==replacement.finding}) else {return "This answer changed. Cancel and review the current place."}
        let old=action.expectedValue.flatMap(InstagramWebsiteParser.profileURL).flatMap(URL.init(string:)).map {"@"+$0.lastPathComponent} ?? "the existing Instagram"
        let new=URL(string:action.finding.value).map {"@"+$0.lastPathComponent} ?? "the new account"
        let name=turn.response?.candidates.first(where:{$0.id==action.finding.recordID})?.name ?? "this place"
        return "Replace "+old+" with "+new+" for "+name+"?"
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
            if let attachment = session.attachment, let image = UIImage(data: attachment.jpeg) {
                HStack {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 90).accessibilityLabel("Selected screenshot preview")
                    Spacer()
                    Button { session.attachment = nil; photo = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Remove selected screenshot")
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                TextEditor(text: $session.input)
                    .font(FeastTheme.Typography.supporting).focused($focused)
                    .frame(height: 140).scrollContentBackground(.hidden)
                    .accessibilityLabel("Message Ask Feast")
                    .accessibilityAction(named:Text("Open chat history")) {showHistory()}
                    .accessibilityAction(named:Text("Start new chat")) {_ = session.newChat()}
                    .overlay(alignment: .topLeading) {
                        if session.input.isEmpty { Text("Ask about a place…").font(FeastTheme.Typography.supporting).foregroundStyle(FeastTheme.AdaptiveColors.secondaryText).allowsHitTesting(false).accessibilityHidden(true) }
                    }
            } else {
                TextField("Message", text: $session.input, prompt: Text("Ask about a place…"), axis: .vertical)
                    .lineLimit(1...5).focused($focused).font(FeastTheme.Typography.supporting)
                    .accessibilityLabel("Message Ask Feast")
                    .accessibilityAction(named:Text("Open chat history")) {showHistory()}
                    .accessibilityAction(named:Text("Start new chat")) {_ = session.newChat()}
            }
            HStack {
                if state.screenshotSendingAvailable {
                    PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo").font(.system(size: 22)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Attach one screenshot").disabled(session.isLoading || readingPhoto)
                }
                if readingPhoto { ProgressView("Preparing screenshot…").font(FeastTheme.Typography.caption) }
                Spacer()
                Button {
                    if session.isLoading { session.cancel() } else { send() }
                } label: {
                    Image(systemName: session.isLoading ? "stop.fill" : "arrow.up").font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44).background(FeastTheme.Colors.secondaryAction, in: Circle()).foregroundStyle(.white)
                }.accessibilityLabel(session.isLoading ? "Stop" : "Send message")
                    .disabled(readingPhoto || (!session.isLoading && session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachment == nil))
            }
            if let error = session.error, !session.turns.contains(where: { if case .failed = $0.status { return true }; return false }) { Text(error).font(FeastTheme.Typography.caption) }
            if let inputError { Text(inputError).font(FeastTheme.Typography.caption) }
        }
        .padding(FeastTheme.Spacing.medium)
        .background(FeastTheme.AdaptiveColors.surfaceBackground, in: RoundedRectangle(cornerRadius: FeastTheme.CornerRadius.large))
        .padding(FeastTheme.Spacing.large)
        .background(FeastTheme.AdaptiveColors.groupedBackground)
    }
    private func send() {
        do {
            try state.refreshSavedCollection()
            guard session.attachment == nil || state.screenshotSendingAvailable else { inputError = "Screenshot sending is currently unavailable."; return }
            guard state.collectionCount > 0 || session.attachment != nil || AskQueryPlan.route(session.input) != .personal else { inputError = "No saved places are available here yet."; return }
            inputError = nil; focused = false; session.sourceOverride = nil; session.fromOCR = false
            if session.attachment != nil { session.mode = .collection; session.run() } else { session.runAutomatically() }
        } catch { inputError = "Saved places could not be read. Nothing was sent." }
    }
    private func retry(_ message: String, id: UUID) -> some View {
        HStack(alignment: .top) {
            Text(message).font(FeastTheme.Typography.caption)
            Spacer()
            if session.canRetry[id] != false { Button("Retry") {
                do { try state.refreshSavedCollection(); session.retry(id) }
                catch { inputError = "Saved places are unavailable. Nothing was sent." }
            }.disabled(session.isLoading) }
        }
    }
    private func openSave(_ place: AskWebPlace) {
        do {
            guard let adapter = state.savedCollection else { throw AskError.invalidEvidence }
            saveRoute = .init(place: place, context: try adapter.makeSaveContext())
        } catch { inputError = "The save form couldn’t be opened. Your places weren’t changed." }
    }
    private func openPlace(_ value: String) {
        guard let id = UUID(uuidString: value), let adapter = state.savedCollection else { return }
        do {
            let visible = try adapter.visibleCities()
            let fetch = SavedPlace.fetchRequest()
            fetch.predicate = NSPredicate(format: "id == %@ AND feastList.id IN %@", id as NSUUID, Array(visible) as NSArray)
            fetch.fetchLimit = 2
            let matches = try adapter.context.fetch(fetch)
            guard matches.count == 1 else { throw AskError.invalidEvidence }
            selectedPlace = matches[0]
        } catch { inputError = "This saved place is no longer available." }
    }
    private func loadSelected(_ item: PhotosPickerItem?) {
        photoTask?.cancel()
        guard let item else { readingPhoto = false; return }
        readingPhoto = true
        photoTask = Task {
            do {
                guard let file = try await item.loadTransferable(type: AskSelectedImage.self) else { throw AskError.unreadableImage }
                let screenshot = try await Task.detached(priority: .userInitiated) { try AskScreenshotPreparation.prepare(file.data) }.value
                try Task.checkCancellation()
                guard AskPrivacy.onlineAllowed && state.screenshotSendingAvailable else {
                    session.attachment = nil; readingPhoto = false; photo = nil; return
                }
                session.attachment = screenshot; readingPhoto = false; inputError = nil
            } catch {
                if !Task.isCancelled { readingPhoto = false; inputError = error.localizedDescription }
            }
        }
    }
}

private struct AskSaveDestination: Identifiable {
    let id = UUID()
    let place: AskWebPlace
    let context: NSManagedObjectContext
}
