import Foundation

/// Fixed public-only evaluation contract. No free text, collection, notes, image or location payload.
enum AskEvaluationContract {
    static let runID = "local-extraction-20261025-v1"
    static let cases: [(id: String, criteria: AskPublicCriteria)] = [
        ("manhattan-cafe-month", .init(category: "cafe", region: "Manhattan", intent: "recent_openings", windowDays: 30, period: "calendar_month")),
        ("philadelphia-bakery-today", .init(category: "bakery", region: "Philadelphia", intent: "recent_openings", windowDays: 1, period: "today")),
        ("london-bakery-upcoming30", .init(category: "bakery", region: "London", intent: "upcoming_openings", windowDays: 30))
    ]
    struct Budget: Codable {
        let `protocol`: Int
        let readOnly: Bool
        let runID: String
        let reservationMicroUSD: Int
        let maximumAttempts: Int
        let maximumReservationMicroUSD: Int
        let totalCapMicroUSD: Int
        let userCapMicroUSD: Int
        let totalReservedMicroUSD: Int
        let userReservedMicroUSD: Int
        let totalRemainingMicroUSD: Int
        let userRemainingMicroUSD: Int
        let attemptedCount: Int
        let availableAttempts: Int
        let halted: Bool
        let cases: [CaseStatus]
        struct CaseStatus: Codable {
            let caseID: String
            let state: String
            var requestID: String? = nil
            var usageRecorded: Bool? = nil
        }
        var verified: Bool {
            guard self.protocol == 1, readOnly, runID == AskEvaluationContract.runID,
                  reservationMicroUSD == 200000, maximumAttempts == 3, maximumReservationMicroUSD == 600000,
                  totalCapMicroUSD == 5000000, userCapMicroUSD == 2500000,
                  (0...5000000).contains(totalReservedMicroUSD), (0...2500000).contains(userReservedMicroUSD), userReservedMicroUSD <= totalReservedMicroUSD,
                  totalRemainingMicroUSD == 5000000 - totalReservedMicroUSD, userRemainingMicroUSD == 2500000 - userReservedMicroUSD,
                  (0...3).contains(attemptedCount), cases.map(\.caseID) == AskEvaluationContract.cases.map(\.id),
                  cases.allSatisfy({ ["not-attempted","reserved","complete","stopped"].contains($0.state) && ($0.state == "not-attempted" ? $0.requestID == nil : $0.requestID.flatMap(UUID.init(uuidString:)) != nil) }),
                  cases.filter({ $0.requestID != nil }).count == attemptedCount else { return false }
            let blocked = halted || cases.contains { $0.state == "reserved" }
            return availableAttempts == (blocked ? 0 : max(0,min(3-attemptedCount,totalRemainingMicroUSD/200000,userRemainingMicroUSD/200000)))
        }
    }
    struct Payload: Encodable {
        let version = 3
        let requestID: String
        let mode = "discovery"
        let criteria: AskPublicCriteria
    }
    struct Reply: Codable {
        let version: Int
        let model: String
        let summary: String
        let paragraphs: [Paragraph]
        let places: [AskWebPlace]
        let usage: Usage
        let budget: Reservation
        let evaluation: Comparison
        struct Paragraph: Codable { let id: String; let text: String; let citations: [AskWebCitation] }
        struct Usage: Codable { let input: Int; let output: Int; let webCalls: Int; let estimatedMicroUSD: Int }
        struct Reservation: Codable { let reservedMicroUSD: Int; let userReservedMicroUSD: Int; let estimatedUsageMicroUSD: Int }
        struct Comparison: Codable {
            let `protocol`: Int
            let runID: String
            let caseID: String
            let candidateKind: String
            let asOf: String
            let baselineCalls: Int
            let candidateAdditionalCalls: Int
            let candidate: Candidate
            var comparison: Counts? = nil
            var timings: [String: Double]? = nil
            let humanSourceReviewRequired: Bool
            let stop: Bool
            struct Candidate: Codable { let status: String; var places: [AskWebPlace]? = nil; var usage: Usage? = nil }
            struct Counts: Codable { let baselineCount: Int; let candidateCount: Int; let matchedCount: Int; let candidateExtraCount: Int; let baselineOnlyCount: Int }
        }
        func verified(caseID: String, before: Budget) -> Bool {
            guard let criteria = AskEvaluationContract.cases.first(where: { $0.id == caseID })?.criteria else { return false }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
            guard let asOf = formatter.date(from: evaluation.asOf), formatter.string(from: asOf) == evaluation.asOf, abs(asOf.timeIntervalSinceNow) <= 172800 else { return false }
            func validPlace(_ place: AskWebPlace) -> Bool {
                guard place.region == criteria.region, !place.name.isEmpty, place.name.count <= 200, place.evidence.count <= 600,
                      AskWebCitation(title: "",url: place.sourceURL).safeURL != nil,
                      let event = formatter.date(from: place.openingDate), formatter.string(from: event) == place.openingDate else { return false }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: asOf), to: calendar.startOfDay(for: event)).day ?? Int.max
                if criteria.intent == "upcoming_openings" { guard place.openingKind == "announced", (0...30).contains(days) else { return false } }
                else {
                    guard place.openingKind == "opened", days <= 0, days >= -criteria.windowDays else { return false }
                    if criteria.period == "today" && days != 0 { return false }
                    if criteria.period == "calendar_month" && !calendar.isDate(event,equalTo: asOf,toGranularity: .month) { return false }
                }
                return true
            }
            guard before.verified, version == 2, model == "gpt-6-luna", summary.count <= 3000,
                  paragraphs.count <= 3, places.count <= 3, evaluation.protocol == 1,
                  evaluation.runID == AskEvaluationContract.runID, evaluation.caseID == caseID,
                  evaluation.candidateKind == "local-extraction", evaluation.baselineCalls == 2, evaluation.candidateAdditionalCalls == 0,
                  evaluation.humanSourceReviewRequired, ["valid","unsupported","rejected"].contains(evaluation.candidate.status),
                  usage.webCalls == 1, (0...200000).contains(usage.estimatedMicroUSD), (0...1114000).contains(usage.input), (0...3000).contains(usage.output),
                  budget.estimatedUsageMicroUSD >= usage.estimatedMicroUSD,
                  budget.reservedMicroUSD >= before.totalReservedMicroUSD + 200000, budget.reservedMicroUSD <= 5000000,
                  budget.userReservedMicroUSD >= before.userReservedMicroUSD + 200000, budget.userReservedMicroUSD <= 2500000,
                  paragraphs.allSatisfy({ $0.text.count <= 1000 && $0.citations.count <= 6 && $0.citations.allSatisfy { $0.safeURL != nil } }),
                  places.allSatisfy({ place in validPlace(place) && paragraphs.flatMap(\.citations).contains { $0.url == place.sourceURL } }) else { return false }
            let candidate = evaluation.candidate.places ?? []
            guard candidate.count <= 3, candidate.allSatisfy(validPlace) else { return false }
            if evaluation.candidate.status != "valid" && !evaluation.stop { return false }
            if evaluation.candidate.status == "valid" {
                guard let cost = evaluation.candidate.usage, cost.webCalls == 1, cost.input >= 0, cost.input <= usage.input, cost.output >= 0, cost.output <= usage.output,
                      cost.estimatedMicroUSD >= 0, cost.estimatedMicroUSD <= usage.estimatedMicroUSD,
                      let timings = evaluation.timings, Set(timings.keys) == ["research","extraction","validation","overall","candidateLocal"] else { return false }
            }
            if let counts = evaluation.comparison {
                func key(_ p: AskWebPlace) -> String { [p.name.lowercased(),p.region,p.openingDate,p.openingKind,p.sourceURL].joined(separator: "|") }
                let a = Set(places.map(key)), b = Set(candidate.map(key))
                guard counts.baselineCount == a.count, counts.candidateCount == b.count, counts.matchedCount == a.intersection(b).count,
                      counts.candidateExtraCount == b.subtracting(a).count, counts.baselineOnlyCount == a.subtracting(b).count else { return false }
            } else if evaluation.candidate.status == "valid" { return false }
            if let timings = evaluation.timings, !timings.allSatisfy({ ["research","extraction","validation","overall","candidateLocal"].contains($0.key) && $0.value.isFinite && (0...240000).contains($0.value) }) { return false }
            return true
        }
    }
}
