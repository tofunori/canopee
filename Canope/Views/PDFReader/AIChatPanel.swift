import SwiftUI
@preconcurrency import SwiftTerm
import PDFKit
import MetalKit

extension Notification.Name {
    static let canopeSendPromptToTerminal = Notification.Name("canopeSendPromptToTerminal")
    static let canopeTerminalAddTab = Notification.Name("canopeTerminalAddTab")
}

// MARK: - SwiftTerm + Metal NSViewRepresentable

struct TerminalViewWrapper: NSViewRepresentable {
    let tabID: UUID
    let workspaceState: TerminalWorkspaceState
    let pane: TerminalSessionPane
    let isActive: Bool
    let optionAsMetaKey: Bool
    let appearance: TerminalAppearanceState
    let colorScheme: ColorScheme
    let startupWorkingDirectory: URL?

    func makeNSView(context: Context) -> FocusAwareLocalProcessTerminalView {
        if let existing = workspaceState.terminalView(for: tabID, in: pane) {
            existing.shouldCaptureFocusFromClicks = isActive
            existing.optionAsMetaKey = optionAsMetaKey
            existing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            existing.setContentHuggingPriority(.defaultLow, for: .horizontal)
            TerminalAppearanceApplicator.apply(appearance: appearance, colorScheme: colorScheme, to: existing)
            return existing
        }

        let tv = FocusAwareLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.optionAsMetaKey = optionAsMetaKey
        tv.shouldCaptureFocusFromClicks = isActive
        TerminalAppearanceApplicator.apply(appearance: appearance, colorScheme: colorScheme, to: tv)

        if !AppRuntime.isRunningTests {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            ClaudeIDEBridgeService.shared.startIfNeeded()
            env = ClaudeCLIWrapperService.shared.apply(to: env, shellPath: shell)
            env.append(contentsOf: CanopeContextFiles.terminalEnvironment)
            tv.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: shell,
                currentDirectory: startupWorkingDirectory?.path
            )
            tv.schedulePreferredCursorWarmup()
            ChildProcessRegistry.shared.track(terminalView: tv)
        }

        enableMetalWhenReady(for: tv)

        DispatchQueue.main.async {
            workspaceState.registerTerminalView(tv, for: tabID, in: pane)
        }

        return tv
    }

    func updateNSView(_ nsView: FocusAwareLocalProcessTerminalView, context: Context) {
        nsView.shouldCaptureFocusFromClicks = isActive
        nsView.optionAsMetaKey = optionAsMetaKey
        TerminalAppearanceApplicator.apply(appearance: appearance, colorScheme: colorScheme, to: nsView)
    }

    static func dismantleNSView(_ nsView: FocusAwareLocalProcessTerminalView, coordinator: ()) {
        nsView.detachFromSwiftUIHierarchy()
    }

    private func enableMetalWhenReady(for tv: FocusAwareLocalProcessTerminalView, remainingAttempts: Int = 40) {
        guard remainingAttempts > 0 else { return }
        guard tv.window != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                enableMetalWhenReady(for: tv, remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        do {
            try tv.setUseMetal(true)
            if tv.isUsingMetalRenderer {
                tv.metalBufferingMode = .perRowPersistent
                tv.applyCursorStyle(appearance.cursorStyle.swiftTermValue)
                tv.schedulePreferredCursorWarmup()
                // Ensure MTKView forwards events to terminal
                for subview in tv.subviews {
                    if let mtkView = subview as? MTKView {
                        mtkView.nextResponder = tv
                    }
                }
                tv.activateInputFocus()
                print("[Canope] Metal GPU rendering active ✓")
            }
        } catch {
            print("[Canope] Metal not available, using CoreGraphics: \(error)")
        }
    }
}

/// Transparent view that forwards all mouse/scroll events to a target view
final class EventForwardingView: NSView {
    weak var target: NSView?

    init(frame: NSRect, target: NSView) {
        self.target = target
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        target?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        target?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        target?.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        target?.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        target?.rightMouseDown(with: event)
    }
}

@MainActor
final class FocusAwareLocalProcessTerminalView: LocalProcessTerminalView, ChildProcessTerminable {
    var shouldCaptureFocusFromClicks = true
    private var preferredCursorStyle: CursorStyle = defaultTerminalCursorStyle
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private weak var focusClickGesture: NSClickGestureRecognizer?
    private var mouseWheelAccumulator: CGFloat = 0
    private var alternateWheelAccumulator: CGFloat = 0

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        source.options.cursorStyle = preferredCursorStyle
        super.cursorStyleChanged(source: source, newStyle: preferredCursorStyle)
    }

    func terminateTrackedProcess() {
        terminate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitors()
        } else {
            installFocusClickGestureIfNeeded()
            installClickMonitorIfNeeded()
            installKeyMonitorIfNeeded()
            installScrollMonitorIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.activateInputFocus()
                self?.applyPreferredCursorAppearance()
                self?.schedulePreferredCursorWarmup()
            }
        }
    }

    @objc private func handleFocusClickGesture(_ recognizer: NSClickGestureRecognizer) {
        guard shouldCaptureFocusFromClicks else { return }
        guard recognizer.state == .ended else { return }
        activateInputFocus()
    }

    private func installFocusClickGestureIfNeeded() {
        guard focusClickGesture == nil else { return }
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleFocusClickGesture(_:)))
        recognizer.buttonMask = 0x1
        recognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(recognizer)
        focusClickGesture = recognizer
    }

    func activateInputFocus() {
        guard let window else { return }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        applyPreferredCursorAppearance()
    }

    private func applyPreferredCursorAppearance() {
        let terminal = getTerminal()
        terminal.setCursorStyle(preferredCursorStyle)
        terminal.showCursor()
        needsDisplay = true
    }

    func schedulePreferredCursorWarmup() {
        let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.7]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyPreferredCursorAppearance()
            }
        }
    }

    func prepareForRemoval() {
        removeEventMonitors()
        terminate()
    }

    func detachFromSwiftUIHierarchy() {
        removeEventMonitors()
    }

    private func installClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard shouldCaptureFocusFromClicks, let window = self.window else { return event }
            guard event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
            return event
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard event.window === window, window.firstResponder === self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.option),
                  !flags.contains(.command),
                  !flags.contains(.control) else {
                return event
            }

            if self.optionAsMetaKey,
               let rawCharacter = event.charactersIgnoringModifiers,
               !rawCharacter.isEmpty {
                self.send(txt: "\u{1b}\(rawCharacter)")
                return nil
            }

            let terminal = self.getTerminal()
            if !self.optionAsMetaKey,
               !terminal.keyboardEnhancementFlags.isEmpty,
               let composedCharacter = event.characters,
               let rawCharacter = event.charactersIgnoringModifiers,
               !composedCharacter.isEmpty,
               composedCharacter != rawCharacter {
                self.send(txt: composedCharacter)
                return nil
            }

            return event
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func removeEventMonitors() {
        removeClickMonitor()
        removeKeyMonitor()
        removeScrollMonitor()
    }

    private func installScrollMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard event.window === window else { return event }
            guard event.scrollingDeltaY != 0 else { return event }

            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            let terminal = self.getTerminal()

            // Mouse mode active: prefer SGR mouse wheel events for the TUI app
            // (Claude Code, vim, tmux, etc.). Only consume the event once we
            // actually emitted a scroll action; otherwise leave room for
            // alternate-screen fallbacks or native handling.
            if terminal.mouseMode != .off {
                if self.sendMouseWheelEvent(event, terminal: terminal) {
                    return nil
                }

                if !self.canScroll {
                    if self.sendAlternateBufferScrollFallback(event, terminal: terminal) {
                        return nil
                    }
                }

                return event
            }

            // Alternate buffer without native scrollback (e.g. Claude Code/Codex
            // full-screen views): try paging first, then cursor-key fallback.
            if !self.canScroll {
                if self.sendAlternateBufferScrollFallback(event, terminal: terminal) {
                    return nil
                }
                return event
            }

            return event
        }
    }

    private func removeScrollMonitor() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    private func resetWheelAccumulatorsForDirectionChange(deltaY: CGFloat) {
        if mouseWheelAccumulator != 0, deltaY.sign != mouseWheelAccumulator.sign {
            mouseWheelAccumulator = 0
        }
        if alternateWheelAccumulator != 0, deltaY.sign != alternateWheelAccumulator.sign {
            alternateWheelAccumulator = 0
        }
    }

    @discardableResult
    private func sendMouseWheelEvent(_ event: NSEvent, terminal: Terminal) -> Bool {
        let flags = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        let safeWidth = max(bounds.width, 1)
        let safeHeight = max(bounds.height, 1)
        let cellWidth = safeWidth / CGFloat(max(terminal.cols, 1))
        let cellHeight = safeHeight / CGFloat(max(terminal.rows, 1))

        let clampedX = min(max(point.x, 0), safeWidth - 1)
        let clampedY = min(max(point.y, 0), safeHeight - 1)
        let column = min(max(Int(clampedX / max(cellWidth, 1)), 0), max(terminal.cols - 1, 0))
        let rowFromTop = min(max(Int((safeHeight - clampedY) / max(cellHeight, 1)), 0), max(terminal.rows - 1, 0))
        let pixelX = Int(clampedX)
        let pixelY = Int(safeHeight - clampedY)

        let deltaY = event.scrollingDeltaY
        resetWheelAccumulatorsForDirectionChange(deltaY: deltaY)

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        mouseWheelAccumulator += deltaY
        let steps = min(max(Int(abs(mouseWheelAccumulator) / threshold), 0), 3)
        guard steps > 0 else { return false }
        mouseWheelAccumulator -= CGFloat(steps) * threshold * (mouseWheelAccumulator >= 0 ? 1 : -1)

        let button = deltaY > 0 ? 4 : 5
        let buttonFlags = terminal.encodeButton(
            button: button,
            release: false,
            shift: flags.contains(.shift),
            meta: flags.contains(.option),
            control: flags.contains(.control)
        )

        for _ in 0..<steps {
            terminal.sendEvent(
                buttonFlags: buttonFlags,
                x: column,
                y: rowFromTop,
                pixelX: pixelX,
                pixelY: pixelY
            )
        }
        return true
    }

    @discardableResult
    private func sendAlternateBufferScrollFallback(_ event: NSEvent, terminal: Terminal) -> Bool {
        let deltaY = event.scrollingDeltaY
        resetWheelAccumulatorsForDirectionChange(deltaY: deltaY)

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
        alternateWheelAccumulator += deltaY
        let steps = min(max(Int(abs(alternateWheelAccumulator) / threshold), 0), 2)
        guard steps > 0 else { return false }
        alternateWheelAccumulator -= CGFloat(steps) * threshold * (alternateWheelAccumulator >= 0 ? 1 : -1)

        let sequence = deltaY > 0 ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown
        for _ in 0..<steps {
            send(data: sequence[...])
        }
        return true
    }

}

@MainActor
extension FocusAwareLocalProcessTerminalView: TerminalAppearanceApplying {
    func setAnsi256PaletteStrategy(_ strategy: Ansi256PaletteStrategy) {
        getTerminal().ansi256PaletteStrategy = strategy
    }

    func setTerminalBaseColors(background: SwiftTerm.Color, foreground: SwiftTerm.Color) {
        let terminal = getTerminal()
        terminal.backgroundColor = background
        terminal.foregroundColor = foreground
    }

    func setScrollbackLines(_ lines: Int?) {
        changeScrollback(lines)
    }

    func applyCursorStyle(_ style: CursorStyle) {
        preferredCursorStyle = style
        let terminal = getTerminal()
        terminal.options.cursorStyle = style
        terminal.setCursorStyle(style)
        applyPreferredCursorAppearance()
    }
}
