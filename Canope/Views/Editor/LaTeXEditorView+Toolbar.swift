import SwiftUI
import PDFKit

// MARK: - Toolbar

extension LaTeXEditorView {
    var editorToolbar: some View {
        HStack(spacing: 8) {
            toolbarCluster {
                Button(action: {
                    showSidebar.toggle()
                }) {
                    Image(systemName: "sidebar.left")
                        .symbolVariant(showSidebar ? .none : .slash)
                }
                .buttonStyle(.plain)
                .help("Afficher la barre latérale")

                toolbarInnerDivider

                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.green)
                Text(fileURL.lastPathComponent)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            toolbarCluster {
                Button(action: compile) {
                    if isCompiling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.plain)
                .help("Compiler (⌘B)")
                .keyboardShortcut("b", modifiers: .command)
                .disabled(isCompiling)

                Button(action: saveFile) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Sauvegarder (⌘S)")
                .keyboardShortcut("s", modifiers: .command)

                Button(action: beginAnnotationFromSelection) {
                    Image(systemName: "highlighter")
                }
                .buttonStyle(.plain)
                .help("Annoter la sélection (⇧⌘A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!canCreateAnnotationFromSelection)

                Button(action: reflowParagraphs) {
                    Image(systemName: "text.justify.leading")
                }
                .buttonStyle(.plain)
                .help("Reflow paragraphes (⌘⇧W)")
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button(action: { showErrors.toggle() }) {
                    Image(systemName: "doc.text.below.ecg")
                        .foregroundStyle(showErrors ? .green : errors.contains(where: { !$0.isWarning }) ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help("Console de compilation")
            }

            toolbarCluster {
                Menu {
                    let openPapers = allPapers.filter { openPaperIDs.contains($0.id) }
                    if openPapers.isEmpty {
                        Text("Aucun article ouvert en onglet")
                    } else {
                        ForEach(openPapers) { paper in
                            Button {
                                openReference(paper)
                            } label: {
                                let alreadyOpen = pdfPaneTabs.contains(.reference(paper.id))
                                Text("\(alreadyOpen ? "✓ " : "")\(paper.authorsShort) (\(paper.year.map { String($0) } ?? "—")) — \(paper.title)")
                            }
                        }
                    }
                } label: {
                    Image(systemName: pdfPaneTabs.count > 1 ? "book.fill" : "book")
                        .foregroundStyle(pdfPaneTabs.count > 1 ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help("Ouvrir un article de référence")

                toolbarInnerDivider

                Menu {
                    Button {
                        splitLayout = .horizontal
                        showPDFPreview = true
                    } label: {
                        Label("Côte à côte", systemImage: "rectangle.split.2x1")
                        if splitLayout == .horizontal { Image(systemName: "checkmark") }
                    }
                    Button {
                        splitLayout = .vertical
                        showPDFPreview = true
                    } label: {
                        Label("Haut / Bas", systemImage: "rectangle.split.1x2")
                        if splitLayout == .vertical { Image(systemName: "checkmark") }
                    }
                    Button {
                        splitLayout = .editorOnly
                        showPDFPreview = false
                    } label: {
                        Label("Éditeur seul", systemImage: "doc.text")
                        if splitLayout == .editorOnly { Image(systemName: "checkmark") }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .help("Disposition")

                Menu {
                    ForEach(LaTeXPanelArrangement.allCases, id: \.self) { arrangement in
                        Button {
                            panelArrangement = arrangement
                        } label: {
                            HStack {
                                if panelArrangement == arrangement {
                                    Image(systemName: "checkmark")
                                }
                                Text(arrangement.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .help("Ordre des panneaux")
            }

            if let referenceState = activeReferencePDFState {
                ReferencePDFToolCluster(state: referenceState)

                ReferencePDFActionsCluster(
                    state: referenceState,
                    annotationCount: activeReferenceAnnotationCount,
                    isAnnotationSidebarVisible: showSidebar && selectedSidebarSection == .annotations,
                    onChangeSelectedColor: changeSelectedReferenceAnnotationColor,
                    onFitToWidth: fitToWidth,
                    onRefresh: refreshCurrentReference,
                    onSave: saveCurrentReferencePDF,
                    onDeleteSelected: deleteSelectedReferenceAnnotation,
                    onDeleteAll: deleteAllReferenceAnnotations,
                    onToggleAnnotations: {
                        if showSidebar && selectedSidebarSection == .annotations {
                            showSidebar = false
                        } else {
                            selectedSidebarSection = .annotations
                            showSidebar = true
                        }
                    }
                )
            }

            Spacer(minLength: 8)

            toolbarCluster {
                Menu {
                    ForEach([11, 12, 13, 14, 15, 16, 18, 20, 24], id: \.self) { size in
                        Button {
                            editorFontSize = CGFloat(size)
                        } label: {
                            HStack {
                                if Int(editorFontSize) == size { Image(systemName: "checkmark") }
                                Text("\(size) pt")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .buttonStyle(.plain)
                .help("Taille police")

                Menu {
                    ForEach(0..<Self.editorThemes.count, id: \.self) { i in
                        Button {
                            editorTheme = i
                        } label: {
                            HStack {
                                if i == editorTheme { Image(systemName: "checkmark") }
                                Text(Self.editorThemes[i].name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                }
                .buttonStyle(.plain)
                .help("Thème éditeur")
            }

            toolbarCluster {
                Button(action: { showTerminal.toggle() }) {
                    Image(systemName: showTerminal ? "terminal.fill" : "terminal")
                        .foregroundStyle(showTerminal ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Terminal")

                if showTerminal {
                    toolbarInnerDivider

                    Button(action: addTerminalTab) {
                        Image(systemName: "plus")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Nouveau terminal")

                    Menu {
                        ForEach(0..<TerminalPanel.themes.count, id: \.self) { index in
                            Button {
                                applyTerminalTheme(index)
                            } label: {
                                Text(TerminalPanel.themes[index].name)
                            }
                        }
                    } label: {
                        Image(systemName: "paintpalette")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Thème du terminal")

                    Menu {
                        ForEach(TerminalPanel.fontSizes, id: \.self) { size in
                            Button {
                                applyTerminalFontSize(size)
                            } label: {
                                Text("\(size) pt")
                            }
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Taille de la police du terminal")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: EditorChromeMetrics.toolbarHeight)
        .background(.bar)
    }

    var toolbarInnerDivider: some View {
        Divider()
            .frame(height: 12)
    }

    func toolbarCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}
