import SwiftData

enum SidebarSelection: Hashable {
    case allPapers
    case favorites
    case unread
    case recent
    case collection(PersistentIdentifier)
}

enum TabItem: Hashable {
    case library
    case paper(UUID)
    case editor(String) // file path as string (URL isn't Hashable)
    case pdfFile(String) // standalone PDF file path
}
