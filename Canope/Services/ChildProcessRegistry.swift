import Foundation
import Darwin

@MainActor
protocol ChildProcessTerminable: AnyObject {
    func terminateTrackedProcess()
}

private final class WeakTerminalBox {
    weak var value: ChildProcessTerminable?

    init(_ value: ChildProcessTerminable) {
        self.value = value
    }
}

final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    private var runningProcesses: [ObjectIdentifier: Process] = [:]
    private var terminalViews: [ObjectIdentifier: WeakTerminalBox] = [:]

    private init() {}

    func track(process: Process) {
        lock.withLock {
            runningProcesses[ObjectIdentifier(process)] = process
        }
    }

    func untrack(process: Process) {
        lock.withLock {
            runningProcesses.removeValue(forKey: ObjectIdentifier(process))
        }
    }

    @MainActor
    func track(terminalView: ChildProcessTerminable) {
        lock.withLock {
            cleanupLocked()
            terminalViews[ObjectIdentifier(terminalView)] = WeakTerminalBox(terminalView)
        }
    }

    @MainActor
    func untrack(terminalView: ChildProcessTerminable) {
        _ = lock.withLock {
            terminalViews.removeValue(forKey: ObjectIdentifier(terminalView))
        }
    }

    @MainActor
    func terminateAllTrackedChildren() {
        let snapshot = lock.withLock { () -> ([Process], [ChildProcessTerminable]) in
            cleanupLocked()
            let processes = Array(runningProcesses.values)
            let terminals = terminalViews.values.compactMap(\.value)
            return (processes, terminals)
        }

        for terminal in snapshot.1 {
            terminal.terminateTrackedProcess()
        }

        for process in snapshot.0 {
            terminate(process: process)
        }
    }

    private func terminate(process: Process) {
        guard process.isRunning else { return }

        process.terminate()

        for _ in 0..<20 {
            if !process.isRunning {
                return
            }
            usleep(50_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func cleanupLocked() {
        terminalViews = terminalViews.filter { $0.value.value != nil }
        runningProcesses = runningProcesses.filter { $0.value.isRunning }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
