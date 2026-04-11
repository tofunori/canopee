import Foundation

enum CodexNotificationEvent {
    case turnStarted(turnID: String?)
    case itemStarted(item: [String: Any])
    case assistantDelta(itemID: String?, delta: String)
    case toolOutputDelta(itemID: String, delta: String)
    case itemCompleted(item: [String: Any])
    case turnCompleted
    case turnPlanUpdated(explanation: String?, plan: [[String: Any]])
    case serverRequestResolved(requestID: Int)
    case approvalResolved(itemID: String?)
    case error(rendered: String, willRetry: Bool)
    case ignored
}

enum CodexNotificationRouter {
    static func route(method: String, params: [String: Any]) -> CodexNotificationEvent {
        switch method {
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            return .turnStarted(turnID: turn?["id"] as? String)

        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return .ignored }
            return .itemStarted(item: item)

        case "item/agentMessage/delta", "item/plan/delta":
            let delta = extractDeltaText(from: params) ?? ""
            guard !delta.isEmpty else { return .ignored }
            return .assistantDelta(itemID: params["itemId"] as? String, delta: delta)

        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            guard let itemID = params["itemId"] as? String else { return .ignored }
            let delta = extractDeltaText(from: params)
                ?? (params["output"] as? String)
                ?? (params["aggregatedOutput"] as? String)
                ?? ""
            guard !delta.isEmpty else { return .ignored }
            return .toolOutputDelta(itemID: itemID, delta: delta)

        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return .ignored }
            return .itemCompleted(item: item)

        case "turn/completed":
            return .turnCompleted

        case "turn/plan/updated":
            let plan = params["plan"] as? [[String: Any]] ?? []
            guard !plan.isEmpty else { return .ignored }
            return .turnPlanUpdated(
                explanation: params["explanation"] as? String,
                plan: plan
            )

        case "serverRequest/resolved":
            guard let requestID = jsonInt(params["requestId"]) else { return .ignored }
            return .serverRequestResolved(requestID: requestID)

        case "item/commandExecution/approvalResolved",
             "item/fileChange/approvalResolved",
             "item/tool/requestUserInputResolved":
            return .approvalResolved(itemID: params["itemId"] as? String)

        case "error":
            let errorPayload = params["error"] as? [String: Any]
            let message = (errorPayload?["message"] as? String)
                ?? (params["message"] as? String)
                ?? AppStrings.codexError
            let details = errorPayload?["additionalDetails"] as? String
            let rendered = [message, details]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n")
            let willRetry = params["willRetry"] as? Bool ?? false
            return .error(rendered: rendered, willRetry: willRetry)

        default:
            return .ignored
        }
    }

    private static func extractDeltaText(from params: [String: Any]) -> String? {
        if let delta = params["delta"] as? String { return delta }
        if let text = params["text"] as? String { return text }
        if let delta = params["textDelta"] as? String { return delta }
        return nil
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String { return Int(stringValue) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
