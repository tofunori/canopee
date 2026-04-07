import SwiftUI

struct PaperRowView: View {
    let paper: Paper
    var isSelected = false
    var isHovered = false

    private var rowBackground: Color {
        if isSelected {
            return AppChromePalette.selectedAccentFill.opacity(0.78)
        }
        if isHovered {
            return AppChromePalette.hoverFill.opacity(0.6)
        }
        return .clear
    }

    private var iconTint: Color {
        if let key = paper.labelColor,
           let label = Paper.labelColors.first(where: { $0.key == key }) {
            return Color(nsColor: label.color)
        }
        if paper.isFlagged {
            return AppChromePalette.danger
        }
        if !paper.isRead {
            return AppChromePalette.info
        }
        return .secondary.opacity(0.7)
    }

    private var notesPreview: String {
        let trimmed = paper.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "" : trimmed
    }

    private var rowBorder: Color {
        if isSelected {
            return AppChromePalette.selectedAccentStroke.opacity(0.9)
        }
        return AppChromePalette.dividerSoft
    }

    var body: some View {
        HStack(spacing: 0) {
            PapersColumn(width: 34, alignment: .center) {
                HStack(spacing: 3) {
                    Image(systemName: paper.labelIconName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(iconTint)

                    if !paper.isRead {
                        Circle()
                            .fill(AppChromePalette.info)
                            .frame(width: 5, height: 5)
                    }

                    if paper.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.yellow)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            PapersColumn(width: 140) {
                rowText(paper.authorsShort)
            }

            PapersColumn(width: 110) {
                rowText(paper.lastAuthor, secondary: true)
            }

            PapersColumn(minWidth: 230) {
                rowText(paper.title, weight: .medium)
            }

            PapersColumn(width: 180) {
                rowText(paper.journal ?? "", secondary: true)
            }

            PapersColumn(width: 58, alignment: .trailing) {
                rowText(paper.year.map(String.init) ?? "", monospaced: true, alignment: .trailing)
            }

            PapersColumn(width: 136) {
                if notesPreview.isEmpty {
                    rowText("", secondary: true)
                } else {
                    rowText(notesPreview, secondary: true)
                }
            }

            PapersColumn(width: 92, alignment: .trailing) {
                HStack(spacing: 1) {
                    RatingView(rating: Binding(
                        get: { paper.rating },
                        set: { paper.rating = $0 }
                    ))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 27)
        .padding(.horizontal, 6)
        .background(
            Rectangle()
                .fill(rowBackground)
        )
        .overlay(
            Rectangle()
                .fill(rowBorder)
                .frame(height: 1),
            alignment: .bottom
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowText(
        _ text: String,
        secondary: Bool = false,
        weight: Font.Weight = .regular,
        monospaced: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        let base = Text(text.isEmpty ? " " : text)
            .font(.system(size: 11, weight: weight))
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)

        if monospaced {
            base.monospacedDigit()
        } else {
            base
        }
    }
}

private struct PapersColumn<Content: View>: View {
    var width: CGFloat? = nil
    var minWidth: CGFloat? = nil
    var alignment: Alignment = .leading
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: width, alignment: alignment)
            .frame(minWidth: minWidth, maxWidth: width == nil ? .infinity : width, alignment: alignment)
            .padding(.horizontal, 6)
    }
}
