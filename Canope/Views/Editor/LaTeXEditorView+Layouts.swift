import SwiftUI

// MARK: - Pane Layouts

extension LaTeXEditorView {
    @ViewBuilder
    var workAreaPane: some View {
        if isActive && showTerminal && showPDFPreview && splitLayout == .horizontal {
            horizontalThreePaneLayout
        } else if isActive && showTerminal {
            switch panelArrangement {
            case .terminalEditorPDF:
                HSplitView {
                    embeddedTerminalPane
                    editorAndPDFPane
                        .layoutPriority(1)
                }
            case .editorPDFTerminal, .pdfEditorTerminal:
                HSplitView {
                    editorAndPDFPane
                        .layoutPriority(1)
                    embeddedTerminalPane
                }
            }
        } else {
            editorAndPDFPane
        }
    }

    @ViewBuilder
    var horizontalThreePaneLayout: some View {
        GeometryReader { proxy in
            let roles = threePaneRoles
            let totalContentWidth = max(0, proxy.size.width - (ThreePaneSizing.dividerWidth * 2))
            let widths = resolvedThreePaneWidths(for: roles, totalContentWidth: totalContentWidth)

            HStack(spacing: 0) {
                threePaneView(for: roles.0)
                    .frame(width: widths.left)

                threePaneResizeHandle {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.resizeLeftRight.set()
                } onExit: {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.arrow.set()
                } drag: {
                    AnyGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.threePaneCoordinateSpace))
                        .onChanged { value in
                            if !isDraggingThreePaneDivider {
                                isDraggingThreePaneDivider = true
                                NSCursor.resizeLeftRight.set()
                            }
                            if threePaneDragStartLeftWidth == nil {
                                threePaneDragStartLeftWidth = widths.left
                            }
                            let startLeft = threePaneDragStartLeftWidth ?? widths.left
                            let leftMin = paneMinWidth(for: roles.0)
                            let middleMin = paneMinWidth(for: roles.1)
                            let maxLeft = max(leftMin, totalContentWidth - widths.right - middleMin)
                            threePaneLeftWidth = min(max(startLeft + value.translation.width, leftMin), maxLeft)
                        }
                        .onEnded { _ in
                            threePaneDragStartLeftWidth = nil
                            isDraggingThreePaneDivider = false
                            NSCursor.arrow.set()
                        }
                    )
                }

                threePaneView(for: roles.1)
                    .frame(width: widths.middle)

                threePaneResizeHandle {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.resizeLeftRight.set()
                } onExit: {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.arrow.set()
                } drag: {
                    AnyGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.threePaneCoordinateSpace))
                        .onChanged { value in
                            if !isDraggingThreePaneDivider {
                                isDraggingThreePaneDivider = true
                                NSCursor.resizeLeftRight.set()
                            }
                            if threePaneDragStartRightWidth == nil {
                                threePaneDragStartRightWidth = widths.right
                            }
                            let startRight = threePaneDragStartRightWidth ?? widths.right
                            let middleMin = paneMinWidth(for: roles.1)
                            let rightMin = paneMinWidth(for: roles.2)
                            let maxRight = max(rightMin, totalContentWidth - widths.left - middleMin)
                            threePaneRightWidth = min(max(startRight - value.translation.width, rightMin), maxRight)
                        }
                        .onEnded { _ in
                            threePaneDragStartRightWidth = nil
                            isDraggingThreePaneDivider = false
                            NSCursor.arrow.set()
                        }
                    )
                }

                threePaneView(for: roles.2)
                    .frame(width: widths.right)
            }
            .coordinateSpace(name: Self.threePaneCoordinateSpace)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    var threePaneRoles: (ThreePaneRole, ThreePaneRole, ThreePaneRole) {
        switch panelArrangement {
        case .terminalEditorPDF:
            return (.terminal, .editor, .pdf)
        case .editorPDFTerminal:
            return (.editor, .pdf, .terminal)
        case .pdfEditorTerminal:
            return (.pdf, .editor, .terminal)
        }
    }

    @ViewBuilder
    func threePaneView(for role: ThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .pdf:
            pdfPane
        }
    }

    func paneMinWidth(for role: ThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 160
        case .editor:
            return 160
        case .pdf:
            return 180
        }
    }

    func paneIdealWidth(for role: ThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 320
        case .editor:
            return 620
        case .pdf:
            return 320
        }
    }

    func resolvedThreePaneWidths(
        for roles: (ThreePaneRole, ThreePaneRole, ThreePaneRole),
        totalContentWidth: CGFloat
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let leftMin = paneMinWidth(for: roles.0)
        let middleMin = paneMinWidth(for: roles.1)
        let rightMin = paneMinWidth(for: roles.2)
        let minimumTotal = leftMin + middleMin + rightMin
        let availableWidth = max(totalContentWidth, minimumTotal)

        let seededLeft = threePaneLeftWidth ?? paneIdealWidth(for: roles.0)
        let seededRight = threePaneRightWidth ?? paneIdealWidth(for: roles.2)

        let leftMaxBeforeRightClamp = max(leftMin, availableWidth - middleMin - rightMin)
        let left = min(max(seededLeft, leftMin), leftMaxBeforeRightClamp)

        let rightMaxBeforeLeftClamp = max(rightMin, availableWidth - left - middleMin)
        let right = min(max(seededRight, rightMin), rightMaxBeforeLeftClamp)

        let leftMax = max(leftMin, availableWidth - right - middleMin)
        let clampedLeft = min(left, leftMax)
        let rightMax = max(rightMin, availableWidth - clampedLeft - middleMin)
        let clampedRight = min(right, rightMax)
        let middle = max(middleMin, availableWidth - clampedLeft - clampedRight)

        return (clampedLeft, middle, clampedRight)
    }

    func threePaneResizeHandle(
        onEnter: @escaping () -> Void,
        onExit: @escaping () -> Void,
        drag: @escaping () -> AnyGesture<DragGesture.Value>
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: ThreePaneSizing.dividerWidth)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
            }
            .onHover { hovering in
                if hovering {
                    onEnter()
                } else {
                    onExit()
                }
            }
            .gesture(drag())
    }

    @ViewBuilder
    var editorAndPDFPane: some View {
        if !showPDFPreview {
            editorPane
        } else if splitLayout == .horizontal {
            HSplitView {
                if isPDFLeadingInLayout { pdfPane }
                editorPane
                if !isPDFLeadingInLayout { pdfPane }
            }
        } else if splitLayout == .vertical {
            VSplitView {
                if isPDFLeadingInLayout { pdfPane }
                editorPane
                if !isPDFLeadingInLayout { pdfPane }
            }
        } else {
            editorPane
        }
    }

    var embeddedTerminalPane: some View {
        TerminalPanel(
            workspaceState: terminalWorkspaceState,
            document: nil,
            isVisible: isActive && showTerminal,
            topInset: 0,
            showsInlineControls: false
        )
        .frame(minWidth: 160, idealWidth: 320, maxWidth: .infinity)
    }

    var editorPane: some View {
        VStack(spacing: 0) {
            if let editorTabBar {
                editorTabBar
                Divider()
            }

            LaTeXTextEditor(
                fileURL: fileURL,
                text: $text,
                errorLines: errorLines,
                fontSize: editorFontSize,
                theme: Self.editorThemes[editorTheme],
                baselineText: savedText,
                resolvedAnnotations: resolvedLaTeXAnnotations,
                onSelectionChange: { selectedEditorRange = $0 },
                onAnnotationActivate: beginEditingAnnotation,
                onCreateAnnotationFromSelection: beginAnnotationFromSelection,
                onTextChange: reconcileAnnotations
            )
            if showErrors {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        Image(systemName: errors.contains(where: { !$0.isWarning }) ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(errors.contains(where: { !$0.isWarning }) ? .red : .green)
                        Text(errors.isEmpty ? "Compilation réussie" : "\(errors.filter { !$0.isWarning }.count) erreur(s), \(errors.filter { $0.isWarning }.count) avertissement(s)")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { showErrors = false }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.bar)

                    // Console output
                    ScrollView {
                        Text(compileOutput.isEmpty ? "Aucune sortie" : compileOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                .frame(height: 150)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(minWidth: 160, idealWidth: 620, maxWidth: .infinity)
        .layoutPriority(1)
    }
}
