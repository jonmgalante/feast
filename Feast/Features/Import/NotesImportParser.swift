import Foundation

struct NotesImportSourceDescriptor: Hashable {
    let title: String
    let detailTitle: String
    let detail: String
}

enum NotesImportLineMarker: Hashable {
    case plain
    case bullet(symbol: String)
    case checklist(isChecked: Bool)
    case heading(level: Int)
}

struct NotesImportSourceLine: Identifiable, Hashable {
    let id: Int
    let lineNumber: Int
    let rawText: String
    let indentation: Int
    let marker: NotesImportLineMarker
    let content: String
    let standaloneURL: URL?

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool {
        trimmedContent.isEmpty
    }
}

struct NotesImportCandidatePlace: Identifiable, Hashable {
    let id: UUID
    let sourceLineNumber: Int
    let displayNameSnapshot: String
    let status: PlaceStatus
    let placeType: PlaceType?
    let cuisines: [String]
    let tags: [String]
    let note: String?
    let websiteURL: String?
    let instagramURL: String?
}

struct NotesImportCandidateNeighborhood: Identifiable, Hashable {
    let id: UUID
    let sourceLineNumber: Int
    let name: String
    let places: [NotesImportCandidatePlace]
}

struct NotesImportReviewState: Identifiable, Hashable {
    let id = UUID()
    let cityName: String
    let source: NotesImportSourceDescriptor
    let lines: [NotesImportSourceLine]
    let neighborhoods: [NotesImportCandidateNeighborhood]
    let unassignedPlaces: [NotesImportCandidatePlace]

    var placeCount: Int {
        neighborhoods.reduce(0) { $0 + $1.places.count } + unassignedPlaces.count
    }

    var parsedNeighborhoodCount: Int {
        neighborhoods.count
    }

    var nonEmptyLineCount: Int {
        lines.filter { !$0.isBlank }.count
    }
}

enum NotesImportParser {
    static func parse(
        text: String,
        cityName: String,
        source: NotesImportSourceDescriptor
    ) -> NotesImportReviewState {
        let lines = normalizedLines(from: text)

        var neighborhoods: [NeighborhoodBuilder] = []
        var unassignedPlaces: [PlaceBuilder] = []
        var currentNeighborhoodIndex: Int?
        var currentContext = CategoryContext.empty
        var lastPlaceLocation: PlaceLocation?

        for index in lines.indices {
            let line = lines[index]
            guard !line.isBlank else {
                continue
            }

            let previousNonEmptyLine = previousNonEmptyLine(before: index, in: lines)
            let nextNonEmptyLine = nextNonEmptyLine(after: index, in: lines)

            if let heading = headingClassification(
                for: line,
                cityName: cityName,
                previousNonEmptyLine: previousNonEmptyLine,
                nextNonEmptyLine: nextNonEmptyLine
            ) {
                switch heading {
                case let .neighborhood(name):
                    neighborhoods.append(
                        NeighborhoodBuilder(
                            sourceLineNumber: line.lineNumber,
                            name: name,
                            places: []
                        )
                    )
                    currentNeighborhoodIndex = neighborhoods.indices.last
                    currentContext = .empty
                    lastPlaceLocation = nil

                case let .category(context):
                    currentContext = context
                }

                continue
            }

            if let standaloneURL = line.standaloneURL {
                guard let lastPlaceLocation else {
                    continue
                }

                appendURL(
                    standaloneURL,
                    to: lastPlaceLocation,
                    neighborhoods: &neighborhoods,
                    unassignedPlaces: &unassignedPlaces
                )
                continue
            }

            switch line.marker {
            case let .checklist(isChecked):
                guard let builder = makePlaceBuilder(
                    from: line,
                    status: isChecked ? .been : .wantToTry,
                    context: currentContext
                ) else {
                    continue
                }

                lastPlaceLocation = appendPlace(
                    builder,
                    to: currentNeighborhoodIndex,
                    neighborhoods: &neighborhoods,
                    unassignedPlaces: &unassignedPlaces
                )

            case .bullet:
                if let lastPlaceLocation,
                   shouldAttachBulletAsNote(
                    line,
                    to: lastPlaceLocation,
                    neighborhoods: neighborhoods,
                    unassignedPlaces: unassignedPlaces
                   ) {
                    appendNote(
                        line.trimmedContent,
                        to: lastPlaceLocation,
                        neighborhoods: &neighborhoods,
                        unassignedPlaces: &unassignedPlaces
                    )
                    continue
                }

                guard let builder = makePlaceBuilder(
                    from: line,
                    status: .wantToTry,
                    context: currentContext
                ) else {
                    continue
                }

                lastPlaceLocation = appendPlace(
                    builder,
                    to: currentNeighborhoodIndex,
                    neighborhoods: &neighborhoods,
                    unassignedPlaces: &unassignedPlaces
                )

            case .plain, .heading:
                guard let lastPlaceLocation else {
                    continue
                }

                appendNote(
                    line.trimmedContent,
                    to: lastPlaceLocation,
                    neighborhoods: &neighborhoods,
                    unassignedPlaces: &unassignedPlaces
                )
            }
        }

        return NotesImportReviewState(
            cityName: cityName,
            source: source,
            lines: lines,
            neighborhoods: neighborhoods.map(\.reviewValue),
            unassignedPlaces: unassignedPlaces.map(\.reviewValue)
        )
    }
}

extension NotesImportReviewState {
    static var previewSample: NotesImportReviewState {
        NotesImportParser.parse(
            text: """
            ## West Village
            Coffee
            - [ ] Third Rail Coffee: early espresso stop
              Strong cappuccino and a little room in back.
              https://instagram.com/thirdrailcoffee
            - [x] I Sodi — Italian date night, great pasta

            ## Soho
            Cocktails
            - [ ] Bar Pisellino
            - [ ] Thai Diner: brunch is worth the wait
            https://www.thaidiner.com
            """,
            cityName: "New York",
            source: NotesImportSourceDescriptor(
                title: "Pasted Note",
                detailTitle: "Contents",
                detail: "Preview"
            )
        )
    }
}

private enum HeadingClassification {
    case neighborhood(String)
    case category(CategoryContext)
}

private struct CategoryContext {
    var placeType: PlaceType?
    var cuisines: [String]
    var tags: [String]

    static let empty = CategoryContext(
        placeType: nil,
        cuisines: [],
        tags: []
    )

    var isEmpty: Bool {
        placeType == nil && cuisines.isEmpty && tags.isEmpty
    }
}

private struct Inference {
    var placeType: PlaceType?
    var cuisines: [String]
    var tags: [String]

    static let empty = Inference(placeType: nil, cuisines: [], tags: [])
}

private struct PlaceLocation {
    let neighborhoodIndex: Int?
    let placeIndex: Int
}

private struct NeighborhoodBuilder {
    let id = UUID()
    let sourceLineNumber: Int
    let name: String
    var places: [PlaceBuilder]

    var reviewValue: NotesImportCandidateNeighborhood {
        NotesImportCandidateNeighborhood(
            id: id,
            sourceLineNumber: sourceLineNumber,
            name: name,
            places: places.map(\.reviewValue)
        )
    }
}

private struct PlaceBuilder {
    let id = UUID()
    let sourceLineNumber: Int
    let sourceIndentation: Int
    var displayNameSnapshot: String
    var status: PlaceStatus
    var placeType: PlaceType?
    var cuisines: [String]
    var tags: [String]
    var noteFragments: [String]
    var websiteURL: String?
    var instagramURL: String?

    var reviewValue: NotesImportCandidatePlace {
        NotesImportCandidatePlace(
            id: id,
            sourceLineNumber: sourceLineNumber,
            displayNameSnapshot: displayNameSnapshot,
            status: status,
            placeType: placeType,
            cuisines: cuisines,
            tags: tags,
            note: joinedNote,
            websiteURL: websiteURL,
            instagramURL: instagramURL
        )
    }

    private var joinedNote: String? {
        let normalized = noteFragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty else {
            return nil
        }

        return normalized.joined(separator: "\n")
    }
}

private extension NotesImportParser {
    static func normalizedLines(from text: String) -> [NotesImportSourceLine] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawLines = normalizedText.components(separatedBy: "\n")

        return rawLines.enumerated().map { index, rawLine in
            let indentation = indentationWidth(for: rawLine)
            let contentStartIndex = rawLine.index(rawLine.startIndex, offsetBy: min(indentationCharacterCount(in: rawLine), rawLine.count))
            let withoutIndentation = String(rawLine[contentStartIndex...])
            let parsed = parsedMarkerLine(from: withoutIndentation)

            return NotesImportSourceLine(
                id: index,
                lineNumber: index + 1,
                rawText: rawLine,
                indentation: indentation,
                marker: parsed.marker,
                content: cleanLineContent(parsed.content),
                standaloneURL: standaloneURL(from: parsed.content)
            )
        }
    }

    static func indentationCharacterCount(in rawLine: String) -> Int {
        var count = 0

        for character in rawLine {
            if character == " " || character == "\t" {
                count += 1
            } else {
                break
            }
        }

        return count
    }

    static func indentationWidth(for rawLine: String) -> Int {
        rawLine.prefix(while: { $0 == " " || $0 == "\t" }).reduce(into: 0) { total, character in
            total += character == "\t" ? 4 : 1
        }
    }

    static func parsedMarkerLine(from rawLine: String) -> (marker: NotesImportLineMarker, content: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        guard !line.isEmpty else {
            return (.plain, "")
        }

        if let match = NotesImportRegex.heading.firstMatch(in: line),
           let markerRange = Range(match.range(at: 1), in: line),
           let contentRange = Range(match.range(at: 2), in: line) {
            return (.heading(level: line[markerRange].count), String(line[contentRange]))
        }

        if let match = NotesImportRegex.checklist.firstMatch(in: line),
           let checkedRange = Range(match.range(at: 1), in: line),
           let contentRange = Range(match.range(at: 2), in: line) {
            let checkedValue = line[checkedRange].lowercased()
            return (.checklist(isChecked: checkedValue == "x"), String(line[contentRange]))
        }

        if let match = NotesImportRegex.bullet.firstMatch(in: line),
           let markerRange = Range(match.range(at: 1), in: line),
           let contentRange = Range(match.range(at: 2), in: line) {
            return (.bullet(symbol: String(line[markerRange])), String(line[contentRange]))
        }

        if let match = NotesImportRegex.orderedBullet.firstMatch(in: line),
           let markerRange = Range(match.range(at: 1), in: line),
           let contentRange = Range(match.range(at: 2), in: line) {
            return (.bullet(symbol: String(line[markerRange])), String(line[contentRange]))
        }

        return (.plain, line)
    }

    static func cleanLineContent(_ value: String) -> String {
        var cleaned = trimmed(value)

        let wrappers = ["**", "__", "*", "_", "`"]
        for wrapper in wrappers {
            while cleaned.hasPrefix(wrapper), cleaned.hasSuffix(wrapper), cleaned.count > wrapper.count * 2 {
                cleaned.removeFirst(wrapper.count)
                cleaned.removeLast(wrapper.count)
                cleaned = trimmed(cleaned)
            }
        }

        return cleaned
    }

    static func standaloneURL(from rawContent: String) -> URL? {
        let cleaned = trimmed(rawContent)
        guard
            !cleaned.isEmpty,
            let url = URL(string: cleaned),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            return nil
        }

        return url
    }

    static func headingClassification(
        for line: NotesImportSourceLine,
        cityName: String,
        previousNonEmptyLine: NotesImportSourceLine?,
        nextNonEmptyLine: NotesImportSourceLine?
    ) -> HeadingClassification? {
        switch line.marker {
        case .plain, .heading:
            break
        case .bullet, .checklist:
            return nil
        }

        let headingText = cleanHeadingName(line.trimmedContent)

        guard !headingText.isEmpty else {
            return nil
        }

        if let categoryContext = categoryContext(forHeading: headingText) {
            return .category(categoryContext)
        }

        guard shouldTreatAsHeading(
            line,
            headingText: headingText,
            cityName: cityName,
            previousNonEmptyLine: previousNonEmptyLine,
            nextNonEmptyLine: nextNonEmptyLine
        ) else {
            return nil
        }

        return .neighborhood(headingText)
    }

    static func shouldTreatAsHeading(
        _ line: NotesImportSourceLine,
        headingText: String,
        cityName: String,
        previousNonEmptyLine: NotesImportSourceLine?,
        nextNonEmptyLine: NotesImportSourceLine?
    ) -> Bool {
        guard
            !isIgnoredHeading(headingText),
            !matchesSelectedCity(headingText, cityName: cityName),
            headingWordCount(for: headingText) <= 5,
            headingText.count <= 40,
            headingText.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!:")) == nil,
            !headingText.contains(" - "),
            !headingText.contains(" — "),
            !headingText.contains(" – ")
        else {
            return false
        }

        switch line.marker {
        case .heading:
            return true

        case .plain:
            guard line.indentation == 0 else {
                return false
            }

            guard let nextNonEmptyLine else {
                return false
            }

            let startsSection: Bool
            switch nextNonEmptyLine.marker {
            case .checklist, .bullet, .heading:
                startsSection = true
            case .plain:
                startsSection = nextNonEmptyLine.indentation > line.indentation
            }

            guard startsSection else {
                return false
            }

            let hasBlankSpaceAroundHeading: Bool
            if let previousNonEmptyLine {
                hasBlankSpaceAroundHeading = line.lineNumber - previousNonEmptyLine.lineNumber > 1
            } else {
                hasBlankSpaceAroundHeading = true
            }

            if hasBlankSpaceAroundHeading {
                return true
            }

            guard looksLikeNeighborhoodHeadingText(headingText) else {
                return false
            }

            guard let previousNonEmptyLine else {
                return false
            }

            switch previousNonEmptyLine.marker {
            case .checklist, .bullet, .heading:
                return true
            case .plain:
                if previousNonEmptyLine.standaloneURL != nil {
                    return true
                }

                return previousNonEmptyLine.indentation > line.indentation
            }

        case .bullet, .checklist:
            return false
        }
    }

    static func cleanHeadingName(_ value: String) -> String {
        cleanLineContent(value)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isIgnoredHeading(_ value: String) -> Bool {
        guard let key = FeastTag.normalizedKey(for: value) else {
            return false
        }

        return ignoredHeadingKeys.contains(key)
    }

    static func matchesSelectedCity(_ headingText: String, cityName: String) -> Bool {
        FeastTag.normalizedKey(for: headingText) == FeastTag.normalizedKey(for: cityName)
    }

    static func headingWordCount(for value: String) -> Int {
        value.split(whereSeparator: \.isWhitespace).count
    }

    static func looksLikeNeighborhoodHeadingText(_ value: String) -> Bool {
        let words = value.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else {
            return false
        }

        var sawLetter = false

        for word in words {
            let token = String(word)
            let letters = token.unicodeScalars.filter(CharacterSet.letters.contains)

            if letters.isEmpty {
                continue
            }

            sawLetter = true

            if token == token.uppercased(with: .current) {
                continue
            }

            if let firstCharacter = token.first, firstCharacter.isUppercase {
                continue
            }

            if token.contains(where: \.isUppercase) {
                continue
            }

            return false
        }

        return sawLetter
    }

    static func categoryContext(forHeading headingText: String) -> CategoryContext? {
        let inference = inference(for: headingText)
        guard !inference.cuisines.isEmpty || !inference.tags.isEmpty || inference.placeType != nil else {
            return nil
        }

        return CategoryContext(
            placeType: inference.placeType,
            cuisines: inference.cuisines,
            tags: inference.tags
        )
    }

    static func makePlaceBuilder(
        from line: NotesImportSourceLine,
        status: PlaceStatus,
        context: CategoryContext
    ) -> PlaceBuilder? {
        let split = splitPlaceLine(line.trimmedContent)
        guard !split.name.isEmpty else {
            return nil
        }

        let baseInference = inference(
            for: [split.name, split.inlineNote]
                .compactMap { $0 }
                .joined(separator: " ")
        )

        var builder = PlaceBuilder(
            sourceLineNumber: line.lineNumber,
            sourceIndentation: line.indentation,
            displayNameSnapshot: split.name,
            status: status,
            placeType: baseInference.placeType ?? context.placeType,
            cuisines: mergedDisplayValues(context.cuisines, baseInference.cuisines),
            tags: FeastTag.normalizedTags(context.tags + baseInference.tags),
            noteFragments: [],
            websiteURL: nil,
            instagramURL: nil
        )

        if let inlineNote = split.inlineNote {
            appendNote(inlineNote, to: &builder)
        }

        return builder
    }

    static func splitPlaceLine(_ rawValue: String) -> (name: String, inlineNote: String?) {
        let cleaned = cleanLineContent(rawValue)
        guard !cleaned.isEmpty else {
            return ("", nil)
        }

        let separators = [":", " — ", " – ", " - "]
        let firstSeparator = separators
            .compactMap { separator -> (separator: String, range: Range<String.Index>)? in
                guard let range = cleaned.range(of: separator) else {
                    return nil
                }

                return (separator, range)
            }
            .sorted { lhs, rhs in
                lhs.range.lowerBound < rhs.range.lowerBound
            }
            .first

        guard let firstSeparator else {
            return (cleaned, nil)
        }

        let name = trimmed(String(cleaned[..<firstSeparator.range.lowerBound]))
        let noteStartIndex = firstSeparator.range.upperBound
        let note = trimmed(String(cleaned[noteStartIndex...]))

        return (
            name,
            note.isEmpty ? nil : note
        )
    }

    static func appendPlace(
        _ builder: PlaceBuilder,
        to neighborhoodIndex: Int?,
        neighborhoods: inout [NeighborhoodBuilder],
        unassignedPlaces: inout [PlaceBuilder]
    ) -> PlaceLocation {
        if let neighborhoodIndex {
            neighborhoods[neighborhoodIndex].places.append(builder)
            return PlaceLocation(
                neighborhoodIndex: neighborhoodIndex,
                placeIndex: neighborhoods[neighborhoodIndex].places.count - 1
            )
        }

        unassignedPlaces.append(builder)
        return PlaceLocation(
            neighborhoodIndex: nil,
            placeIndex: unassignedPlaces.count - 1
        )
    }

    static func appendNote(
        _ note: String,
        to location: PlaceLocation,
        neighborhoods: inout [NeighborhoodBuilder],
        unassignedPlaces: inout [PlaceBuilder]
    ) {
        if let neighborhoodIndex = location.neighborhoodIndex {
            appendNote(note, to: &neighborhoods[neighborhoodIndex].places[location.placeIndex])
            return
        }

        appendNote(note, to: &unassignedPlaces[location.placeIndex])
    }

    static func appendNote(_ note: String, to builder: inout PlaceBuilder) {
        let trimmedNote = noteAfterExtractingFieldURLs(from: note, into: &builder)
        guard !trimmedNote.isEmpty else {
            return
        }

        appendProcessedNote(trimmedNote, to: &builder)
    }

    static func appendProcessedNote(_ note: String, to builder: inout PlaceBuilder) {
        let trimmedNote = trimmed(note)
        guard !trimmedNote.isEmpty else {
            return
        }

        builder.noteFragments.append(trimmedNote)

        let noteInference = inference(for: trimmedNote)
        if builder.placeType == nil {
            builder.placeType = noteInference.placeType
        }
        builder.cuisines = mergedDisplayValues(builder.cuisines, noteInference.cuisines)
        builder.tags = FeastTag.normalizedTags(builder.tags + noteInference.tags)
    }

    static func appendURL(
        _ url: URL,
        to location: PlaceLocation,
        neighborhoods: inout [NeighborhoodBuilder],
        unassignedPlaces: inout [PlaceBuilder]
    ) {
        if let neighborhoodIndex = location.neighborhoodIndex {
            appendURL(url, to: &neighborhoods[neighborhoodIndex].places[location.placeIndex])
            return
        }

        appendURL(url, to: &unassignedPlaces[location.placeIndex])
    }

    static func appendURL(_ url: URL, to builder: inout PlaceBuilder) {
        if assignedClassifiedURL(url, to: &builder) {
            return
        }

        appendProcessedNote(url.absoluteString, to: &builder)
    }

    static func shouldAttachBulletAsNote(
        _ line: NotesImportSourceLine,
        to location: PlaceLocation,
        neighborhoods: [NeighborhoodBuilder],
        unassignedPlaces: [PlaceBuilder]
    ) -> Bool {
        let place = place(at: location, neighborhoods: neighborhoods, unassignedPlaces: unassignedPlaces)

        if line.indentation > place.sourceIndentation {
            return true
        }

        return looksLikeNoteFragment(line.trimmedContent)
    }

    static func place(
        at location: PlaceLocation,
        neighborhoods: [NeighborhoodBuilder],
        unassignedPlaces: [PlaceBuilder]
    ) -> PlaceBuilder {
        if let neighborhoodIndex = location.neighborhoodIndex {
            return neighborhoods[neighborhoodIndex].places[location.placeIndex]
        }

        return unassignedPlaces[location.placeIndex]
    }

    static func looksLikeNoteFragment(_ value: String) -> Bool {
        guard let firstCharacter = value.first else {
            return false
        }

        if firstCharacter.isLowercase {
            return true
        }

        if value.count >= 40 {
            return true
        }

        if value.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,;()")) != nil {
            return true
        }

        let wordCount = value.split(whereSeparator: \.isWhitespace).count
        return wordCount >= 5
    }

    static func inference(for rawValue: String) -> Inference {
        let searchable = searchableText(from: rawValue)
        guard !searchable.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .empty
        }

        let placeType = inferredPlaceType(from: searchable)
        let cuisines = cuisineRules.compactMap { rule in
            matchesAny(searchable, phrases: rule.keywords) ? rule.display : nil
        }
        let tags = tagRules.compactMap { rule in
            matchesAny(searchable, phrases: rule.keywords) ? rule.display : nil
        }

        return Inference(
            placeType: placeType,
            cuisines: mergedDisplayValues([], cuisines),
            tags: FeastTag.normalizedTags(tags)
        )
    }

    static func searchableText(from rawValue: String) -> String {
        let folded = rawValue.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            return " "
        }

        let normalized = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return " \(normalized.lowercased()) "
    }

    static func inferredPlaceType(from searchableText: String) -> PlaceType? {
        for rule in placeTypeRules where matchesAny(searchableText, phrases: rule.keywords) {
            return rule.placeType
        }

        return nil
    }

    static func matchesAny(_ normalizedSource: String, phrases: [String]) -> Bool {
        phrases.contains { phrase in
            let normalizedPhrase = searchableText(from: phrase)
            return normalizedSource.contains(normalizedPhrase)
        }
    }

    static func mergedDisplayValues(_ existing: [String], _ incoming: [String]) -> [String] {
        var orderedValues: [String] = []
        var seenKeys: Set<String> = []

        for value in existing + incoming {
            let trimmedValue = trimmed(value)
            guard
                !trimmedValue.isEmpty,
                let key = FeastTag.normalizedKey(for: trimmedValue),
                !seenKeys.contains(key)
            else {
                continue
            }

            seenKeys.insert(key)
            orderedValues.append(trimmedValue)
        }

        return orderedValues
    }

    static func noteAfterExtractingFieldURLs(from rawNote: String, into builder: inout PlaceBuilder) -> String {
        let trimmedNote = trimmed(rawNote)
        guard !trimmedNote.isEmpty else {
            return ""
        }

        let matches = urlDetector.matches(
            in: trimmedNote,
            options: [],
            range: NSRange(location: 0, length: (trimmedNote as NSString).length)
        )
        guard !matches.isEmpty else {
            return trimmedNote
        }

        let mutableNote = NSMutableString(string: trimmedNote)

        for match in matches.reversed() {
            guard
                let url = match.url,
                assignedClassifiedURL(url, to: &builder)
            else {
                continue
            }

            mutableNote.replaceCharacters(in: match.range, with: "")
        }

        let cleanedNote = cleanedNoteAfterRemovingFieldURLs(String(mutableNote))
        return shouldDropResidualLinkLabel(cleanedNote) ? "" : cleanedNote
    }

    static func cleanedNoteAfterRemovingFieldURLs(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(
                of: #"\[([^\]]+)\]\(\s*\)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(of: "<>", with: "")
            .replacingOccurrences(
                of: #"[\t ]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+([,.;:!?])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([(\[])\s+"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+([)\]])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b(?:website|web ?site|site|link|url|instagram|insta|ig)\b\s*[:\-–—]?\s*$"#,
                with: "",
                options: .regularExpression
            )

        return trimmed(cleaned)
    }

    static func shouldDropResidualLinkLabel(_ value: String) -> Bool {
        let searchable = searchableText(from: value)
        return searchable == " website "
            || searchable == " web site "
            || searchable == " site "
            || searchable == " link "
            || searchable == " url "
            || searchable == " instagram "
            || searchable == " insta "
            || searchable == " ig "
    }

    static func assignedClassifiedURL(_ url: URL, to builder: inout PlaceBuilder) -> Bool {
        let classification = classifiedPlaceURL(from: url)

        if let instagramURL = classification.instagramURL, builder.instagramURL == nil {
            builder.instagramURL = instagramURL
            return true
        }

        if let websiteURL = classification.websiteURL, builder.websiteURL == nil {
            builder.websiteURL = websiteURL
            return true
        }

        return false
    }

    static func classifiedPlaceURL(from url: URL) -> ClassifiedImportedURL {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = normalizedHost(for: url)
        else {
            return ClassifiedImportedURL(websiteURL: nil, instagramURL: nil)
        }

        let absoluteString = url.absoluteString
        if isInstagramHost(host) {
            return ClassifiedImportedURL(websiteURL: nil, instagramURL: absoluteString)
        }

        return ClassifiedImportedURL(websiteURL: absoluteString, instagramURL: nil)
    }

    static func normalizedHost(for url: URL) -> String? {
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else {
            return nil
        }

        return host.lowercased()
    }

    static func isInstagramHost(_ host: String) -> Bool {
        host == "instagram.com"
            || host.hasSuffix(".instagram.com")
            || host == "instagr.am"
            || host.hasSuffix(".instagr.am")
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func previousNonEmptyLine(before index: Int, in lines: [NotesImportSourceLine]) -> NotesImportSourceLine? {
        guard index > 0 else {
            return nil
        }

        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let line = lines[candidateIndex]
            if !line.isBlank {
                return line
            }
        }

        return nil
    }

    static func nextNonEmptyLine(after index: Int, in lines: [NotesImportSourceLine]) -> NotesImportSourceLine? {
        guard index + 1 < lines.count else {
            return nil
        }

        for candidateIndex in (index + 1)..<lines.count {
            let line = lines[candidateIndex]
            if !line.isBlank {
                return line
            }
        }

        return nil
    }

    static let ignoredHeadingKeys: Set<String> = [
        "notes",
        "places",
        "restaurants",
        "favorite places",
        "favourite places",
        "favorites",
        "favourites",
        "want to try",
        "been",
        "regulars",
        "love"
    ]

    static let cuisineRules: [(display: String, keywords: [String])] = [
        ("American", ["american", "new american"]),
        ("Bakery", ["bread", "bakeries"]),
        ("British", ["british"]),
        ("Caribbean", ["caribbean"]),
        ("Chinese", ["chinese", "dim sum"]),
        ("Ethiopian", ["ethiopian"]),
        ("French", ["french"]),
        ("Greek", ["greek"]),
        ("Indian", ["indian"]),
        ("Italian", ["italian", "pasta"]),
        ("Japanese", ["japanese", "omakase"]),
        ("Korean", ["korean"]),
        ("Lebanese", ["lebanese"]),
        ("Mediterranean", ["mediterranean"]),
        ("Mexican", ["mexican", "taco"]),
        ("Middle Eastern", ["middle eastern"]),
        ("Persian", ["persian"]),
        ("Pizza", ["pizza", "pizzeria"]),
        ("Seafood", ["seafood", "oyster"]),
        ("Spanish", ["spanish", "tapas"]),
        ("Sushi", ["sushi"]),
        ("Thai", ["thai"]),
        ("Turkish", ["turkish"]),
        ("Vietnamese", ["vietnamese", "pho"])
    ]

    static let tagRules: [(display: String, keywords: [String])] = [
        ("Bakery", ["bakery", "bakeries", "pastry"]),
        ("Breakfast", ["breakfast"]),
        ("Brunch", ["brunch"]),
        ("Cocktails", ["cocktail", "cocktails", "martini"]),
        ("Coffee", ["coffee", "espresso", "cafe"]),
        ("Date Night", ["date night"]),
        ("Dessert", ["dessert", "gelato", "ice cream"]),
        ("Dinner", ["dinner"]),
        ("Family", ["family", "kids", "kid friendly", "family style"]),
        ("Groups", ["groups", "group dinner", "large group", "big group"]),
        ("Lunch", ["lunch"])
    ]

    static let placeTypeRules: [(placeType: PlaceType, keywords: [String])] = [
        (.bakery, ["bakery", "bakeries"]),
        (.bar, ["bar", "bars", "cocktail", "cocktails", "wine bar"]),
        (.cafe, ["coffee", "espresso", "cafe", "cafes"]),
        (.dessert, ["dessert", "gelato", "ice cream"]),
        (.market, ["market", "grocery"])
    ]

    static let urlDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

private enum NotesImportRegex {
    static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.+)$"#)
    static let checklist = try! NSRegularExpression(pattern: #"^(?:[-*+]\s*)?\[( |x|X)\]\s+(.+)$"#)
    static let bullet = try! NSRegularExpression(pattern: #"^([-*+•])\s+(.+)$"#)
    static let orderedBullet = try! NSRegularExpression(pattern: #"^(\d+\.)\s+(.+)$"#)
}

private extension NSRegularExpression {
    func firstMatch(in string: String) -> NSTextCheckingResult? {
        firstMatch(in: string, options: [], range: NSRange(location: 0, length: string.utf16.count))
    }
}

private struct ClassifiedImportedURL {
    let websiteURL: String?
    let instagramURL: String?
}
