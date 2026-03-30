import Foundation

enum CanopeContextFiles {
    static let selectionPaths = [
        "/tmp/canope_selection.txt",
        "/tmp/canopee_selection.txt",
    ]

    static let paperPaths = [
        "/tmp/canope_paper.txt",
        "/tmp/canopee_paper.txt",
    ]

    static let annotationPromptPaths = [
        "/tmp/canope_annotation_prompt.txt",
        "/tmp/canopee_annotation_prompt.txt",
    ]

    static var terminalEnvironment: [String] {
        [
            "CANOPE_SELECTION=\(selectionPaths[0])",
            "CANOPEE_SELECTION=\(selectionPaths[1])",
            "CANOPE_PAPER=\(paperPaths[0])",
            "CANOPEE_PAPER=\(paperPaths[1])",
            "CANOPE_ANNOTATION_PROMPT=\(annotationPromptPaths[0])",
            "CANOPEE_ANNOTATION_PROMPT=\(annotationPromptPaths[1])",
        ]
    }

    static func writeSelection(_ content: String) {
        write(content, to: selectionPaths)
    }

    static func writePaper(_ content: String) {
        write(content, to: paperPaths)
    }

    static func writeAnnotationPrompt(_ content: String) {
        write(content, to: annotationPromptPaths)
    }

    static func clearAll() {
        for path in selectionPaths + paperPaths + annotationPromptPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func write(_ content: String, to paths: [String]) {
        for path in paths {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
