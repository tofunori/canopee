import SwiftUI

struct SessionPickerView: View {
    let loadSessions: () -> [ChatSessionListItem]
    let renameSession: (String, String) -> Void
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var sessions: [ChatSessionListItem] = []
    @State private var search = ""
    @State private var renamingSession: ChatSessionListItem?
    @State private var renameText = ""

    private var filtered: [ChatSessionListItem] {
        if search.isEmpty { return sessions }
        let q = search.lowercased()
        return sessions.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.project.lowercased().contains(q) ||
            $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Reprendre une session")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Annuler") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Search
            TextField("Rechercher…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            Divider()

            // Session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        Button {
                            onSelect(entry.id)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text(String(entry.id.prefix(8)))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)

                                        if !entry.project.isEmpty && entry.project != entry.displayName {
                                            Text("·")
                                                .foregroundStyle(.secondary.opacity(0.5))
                                            Text(entry.project)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                Text(entry.dateString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        .contextMenu {
                            Button("Renommer…") {
                                renameText = entry.name
                                renamingSession = entry
                            }
                        }

                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(width: 420, height: 350)
        .background(AppChromePalette.surfaceBar)
        .onAppear {
            sessions = loadSessions()
        }
        .sheet(item: $renamingSession) { entry in
            VStack(spacing: 12) {
                Text("Renommer la session")
                    .font(.system(size: 13, weight: .semibold))

                TextField("Nom", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                HStack {
                    Button("Annuler") { renamingSession = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Renommer") {
                        renameSession(entry.id, renameText)
                        sessions = loadSessions()
                        renamingSession = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(20)
            .frame(width: 300)
        }
    }
}
