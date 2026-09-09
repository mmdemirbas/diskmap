import Foundation

/// What two filenames have to look like before they count as the same name.
///
/// macOS volumes are case-insensitive by default and treat a name composed two
/// ways as one name, so `Photo.jpg` and `photo.jpg` in two folders are, to the
/// filesystem, the same name — and to anyone looking for copies, obviously the
/// same file twice. Matching raw bytes misses every one of them, and misses
/// every accented name that came from somewhere storing it decomposed.
///
/// The comparison already worked this way. This is the same rule, written once,
/// for the two places that hunt for copies.
///
/// Deliberately not a `String` per name. This is called once per node on trees
/// of ten million, and building a Swift string for each is the difference
/// between a second and a minute. Plain ASCII — nearly every name — folds a
/// byte at a time with no allocation at all; only a name with a byte of 0x80 or
/// more takes the slow road, where normalisation actually has something to do.
public enum NameKey {
    /// The FNV-1a offset basis, so a caller can fold the name into a hash it is
    /// already building.
    public static let seed: UInt64 = 0xcbf2_9ce4_8422_2325

    /// Hashes a name as the folded form of itself.
    public static func hash(_ bytes: UnsafeBufferPointer<UInt8>,
                            offset: Int, length: Int) -> UInt64 {
        guard let base = bytes.baseAddress, length > 0 else { return seed }
        var hash = seed
        var ascii = true
        for k in 0..<length {
            let b = base[offset + k]
            if b >= 0x80 { ascii = false; break }
        }
        guard ascii else {
            return folded(String(decoding: UnsafeBufferPointer(start: base + offset,
                                                               count: length), as: UTF8.self))
                .utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        }
        for k in 0..<length {
            let b = base[offset + k]
            hash = (hash ^ UInt64(lowerASCII(b))) &* 0x100_0000_01b3
        }
        return hash
    }

    /// The folded form as text, for the places that already hold a string.
    ///
    /// Composed first, then lowercased: the two are not interchangeable, and
    /// doing it the other way round leaves the same name in two forms.
    public static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    @inline(__always)
    static func lowerASCII(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
}
