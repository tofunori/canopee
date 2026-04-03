import SwiftUI
import PDFKit

struct AnnotationSidebarView: View {
    let document: PDFDocument
    @Binding var selectedAnnotation: PDFAnnotation?
    let onNavigate: (PDFAnnotation) -> Void
    let onDelete: (PDFAnnotation) -> Void
    let onEditNote: (PDFAnnotation) -> Void
    let onChangeColor: (PDFAnnotation, NSColor) -> Void

    struct PageAnnotations: Identifiable {
        let id: Int
        let pageLabel: String
        let annotations: [PDFAnnotation]
    }

    private var pageAnnotations: [PageAnnotations] {
        var result: [PageAnnotations] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageAnnotations = page.annotations.filter { annotation in
                annotation.type != "Link" && annotation.type != "Widget"
            }
            if !pageAnnotations.isEmpty {
                result.append(PageAnnotations(
                    id: i,
                    pageLabel: page.label ?? "\(i + 1)",
                    annotations: pageAnnotations
                ))
            }
        }
        return result
    }

    private var totalCount: Int {
        pageAnnotations.reduce(0) { $0 + $1.annotations.count }
    }

    var body: some View {
        let annotations = pageAnnotations

        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Text("\(totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List {
                if annotations.isEmpty {
                    ContentUnavailableView(
                        "Aucune annotation",
                        systemImage: "pencil.slash",
                        description: Text("Surlignez du texte ou placez des notes")
                    )
                } else {
                    ForEach(annotations) { pageGroup in
                        Section("Page \(pageGroup.pageLabel)") {
                            ForEach(pageGroup.annotations, id: \.self) { annotation in
                                AnnotationRowView(
                                    annotation: annotation,
                                    isSelected: selectedAnnotation === annotation
                                )
                                .onTapGesture {
                                    selectedAnnotation = annotation
                                    onNavigate(annotation)
                                }
                                .contextMenu {
                                    Button("Modifier la note…") {
                                        onEditNote(annotation)
                                    }

                                    Menu("Couleur") {
                                        ForEach(AnnotationColor.all, id: \.name) { item in
                                            Button(item.name) {
                                                onChangeColor(annotation, item.color)
                                            }
                                        }
                                    }

                                    Divider()

                                    Button("Supprimer", role: .destructive) {
                                        onDelete(annotation)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct AnnotationRowView: View {
    let annotation: PDFAnnotation
    let isSelected: Bool

    private var displayColor: NSColor {
        annotation.isTextBoxAnnotation ? annotation.textBoxFillColor : annotation.color
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: displayColor))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: iconForType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(annotationTypeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let contents = annotation.contents, !contents.isEmpty {
                    Text(contents)
                        .font(.caption2)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var annotationTypeName: String {
        if annotation.isCanopeHighlightBlock { return "Surligné" }
        if annotation.isTextBoxAnnotation { return "Texte" }
        switch annotation.type {
        case "Highlight": return "Surligné"
        case "Underline": return "Souligné"
        case "StrikeOut": return "Barré"
        case "Text": return "Note"
        case "Ink": return "Dessin"
        case "Square": return "Rectangle"
        case "Circle": return "Ovale"
        case "Line": return "Flèche"
        default: return annotation.type ?? "Annotation"
        }
    }

    private var iconForType: String {
        if annotation.isCanopeHighlightBlock { return "highlighter" }
        if annotation.isTextBoxAnnotation { return "textbox" }
        switch annotation.type {
        case "Highlight": return "highlighter"
        case "Underline": return "underline"
        case "StrikeOut": return "strikethrough"
        case "Text": return "note.text"
        case "Ink": return "pencil.tip"
        case "Square": return "rectangle"
        case "Circle": return "oval"
        case "Line": return "arrow.up.right"
        default: return "pencil"
        }
    }
}
