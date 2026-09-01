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
    func sharedItems(_ shared: Int, _ of: Int) -> String {
        active == .tr ? "\(of) öğenin \(shared)'i ortak" : "\(shared) of \(of) items shared"
    }
    func readsBytes(_ size: String) -> String {
        active == .tr ? "\(size) okur" : "reads \(size)"
    }
    func readSoFar(_ done: String, _ total: String) -> String {
        active == .tr ? "\(total) içinden \(done)" : "\(done) of \(total)"
    }
    func verifyDiffer(_ distinct: Int) -> String {
        active == .tr ? "içerikler farklı (\(distinct) ayrı sürüm)"
                      : "contents differ (\(distinct) different)"
    }
    func verifyPartial(_ n: Int) -> String {
        active == .tr ? "eşleşti, ancak \(fmt(n)) dosya okunamadı"
                      : "matched, but \(fmt(n)) files were not read"
    }
    func copyCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) kopya" : "\(fmt(n)) copies"
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
    func locationCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) konum" : (n == 1 ? "1 location" : "\(fmt(n)) locations")
    }
    func scanLocations(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) konumu tara" : (n == 1 ? "Scan 1 Location" : "Scan \(fmt(n)) Locations")
    }
    func rejectedNote(_ path: String, _ reason: String) -> String {
        let name = (path as NSString).lastPathComponent
        return active == .tr ? "\(name) atlandı: \(reason)" : "Skipped \(name): \(reason)"
    }

    func moreItems(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) küçük öğe daha" : "\(fmt(n)) smaller items"
    }
    func moreRows(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe daha (listede gösterilmiyor)" : "\(fmt(n)) more items, not listed"
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
        case showDiagnostics
        case treemapView, sunburstView, icicleView, colourBy, colourByType, colourByAge
        case panelContents, panelLargest, panelTypes, panelDuplicates, computing, ofSubtree
        case duplicatesNote, duplicatesEmpty, reclaimable, sectionFolders, sectionFiles
        case matchExact, verify, verifyAgain, verifyIdentical, verifyStopped
        case ageWeek, ageMonth, ageHalfYear, ageYear, ageTwoYears, ageOlder, staleNote
        case goBack, goForward, expandFolder, collapseFolder, foldersOnlyNote, chooseFolders, choosePanelMessage, dropFolders, orWord, scanWholeDisk
        case clearTargets, addMore, skippedTargets, multipleVolumesNote, targetsHeader
        case folderLabel, videoLabel, imageLabel, audioLabel, archiveLabel, documentLabel
        case codeLabel, appLabel, diskImageLabel, vmLabel, modelLabel, databaseLabel, cacheLabel, otherLabel
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
        .showDiagnostics: ("Show diagnostics log", "Tanılama kaydını göster"),
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
        .treemapView: ("Treemap", "Alan haritası"),
        .sunburstView: ("Sunburst", "Halka grafik"),
        .icicleView: ("Icicle", "Katman grafiği"),
        .colourBy: ("Colour by", "Renklendirme"),
        .colourByType: ("By type", "Türe göre"),
        .colourByAge: ("By age", "Yaşa göre"),
        .panelContents: ("Contents", "İçerik"),
        .panelLargest: ("Largest", "En büyük"),
        .panelTypes: ("Types", "Türler"),
        .panelDuplicates: ("Copies", "Kopyalar"),
        .duplicatesNote: ("Matched on names and sizes only. Open a match and press Verify to compare the contents.",
                          "Yalnızca ad ve boyut karşılaştırıldı. Eşleşmeyi açıp Doğrula ile içerikleri karşılaştırın."),
        .duplicatesEmpty: ("Nothing here has a copy elsewhere below this folder.",
                           "Bu klasörün altında kopyası olan bir şey yok."),
        .sectionFolders: ("Folders", "Klasörler"),
        .sectionFiles: ("Files", "Dosyalar"),
        .matchExact: ("identical", "birebir aynı"),
        .verify: ("Verify", "Doğrula"),
        .verifyAgain: ("Check again", "Yeniden bak"),
        .verifyIdentical: ("contents match", "içerikler aynı"),
        .verifyStopped: ("stopped", "durduruldu"),
        .reclaimable: ("could be freed", "boşaltılabilir"),
        .computing: ("Working…", "Hesaplanıyor…"),
        .ofSubtree: ("everything below this folder", "bu klasörün altındaki her şey"),
        .ageWeek: ("This week", "Bu hafta"),
        .ageMonth: ("This month", "Bu ay"),
        .ageHalfYear: ("6 months", "6 ay"),
        .ageYear: ("1 year", "1 yıl"),
        .ageTwoYears: ("2 years", "2 yıl"),
        .ageOlder: ("Older", "Daha eski"),
        .staleNote: ("untouched for over two years", "iki yıldan uzun süredir dokunulmamış"),
        .goBack: ("Back", "Geri"),
        .goForward: ("Forward", "İleri"),
        .expandFolder: ("Show contents", "İçindekileri göster"),
        .collapseFolder: ("Hide contents", "İçindekileri gizle"),
        .foldersOnlyNote: ("The scan covered the folders you chose, so its total is not compared with the volume.",
                           "Tarama seçtiğiniz klasörleri kapsadı, bu yüzden toplamı diskle karşılaştırılmıyor."),
        .chooseFolders: ("Choose Folders…", "Klasör seç…"),
        .choosePanelMessage: ("Pick one or more folders to measure together",
                              "Birlikte ölçülecek bir ya da daha çok klasör seçin"),
        .dropFolders: ("Drop folders here", "Klasörleri buraya bırakın"),
        .orWord: ("or", "ya da"),
        .scanWholeDisk: ("Scan Whole Disk", "Tüm diski tara"),
        .clearTargets: ("Clear", "Temizle"),
        .addMore: ("Add More…", "Başka ekle…"),
        .skippedTargets: ("Skipped", "Atlananlar"),
        .multipleVolumesNote: ("These folders sit on more than one disk, so the bar above describes only the first.",
                               "Bu klasörler birden çok diskte, bu yüzden yukarıdaki çubuk yalnızca ilkini anlatıyor."),
        .targetsHeader: ("Measuring together", "Birlikte ölçülüyor"),
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
        .databaseLabel: ("Database", "Veritabanı"),
        .cacheLabel: ("Cache", "Önbellek"),
        .otherLabel: ("Other", "Diğer"),
    ]
}

/// For call sites that are not SwiftUI views (Canvas drawing, formatters).
@MainActor func t(_ key: L10n.K) -> String { L10n.shared[key] }
