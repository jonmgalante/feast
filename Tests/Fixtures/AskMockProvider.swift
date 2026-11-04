import Foundation

struct MockAskFeastProvider: AskFeastProvider {
    let label = "Mock provider · fixtures only"
    private let delayMilliseconds: Int
    nonisolated init(delayMilliseconds: Int = 350) { self.delayMilliseconds = delayMilliseconds }
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        try Task.checkCancellation()
        let evidence: AskEvidence
        let summary: String
        switch request.mode {
        case .collection:
            evidence = try tools.collection(.init(text: request.text, limit: 5))
            summary = evidence.candidates.isEmpty
                ? "No matching accessible synthetic records. Try a cuisine, neighborhood, name, or note clue."
                : "Possible saved matches. These clues do not establish where you visited."
        case .discovery:
            evidence = try tools.discovery(.init(text: request.text, limit: 5))
            summary = evidence.candidates.isEmpty
                ? "No fixture covers this query. This prototype cannot search the live web."
                : "Fixture announcements, not live search or an exhaustive list. Opening windows are unconfirmed."
        case .importText:
            evidence = try tools.importedText()
            summary = "Review supplied names and exact branches. Text is unverified; links were not fetched."
        }
        let candidates = evidence.candidates
        let allSources = Array(Set(candidates.flatMap(\.sourceIDs))).sorted()
        func paragraph(_ id: String, _ spans: [AskAnswerSpan], _ sources: [String] = []) -> AskAnswerParagraph {
            .init(id: id, spans: spans, sourceIDs: sources)
        }
        if request.previousQuestion != nil, request.mode != .importText {
            let text = request.text.lowercased()
            if text.contains("quiet") || text.contains("noise") || text.contains("calm") {
                return .init(summary: summary, candidates: candidates, paragraphs: [paragraph("answer", [
                    .text(request.mode == .collection
                        ? "I can’t rank quietness from this mock result. The demo doesn’t verify noise levels; review the saved notes before choosing."
                        : "These fictional announcements don’t describe noise levels, so I can’t compare quietness.")
                ], allSources)], listedCandidateIDs: [])
            }
            if request.mode == .collection, text.contains("cocktail"), let clue = cocktailClue(candidates, tools: tools) {
                return .init(summary: summary, candidates: candidates, paragraphs: [paragraph("answer", [
                    .place(clue.0.id), .text(" has a cocktail mention: \(clue.1.author)’s saved note mentions them. That doesn’t verify availability or a visit.")
                ], [clue.1.id])], listedCandidateIDs: [])
            }
            if request.mode == .discovery, text.contains("open") || text.contains("when") {
                let paragraphs = candidates.compactMap { candidate -> AskAnswerParagraph? in
                    guard let opening = candidate.facts.first(where: { $0.kind == .opening }) else { return nil }
                    return paragraph(candidate.id, [.place(candidate.id), .text(" has an announced target of \(opening.value).")], [opening.sourceID])
                }
                if !paragraphs.isEmpty {
                    return .init(summary: summary, candidates: candidates, paragraphs: paragraphs + [paragraph("limit", [.text("Those are fictional announcement windows, not confirmed opening dates.")])], listedCandidateIDs: [])
                }
            }
            return .init(summary: summary, candidates: candidates, paragraphs: [paragraph("answer", [.text(
                candidates.isEmpty ? "I couldn’t find supporting demo evidence for that follow-up."
                : "The available demo sources don’t establish that detail. You can review their original excerpts below; I can’t infer more from them."
            )], allSources)], listedCandidateIDs: [])
        }
        if request.mode == .collection, !candidates.isEmpty {
            var spans: [AskAnswerSpan] = [.text("Possible matches in your saved demo places are ")]
            for (index, candidate) in candidates.enumerated() {
                if index > 0 { spans.append(.text(index == candidates.count - 1 ? " and " : ", ")) }
                spans.append(.place(candidate.id))
            }
            spans.append(.text(". These are recognition clues, not confirmation of where you visited."))
            var paragraphs = [paragraph("matches", spans, allSources)]
            if request.text.localizedCaseInsensitiveContains("cocktail"), let clue = cocktailClue(candidates, tools: tools) {
                paragraphs.append(paragraph("clue", [.text("\(clue.1.author)’s saved note mentions cocktails at "), .place(clue.0.id), .text(". Availability is still unverified.")], [clue.1.id]))
            }
            return .init(summary: summary, candidates: candidates, paragraphs: paragraphs, listedCandidateIDs: [])
        }
        return .init(summary: summary, candidates: candidates,
            paragraphs: [paragraph("answer", [.text(summary)])])
    }
    private func cocktailClue(_ candidates: [AskCandidate], tools: AskReadTools) -> (AskCandidate, AskSource)? {
        for candidate in candidates {
            for id in candidate.sourceIDs {
                if let source = tools.source(id), source.kind == .savedNote, !source.id.hasPrefix("record-"),
                   source.excerpt.localizedCaseInsensitiveContains("cocktail"), !source.excerpt.localizedCaseInsensitiveContains("unsure") {
                    return (candidate, source)
                }
            }
        }
        return nil
    }
}
