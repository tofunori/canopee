import SwiftUI

// MARK: - Diff Review Sidebar

extension LaTeXEditorView {
    var diffSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Diff", systemImage: "arrow.left.arrow.right.square")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if !diffGroups.isEmpty {
                    Text("\(diffGroups.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if !diffGroups.isEmpty {
                HStack(spacing: 6) {
                    Text(isCompactDiffSidebar ? "Global" : "Toutes les modifications")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 6) {
                        diffBatchActionButton(
                            title: "Tout rejeter",
                            systemImage: "xmark",
                            tint: .red,
                            compact: isCompactDiffSidebar,
                            action: rejectAllDiffs
                        )

                        diffBatchActionButton(
                            title: "Tout accepter",
                            systemImage: "checkmark",
                            tint: .green,
                            compact: isCompactDiffSidebar,
                            action: acceptAllDiffs
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            Divider()

            if diffGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("Aucun changement")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Les modifications non sauvegardées du fichier apparaîtront ici.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(diffGroups) { group in
                            diffRow(group)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    func diffBatchActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        compact: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                } else {
                    Label(title, systemImage: systemImage)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 4)
        .background(tint.opacity(0.08))
        .clipShape(Capsule())
        .help(title)
    }

    @ViewBuilder
    func diffRow(_ group: DiffGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(diffLabel(for: group))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(diffAccentColor(for: group))
                Text(diffLineLabel(for: group))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    rejectDiffGroup(group)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Rejeter ce bloc")

                Button {
                    acceptDiffGroup(group)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .help("Accepter ce bloc")

                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                    reviewRow(row)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            revealEditorLocation(for: group)
        }
    }

    @ViewBuilder
    func reviewRow(_ row: ReviewDiffRow) -> some View {
        switch row.kind {
        case .added:
            compactDiffSnippet(
                prefix: "+",
                text: reviewText(from: row.newSpans, accent: .green),
                accent: .green
            )
        case .removed:
            compactDiffSnippet(
                prefix: "-",
                text: reviewText(from: row.oldSpans, accent: .red),
                accent: .red
            )
        case .modified:
            VStack(alignment: .leading, spacing: 6) {
                compactDiffSnippet(
                    prefix: "-",
                    text: reviewText(from: row.oldSpans, accent: .red),
                    accent: .red
                )
                compactDiffSnippet(
                    prefix: "+",
                    text: reviewText(from: row.newSpans, accent: .green),
                    accent: .green
                )
            }
        }
    }

    func compactDiffSnippet(
        prefix: String,
        text: Text,
        accent: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)

            text
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    func reviewText(from spans: [ReviewInlineSpan], accent: Color) -> Text {
        guard !spans.isEmpty else { return Text(" ") }

        return spans.reduce(Text("")) { partial, span in
            partial + reviewSpanText(span, accent: accent)
        }
    }

    func reviewSpanText(_ span: ReviewInlineSpan, accent: Color) -> Text {
        let text = Text(verbatim: span.text.isEmpty ? " " : span.text)
        switch span.kind {
        case .equal:
            return text.foregroundStyle(.secondary)
        case .insert:
            return text.foregroundStyle(.primary).bold()
        case .delete:
            return text
                .foregroundStyle(accent)
                .strikethrough(true, color: accent)
                .underline(true, color: accent)
        }
    }

    func diffLabel(for group: DiffGroup) -> String {
        switch group.kind {
        case .added:
            return "Ajout"
        case .removed:
            return "Suppression"
        case .modified:
            return "Modification"
        }
    }

    func diffLineLabel(for group: DiffGroup) -> String {
        if group.startLine == group.endLine {
            return "Ligne \(group.startLine)"
        }
        return "Lignes \(group.startLine)-\(group.endLine)"
    }

    func diffAccentColor(for group: DiffGroup) -> Color {
        switch group.kind {
        case .added:
            return .green
        case .removed:
            return .red
        case .modified:
            return .orange
        }
    }

    func acceptDiffGroup(_ group: DiffGroup) {
        savedText = DiffEngine.replacingOldBlock(in: savedText, with: group.block)
    }

    func rejectDiffGroup(_ group: DiffGroup) {
        text = DiffEngine.replacingNewBlock(in: text, with: group.block)
        reconcileAnnotations()
    }

    func acceptAllDiffs() {
        savedText = text
        reconcileAnnotations()
    }

    func rejectAllDiffs() {
        text = savedText
        reconcileAnnotations()
    }
}
