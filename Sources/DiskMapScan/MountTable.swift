import Darwin
import Foundation

/// The set of mount points on this machine.
///
/// Device numbers cannot be used to tell volumes apart on APFS: every volume in
/// a container reports the same `st_dev`, so `/` and `/System/Volumes/Data`
/// look identical to `stat` despite being separate volumes on separate
/// partitions. The mount table is the only reliable answer.
public enum MountTable {
    public static func mountPoints() -> Set<String> {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var out = Set<String>()
        for i in 0..<Int(count) {
            let name = withUnsafeBytes(of: buffer[i].f_mntonname) { raw -> String? in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
            }
            if let name, !name.isEmpty { out.insert(name) }
        }
        return out
    }
}
