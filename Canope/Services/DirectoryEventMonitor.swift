import Foundation
import Darwin

final class DirectoryEventMonitor {
    private let directoryURL: URL
    private let debounceInterval: TimeInterval
    private let eventHandler: @Sendable () -> Void
    private let sourceQueue: DispatchQueue

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingEvent: DispatchWorkItem?

    init(
        directoryURL: URL,
        debounceInterval: TimeInterval = 0.12,
        eventHandler: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.debounceInterval = debounceInterval
        self.eventHandler = eventHandler
        self.sourceQueue = DispatchQueue(label: "canope.directory-monitor.\(directoryURL.path)")
    }

    deinit {
        stop()
    }

    func start() {
        guard source == nil else { return }

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: sourceQueue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleEvent()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        fileDescriptor = descriptor
        self.source = source
        source.resume()
    }

    func stop() {
        pendingEvent?.cancel()
        pendingEvent = nil
        source?.cancel()
        source = nil
    }

    private func scheduleEvent() {
        pendingEvent?.cancel()
        let workItem = DispatchWorkItem(block: eventHandler)
        pendingEvent = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
