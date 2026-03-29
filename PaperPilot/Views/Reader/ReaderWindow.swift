import SwiftUI
import SwiftData

struct ReaderWindow: View {
    let initialPaperID: PersistentIdentifier
    @Environment(\.modelContext) private var modelContext
    @State private var showTerminal = false
    @State private var selectedText = ""

    private var paper: Paper? {
        try? modelContext.fetch(
            FetchDescriptor<Paper>(predicate: #Predicate { $0.persistentModelID == initialPaperID })
        ).first
    }

    var body: some View {
        PDFReaderView(paperID: initialPaperID, showTerminal: $showTerminal, selectedText: $selectedText)
            .navigationTitle(paper?.title ?? "Article")
            .frame(minWidth: 700, minHeight: 500)
    }
}
