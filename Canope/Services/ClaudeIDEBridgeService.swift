import Foundation
import Darwin

final class ClaudeIDEBridgeService: @unchecked Sendable {
    static let shared = ClaudeIDEBridgeService()

    private let lock = NSLock()
    private var bridgeProcess: Process?
    private var didRefreshExternalBridge = false

    private init() {}

    func startIfNeeded() {
        CanopeContextFiles.writeClaudeIDEMcpConfig()
        BridgeCommandWatcher.shared.start()

        lock.withLock {
            if let bridgeProcess, bridgeProcess.isRunning {
                return
            }

            if !didRefreshExternalBridge, isBridgeHealthy() {
                terminateExternalBridgeProcesses()
                didRefreshExternalBridge = true
            }

            if isBridgeHealthy() {
                return
            }

            if let bridgeProcess, bridgeProcess.isRunning {
                return
            }

            guard let pythonPath = ExecutableLocator.find(
                "python3",
                preferredPaths: [
                    "/opt/homebrew/bin/python3",
                    "/usr/bin/python3",
                ]
            ) else {
                print("[Canope] Claude IDE bridge not started: python3 not found")
                return
            }

            guard let scriptURL = resolveBridgeScriptURL() else {
                print("[Canope] Claude IDE bridge not started: script not found")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [
                scriptURL.path,
                "--port", "8765",
                "--state-file", CanopeContextFiles.ideSelectionStatePaths[0],
            ]

            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.terminationHandler = { [weak self] process in
                ChildProcessRegistry.shared.untrack(process: process)
                self?.lock.withLock {
                    if self?.bridgeProcess === process {
                        self?.bridgeProcess = nil
                    }
                }
            }

            do {
                try process.run()
                bridgeProcess = process
                didRefreshExternalBridge = true
                ChildProcessRegistry.shared.track(process: process)
            } catch {
                bridgeProcess = nil
                print("[Canope] Claude IDE bridge failed to launch: \(error.localizedDescription)")
            }
        }
    }

    private func resolveBridgeScriptURL() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "canope_claude_ide_bridge",
            withExtension: "py"
        ) {
            return bundled
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallback = repoRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("canope_claude_ide_bridge.py")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func isBridgeHealthy(timeout: TimeInterval = 0.25) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8765).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var timeoutValue = timeval(
            tv_sec: Int(timeout.rounded(.down)),
            tv_usec: __darwin_suseconds_t((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.stride))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.stride))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
            }
        }
    }

    private func terminateExternalBridgeProcesses() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "canope_claude_ide_bridge.py"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[Canope] Unable to refresh old bridge processes: \(error.localizedDescription)")
        }
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
