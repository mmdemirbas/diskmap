import DiskMapCore
import SwiftUI

/// One hue per file category, at a single saturation and lightness so no
/// category shouts louder than another. Size carries the message in a treemap;
/// colour only says "what kind of thing".
extension FileCategory {
    var color: Color {
        switch self {
        case .folder:         Color(red: 0.45, green: 0.53, blue: 0.62)
        case .video:          Color(red: 0.55, green: 0.42, blue: 0.80)
        case .image:          Color(red: 0.20, green: 0.62, blue: 0.63)
        case .audio:          Color(red: 0.84, green: 0.44, blue: 0.62)
        case .archive:        Color(red: 0.82, green: 0.62, blue: 0.24)
        case .document:       Color(red: 0.30, green: 0.54, blue: 0.82)
        case .code:           Color(red: 0.36, green: 0.66, blue: 0.42)
        case .application:    Color(red: 0.42, green: 0.46, blue: 0.80)
        case .diskImage:      Color(red: 0.85, green: 0.51, blue: 0.28)
        case .virtualMachine: Color(red: 0.80, green: 0.38, blue: 0.34)
        case .model:          Color(red: 0.70, green: 0.38, blue: 0.72)
        case .cache:          Color(red: 0.58, green: 0.55, blue: 0.50)
        case .other:          Color(red: 0.52, green: 0.55, blue: 0.58)
        }
    }
}

enum Palette {
    /// Capacity bar segments. Free space is the quiet one: it is the good news.
    static let used = Color(red: 0.28, green: 0.51, blue: 0.79)
    static let purgeable = Color(red: 0.85, green: 0.62, blue: 0.24)
    static let free = Color(red: 0.72, green: 0.75, blue: 0.78).opacity(0.35)
    static let warning = Color(red: 0.83, green: 0.42, blue: 0.30)
}

func shortBytes(_ v: Int64) -> String { formatBytes(v) }

func percentString(_ f: Double) -> String {
    f <= 0 ? "0%" : (f < 0.001 ? "<0.1%" : String(format: "%.1f%%", f * 100))
}
