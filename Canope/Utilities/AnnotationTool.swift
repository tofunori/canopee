import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case pointer
    case highlight
    case underline
    case strikethrough
    case note
    case textBox
    case ink
    case rectangle
    case oval
    case arrow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pointer: return "Sélection"
        case .highlight: return "Surligner"
        case .underline: return "Souligner"
        case .strikethrough: return "Barrer"
        case .note: return "Note"
        case .textBox: return "Zone de texte"
        case .ink: return "Dessin"
        case .rectangle: return "Rectangle"
        case .oval: return "Ovale"
        case .arrow: return "Flèche"
        }
    }

    var icon: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .note: return "note.text"
        case .textBox: return "character.textbox"
        case .ink: return "pencil.tip"
        case .rectangle: return "rectangle"
        case .oval: return "oval"
        case .arrow: return "arrow.up.right"
        }
    }

    /// Tools that need the CursorTrackingView to intercept mouse drag
    var needsDragInteraction: Bool {
        switch self {
        case .textBox, .ink, .rectangle, .oval, .arrow: return true
        default: return false
        }
    }
}
