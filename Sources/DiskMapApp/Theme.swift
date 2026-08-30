import DiskMapCore
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var key: L10n.K {
        switch self {
        case .system: .appearanceSystem
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
    }
}

/// One hue per category, given separately for light and dark.
///
/// The two sets are not the same colour at different opacity: on a dark canvas
/// a mid-tone reads as muddy, on a light one it disappears. Both sets stay in a
/// narrow lightness band so white labels remain legible on every tile and no
/// category shouts louder than another.
extension FileCategory {
    func color(_ scheme: ColorScheme) -> Color {
        let (l, d): ((Double, Double, Double), (Double, Double, Double)) = switch self {
        case .folder:         ((0.42, 0.50, 0.60), (0.38, 0.46, 0.56))
        case .video:          ((0.52, 0.38, 0.76), (0.60, 0.47, 0.85))
        case .image:          ((0.15, 0.55, 0.57), (0.24, 0.68, 0.70))
        case .audio:          ((0.80, 0.38, 0.57), (0.88, 0.50, 0.68))
        case .archive:        ((0.76, 0.55, 0.16), (0.87, 0.68, 0.28))
        case .document:       ((0.24, 0.48, 0.76), (0.36, 0.60, 0.88))
        case .code:           ((0.28, 0.60, 0.36), (0.40, 0.72, 0.48))
        case .application:    ((0.36, 0.40, 0.76), (0.48, 0.52, 0.86))
        case .diskImage:      ((0.80, 0.46, 0.22), (0.90, 0.58, 0.32))
        case .virtualMachine: ((0.76, 0.32, 0.28), (0.86, 0.44, 0.40))
        case .model:          ((0.64, 0.32, 0.68), (0.76, 0.45, 0.80))
        case .cache:          ((0.52, 0.49, 0.44), (0.60, 0.57, 0.52))
        case .other:          ((0.46, 0.49, 0.53), (0.54, 0.57, 0.61))
        }
        let c = scheme == .dark ? d : l
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    @MainActor var localizedLabel: String {
        switch self {
        case .folder: t(.folderLabel);          case .video: t(.videoLabel)
        case .image: t(.imageLabel);            case .audio: t(.audioLabel)
        case .archive: t(.archiveLabel);        case .document: t(.documentLabel)
        case .code: t(.codeLabel);              case .application: t(.appLabel)
        case .diskImage: t(.diskImageLabel);    case .virtualMachine: t(.vmLabel)
        case .model: t(.modelLabel);            case .cache: t(.cacheLabel)
        case .other: t(.otherLabel)
        }
    }
}

enum Palette {
    static func used(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.35, green: 0.58, blue: 0.86) : Color(red: 0.22, green: 0.45, blue: 0.74)
    }
    static func purgeable(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.88, green: 0.68, blue: 0.32) : Color(red: 0.80, green: 0.57, blue: 0.20)
    }
    static func free(_ s: ColorScheme) -> Color {
        s == .dark ? Color(white: 0.42) : Color(white: 0.80)
    }
    static func warning(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.94, green: 0.52, blue: 0.42) : Color(red: 0.76, green: 0.28, blue: 0.18)
    }
    /// Frame around a folder block in the treemap.
    static func folderStroke(_ s: ColorScheme) -> Color {
        s == .dark ? Color.black.opacity(0.65) : Color.black.opacity(0.42)
    }
}

/// Decimal units, matching what Finder and the rest of macOS show, formatted in
/// the language the user picked rather than the system one.
@MainActor
func shortBytes(_ v: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(v < 0 ? 0 : v)
    var unit = 0
    while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
    let f = NumberFormatter()
    f.locale = L10n.shared.locale
    f.numberStyle = .decimal
    f.maximumFractionDigits = unit == 0 ? 0 : (value < 10 ? 2 : (value < 100 ? 1 : 0))
    f.minimumFractionDigits = 0
    return (f.string(from: NSNumber(value: value)) ?? "\(Int(value))") + " " + units[unit]
}

@MainActor
func percentString(_ fraction: Double) -> String {
    guard fraction.isFinite, fraction > 0 else { return "0%" }
    if fraction < 0.001 { return "<0,1%".replacingOccurrences(of: ",", with: L10n.shared.active == .tr ? "," : ".") }
    let f = NumberFormatter()
    f.locale = L10n.shared.locale
    f.numberStyle = .percent
    f.maximumFractionDigits = 1
    f.minimumFractionDigits = 1
    return f.string(from: NSNumber(value: fraction)) ?? "0%"
}
