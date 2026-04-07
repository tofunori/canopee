import AppKit
import Foundation

enum ClipboardCitationService {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func latexCitation(for citeKeys: [String]) -> String {
        let filteredKeys = citeKeys.filter { !$0.isEmpty }
        return "\\cite{\(filteredKeys.joined(separator: ","))}"
    }
}
