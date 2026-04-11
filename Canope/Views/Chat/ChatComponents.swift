import SwiftUI

struct ChatSessionHeader<Provider: HeadlessChatProviding, StatusBadgeContent: View>: View {
    @ObservedObject var provider: Provider

    let usesCodexVisualStyle: Bool
    let effortDisplayLabel: (String) -> String
    let onRename: () -> Void
    let onStop: () -> Void
    let statusBadgeView: (ChatStatusBadge) -> StatusBadgeContent

    private var visibleStatusBadges: [ChatStatusBadge] {
        guard usesCodexVisualStyle else { return provider.chatStatusBadges }
        return provider.chatStatusBadges.filter { badge in
            switch badge.kind {
            case .connected, .mcpOkay:
                return false
            default:
                return true
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if !usesCodexVisualStyle {
                Image(systemName: provider.providerIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(provider.chatSessionDisplayName)
                .font(.system(size: usesCodexVisualStyle ? 10 : 11, weight: .semibold))
                .lineLimit(1)

            if provider.chatCanRenameCurrentSession {
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
                }
                .buttonStyle(.plain)
                .help(AppStrings.renameConversation)
            }

            if !provider.chatUsesBottomPromptControls {
                Menu {
                    ForEach(provider.chatAvailableModels, id: \.self) { model in
                        Button {
                            provider.chatSelectedModel = model
                        } label: {
                            HStack {
                                Text(model)
                                if provider.chatSelectedModel == model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(provider.chatSelectedModel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))

                Menu {
                    ForEach(provider.chatAvailableEfforts, id: \.self) { effort in
                        Button {
                            provider.chatSelectedEffort = effort
                        } label: {
                            HStack {
                                Text(effortDisplayLabel(effort))
                                if provider.chatSelectedEffort == effort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(effortDisplayLabel(provider.chatSelectedEffort))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if provider.session.turns > 0 {
                if !provider.chatUsesBottomPromptControls {
                    Text("·")
                        .foregroundStyle((usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary).opacity(0.5))
                }
                Text("\(provider.session.turns) turns")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
            }

            ForEach(visibleStatusBadges) { badge in
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                statusBadgeView(badge)
            }

            Spacer()

            if provider.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            Button(action: onStop) {
                Image(systemName: provider.isProcessing ? "stop.circle.fill" : "stop.fill")
                    .font(.system(size: provider.isProcessing ? 14 : 9))
                    .foregroundStyle(provider.isProcessing ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(provider.isProcessing ? 1 : 0.3)
            .disabled(!provider.isProcessing)
        }
        .padding(.horizontal, 12)
        .frame(height: usesCodexVisualStyle ? AppChromeMetrics.codexHeaderHeight : 28)
        .background(usesCodexVisualStyle ? AppChromePalette.codexHeaderFill : AppChromePalette.surfaceSubbar)
    }
}

struct ChatApprovalCard: View {
    let approval: ChatApprovalRequest
    let usesCodexVisualStyle: Bool
    @ObservedObject var formModel: ChatApprovalFormModel
    let onDismiss: () -> Void
    let onApprove: () -> Void
    let onSubmit: ([String: String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if let actionLabel = approval.actionLabel {
                    Text(actionLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                } else {
                    Image(systemName: approval.requiresFormInput ? "square.and.pencil" : "checkmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Text(approval.message ?? "Autoriser l’action \(approval.toolName) ?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 8)
            }

            if approval.requiresFormInput {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(approval.fields) { field in
                        ChatApprovalFieldRow(field: field, formModel: formModel)
                    }
                }

                HStack(spacing: 8) {
                    Button(AppStrings.cancel, action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Send") {
                        onSubmit(formModel.fieldValues)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(!formModel.canSubmit(approval))
                }
            } else {
                if let preview = approval.preview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preview.title)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(preview.body)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptInner.opacity(0.85) : Color.white.opacity(0.05))
                        )
                    }
                }

                if !approval.details.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(approval.details, id: \.self) { detail in
                            Text(detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptInner.opacity(0.7) : Color.white.opacity(0.04))
                                )
                        }
                    }
                }

                HStack {
                    Spacer(minLength: 0)

                    Button("Refuser", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)

                    Button("Autoriser", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(usesCodexVisualStyle ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexEventCornerRadius : 0, style: .continuous)
                .fill(usesCodexVisualStyle ? AppChromePalette.codexEventFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexEventCornerRadius : 0, style: .continuous)
                .strokeBorder(usesCodexVisualStyle ? AppChromePalette.codexPromptStroke.opacity(0.75) : Color.clear, lineWidth: usesCodexVisualStyle ? 0.8 : 0)
        )
    }
}

private struct ChatApprovalFieldRow: View {
    let field: ChatInteractiveField
    @ObservedObject var formModel: ChatApprovalFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                if field.isRequired {
                    Text("*")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }

            if let prompt = field.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch field.kind {
            case .boolean:
                Toggle(isOn: formModel.boolBinding(for: field)) {
                    Text(formModel.boolBinding(for: field).wrappedValue ? "Oui" : "Non")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

            case .singleChoice:
                Picker("", selection: formModel.textBinding(for: field)) {
                    ForEach(field.options) { option in
                        Text(option.label).tag(option.label)
                    }
                    if field.supportsCustomValue {
                        Text("Autre…").tag("__other__")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if formModel.textBinding(for: field).wrappedValue == "__other__" {
                    TextField("Autre valeur", text: formModel.otherTextBinding(for: field))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

            case .secureText:
                SecureField(field.placeholder ?? "Valeur", text: formModel.textBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

            case .text, .integer, .number:
                TextField(field.placeholder ?? "Valeur", text: formModel.textBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
    }
}

struct ChatCustomInstructionsSheet: View {
    let summaryLabel: String
    let hasAnyInstructions: Bool
    @Binding var globalText: String
    @Binding var sessionText: String
    let onResetGlobal: () -> Void
    let onResetSession: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppStrings.instructions)
                                .font(.system(size: 15, weight: .semibold))
                            Text(AppStrings.codexPromptOnly)
                                .font(.system(size: 11))
                                .foregroundStyle(AppChromePalette.codexMutedText)
                        }

                        Spacer(minLength: 0)

                        Text(summaryLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hasAnyInstructions ? AppChromePalette.codexIDEContext : AppChromePalette.codexMutedText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppChromePalette.codexPromptInner))
                    }

                    customInstructionsEditorSection(
                        title: AppStrings.globalInstructions,
                        subtitle: AppStrings.globalInstructionsSubtitle,
                        text: $globalText,
                        placeholder: "E.g. Respond in simple, direct English."
                    )

                    customInstructionsEditorSection(
                        title: AppStrings.sessionInstructions,
                        subtitle: AppStrings.sessionInstructionsSubtitle,
                        text: $sessionText,
                        placeholder: "E.g. In this conversation, be concise and always cite files."
                    )

                    HStack(spacing: 10) {
                        Button("Reset global", action: onResetGlobal)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                        Button("Reset session", action: onResetSession)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()
                .overlay(AppChromePalette.codexPromptDivider.opacity(0.65))

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(AppStrings.cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button(AppStrings.save, action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(AppChromePalette.codexCanvas)
        }
        .frame(width: 620)
        .frame(minHeight: 430, idealHeight: 500, maxHeight: 620, alignment: .topLeading)
        .background(AppChromePalette.codexCanvas)
    }

    private func customInstructionsEditorSection(
        title: String,
        subtitle: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppChromePalette.codexMutedText)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)

                if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(AppChromePalette.codexMutedText.opacity(0.7))
                        .padding(.top, 8)
                        .padding(.leading, 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 112, maxHeight: 140)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppChromePalette.codexPromptShell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppChromePalette.codexPromptStroke, lineWidth: 1)
            )
        }
    }
}

struct ChatComposerBar<
    Provider: HeadlessChatProviding,
    ApprovalContent: View,
    SuggestionsContent: View,
    AttachmentsContent: View,
    PromptFieldContent: View,
    StandardFooterContent: View,
    CodexFooterContent: View,
    CodexSecondaryContent: View
>: View {
    @ObservedObject var provider: Provider

    let usesCodexVisualStyle: Bool
    let selection: ChatSelectionInfo?
    let showsSuggestions: Bool
    let showsAttachments: Bool
    let onInstallPasteMonitor: () -> Void
    let onRemovePasteMonitor: () -> Void
    let onExitStop: () -> Void
    let approvalContent: (ChatApprovalRequest) -> ApprovalContent
    let suggestionsContent: () -> SuggestionsContent
    let attachmentsContent: () -> AttachmentsContent
    let promptFieldContent: () -> PromptFieldContent
    let standardFooterContent: () -> StandardFooterContent
    let codexFooterContent: () -> CodexFooterContent
    let codexSecondaryContent: () -> CodexSecondaryContent

    var body: some View {
        Group {
            if usesCodexVisualStyle {
                codexBody
            } else {
                standardBody
            }
        }
        .onAppear(perform: onInstallPasteMonitor)
        .onDisappear(perform: onRemovePasteMonitor)
        .onExitCommand {
            if provider.isProcessing {
                onExitStop()
            }
        }
    }

    private var standardBody: some View {
        VStack(spacing: 0) {
            if let selection {
                ChatSelectionSummaryBar(selection: selection, usesCodexVisualStyle: false)
                Divider()
            }

            if let approval = provider.pendingApprovalRequest {
                approvalContent(approval)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.08))
                Divider()
            }

            if showsSuggestions {
                suggestionsContent()
            }

            if showsAttachments {
                attachmentsContent()
            }

            promptFieldContent()
            standardFooterContent()
        }
        .background(AppChromePalette.surfaceSubbar)
    }

    private var codexBody: some View {
        VStack(spacing: 6) {
            if let approval = provider.pendingApprovalRequest {
                approvalContent(approval)
                    .padding(.horizontal, 14)
            }

            if showsSuggestions {
                suggestionsContent()
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 0) {
                if let selection {
                    ChatSelectionSummaryBar(selection: selection, usesCodexVisualStyle: true)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                }

                if showsAttachments {
                    attachmentsContent()
                        .padding(.top, selection == nil ? 8 : 5)
                }

                promptFieldContent()

                Rectangle()
                    .fill(AppChromePalette.codexPromptDivider.opacity(0.55))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                codexFooterContent()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppChromePalette.codexPromptShell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(AppChromePalette.codexPromptStroke, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)

            codexSecondaryContent()
                .padding(.horizontal, 10)
                .padding(.bottom, 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 0)
        .padding(.vertical, 6)
        .background(AppChromePalette.codexCanvas)
    }
}

private struct ChatSelectionSummaryBar: View {
    let selection: ChatSelectionInfo
    let usesCodexVisualStyle: Bool

    var body: some View {
        HStack(spacing: usesCodexVisualStyle ? 8 : 6) {
            Image(systemName: usesCodexVisualStyle ? "sparkles" : "text.quote")
                .font(.system(size: usesCodexVisualStyle ? 10 : 9, weight: .semibold))
                .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexIDEContext : .orange)

            Text(selection.fileName)
                .font(.system(size: usesCodexVisualStyle ? 11 : 10, weight: usesCodexVisualStyle ? .medium : .medium, design: usesCodexVisualStyle ? .default : .monospaced))
                .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("·")
                .foregroundStyle((usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary).opacity(0.4))

            Text(AppStrings.lineCount(selection.lineCount))
                .font(.system(size: usesCodexVisualStyle ? 11 : 10, weight: usesCodexVisualStyle ? .medium : .regular, design: usesCodexVisualStyle ? .default : .monospaced))
                .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)

            Spacer(minLength: 0)
        }
    }
}
