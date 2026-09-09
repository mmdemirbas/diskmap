import Darwin
import Foundation

/// FSEvents wrapper. `kFSEventStreamCreateFlagFileEvents` gives per-file paths
/// instead of directory-level hints, so a change can be applied to exactly one
/// directory rather than triggering a broad rescan.
public final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "diskmap.fsevents")
    private let handler: ([String]) -> Void
    private let paths: [String]
    private let latency: TimeInterval

    public init(paths: [String], latency: TimeInterval = 0.4, handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
                         | kFSEventStreamCreateFlagFileEvents
                         | kFSEventStreamCreateFlagNoDefer
                         | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            me.handler(Array(cfPaths.prefix(count)))
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                     paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     latency, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
