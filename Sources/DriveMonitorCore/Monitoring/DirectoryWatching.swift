import CoreServices
import Foundation

public protocol DirectoryWatching: Sendable {
    func start(root: URL, handler: @escaping @Sendable (String) -> Void) throws
    func stop()
}

public enum DirectoryWatchingError: Error, Sendable {
    case cannotCreateStream
    case cannotStartStream
}

/// The lock owns the stream lifecycle. The stream owns its callback context.
public final class FSEventsDirectoryWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.devenio.Unstuckerator.events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var delivery: EventDelivery?

    public init() {}

    public func start(root: URL, handler: @escaping @Sendable (String) -> Void) throws {
        try lock.withLock {
            stopLocked()
            let delivery = EventDelivery(rootPath: root.path, handler: handler)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(delivery).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    return UnsafeRawPointer(Unmanaged<EventDelivery>.fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    if let pointer { Unmanaged<EventDelivery>.fromOpaque(pointer).release() }
                },
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, context, count, paths, eventFlags, _ in
                    guard let context else { return }
                    let delivery = Unmanaged<EventDelivery>.fromOpaque(context).takeUnretainedValue()
                    let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    for index in 0..<count {
                        let flags = eventFlags[index]
                        let needsRescan = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                        delivery.send(needsRescan ? delivery.rootPath : String(cString: strings[index]))
                    }
                },
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                flags
            ) else { throw DirectoryWatchingError.cannotCreateStream }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                delivery.cancel()
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                throw DirectoryWatchingError.cannotStartStream
            }
            self.delivery = delivery
            self.stream = stream
        }
    }

    public func stop() { lock.withLock { stopLocked() } }

    private func stopLocked() {
        delivery?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        delivery = nil
    }

    deinit { stop() }
}

private final class EventDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    let rootPath: String
    private let handler: @Sendable (String) -> Void

    init(rootPath: String, handler: @escaping @Sendable (String) -> Void) { self.rootPath = rootPath; self.handler = handler }
    func cancel() { lock.withLock { active = false } }
    func send(_ path: String) {
        // The engine also checks its generation after the asynchronous actor hop.
        if lock.withLock({ active }) { handler(path) }
    }
}
