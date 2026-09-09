import Darwin
import Foundation

/// The four numbers macOS reports for a volume, and why they disagree.
///
/// Finder's "available" is `importantUsage`, which adds *purgeable* space
/// (evictable iCloud content, caches, local snapshots) to the real free space.
/// On a disk that leans on iCloud Drive the gap runs to terabytes, which is why
/// Finder can claim a nearly empty disk that is in fact nearly full.
public struct VolumeInfo: Sendable {
    public var path: String
    public var name: String
    public var total: Int64
    /// Bytes you can write right now without macOS deleting anything.
    public var trueAvailable: Int64
    /// What Finder shows. Includes purgeable.
    public var finderAvailable: Int64
    public var opportunisticAvailable: Int64
    public var isEncrypted: Bool
    public var isRemovable: Bool

    public var purgeable: Int64 { max(0, finderAvailable - trueAvailable) }
    public var used: Int64 { total - trueAvailable }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// How badly Finder overstates free space.
    public var finderOverstatement: Int64 { purgeable }

    public static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeNameKey, .volumeIsEncryptedKey, .volumeIsRemovableKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeInfo(
            path: path,
            name: v.volumeName ?? path,
            total: Int64(v.volumeTotalCapacity ?? 0),
            trueAvailable: Int64(v.volumeAvailableCapacity ?? 0),
            finderAvailable: v.volumeAvailableCapacityForImportantUsage ?? 0,
            opportunisticAvailable: v.volumeAvailableCapacityForOpportunisticUsage ?? 0,
            isEncrypted: v.volumeIsEncrypted ?? false,
            isRemovable: v.volumeIsRemovable ?? false)
    }

    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                        options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { VolumeInfo.forPath($0.path) }
    }
}

/// APFS local snapshots hold onto deleted bytes. Deleting a large file frees
/// nothing until every snapshot referencing it expires, which is the single
/// most common reason "I deleted 200 GB and nothing happened".
public struct LocalSnapshot: Sendable {
    public var name: String
    public var date: String
}

public enum Snapshots {
    public static func list(volume: String = "/") -> [LocalSnapshot] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", volume]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("com.apple.") else { return nil }
            let date = s.split(separator: ".").last.map(String.init) ?? ""
            return LocalSnapshot(name: s, date: date)
        }
    }
}

/// Where the scan and the filesystem disagree, and why.
///
/// A scanner that only reports what it walked is untrustworthy: the interesting
/// bytes are the ones it *could not* see. This states the gap explicitly.
public struct Reconciliation: Sendable {
    public var volumeUsed: Int64
    public var scannedPhysical: Int64
    public var datalessLogical: Int64
    public var hardlinkDuplicateLogical: Int64
    public var unreadableDirectories: Int
    public var snapshotCount: Int
    public var scanRootIsWholeVolume: Bool

    public init(volumeUsed: Int64, scannedPhysical: Int64, datalessLogical: Int64,
                hardlinkDuplicateLogical: Int64, unreadableDirectories: Int,
                snapshotCount: Int, scanRootIsWholeVolume: Bool) {
        self.volumeUsed = volumeUsed
        self.scannedPhysical = scannedPhysical
        self.datalessLogical = datalessLogical
        self.hardlinkDuplicateLogical = hardlinkDuplicateLogical
        self.unreadableDirectories = unreadableDirectories
        self.snapshotCount = snapshotCount
        self.scanRootIsWholeVolume = scanRootIsWholeVolume
    }

    /// Only a scan of the whole volume can be compared with the volume's own
    /// figure. Subtracting a folder's bytes from the disk total produces a
    /// large, precise, meaningless number.
    public var comparesToVolume: Bool { scanRootIsWholeVolume }

    /// Positive: bytes on the volume the scan did not attribute to any file.
    /// Only meaningful when `comparesToVolume` is true.
    public var unaccounted: Int64 { volumeUsed - scannedPhysical }
    public var unaccountedFraction: Double {
        volumeUsed > 0 ? Double(unaccounted) / Double(volumeUsed) : 0
    }

    public var explanations: [String] {
        var out: [String] = []
        guard comparesToVolume else {
            return ["The scan covered the folders you chose, so its total is not compared with the volume."]
        }
        if snapshotCount > 0 {
            out.append("\(snapshotCount) APFS local snapshot\(snapshotCount == 1 ? "" : "s") hold blocks from deleted files.")
        }
        if unreadableDirectories > 0 {
            out.append("\(unreadableDirectories) directories could not be read. Grant Full Disk Access to see them.")
        }
        if unaccounted > 0 {
            out.append("APFS clones share blocks between files; cloned bytes are counted once by the volume but can appear under several names.")
        }
        return out
    }
}

/// Mount point of the filesystem holding `path`, e.g. "/" or "/Volumes/Backup".
public func volumeMountPoint(_ path: String) -> String? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    return withUnsafeBytes(of: fs.f_mntonname) { raw in
        raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
    }
}

public func formatBytes(_ v: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: v)
}
