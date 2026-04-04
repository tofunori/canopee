import SwiftUI
import PDFKit

// MARK: - LaTeX Landing View (empty editor state)

struct LaTeXLandingView: View {
    var onOpenTeX: (URL) -> Void
    let allPapers: [Paper]
    let referencePaperIDs: [UUID]
    @Binding var selectedReferencePaperID: UUID?
    let referencePDFs: [UUID: PDFDocument]
    var onCloseReference: (UUID) -> Void = { _ in }

    /// Root directory: parent of last opened .tex, or home as fallback
    private var rootURL: URL {
        if let lastPath = RecentTeXFilesStore.recentTeXFiles.first {
            return URL(fileURLWithPath: lastPath).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var activeReferenceID: UUID? {
        if let selectedReferencePaperID, referencePaperIDs.contains(selectedReferencePaperID) {
            return selectedReferencePaperID
        }
        return referencePaperIDs.first
    }

    private func paper(for id: UUID) -> Paper? {
        allPapers.first { $0.id == id }
    }

    private func selectReference(_ id: UUID) {
        selectedReferencePaperID = id
    }

    var body: some View {
        HSplitView {
            FileBrowserView(rootURL: rootURL) { url in
                let ext = url.pathExtension.lowercased()
                if ext == "tex" || ext == "bib" || ext == "txt" || ext == "md" {
                    onOpenTeX(url)
                }
            }
            .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)

            Group {
                if referencePaperIDs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Éditeur LaTeX")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Ouvrez un fichier .tex depuis l'arborescence\nou utilisez le menu + en haut à droite")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)

                        let recents = RecentTeXFilesStore.recentTeXFiles
                        if !recents.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Récents")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 4)
                                ForEach(recents.prefix(5), id: \.self) { path in
                                    Button {
                                        onOpenTeX(URL(fileURLWithPath: path))
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "doc.plaintext")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.green)
                                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                                .font(.system(size: 12))
                                            Spacer()
                                            Text(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.03))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(width: 300)
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 42))
                                .foregroundStyle(.tertiary)
                            Text("Aucun fichier .tex ouvert")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("Le panneau LaTeX reste vide.\nTu peux quand même consulter les PDFs de référence.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                        VStack(spacing: 0) {
                            if referencePaperIDs.count > 1 {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 0) {
                                        ForEach(referencePaperIDs, id: \.self) { id in
                                            let isSelected = activeReferenceID == id
                                            HStack(spacing: 4) {
                                                Button {
                                                    selectReference(id)
                                                } label: {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "book")
                                                            .font(.system(size: 9))
                                                        Text(paper(for: id)?.authorsShort ?? "Article")
                                                            .font(.system(size: 11))
                                                            .lineLimit(1)
                                                    }
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                Button {
                                                    onCloseReference(id)
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                                            .cornerRadius(4)
                                        }
                                    }
                                }
                                .frame(height: AppChromeMetrics.tabBarHeight)
                                .background(AppChromePalette.surfaceSubbar)
                                AppChromeDivider(role: .panel)
                            }

                            Group {
                                if let activeReferenceID,
                                   let document = referencePDFs[activeReferenceID] {
                                    PDFPreviewView(document: document)
                                } else {
                                    ContentUnavailableView(
                                        "PDF introuvable",
                                        systemImage: "doc.text",
                                        description: Text("Le PDF de référence n'a pas pu être chargé")
                                    )
                                }
                            }
                        }
                        .frame(minWidth: 280, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}
