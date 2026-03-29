import SwiftUI

struct CompilationErrorView: View {
    let errors: [CompilationError]
    let onGoToLine: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: errorCount > 0 ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(errorCount > 0 ? .red : .green)
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            if errors.isEmpty {
                ContentUnavailableView("Aucune erreur", systemImage: "checkmark.circle", description: Text("La compilation a réussi"))
                    .frame(maxHeight: .infinity)
            } else {
                List(errors) { error in
                    Button(action: { if error.line > 0 { onGoToLine(error.line) } }) {
                        HStack(spacing: 6) {
                            Image(systemName: error.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                                .foregroundStyle(error.isWarning ? .yellow : .red)
                                .font(.caption)

                            if error.line > 0 {
                                Text("l.\(error.line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 35, alignment: .trailing)
                            }

                            Text(error.message)
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var errorCount: Int {
        errors.filter { !$0.isWarning }.count
    }

    private var warningCount: Int {
        errors.filter { $0.isWarning }.count
    }

    private var statusText: String {
        if errors.isEmpty { return "Compilation réussie" }
        var parts: [String] = []
        if errorCount > 0 { parts.append("\(errorCount) erreur\(errorCount > 1 ? "s" : "")") }
        if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount > 1 ? "s" : "")") }
        return parts.joined(separator: ", ")
    }
}
