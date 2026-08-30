import Foundation

/// On modern macOS the read-only System volume exposes the Data volume's
/// directories under a second set of names (`/Users`, `/Applications`, ...).
/// They are the same bytes. Walking both from `/` counts the disk twice.
public enum Firmlinks {
    public static func mountPaths() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap {
            let path = $0.split(separator: "\t").first.map(String.init)
            return path?.isEmpty == false ? path : nil
        })
    }
}
