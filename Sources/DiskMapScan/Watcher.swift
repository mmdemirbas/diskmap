import Darwin
import Foundation

/// FSEvents wrapper. `kFSEventStreamCreateFlagFileEvents` gives per-file paths
/// instead of directory-level hints, so a change can be applied to exactly one
/// directory rather than triggering a broad rescan.
public final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "diskmap.fsevents")
    private let handler: ([RawPath]) -> Void
    private let paths: [String]
    private let latency: TimeInterval

    public init(paths: [String], latency: TimeInterval = 0.4,
                handler: @escaping ([RawPath]) -> Void) {
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
        // Deliberately not `UseCFTypes`. That hands the paths over as
        // CFStrings, and a name the volume allowed but Unicode does not comes
        // back with U+FFFD where the awkward bytes were — after which the
        // directory it names cannot be found in the tree and stops updating.
        // Without it the paths are C strings, which are the bytes.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                         | kFSEventStreamCreateFlagNoDefer
                         | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let me = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let raw = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var out: [RawPath] = []
            out.reserveCapacity(count)
            for index in 0..<count {
                guard let entry = raw[index] else { continue }
                out.append(RawPath(bytes: Array(UnsafeBufferPointer(
                    start: UnsafeRawPointer(entry).assumingMemoryBound(to: UInt8.self),
                    count: strlen(entry)))))
            }
            me.handler(out)
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
