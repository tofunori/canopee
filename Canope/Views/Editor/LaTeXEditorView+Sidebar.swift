import SwiftUI
import PDFKit

// MARK: - Sidebar

extension LaTeXEditorView {
    var sidebarPane: some View {
        HStack(spacing: 0) {
            sidebarActivityBar
            Divider()
            Group {
                switch selectedSidebarSection {
                case .files:
                    fileBrowserSidebar
                case .annotations:
                    annotationSidebar
                case .diff:
                    diffSidebar
                }
            }
            .frame(
                minWidth: showSidebar ? sidebarWidth : 0,
                idealWidth: showSidebar ? sidebarWidth : 0,
                maxWidth: showSidebar ? sidebarWidth : 0
            )
            .opacity(showSidebar ? 1 : 0)
            .allowsHitTesting(showSidebar)
            .clipped()

            if showSidebar {
                sidebarResizeHandle
            }
        }
        .frame(
            width: showSidebar
                ? SidebarSizing.activityBarWidth + sidebarWidth + SidebarSizing.resizeHandleWidth + 1
                : SidebarSizing.activityBarWidth
        )
        .animation(nil, value: showSidebar)
    }

    var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: SidebarSizing.resizeHandleWidth)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let baseWidth = sidebarResizeStartWidth ?? sidebarWidth
                        if sidebarResizeStartWidth == nil {
                            sidebarResizeStartWidth = sidebarWidth
                        }
                        sidebarWidth = baseWidth + value.translation.width
                    }
                    .onEnded { _ in
                        sidebarResizeStartWidth = nil
                    }
            )
    }

    var sidebarActivityBar: some View {
        VStack(spacing: 8) {
            sidebarButton(for: .files, systemImage: "folder")
            sidebarButton(for: .annotations, systemImage: "note.text")
            sidebarButton(for: .diff, systemImage: "arrow.left.arrow.right.square")
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 44)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    var fileBrowserSidebar: some View {
        FileBrowserView(rootURL: projectRoot) { url in
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                onOpenPDF?(url)
            } else if ext == "md" || ext == "tex" || ext == "bib" || ext == "txt" {
                onOpenInNewTab?(url)
            } else {
                openFile(url)
            }
        }
    }

    var annotationSidebar: some View {
        Group {
            if let referenceID = activeReferencePDFID,
               let document = activeReferencePDFDocument,
               let state = activeReferencePDFState {
                referenceAnnotationSidebar(referenceID: referenceID, document: document, state: state)
            } else {
                latexAnnotationSidebar
            }
        }
    }

    var latexAnnotationSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Annotations", systemImage: "note.text")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if !sidebarAnnotations.isEmpty {
                    Button("Tout envoyer") {
                        sendAllAnnotationsToClaude()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !sidebarAnnotations.isEmpty {
                    Text("\(sidebarAnnotations.count)")
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
            Divider()

            if sidebarAnnotations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("Aucune annotation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Sélectionne un passage puis clique sur le surligneur dans la barre du haut.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sidebarAnnotations, id: \.annotation.id) { resolved in
                            annotationRow(resolved)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func referenceAnnotationSidebar(
        referenceID: UUID,
        document: PDFDocument,
        state: ReferencePDFUIState
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Annotations", systemImage: "note.text")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if activeReferenceAnnotationCount > 0 {
                    Text("\(activeReferenceAnnotationCount)")
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
            Divider()

            AnnotationSidebarView(
                document: document,
                selectedAnnotation: Binding(
                    get: { state.selectedAnnotation },
                    set: { state.selectedAnnotation = $0 }
                ),
                onNavigate: { annotation in
                    state.selectedAnnotation = annotation
                },
                onDelete: { annotation in
                    deleteReferenceAnnotation(annotation, in: referenceID)
                },
                onEditNote: { annotation in
                    beginEditingReferenceAnnotationNote(annotation, in: referenceID)
                }
            )
            .id(state.annotationRefreshToken)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    func sidebarButton(for section: SidebarSection, systemImage: String) -> some View {
        let isActive = showSidebar && selectedSidebarSection == section

        Button {
            if isActive {
                showSidebar = false
            } else {
                selectedSidebarSection = section
                showSidebar = true
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(section == .files ? "Fichiers" : "Annotations")
    }

    func annotationRow(_ resolved: ResolvedLaTeXAnnotation) -> some View {
        let annotation = resolved.annotation

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(resolved.isDetached ? Color.orange : Color.yellow)
                    .frame(width: 7, height: 7)
                Text(resolved.isDetached ? "À recoller" : "Ancrée")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    deleteAnnotation(annotation.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Supprimer l'annotation")
            }

            Button {
                beginEditingAnnotation(annotation.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(annotation.selectedText.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    if !annotation.note.isEmpty {
                        Text(annotation.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Button("Modifier") {
                    beginEditingAnnotation(annotation.id)
                }
                .buttonStyle(.plain)
                .font(.caption)

                Button("Envoyer") {
                    sendAnnotationToClaude(resolved)
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
