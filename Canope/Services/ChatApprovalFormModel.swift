import SwiftUI

@MainActor
final class ChatApprovalFormModel: ObservableObject {
    @Published private(set) var fieldValues: [String: String] = [:]

    func sync(with approval: ChatApprovalRequest?) {
        guard let approval else {
            fieldValues = [:]
            return
        }

        var values: [String: String] = [:]
        for field in approval.fields {
            values[field.id] = field.defaultValue
            if field.supportsCustomValue {
                values["\(field.id)__other"] = ""
            }
        }
        fieldValues = values
    }

    func textBinding(for field: ChatInteractiveField) -> Binding<String> {
        Binding(
            get: { self.fieldValues[field.id] ?? field.defaultValue },
            set: { self.fieldValues[field.id] = $0 }
        )
    }

    func otherTextBinding(for field: ChatInteractiveField) -> Binding<String> {
        Binding(
            get: { self.fieldValues["\(field.id)__other"] ?? "" },
            set: { self.fieldValues["\(field.id)__other"] = $0 }
        )
    }

    func boolBinding(for field: ChatInteractiveField) -> Binding<Bool> {
        Binding(
            get: { (self.fieldValues[field.id] ?? field.defaultValue) == "true" },
            set: { self.fieldValues[field.id] = $0 ? "true" : "false" }
        )
    }

    func resolvedValue(for field: ChatInteractiveField) -> String {
        let raw = (fieldValues[field.id] ?? field.defaultValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if field.supportsCustomValue && raw == "__other__" {
            return (fieldValues["\(field.id)__other"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    func canSubmit(_ approval: ChatApprovalRequest) -> Bool {
        for field in approval.fields {
            let value = resolvedValue(for: field)
            if field.isRequired && value.isEmpty {
                return false
            }
            switch field.kind {
            case .integer where !value.isEmpty && Int(value) == nil:
                return false
            case .number where !value.isEmpty && Double(value) == nil:
                return false
            default:
                break
            }
        }
        return true
    }

    func setValue(_ value: String, for fieldID: String) {
        fieldValues[fieldID] = value
    }

    func setOtherValue(_ value: String, for fieldID: String) {
        fieldValues["\(fieldID)__other"] = value
    }
}
