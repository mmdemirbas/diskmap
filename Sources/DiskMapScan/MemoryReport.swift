import Foundation

/// Where a scanned tree's memory actually goes, measured rather than assumed.
public struct MemoryReport: Sendable {
    public var nodes: Int
    public var perNodeArrayBytes: Int
    public var arrayBytes: Int
    public var nameBytes: Int
    public var uniqueNameBytes: Int
    public var uniqueNames: Int
    public var reservedSlack: Int

    public var total: Int { arrayBytes + nameBytes }
    public var bytesPerNode: Double { nodes > 0 ? Double(total) / Double(nodes) : 0 }
    /// What name interning would save, if every distinct name were stored once.
    public var internSaving: Int { max(0, nameBytes - uniqueNameBytes) }

    public var lines: [String] {
        [
            "nodes                \(nodes)",
            "arrays               \(formatBytes(Int64(arrayBytes)))  (\(perNodeArrayBytes) B/node)",
            "names                \(formatBytes(Int64(nameBytes)))",
            "  distinct           \(uniqueNames) names, \(formatBytes(Int64(uniqueNameBytes)))",
            "  interning would save \(formatBytes(Int64(internSaving)))",
            "reserved but unused  \(formatBytes(Int64(reservedSlack)))",
            "total                \(formatBytes(Int64(total)))  (\(String(format: "%.1f", bytesPerNode)) B/node)",
        ]
    }
}

public extension NodeStore {
    /// Per-node cost of the parallel arrays, from their element types.
    static var perNodeArrayBytes: Int {
        MemoryLayout<UInt32>.stride   // nameOffset
        + MemoryLayout<UInt8>.stride  // nameLen
        + MemoryLayout<Int32>.stride  // parent
        + MemoryLayout<Int32>.stride  // firstChild
        + MemoryLayout<Int32>.stride  // childCount
        + MemoryLayout<Int64>.stride  // totalLogical
        + MemoryLayout<Int64>.stride  // totalPhysical
        + MemoryLayout<Int32>.stride  // mtime
        + MemoryLayout<UInt16>.stride // flags
    }

    func memoryReport() -> MemoryReport {
        // 64-bit FNV-1a per name: counting distinct names exactly via a Set of
        // Strings would cost more memory than the tree being measured.
        var seen = Set<UInt64>()
        seen.reserveCapacity(count / 2)
        var uniqueBytes = 0
        nameBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<count {
                let offset = Int(nameOffset[i]), length = Int(nameLen[i])
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for k in 0..<length {
                    hash = (hash ^ UInt64(base[offset + k])) &* 0x100_0000_01b3
                }
                if seen.insert(hash).inserted { uniqueBytes += length }
            }
        }
        return MemoryReport(
            nodes: count,
            perNodeArrayBytes: Self.perNodeArrayBytes,
            arrayBytes: count * Self.perNodeArrayBytes,
            nameBytes: nameBytes.count,
            uniqueNameBytes: uniqueBytes,
            uniqueNames: seen.count,
            reservedSlack: (parent.capacity - parent.count) * Self.perNodeArrayBytes
                + (nameBytes.capacity - nameBytes.count))
    }
}
