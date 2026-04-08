import Foundation
import CoreServices

public struct FSEvent: Sendable {
    public let path: String
    public let isCreated: Bool
    public let isRemoved: Bool
    public let isModified: Bool
    public let isRenamed: Bool
}

/// Watches a directory for file system changes using FSEventStream.
public final class FSEventStreamWatcher: @unchecked Sendable {
    private let path: String
    private let debounceInterval: TimeInterval
    private let callback: @Sendable ([FSEvent]) -> Void
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.punkrecords.fsevent", qos: .utility)

    // Debounce state
    private var pendingEvents: [String: FSEvent] = [:]
    private var debounceTimer: DispatchWorkItem?
    private let lock = NSLock()

    public init(
        path: String,
        debounceInterval: TimeInterval = 0.3,
        callback: @escaping @Sendable ([FSEvent]) -> Void
    ) {
        self.path = path
        self.debounceInterval = debounceInterval
        self.callback = callback
    }

    deinit {
        stop()
    }

    public func start() {
        let pathCFArray = [path] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            pathCFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    fileprivate func handleEvents(_ events: [FSEvent]) {
        lock.lock()
        for event in events {
            pendingEvents[event.path] = event
        }
        debounceTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let events = Array(self.pendingEvents.values)
            self.pendingEvents.removeAll()
            self.lock.unlock()
            if !events.isEmpty {
                self.callback(events)
            }
        }
        debounceTimer = workItem
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}

private func fsEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSEventStreamWatcher>.fromOpaque(info).takeUnretainedValue()

    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]

    var events: [FSEvent] = []
    for i in 0..<numEvents {
        let flags = eventFlags[i]
        let event = FSEvent(
            path: paths[i],
            isCreated: flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0,
            isRemoved: flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0,
            isModified: flags & UInt32(kFSEventStreamEventFlagItemModified) != 0,
            isRenamed: flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        )
        events.append(event)
    }

    watcher.handleEvents(events)
}
