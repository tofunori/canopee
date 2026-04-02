import Foundation

enum CanopeContextFiles {
    private static let legacySelectionMirrorPaths = [
        "/tmp/canope_selection.txt",
        "/tmp/canopee_selection.txt",
    ]

    static let ideSelectionStatePaths = [
        "/tmp/canope_ide_selection.json",
        "/tmp/canopee_ide_selection.json",
    ]

    static let paperPaths = [
        "/tmp/canope_paper.txt",
        "/tmp/canopee_paper.txt",
    ]

    static let annotationPromptPaths = [
        "/tmp/canope_annotation_prompt.txt",
        "/tmp/canopee_annotation_prompt.txt",
    ]

    static let claudeIDEMcpConfigPaths = [
        "/tmp/canope_claude_ide_mcp.json",
        "/tmp/canopee_claude_ide_mcp.json",
    ]

    static let bridgeCommandPaths = [
        "/tmp/canope_bridge_commands.json",
        "/tmp/canopee_bridge_commands.json",
    ]

    static let bridgeCommandResultPaths = [
        "/tmp/canope_bridge_command_result.json",
        "/tmp/canopee_bridge_command_result.json",
    ]

    static let claudeIDEBridgeURL = "http://127.0.0.1:8765/sse"

    static var terminalEnvironment: [String] {
        [
            "CANOPE_IDE_SELECTION_STATE=\(ideSelectionStatePaths[0])",
            "CANOPEE_IDE_SELECTION_STATE=\(ideSelectionStatePaths[1])",
            "CANOPE_PAPER=\(paperPaths[0])",
            "CANOPEE_PAPER=\(paperPaths[1])",
            "CANOPE_ANNOTATION_PROMPT=\(annotationPromptPaths[0])",
            "CANOPEE_ANNOTATION_PROMPT=\(annotationPromptPaths[1])",
            "CANOPE_IDE_BRIDGE_URL=\(claudeIDEBridgeURL)",
            "CANOPEE_IDE_BRIDGE_URL=\(claudeIDEBridgeURL)",
            "CANOPE_CLAUDE_IDE_MCP_CONFIG=\(claudeIDEMcpConfigPaths[0])",
            "CANOPEE_CLAUDE_IDE_MCP_CONFIG=\(claudeIDEMcpConfigPaths[1])",
            "CANOPE_CLAUDE_IDE_BRIDGE_URL=\(claudeIDEBridgeURL)",
            "CANOPEE_CLAUDE_IDE_BRIDGE_URL=\(claudeIDEBridgeURL)",
        ]
    }

    static func clearLegacySelectionMirror() {
        for path in legacySelectionMirrorPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func writePaper(_ content: String) {
        write(content, to: paperPaths)
    }

    static func writeAnnotationPrompt(_ content: String) {
        write(content, to: annotationPromptPaths)
    }

    static func writeIDESelectionState(_ state: ClaudeIDESelectionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(state) else { return }
        write(data, to: ideSelectionStatePaths)
    }

    static func writeClaudeIDEMcpConfig() {
        let payload: [String: Any] = [
            "mcpServers": [
                "ide": [
                    "type": "sse-ide",
                    "url": claudeIDEBridgeURL,
                    "ideName": "Canope",
                ],
            ],
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }

        write(data, to: claudeIDEMcpConfigPaths)
    }

    static func clearAll() {
        for path in legacySelectionMirrorPaths + ideSelectionStatePaths + paperPaths + annotationPromptPaths + claudeIDEMcpConfigPaths + bridgeCommandPaths + bridgeCommandResultPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func write(_ content: String, to paths: [String]) {
        for path in paths {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func write(_ content: Data, to paths: [String]) {
        for path in paths {
            try? content.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
