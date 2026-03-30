import Foundation
import SwiftData

@Model
final class PaperCollection {
    var id: UUID
    var name: String
    var icon: String
    var sortOrder: Int
    var dateCreated: Date

    // Hierarchy
    var parent: PaperCollection?

    @Relationship(deleteRule: .cascade, inverse: \PaperCollection.parent)
    var children: [PaperCollection]

    @Relationship(inverse: \Paper.collections)
    var papers: [Paper]

    init(name: String, icon: String = "folder", parent: PaperCollection? = nil) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.sortOrder = 0
        self.dateCreated = Date()
        self.parent = parent
        self.children = []
        self.papers = []
    }
}
