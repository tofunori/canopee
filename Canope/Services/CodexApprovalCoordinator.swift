import Foundation

typealias ServerRequestDisposition = CodexServerRequestDisposition

enum CodexServerRequestDisposition: Equatable {
    case autoApprove
    case inlineApproval
    case reject
    case denyPermissions
    case unsupported
}

struct CodexPendingServerRequest {
    let id: Int
    let method: String
    let itemID: String?
    let threadID: String?
    let turnID: String?
    let params: [String: Any]
}

final class CodexApprovalCoordinator {
    private(set) var pendingRequests: [Int: CodexPendingServerRequest] = [:]

    func registerRequest(id: Int, method: String, params: [String: Any]) -> CodexPendingServerRequest {
        let request = CodexPendingServerRequest(
            id: id,
            method: method,
            itemID: params["itemId"] as? String,
            threadID: params["threadId"] as? String,
            turnID: params["turnId"] as? String,
            params: params
        )
        pendingRequests[id] = request
        return request
    }

    func request(for id: Int) -> CodexPendingServerRequest? {
        pendingRequests[id]
    }

    func removeRequest(id: Int) {
        pendingRequests.removeValue(forKey: id)
    }

    func clearResolvedApproval(for itemID: String?, pendingApprovalRequest: inout ChatApprovalRequest?) {
        guard let itemID else { return }
        if pendingApprovalRequest?.itemID == itemID {
            pendingApprovalRequest = nil
        }
        pendingRequests = pendingRequests.filter { _, value in
            value.itemID != itemID
        }
    }

    func reset() {
        pendingRequests.removeAll()
    }

    func makeApprovalRequest(
        from request: CodexPendingServerRequest,
        prompt: String,
        displayText: String
    ) -> ChatApprovalRequest {
        ChatApprovalRequest(
            toolName: Self.serverRequestToolName(method: request.method, params: request.params),
            actionLabel: Self.serverRequestActionLabel(method: request.method),
            prompt: prompt,
            displayText: displayText,
            message: Self.serverRequestMessage(method: request.method, params: request.params),
            details: Self.serverRequestDetails(method: request.method, params: request.params),
            preview: Self.serverRequestPreview(method: request.method, params: request.params),
            fields: Self.serverRequestFields(method: request.method, params: request.params),
            rpcRequestID: request.id,
            rpcMethod: request.method,
            itemID: request.itemID,
            threadID: request.threadID,
            turnID: request.turnID
        )
    }

    static func approvalPolicy(for mode: ChatInteractionMode) -> String {
        switch mode {
        case .agent, .acceptEdits:
            return "on-request"
        case .plan:
            return "never"
        }
    }

    static func threadSandboxMode(for mode: ChatInteractionMode) -> String {
        switch mode {
        case .plan:
            return "read-only"
        case .agent, .acceptEdits:
            return "workspace-write"
        }
    }

    static func sandboxPolicy(
        for mode: ChatInteractionMode,
        workingDirectory: URL
    ) -> [String: Any] {
        switch mode {
        case .plan:
            return [
                "type": "readOnly",
                "networkAccess": true,
            ]
        case .agent, .acceptEdits:
            return [
                "type": "workspaceWrite",
                "writableRoots": [workingDirectory.path],
                "networkAccess": true,
            ]
        }
    }

    static func grantedPermissions(from params: [String: Any], grant: Bool, workingDirectory: URL) -> [String: Any] {
        guard grant else { return [:] }
        if let additionalPermissions = params["additionalPermissions"] as? [String: Any] {
            return additionalPermissions
        }
        if let permissions = params["permissions"] as? [String: Any] {
            return permissions
        }
        return [
            "fileSystem": [
                "write": [workingDirectory.path],
            ],
        ]
    }

    static func elicitationResponseResult(
        from params: [String: Any],
        approved: Bool,
        fieldValues: [String: String] = [:]
    ) -> [String: Any] {
        if approved {
            let content = mcpElicitationContent(from: params, fieldValues: fieldValues)
            return [
                "action": "accept",
                "content": content,
            ]
        }
        return [
            "action": "decline",
        ]
    }

    static func toolRequestUserInputResponseResult(
        from params: [String: Any],
        fieldValues: [String: String]
    ) -> [String: Any] {
        let questions = params["questions"] as? [[String: Any]] ?? []
        var answers: [String: Any] = [:]
        for question in questions {
            guard let id = question["id"] as? String, !id.isEmpty else { continue }
            answers[id] = [
                "answers": interactiveAnswerStrings(for: id, fieldValues: fieldValues),
            ]
        }
        return ["answers": answers]
    }

    static func serverRequestDisposition(
        for method: String,
        mode: ChatInteractionMode,
        params: [String: Any] = [:]
    ) -> CodexServerRequestDisposition {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            switch mode {
            case .agent: return .autoApprove
            case .acceptEdits: return .inlineApproval
            case .plan: return .reject
            }
        case "item/permissions/requestApproval":
            switch mode {
            case .agent: return .autoApprove
            case .acceptEdits, .plan: return .denyPermissions
            }
        case "mcpServer/elicitation/request":
            if supportsSimpleMCPApprovalElicitation(params) {
                switch mode {
                case .agent: return .autoApprove
                case .acceptEdits: return .inlineApproval
                case .plan: return .reject
                }
            }
            guard supportsInlineMCPFormElicitation(params) else { return .unsupported }
            switch mode {
            case .agent, .acceptEdits: return .inlineApproval
            case .plan: return .reject
            }
        case "item/tool/requestUserInput":
            guard supportsToolRequestUserInput(params) else { return .unsupported }
            switch mode {
            case .agent, .acceptEdits: return .inlineApproval
            case .plan: return .reject
            }
        case "item/tool/call",
             "account/chatgptAuthTokens/refresh":
            return .unsupported
        default:
            return .unsupported
        }
    }

    static func serverRequestToolName(method: String, params: [String: Any]) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            if let command = params["command"] as? String, !command.isEmpty {
                return command
            }
            return "Commande"
        case "item/fileChange/requestApproval":
            if let files = params["paths"] as? [String], let first = files.first {
                return (first as NSString).lastPathComponent
            }
            return "Edition"
        case "item/permissions/requestApproval":
            return "Permissions"
        case "mcpServer/elicitation/request":
            return mcpElicitationToolName(from: params)
        case "item/tool/requestUserInput":
            if let questions = params["questions"] as? [[String: Any]],
               let first = questions.first,
               let header = first["header"] as? String,
               !header.isEmpty {
                return header
            }
            return "Reponse requise"
        default:
            return method
        }
    }

    static func serverRequestActionLabel(method: String) -> String? {
        switch method {
        case "item/fileChange/requestApproval":
            return "Edit"
        case "item/commandExecution/requestApproval":
            return "Bash"
        case "mcpServer/elicitation/request":
            return "MCP"
        case "item/tool/requestUserInput":
            return "Input"
        default:
            return nil
        }
    }

    static func serverRequestMessage(method: String, params: [String: Any]) -> String? {
        switch method {
        case "mcpServer/elicitation/request":
            return trimmedOrNil(params["message"] as? String)
        case "item/tool/requestUserInput":
            if let questions = params["questions"] as? [[String: Any]],
               let first = questions.first,
               let prompt = first["question"] as? String {
                return trimmedOrNil(prompt)
            }
            return "Saisie requise"
        case "item/fileChange/requestApproval":
            return "Autoriser cette modification ?"
        case "item/commandExecution/requestApproval":
            return "Autoriser cette commande ?"
        default:
            return nil
        }
    }

    static func serverRequestDetails(method: String, params: [String: Any]) -> [String] {
        switch method {
        case "item/fileChange/requestApproval":
            var details: [String] = []
            if let paths = params["paths"] as? [String], !paths.isEmpty {
                details.append(contentsOf: paths.map { path in
                    let last = (path as NSString).lastPathComponent
                    return last.isEmpty ? path : last
                })
                if paths.count > 1 {
                    details.append("\(paths.count) files")
                }
                return details
            }
            if let changes = params["changes"] as? [[String: Any]], !changes.isEmpty {
                details.append(contentsOf: changes.compactMap { change in
                    let path = (change["path"] as? String) ?? (change["newPath"] as? String) ?? ""
                    guard !path.isEmpty else { return nil }
                    let last = (path as NSString).lastPathComponent
                    return last.isEmpty ? path : last
                })
                if changes.count > 1 {
                    details.append("\(changes.count) changes")
                }
                return details
            }
            return []
        case "item/commandExecution/requestApproval":
            var details: [String] = []
            if let command = trimmedOrNil(params["command"] as? String) {
                details.append(command)
            }
            if let cwd = trimmedOrNil(params["cwd"] as? String) {
                details.append(cwd)
            }
            return details
        case "mcpServer/elicitation/request":
            if let serverName = trimmedOrNil(params["serverName"] as? String) {
                return [serverName]
            }
            return []
        default:
            return []
        }
    }

    static func serverRequestPreview(method: String, params: [String: Any]) -> ChatApprovalPreview? {
        switch method {
        case "item/fileChange/requestApproval":
            return fileChangeApprovalPreview(params: params)
        default:
            return nil
        }
    }

    static func blockedServerRequestMessage(
        method: String,
        mode: ChatInteractionMode,
        params: [String: Any] = [:]
    ) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            return ClaudeHeadlessProvider.blockedToolMessage(toolName: "Bash", mode: mode)
        case "item/fileChange/requestApproval":
            return ClaudeHeadlessProvider.blockedToolMessage(toolName: "Edit", mode: mode)
        case "mcpServer/elicitation/request":
            return ClaudeHeadlessProvider.blockedToolMessage(
                toolName: mcpElicitationToolName(from: params),
                mode: mode
            )
        case "item/permissions/requestApproval":
            switch mode {
            case .plan:
                return AppStrings.permissionRequestBlocked
            case .acceptEdits:
                return "Mode accept edits: la demande de permission additionnelle a ete bloquee en attendant ton approbation."
            case .agent:
                return "Demande de permission additionnelle."
            }
        default:
            return unsupportedServerRequestMessage(for: method)
        }
    }

    static func unsupportedServerRequestMessage(for method: String) -> String {
        switch method {
        case "item/tool/call":
            return "Codex: les appels d’outils dynamiques ne sont pas encore pris en charge dans Canope."
        case "item/tool/requestUserInput":
            return "Codex: cette demande d’entrée utilisateur interactive n’est pas encore prise en charge dans Canope."
        case "mcpServer/elicitation/request":
            return "Codex: cette demande MCP exige un formulaire interactif qui n’est pas encore prise en charge dans Canope."
        case "account/chatgptAuthTokens/refresh":
            return "Codex: le rafraichissement des jetons ChatGPT n’est pas encore pris en charge dans Canope."
        default:
            return "Codex: requete app-server non prise en charge (\(method))."
        }
    }

    private static func supportsSimpleMCPApprovalElicitation(_ params: [String: Any]) -> Bool {
        guard let requestedSchema = params["requestedSchema"] as? [String: Any],
              (requestedSchema["type"] as? String) == "object"
        else {
            return false
        }
        let properties = requestedSchema["properties"] as? [String: Any] ?? [:]
        let required = requestedSchema["required"] as? [Any] ?? []
        return properties.isEmpty && required.isEmpty
    }

    private static func toolRequestUserInputFields(from params: [String: Any]) -> [ChatInteractiveField] {
        guard let questions = params["questions"] as? [[String: Any]], !questions.isEmpty else {
            return []
        }

        return questions.compactMap { question in
            guard let id = trimmedOrNil(question["id"] as? String),
                  let header = (question["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let prompt = trimmedOrNil(question["question"] as? String)
            else {
                return nil
            }

            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> ChatInteractiveOption? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String
                else {
                    return nil
                }
                return ChatInteractiveOption(label: label, description: description)
            }

            let isSecret = question["isSecret"] as? Bool ?? false
            let allowsOther = question["isOther"] as? Bool ?? false
            let kind: ChatInteractiveFieldKind = options.isEmpty ? (isSecret ? .secureText : .text) : .singleChoice
            let defaultValue = options.first?.label ?? (kind == .boolean ? "false" : "")

            return ChatInteractiveField(
                id: id,
                title: header.isEmpty ? id : header,
                prompt: prompt,
                kind: kind,
                options: options,
                isRequired: true,
                allowsCustomValue: allowsOther,
                placeholder: isSecret ? "Enter value" : nil,
                defaultValue: defaultValue
            )
        }
    }

    private static func mcpElicitationFields(from params: [String: Any]) -> [ChatInteractiveField] {
        guard (params["mode"] as? String) != "url",
              let requestedSchema = params["requestedSchema"] as? [String: Any],
              (requestedSchema["type"] as? String) == "object",
              let properties = requestedSchema["properties"] as? [String: Any]
        else {
            return []
        }

        let requiredSet = Set((requestedSchema["required"] as? [String]) ?? [])

        return properties.keys.sorted().compactMap { key in
            guard let schema = properties[key] as? [String: Any] else { return nil }

            let enumValues = (schema["enum"] as? [Any])?.compactMap { $0 as? String } ?? []
            let type = (schema["type"] as? String) ?? "string"
            let title = trimmedOrNil(schema["title"] as? String)
            let description = trimmedOrNil(schema["description"] as? String)
            let kind: ChatInteractiveFieldKind
            let options: [ChatInteractiveOption]

            if !enumValues.isEmpty {
                kind = .singleChoice
                options = enumValues.map { ChatInteractiveOption(label: $0, description: $0) }
            } else {
                options = []
                switch type {
                case "boolean":
                    kind = .boolean
                case "integer":
                    kind = .integer
                case "number":
                    kind = .number
                default:
                    kind = .text
                }
            }

            let defaultValue: String
            switch kind {
            case .boolean:
                defaultValue = "false"
            case .singleChoice:
                defaultValue = options.first?.label ?? ""
            default:
                defaultValue = ""
            }

            return ChatInteractiveField(
                id: key,
                title: title ?? key,
                prompt: description,
                kind: kind,
                options: options,
                isRequired: requiredSet.contains(key),
                allowsCustomValue: false,
                placeholder: nil,
                defaultValue: defaultValue
            )
        }
    }

    private static func serverRequestFields(method: String, params: [String: Any]) -> [ChatInteractiveField] {
        switch method {
        case "item/tool/requestUserInput":
            return toolRequestUserInputFields(from: params)
        case "mcpServer/elicitation/request":
            return mcpElicitationFields(from: params)
        default:
            return []
        }
    }

    private static func supportsInlineMCPFormElicitation(_ params: [String: Any]) -> Bool {
        !mcpElicitationFields(from: params).isEmpty
    }

    private static func supportsToolRequestUserInput(_ params: [String: Any]) -> Bool {
        !toolRequestUserInputFields(from: params).isEmpty
    }

    private static func interactiveAnswerStrings(
        for fieldID: String,
        fieldValues: [String: String]
    ) -> [String] {
        let key = fieldID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let selected = (fieldValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if selected == "__other__" {
            let custom = (fieldValues["\(key)__other"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? [] : [custom]
        }
        return selected.isEmpty ? [] : [selected]
    }

    private static func mcpElicitationContent(
        from params: [String: Any],
        fieldValues: [String: String]
    ) -> [String: Any] {
        guard let requestedSchema = params["requestedSchema"] as? [String: Any],
              let properties = requestedSchema["properties"] as? [String: Any]
        else {
            return [:]
        }

        var content: [String: Any] = [:]
        for key in properties.keys.sorted() {
            guard let schema = properties[key] as? [String: Any] else { continue }
            let raw = (fieldValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let type = (schema["type"] as? String) ?? "string"

            switch type {
            case "boolean":
                if !raw.isEmpty {
                    content[key] = (raw as NSString).boolValue
                }
            case "integer":
                if let value = Int(raw) {
                    content[key] = value
                }
            case "number":
                if let value = Double(raw) {
                    content[key] = value
                }
            default:
                if !raw.isEmpty {
                    content[key] = raw
                }
            }
        }
        return content
    }

    private static func mcpElicitationToolName(from params: [String: Any]) -> String {
        if let message = params["message"] as? String,
           let toolStart = message.range(of: "\""),
           let toolEnd = message[toolStart.upperBound...].range(of: "\"") {
            return String(message[toolStart.upperBound..<toolEnd.lowerBound])
        }
        if let meta = params["_meta"] as? [String: Any],
           let toolDescription = trimmedOrNil(meta["tool_description"] as? String) {
            return toolDescription
        }
        if let serverName = trimmedOrNil(params["serverName"] as? String) {
            return "\(serverName) MCP"
        }
        return "Appel MCP"
    }

    private static func fileChangeApprovalPreview(params: [String: Any]) -> ChatApprovalPreview? {
        guard let changes = params["changes"] as? [[String: Any]], !changes.isEmpty else { return nil }
        guard let primary = changes.first else { return nil }

        let path = (primary["path"] as? String) ?? (primary["newPath"] as? String) ?? ""
        let fileName: String
        if path.isEmpty {
            fileName = changes.count > 1 ? "\(changes.count) modifications" : "Modification"
        } else {
            let last = (path as NSString).lastPathComponent
            fileName = last.isEmpty ? path : last
        }

        let kind = trimmedOrNil(primary["kind"] as? String) ?? "update"
        let title = path.isEmpty ? kind.capitalized : "\(fileName) · \(kind)"

        guard let diff = trimmedOrNil(primary["diff"] as? String) else {
            return nil
        }

        let lines = diff
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                if trimmed.hasPrefix("---") || trimmed.hasPrefix("+++") || trimmed == "\\ No newline at end of file" {
                    return false
                }
                return true
            }

        var kept: [String] = []
        for line in lines {
            if line.hasPrefix("@@") {
                kept.append(line)
                continue
            }
            if line.hasPrefix("+") || line.hasPrefix("-") {
                kept.append(line)
            }
            if kept.count >= 6 { break }
        }

        if kept.isEmpty {
            kept = Array(lines.prefix(4))
        }

        guard !kept.isEmpty else { return nil }

        let maxLineLength = 92
        let body = kept.map { line in
            if line.count > maxLineLength {
                return String(line.prefix(maxLineLength - 1)) + "…"
            }
            return line
        }.joined(separator: "\n")

        return ChatApprovalPreview(title: title, body: body)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
