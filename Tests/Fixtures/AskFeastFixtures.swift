import Foundation

enum AskFixtures {
    static let date = "2026-10-18 (fixture)"
    static let records: [AskCollectionRecord] = [
        .init(id: "kiku", cityID: "shared-nyc", city: "NYC", name: "Kiku House (fictional)", neighborhood: "Upper East Side", cuisine: "Japanese", status: "Want to try", notes: [
            .init(id: "maya-kiku", author: "Maya · synthetic collaborator", text: "Japanese small plates. The menu mentioned cocktails; I saved it to investigate, not a record of a visit."),
            .init(id: "jon-kiku", author: "You · synthetic", text: "Could be the UES place I was trying to remember; not confirmed.")]),
        .init(id: "sora", cityID: "shared-nyc", city: "NYC", name: "Sora Table (fictional)", neighborhood: "Upper East Side", cuisine: "Japanese", status: "Want to try", notes: [
            .init(id: "alex-sora", author: "Alex · synthetic collaborator", text: "A Japanese restaurant on the Upper East Side. Unsure whether cocktails are offered.")]),
        .init(id: "hidden", cityID: "unavailable-private", city: "Private City", name: "Invisible private place", neighborhood: "Upper East Side", cuisine: "Japanese", status: "Love", notes: [
            .init(id: "hidden-note", author: "Hidden person", text: "SECRET_DO_NOT_RETURN")])
    ]
    static var index: AskLocalIndex {
        .init(records: records, visibleCityIDs: ["shared-nyc"], visibleNoteIDs: ["maya-kiku", "jon-kiku", "alex-sora"])
    }
    static func collectionEvidence(_ records: [AskCollectionRecord]) -> AskEvidence {
        var sources: [AskSource] = []
        let boundedRecords = Array(records.prefix(6))
        let candidates = boundedRecords.enumerated().map { index, record in
            let metadataID = "record-" + record.id
            sources.append(.init(id: metadataID, title: "Saved synthetic record", kind: .savedNote, author: "Metadata · author unknown", published: nil, checked: date, url: nil,
                excerpt: "\(record.name) · \(record.neighborhood) · \(record.cuisine) · saved status: \(record.status). Status is not proof of a visit. \(record.address ?? "Address not recorded")"))
            let remainingRecords = boundedRecords.count - index - 1
            let notes = Array(record.notes.prefix(min(3, max(0, 12 - sources.count - remainingRecords))))
            for note in notes {
                sources.append(.init(id: note.id, title: "Saved synthetic note", kind: .savedNote, author: note.author, published: nil, checked: date, url: nil, excerpt: note.text))
            }
            var facts: [AskFact] = [.init(kind: .neighborhood, value: record.neighborhood, sourceID: metadataID), .init(kind: .cuisine, value: record.cuisine, sourceID: metadataID)]
            if let address = record.address { facts.append(.init(kind: .address, value: address, sourceID: metadataID)) }
            return AskCandidate(id: record.id, name: record.name, city: record.city,
                facts: facts,
                sourceIDs: [metadataID] + notes.map(\.id), uncertainty: "Recognition option, not confirmed identity or visit history.", mapOptions: [], existingRecordID: record.id)
        }
        return .init(candidates: candidates, sources: sources)
    }
    static let mapOptions: [AskMapOption] = [
        .init(id: "mock-kiku-ues", name: "Kiku House — UES (fictional)", address: "101 Example Avenue, Upper East Side, NYC (fixture)"),
        .init(id: "mock-kiku-soho", name: "Kiku House — Soho (fictional)", address: "202 Example Street, Soho, NYC (fixture)")
    ]
    static func webEvidence(_ query: String) -> AskEvidence {
        let text = query.lowercased()
        if text.contains("baker") {
            let source = AskSource(id: "web-bakery", title: "Fictional bakery announcement", kind: .webFixture, author: "Mock publisher · not a real article", published: "2026-10-12 (fixture)", checked: date,
                url: "https://example.invalid/feast/harbor-flour", excerpt: "Harbor Flour (fictional) announced a Manhattan bakery, targeting November–December 2026. Exact address and opening day unconfirmed.")
            let second = AskSource(id: "web-bakery-2", title: "Fictional bakery newsletter", kind: .webFixture, author: "Mock publisher · not a real article", published: "2026-10-14 (fixture)", checked: date,
                url: "https://example.invalid/feast/morning-fold", excerpt: "Morning Fold (fictional) plans a Manhattan bakery in early 2027. No confirmed address or opening day.")
            let candidates = [("harbor-flour", "Harbor Flour (fictional)", "November–December 2026 (announced target, unconfirmed)", source),
                              ("morning-fold", "Morning Fold (fictional)", "Early 2027 (announced target, unconfirmed)", second)].map { id, name, window, source in
                AskCandidate(id: id, name: name, city: "NYC", facts: [.init(kind: .type, value: "Bakery", sourceID: source.id), .init(kind: .neighborhood, value: "Manhattan; exact address unconfirmed", sourceID: source.id), .init(kind: .opening, value: window, sourceID: source.id)],
                    sourceIDs: [source.id], uncertainty: "No fixture Maps listing. This is a fictional announced window, not confirmation of opening. Save an unpinned manual draft only after review.", mapOptions: [], existingRecordID: nil)
            }
            return .init(candidates: candidates, sources: [source, second])
        }
        if text.contains("japan") || text.contains("kiku") {
            let source = AskSource(id: "web-kiku", title: "Fictional restaurant page", kind: .webFixture, author: "Mock restaurant page", published: nil, checked: date, url: "https://example.invalid/feast/kiku", excerpt: "Kiku House is a fictional Japanese restaurant used to demonstrate multiple branch matches. Cocktail availability is not established by this source.")
            return .init(candidates: [.init(id: "web-kiku", name: "Kiku House (fictional)", city: "NYC", facts: [.init(kind: .type, value: "Restaurant", sourceID: source.id), .init(kind: .cuisine, value: "Japanese", sourceID: source.id)], sourceIDs: [source.id], uncertainty: "Two synthetic branches; choose explicitly. The query does not prove either branch offers cocktails.", mapOptions: mapOptions, existingRecordID: nil)], sources: [source])
        }
        return .init(candidates: [], sources: [])
    }
    static func importEvidence(_ text: String, fromOCR: Bool) -> AskEvidence {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let known = text.localizedCaseInsensitiveContains("Kiku House")
        let first = lines.first ?? ""
        let urlOnly = URL(string: first)?.scheme != nil
        let name = known ? "Kiku House (fictional)" : (urlOnly ? "Name needs review" : String(first.prefix(100)))
        let source = AskSource(id: "input", title: fromOCR ? "Selected screenshot · local OCR" : "Pasted text/link · not fetched", kind: fromOCR ? .localOCR : .pastedText,
            author: "Source author unknown", published: nil, checked: date, url: nil, excerpt: String(text.prefix(4_000)))
        return .init(candidates: [.init(id: "import", name: name, city: known ? "NYC" : "City needs review", facts: [], sourceIDs: [source.id], uncertainty: "Name/text is unverified. No address, cuisine, cocktails, visit history, or opening status has been inferred. Review all fields. Links were not fetched.", mapOptions: known ? mapOptions : [], existingRecordID: nil)], sources: [source])
    }
}

struct AskSaveReview: Equatable {
    let candidate: AskCandidate
    let query: String
    let sources: [AskSource]
    var name: String
    var cityID: String
    var mapOptionID: String?
    var manual = false
    var placeType: PlaceType
    var cuisines: String
    var note: String
    var personalNote = ""
    var status: PlaceStatus = .wantToTry
    init(candidate: AskCandidate, query: String, sources: [AskSource], cityID: String) {
        self.candidate = candidate; self.query = query; self.sources = sources; self.cityID = cityID
        name = candidate.name == "Name needs review" ? "" : candidate.name
        placeType = candidate.facts.first { $0.kind == .type }.flatMap { PlaceType(rawValue: $0.value) } ?? .other
        cuisines = candidate.facts.filter { $0.kind == .cuisine }.map(\.value).joined(separator: ", ")
        note = "MOCK PROTOTYPE — fictional evidence, not live search.\n\nSource-stated details (review, not independently verified):\n" + candidate.valueForReview
            + "\n\nUncertainty: " + candidate.uncertainty
            + "\n\nSearch/import context — criteria, NOT claims about this place:\n" + query
            + "\n\nSources:\n" + sources.map { source in
                "\(source.title) · \(source.author)\nPublished: \(source.published ?? "unknown") · checked: \(source.checked)\n\(source.url ?? "No URL; local supplied/saved content")\n\(source.excerpt)"
            }.joined(separator: "\n\n")
    }
    var selectedMapOption: AskMapOption? { candidate.mapOptions.first { $0.id == mapOptionID } }
    var canSave: Bool {
        !cityID.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200 && note.count + personalNote.count <= 11_500 && cuisines.count <= 500 &&
        candidate.existingRecordID == nil && (selectedMapOption != nil || (manual && candidate.mapOptions.isEmpty))
    }
}
