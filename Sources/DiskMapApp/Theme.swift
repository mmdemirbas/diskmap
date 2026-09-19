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
        case .database:       ((0.18, 0.44, 0.48), (0.30, 0.58, 0.62))
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
        case .model: t(.modelLabel);            case .database: t(.databaseLabel)
        case .cache: t(.cacheLabel)
        case .other: t(.otherLabel)
        }
    }

    /// One glyph per kind, shared by every list that shows a file. It lived in
    /// the tree table until the flat table needed the same mapping, and a kind
    /// drawn one way in one list and another way elsewhere is the reader
    /// learning the same alphabet twice.
    var glyph: String {
        switch self {
        case .folder: "folder.fill";        case .video: "film"
        case .image: "photo";               case .audio: "waveform"
        case .archive: "shippingbox";       case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app";           case .diskImage: "externaldrive"
        case .virtualMachine: "desktopcomputer"
        case .model: "brain";               case .cache: "clock.arrow.circlepath"
        case .database: "doc";              case .other: "doc"
        }
    }
}

/// A sequential ramp, cool for fresh and warm for stale, so a folder full of
/// things nobody has opened in years reads as one warm block.
extension AgeBucket {
    func color(_ scheme: ColorScheme) -> Color {
        let (l, d): ((Double, Double, Double), (Double, Double, Double)) = switch self {
        case .week:     ((0.20, 0.55, 0.72), (0.32, 0.68, 0.85))
        case .month:    ((0.28, 0.60, 0.60), (0.40, 0.73, 0.72))
        case .halfYear: ((0.55, 0.62, 0.40), (0.66, 0.74, 0.50))
        case .year:     ((0.76, 0.62, 0.30), (0.86, 0.72, 0.40))
        case .twoYears: ((0.80, 0.48, 0.24), (0.90, 0.60, 0.34))
        case .older:    ((0.74, 0.30, 0.26), (0.86, 0.44, 0.38))
        }
        let c = scheme == .dark ? d : l
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    @MainActor var localizedLabel: String {
        switch self {
        case .week: t(.ageWeek);         case .month: t(.ageMonth)
        case .halfYear: t(.ageHalfYear); case .year: t(.ageYear)
        case .twoYears: t(.ageTwoYears); case .older: t(.ageOlder)
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
func localizedReason(_ reason: RootRejection) -> String {
    guard L10n.shared.active == .tr else { return reason.explanation }
    switch reason {
    case .missing: return "yok"
    case .notADirectory: return "klasör değil"
    case .duplicate(let other): return "\(other) ile aynı klasör"
    case .containedIn(let parent): return "zaten \(parent) içinde"
    }
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

/// A drop target for folders, except when rendering offscreen.
///
/// `dropDestination` puts an AppKit drag view under the content. It draws
/// nothing in a window, but the offscreen renderer cannot draw AppKit and
/// paints what it cannot draw as a warning glyph the size of the view. On a
/// target the size of a tool that is the whole tool, under every row, and a
/// check of that tool is looking at the glyph rather than the screen. Found
/// the same way the ScrollView case was: a render that had been clean, and
/// was not the next day.
extension View {
    @ViewBuilder
    func acceptsFolders(renderMode: Bool,
                        isTargeted: @escaping (Bool) -> Void = { _ in },
                        perform: @escaping ([URL]) -> Bool) -> some View {
        if renderMode {
            self
        } else {
            dropDestination(for: URL.self, action: { urls, _ in perform(urls) },
                            isTargeted: isTargeted)
        }
    }
}

/// A ScrollView, except when rendering offscreen.
///
/// An offscreen render has no viewport, so a ScrollView measures zero and draws
/// nothing at all — the header appears above an empty box and the render looks
/// like a layout bug rather than a missing viewport. This has now been
/// rediscovered in four separate lists, so it lives in one place.
///
/// Lists that can hold thousands of rows should still use a GeometryReader and
/// take only the rows that fit; this is for the ones whose content is bounded.
@ViewBuilder
func viewportScroller<Content: View>(renderMode: Bool, axis: Axis = .vertical,
                                     @ViewBuilder content: () -> Content) -> some View {
    if renderMode {
        content()
            .frame(maxWidth: axis == .vertical ? .infinity : nil,
                   maxHeight: axis == .vertical ? .infinity : nil,
                   alignment: axis == .vertical ? .top : .leading)
            .clipped()
    } else if axis == .vertical {
        ScrollView { content() }
    } else {
        ScrollView(.horizontal, showsIndicators: false) { content() }
    }
}

/// Four ways two folders can disagree about one name, plus the one way they
/// agree. Hues are borrowed from the capacity bar and the type ramp rather than
/// invented, so a reader who has learned one screen has learned this one.
extension DiffKind {
    func color(_ scheme: ColorScheme) -> Color {
        let (l, d): ((Double, Double, Double), (Double, Double, Double)) = switch self {
        case .identical: ((0.46, 0.53, 0.49), (0.48, 0.56, 0.52))
        case .differs:   ((0.80, 0.57, 0.20), (0.88, 0.68, 0.32))
        case .onlyLeft:  ((0.22, 0.45, 0.74), (0.35, 0.58, 0.86))
        case .onlyRight: ((0.52, 0.38, 0.76), (0.60, 0.47, 0.85))
        case .typeClash: ((0.76, 0.28, 0.18), (0.94, 0.52, 0.42))
        }
        let c = scheme == .dark ? d : l
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    @MainActor var localizedLabel: String {
        switch self {
        case .identical: t(.diffIdentical);  case .differs: t(.diffDiffers)
        case .onlyLeft: t(.diffOnlyLeft);    case .onlyRight: t(.diffOnlyRight)
        case .typeClash: t(.diffClash)
        }
    }

    /// What sits between the two size columns. It reads as a sentence about the
    /// pair rather than a label on one side of it.
    var relation: String {
        switch self {
        case .identical: "="
        case .differs: "≠"
        case .onlyLeft: "→"
        case .onlyRight: "←"
        case .typeClash: "⚠"
        }
    }
}

extension SyncAction {
    @MainActor var localizedLabel: String {
        switch self {
        case .copy: t(.stepCopy); case .replace: t(.stepReplace); case .remove: t(.stepRemove)
        }
    }
    var symbol: String {
        switch self {
        case .copy: "plus.circle"
        case .replace: "arrow.triangle.2.circlepath"
        case .remove: "trash"
        }
    }
    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .copy: DiffKind.onlyLeft.color(scheme)
        case .replace: DiffKind.differs.color(scheme)
        case .remove: Palette.warning(scheme)
        }
    }
}

extension SyncDirection {
    var key: L10n.K {
        switch self {
        case .mirrorLeftToRight: .dirMirrorRight
        case .mirrorRightToLeft: .dirMirrorLeft
        case .updateLeftToRight: .dirUpdateRight
        case .updateRightToLeft: .dirUpdateLeft
        case .merge: .dirMerge
        case .removeLeftDuplicates: .dirFreeLeft
        case .removeRightDuplicates: .dirFreeRight
        }
    }
    var whyKey: L10n.K {
        switch self {
        case .mirrorLeftToRight: .dirMirrorRightWhy
        case .mirrorRightToLeft: .dirMirrorLeftWhy
        case .updateLeftToRight: .dirUpdateRightWhy
        case .updateRightToLeft: .dirUpdateLeftWhy
        case .merge: .dirMergeWhy
        case .removeLeftDuplicates: .dirFreeLeftWhy
        case .removeRightDuplicates: .dirFreeRightWhy
        }
    }
    var symbol: String {
        switch self {
        case .mirrorLeftToRight, .updateLeftToRight: "arrow.right"
        case .mirrorRightToLeft, .updateRightToLeft: "arrow.left"
        case .merge: "arrow.left.arrow.right"
        case .removeLeftDuplicates, .removeRightDuplicates: "trash"
        }
    }

    /// The three things this screen can be asked to do, so the picker groups
    /// them instead of offering seven equals.
    static let groups: [(L10n.K, [SyncDirection])] = [
        (.dirGroupCopy, [.mirrorLeftToRight, .mirrorRightToLeft,
                         .updateLeftToRight, .updateRightToLeft, .merge]),
        (.dirGroupFree, [.removeLeftDuplicates, .removeRightDuplicates]),
    ]
}

@MainActor
func localizedRefusal(_ refusal: CompareRefusal) -> String {
    switch refusal {
    case .notAFolder(let path): "\(t(.refuseNotAFolder)): \((path as NSString).lastPathComponent)"
    case .sameFolder: t(.refuseSameFolder)
    case .nested: t(.refuseNested)
    case .wouldWriteToAVolumeRoot: t(.refuseVolumeRoot)
    case .onTheNeverTouchList(let path): "\(t(.refuseExcluded)): \((path as NSString).lastPathComponent)"
    case .nothingToDo: t(.refuseNothingToDo)
    case .notRedundant: t(.refuseNotRedundant)
    case .comparisonIncomplete: t(.refuseComparisonIncomplete)
    case .volumeMountedInside(let path):
        "\(t(.refuseVolumeInside)) \((path as NSString).lastPathComponent)"
    case .someFoldersUnreadable: t(.refuseUnreadable)
    }
}
