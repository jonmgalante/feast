import SwiftUI

struct FeastTagInputView: View {
    @Binding var tags: [String]

    let existingTags: [String]
    var placeholder = "Add a tag"

    @State private var draftTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.small) {
                if !tags.isEmpty {
                    FeastChipFlowLayout(
                        itemSpacing: FeastTheme.Spacing.small,
                        rowSpacing: FeastTheme.Spacing.small
                    ) {
                        ForEach(tags, id: \.self) { tag in
                            FeastSelectedTagChip(tag: tag) {
                                removeTag(tag)
                            }
                        }
                    }
                }

                HStack(spacing: FeastTheme.Spacing.small) {
                    Image(systemName: "tag")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FeastTheme.Colors.tertiaryText)

                    TextField(placeholder, text: $draftTag)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit {
                            commitDraftTag()
                        }

                    if canCommitDraftTag {
                        Button {
                            commitDraftTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(FeastTheme.Colors.accentSelection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add Tag")
                    }
                }
                .frame(minHeight: 32)
            }
            .feastFieldSurface(minHeight: 52)

            if !suggestedTags.isEmpty {
                FeastChipFlowLayout(
                    itemSpacing: FeastTheme.Spacing.small,
                    rowSpacing: FeastTheme.Spacing.small
                ) {
                    ForEach(suggestedTags, id: \.self) { tag in
                        Button {
                            addTag(tag)
                        } label: {
                            Text(tag)
                        }
                        .buttonStyle(FeastQuietChipButtonStyle())
                        .accessibilityLabel("Add existing tag \(tag)")
                    }
                }
            }
        }
        .onChange(of: draftTag) { _, newValue in
            consumeDraftSeparators(newValue)
        }
    }

    private var canCommitDraftTag: Bool {
        FeastTag.normalizedDisplay(draftTag) != nil
    }

    private var suggestedTags: [String] {
        FeastTag.suggestions(
            matching: draftTag,
            existingTags: existingTags,
            selectedTags: tags
        )
    }

    private func addTag(_ rawValue: String) {
        tags = FeastTag.normalizedTags(tags + [rawValue])
        draftTag = ""
    }

    private func removeTag(_ tag: String) {
        guard let targetKey = FeastTag.normalizedKey(for: tag) else {
            return
        }

        tags.removeAll { existingTag in
            FeastTag.normalizedKey(for: existingTag) == targetKey
        }
    }

    private func commitDraftTag() {
        guard let normalizedDraft = FeastTag.normalizedDisplay(draftTag) else {
            draftTag = ""
            return
        }

        addTag(normalizedDraft)
    }

    private func consumeDraftSeparators(_ rawValue: String) {
        guard rawValue.contains(",") else {
            return
        }

        let components = rawValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1 else {
            return
        }

        tags = FeastTag.normalizedTags(tags + Array(components.dropLast()))
        draftTag = FeastTag.collapsed(components.last ?? "") ?? ""
    }
}

private struct FeastSelectedTagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        Button {
            onRemove()
        } label: {
            HStack(spacing: 6) {
                Text(tag)

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(FeastTheme.Typography.rowUtility)
            .foregroundStyle(FeastTheme.Colors.primaryText)
            .padding(.horizontal, FeastTheme.Spacing.medium)
            .padding(.vertical, 9)
            .background {
                Capsule(style: .continuous)
                    .fill(FeastTheme.Colors.accentSelection.opacity(0.16))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(FeastTheme.Colors.accentSelection.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove tag \(tag)")
    }
}

private struct FeastChipFlowLayout: Layout {
    var itemSpacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = makeRows(
            maxWidth: proposal.width ?? .greatestFiniteMagnitude,
            subviews: subviews
        )

        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { partialResult, row in
            partialResult + row.height
        } + rowSpacing * CGFloat(max(rows.count - 1, 0))

        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX

            for element in row.elements {
                let origin = CGPoint(
                    x: x,
                    y: y + (row.height - element.size.height) / 2
                )

                subviews[element.index].place(
                    at: origin,
                    proposal: ProposedViewSize(element.size)
                )

                x += element.size.width + itemSpacing
            }

            y += row.height + rowSpacing
        }
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [FeastChipFlowRow] {
        guard !subviews.isEmpty else {
            return []
        }

        let effectiveMaxWidth = maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude

        var rows: [FeastChipFlowRow] = []
        var currentRow = FeastChipFlowRow()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = currentRow.elements.isEmpty
                ? size.width
                : currentRow.width + itemSpacing + size.width

            if proposedWidth > effectiveMaxWidth, !currentRow.elements.isEmpty {
                rows.append(currentRow)
                currentRow = FeastChipFlowRow()
            }

            currentRow.append(index: index, size: size, itemSpacing: itemSpacing)
        }

        if !currentRow.elements.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }
}

private struct FeastChipFlowRow {
    struct Element {
        let index: Int
        let size: CGSize
    }

    var elements: [Element] = []
    var width: CGFloat = 0
    var height: CGFloat = 0

    mutating func append(index: Int, size: CGSize, itemSpacing: CGFloat) {
        let spacing = elements.isEmpty ? CGFloat.zero : itemSpacing
        elements.append(Element(index: index, size: size))
        width += spacing + size.width
        height = max(height, size.height)
    }
}
