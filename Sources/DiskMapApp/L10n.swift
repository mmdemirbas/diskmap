import Foundation
import SwiftUI

/// In-app language switching, because the disk is the same disk whatever the
/// system language is set to, and a user may want the app in one language while
/// the OS is in another.
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    enum Language: String, CaseIterable, Identifiable {
        case system, en, tr
        var id: String { rawValue }
        var nativeName: String {
            switch self {
            case .system: "System"
            case .en: "English"
            case .tr: "Türkçe"
            }
        }
    }

    @AppStorage("language") var preference: Language = .system {
        willSet { objectWillChange.send() }
    }

    /// Falls back to English for any system language we do not ship.
    var active: Language {
        if preference != .system { return preference }
        return Locale.preferredLanguages.first?.hasPrefix("tr") == true ? .tr : .en
    }

    var locale: Locale { Locale(identifier: active == .tr ? "tr_TR" : "en_US") }

    subscript(_ key: K) -> String {
        let pair = L10n.table[key] ?? (key.rawValue, key.rawValue)
        return active == .tr ? pair.1 : pair.0
    }

    // Parameterised strings kept as functions so argument order can differ
    // between languages without the call sites knowing.
    func usedOfTotal(_ used: String, _ total: String) -> String {
        active == .tr ? "\(total) diskin \(used) kadarı dolu" : "\(used) of \(total) used"
    }
    func finderClaim(_ finder: String, _ real: String) -> String {
        active == .tr
            ? "Finder \(finder) boş diyor. Gerçekte yalnızca \(real) boş."
            : "Finder says \(finder) free. Only \(real) really is."
    }
    func itemCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe" : "\(fmt(n)) items"
    }
    func folderCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) klasör" : "\(fmt(n)) folders"
    }
    func scannedIn(_ seconds: Double) -> String {
        let t = String(format: "%.1f", seconds)
        return active == .tr ? "\(t) sn'de tarandı" : "scanned in \(t)s"
    }
    func unreadableWarning(_ n: Int) -> String {
        active == .tr
            ? "\(fmt(n)) klasör okunamadı — Tam Disk Erişimi verin"
            : "\(fmt(n)) folders unreadable — grant Full Disk Access"
    }
    func freedBytes(_ size: String) -> String {
        active == .tr ? "Çöp Kutusu'na taşındı · \(size) boşaldı" : "Moved to Trash · freed \(size)"
    }
    func restored(_ name: String) -> String {
        active == .tr ? "\(name) geri alındı" : "Restored \(name)"
    }
    func couldNotRestore(_ reason: String) -> String {
        active == .tr ? "Geri alınamadı: \(reason)" : "Could not restore: \(reason)"
    }
    func confirmTrashTitle(_ name: String) -> String {
        active == .tr ? "\(name) Çöp Kutusu'na taşınsın mı?" : "Move \(name) to Trash?"
    }
    func confirmTrashBody(_ items: Int, _ size: String) -> String {
        active == .tr
            ? "Bu klasörde \(fmt(items)) öğe var, toplam \(size). Çöp Kutusu'ndan ya da Geri Al ile döndürebilirsiniz."
            : "This folder holds \(fmt(items)) items totalling \(size). You can put it back from the Trash or with Undo."
    }
    func datalessNote(_ count: Int, _ size: String) -> String {
        active == .tr
            ? "\(fmt(count)) dosya iCloud yer tutucusu: görünen boyutu \(size), diskte 0 bayt. Silmek yer açmaz."
            : "\(fmt(count)) files are iCloud placeholders: \(size) of apparent size, 0 bytes on this disk. Deleting them frees nothing."
    }
    func hardlinkNote(_ count: Int, _ size: String) -> String {
        active == .tr
            ? "\(fmt(count)) sabit bağlantı zaten sayılmış dosyaları gösteriyor: \(size) yalnızca bir kez var."
            : "\(fmt(count)) hard links point at files already counted: \(size) that exists only once."
    }
    func moreItems(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) küçük öğe daha" : "\(fmt(n)) smaller items"
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    enum K: String, CaseIterable {
        case appName, inUse, purgeable, free, why, capacityHelp
        case whereSpaceIs, whereSpaceIsSubtitle, capacity, used, freeReally, freeFinder
        case purgeableNote, writableNow, includesPurgeable
        case scanVsFilesystem, volumeReportsUsed, scanAttributed, unaccounted, done
        case filter, onDisk, apparent, rescan, enclosingFolder, sizeMetricHelp
        case watching, notWatching, watchHelp, undoTrash, tryAgain
        case chooseTarget, volume, scanVolume, scanHome, fdaWarning, openPrivacy
        case cancel, size, share, name, emptyFolder, noMatches
        case nothingSelected, nothingSelectedHint, ofVolume, reveal, trash
        case apparentMismatch, openHere, revealInFinder, copyPath, moveToTrash
        case icloudZero, pathCopied, scanMenu, appearance, language
        case appearanceSystem, appearanceLight, appearanceDark, cancelScan, scanning
        case folderLabel, videoLabel, imageLabel, audioLabel, archiveLabel, documentLabel
        case codeLabel, appLabel, diskImageLabel, vmLabel, modelLabel, cacheLabel, otherLabel
    }

    static let table: [K: (String, String)] = [
        .appName: ("Disk Map", "Disk Haritası"),
        .inUse: ("In use", "Kullanımda"),
        .purgeable: ("Purgeable", "Temizlenebilir"),
        .free: ("Free", "Boş"),
        .why: ("Why?", "Neden?"),
        .capacityHelp: ("Finder counts purgeable space as available. Click for the breakdown.",
                        "Finder temizlenebilir alanı boş sayıyor. Ayrıntı için tıklayın."),
        .whereSpaceIs: ("Where the space actually is", "Alan gerçekte nerede"),
        .whereSpaceIsSubtitle: ("macOS reports several different numbers for the same disk. These are all of them.",
                                "macOS aynı disk için birkaç farklı sayı bildiriyor. Hepsi burada."),
        .capacity: ("Capacity", "Kapasite"),
        .used: ("Used", "Kullanılan"),
        .freeReally: ("Free, really", "Gerçekte boş"),
        .freeFinder: ("Free, as Finder shows", "Finder'ın gösterdiği boş alan"),
        .writableNow: ("you can write this much now", "şu anda bu kadarını yazabilirsiniz"),
        .includesPurgeable: ("includes purgeable", "temizlenebilir alanı da sayar"),
        .purgeableNote: ("evictable iCloud files, caches, snapshots",
                         "boşaltılabilir iCloud dosyaları, önbellekler, anlık görüntüler"),
        .scanVsFilesystem: ("Scan vs. filesystem", "Tarama ile dosya sistemi karşılaştırması"),
        .volumeReportsUsed: ("Volume reports used", "Diskin bildirdiği kullanım"),
        .scanAttributed: ("Scan attributed to files", "Taramanın dosyalara bağladığı"),
        .unaccounted: ("Unaccounted", "Hesaplanamayan"),
        .done: ("Done", "Tamam"),
        .filter: ("Filter", "Süz"),
        .onDisk: ("On disk", "Diskte"),
        .apparent: ("Apparent", "Görünen"),
        .rescan: ("Rescan", "Yeniden tara"),
        .enclosingFolder: ("Enclosing folder", "Üst klasör"),
        .sizeMetricHelp: ("On disk = bytes actually allocated. Apparent = the size the file reports.",
                          "Diskte = gerçekten ayrılmış bayt. Görünen = dosyanın bildirdiği boyut."),
        .watching: ("watching", "izleniyor"),
        .notWatching: ("not watching", "izlenmiyor"),
        .watchHelp: ("Changes on disk update this view automatically",
                     "Diskteki değişiklikler bu görünüme kendiliğinden yansır"),
        .undoTrash: ("Undo Trash", "Silmeyi geri al"),
        .tryAgain: ("Try Again", "Yeniden dene"),
        .chooseTarget: ("Choose what to measure", "Neyi ölçeceğinizi seçin"),
        .volume: ("Volume", "Disk"),
        .scanVolume: ("Scan Volume", "Diski tara"),
        .scanHome: ("Scan Home Folder", "Ana klasörü tara"),
        .fdaWarning: ("Without Full Disk Access some folders stay invisible and the totals come up short.",
                      "Tam Disk Erişimi olmadan bazı klasörler görünmez ve toplamlar eksik çıkar."),
        .openPrivacy: ("Open Privacy Settings", "Gizlilik ayarlarını aç"),
        .cancel: ("Cancel", "Vazgeç"),
        .cancelScan: ("Stop scanning", "Taramayı durdur"),
        .scanning: ("Scanning", "Taranıyor"),
        .size: ("Size", "Boyut"),
        .share: ("Share", "Pay"),
        .name: ("Name", "Ad"),
        .emptyFolder: ("Empty folder", "Boş klasör"),
        .noMatches: ("Nothing matches", "Eşleşen yok"),
        .nothingSelected: ("Nothing selected", "Seçili öğe yok"),
        .nothingSelectedHint: ("Click a rectangle or a row. Double-click a folder to go inside.",
                               "Bir dikdörtgene ya da satıra tıklayın. Klasöre girmek için çift tıklayın."),
        .ofVolume: ("Of volume", "Disk payı"),
        .reveal: ("Reveal", "Finder'da göster"),
        .trash: ("Trash", "Çöp Kutusu"),
        .apparentMismatch: ("Apparent size is far larger than the bytes on disk: iCloud placeholders, sparse files or compression.",
                            "Görünen boyut diskteki bayttan çok daha büyük: iCloud yer tutucuları, seyrek dosyalar ya da sıkıştırma."),
        .openHere: ("Open here", "Burada aç"),
        .revealInFinder: ("Reveal in Finder", "Finder'da göster"),
        .copyPath: ("Copy Path", "Yolu kopyala"),
        .moveToTrash: ("Move to Trash", "Çöp Kutusu'na taşı"),
        .icloudZero: ("iCloud, 0 bytes here", "iCloud, burada 0 bayt"),
        .pathCopied: ("Path copied", "Yol kopyalandı"),
        .scanMenu: ("Scan", "Tara"),
        .appearance: ("Appearance", "Görünüm"),
        .language: ("Language", "Dil"),
        .appearanceSystem: ("System", "Sistem"),
        .appearanceLight: ("Light", "Açık"),
        .appearanceDark: ("Dark", "Koyu"),
        .folderLabel: ("Folder", "Klasör"),
        .videoLabel: ("Video", "Video"),
        .imageLabel: ("Image", "Görsel"),
        .audioLabel: ("Audio", "Ses"),
        .archiveLabel: ("Archive", "Arşiv"),
        .documentLabel: ("Document", "Belge"),
        .codeLabel: ("Code", "Kod"),
        .appLabel: ("App", "Uygulama"),
        .diskImageLabel: ("Disk image", "Disk kalıbı"),
        .vmLabel: ("Virtual machine", "Sanal makine"),
        .modelLabel: ("AI model", "Yapay zekâ modeli"),
        .cacheLabel: ("Cache", "Önbellek"),
        .otherLabel: ("Other", "Diğer"),
    ]
}

/// For call sites that are not SwiftUI views (Canvas drawing, formatters).
@MainActor func t(_ key: L10n.K) -> String { L10n.shared[key] }
