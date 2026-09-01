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

    /// The app has its own language switch, so a date left to the system
    /// locale makes the screen read as half-translated. Cached per locale
    /// because building a DateFormatter is not free.
    private static var dateFormatters: [String: DateFormatter] = [:]
    func dateTime(_ date: Date) -> String {
        let key = locale.identifier
        if let cached = Self.dateFormatters[key] { return cached.string(from: date) }
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        Self.dateFormatters[key] = f
        return f.string(from: date)
    }

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
    /// Turkish takes no plural suffix after a number, so only English varies.
    private func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(fmt(n)) \(many)"
    }

    func itemCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe" : count(n, "item", "items")
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
                      : "matched, but \(count(n, "file was", "files were")) not read"
    }
    func wouldRemoveEveryCopy(_ name: String) -> String {
        active == .tr
            ? "\(name) için tek kopya bile kalmıyor. En az birini işaretsiz bırakın."
            : "That would leave no copy of \(name). Untick at least one."
    }
    func someCouldNotBeTrashed(_ failed: Int, _ moved: Int) -> String {
        active == .tr
            ? "\(fmt(moved)) taşındı, \(fmt(failed)) taşınamadı"
            : "Moved \(fmt(moved)), could not move \(fmt(failed))"
    }
    func restoredCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe geri alındı" : "Restored \(count(n, "item", "items"))"
    }
    func restoredSome(_ restored: Int, _ total: Int) -> String {
        active == .tr
            ? "\(fmt(total)) öğeden \(fmt(restored)) tanesi geri alındı"
            : "Restored \(fmt(restored)) of \(fmt(total))"
    }
    func largestOfTotal(_ shown: Int, _ total: Int, _ rest: String) -> String {
        active == .tr
            ? "\(fmt(total)) taneden en büyük \(fmt(shown)) tanesi · \(rest) daha var"
            : "the largest \(fmt(shown)) of \(fmt(total)) · \(rest) more not shown"
    }
    func sinceWhen(_ when: String) -> String {
        active == .tr ? "\(when) tarihinden bu yana" : "since \(when)"
    }
    func grewBy(_ size: String) -> String {
        active == .tr ? "\(size) büyüdü" : "Grew by \(size)"
    }
    func shrankBy(_ size: String) -> String {
        active == .tr ? "\(size) küçüldü" : "Shrank by \(size)"
    }
    func couldFreeAbout(_ size: String) -> String {
        active == .tr ? "Yaklaşık \(size) boşaltılabilir" : "About \(size) could be freed"
    }
    func selectedForRemoval(_ n: Int, _ size: String) -> String {
        active == .tr ? "\(fmt(n)) öğe işaretli · \(size)" : "\(fmt(n)) ticked · \(size)"
    }
    func keepingOf(_ staying: Int, _ total: Int) -> String {
        active == .tr ? "\(total) kopyadan \(staying) tanesi kalıyor"
                      : "keeping \(staying) of \(total)"
    }
    func moveCountToTrash(_ n: Int, _ size: String) -> String {
        active == .tr ? "\(fmt(n)) öğeyi Çöp Kutusu'na taşı · \(size)"
                      : "Move \(count(n, "item", "items")) to the Trash · \(size)"
    }
    func confirmBulkTitle(_ n: Int, _ size: String) -> String {
        active == .tr
            ? "\(fmt(n)) öğe Çöp Kutusu'na taşınsın mı? (\(size))"
            : "Move \(fmt(n)) items to the Trash? (\(size))"
    }
    func alsoCovered(_ n: Int) -> String {
        active == .tr
            ? "\(fmt(n)) öğe zaten seçili bir klasörün içinde, ayrıca taşınmayacak"
            : "\(count(n, "more is", "more are")) inside a folder already listed, so not shown separately"
    }
    func syncedItemCount(_ n: Int, _ providers: String) -> String {
        active == .tr
            ? "\(fmt(n)) öğe \(providers) içinde"
            : "\(count(n, "item is", "items are")) in \(providers)"
    }
    func copyCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) kopya" : count(n, "copy", "copies")
    }
    func folderCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) klasör" : count(n, "folder", "folders")
    }
    func scannedIn(_ seconds: Double) -> String {
        let t = String(format: "%.1f", seconds)
        return active == .tr ? "\(t) sn'de tarandı" : "scanned in \(t)s"
    }
    func unreadableWarning(_ n: Int) -> String {
        active == .tr
            ? "\(fmt(n)) klasör okunamadı — Tam Disk Erişimi verin"
            : "\(count(n, "folder", "folders")) unreadable — grant Full Disk Access"
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
        case showDiagnostics, itemGone
        case nothingToRemove, selectionChanged, cannotRemoveScanRoot, cannotRemoveOutside
        case selectExtras, clearSelection, moveSelectedToTrash, keepsOneCopy
        case syncWarningTitle, alsoDeletedFromService, reviewBeforeTrashing, trashIsRecoverable
        case reviewWhatGoes, tickToChange, willStay, willBeTrashed, keepThisOne
        case sameContentsDifferentNames, neverSuggest, allExcluded, exclusions
        case exclusionsExplained, addExclusion, removeExclusion, noExclusions
        case freeUpSpace, lookingForSpace, nothingObviousToFree, reviewItems, showInFinder
        case suggestionsNeverDelete, close
        case safetyComesBack, safetyCopyRemains, safetyYourCall
        case whatChanged, noEarlierScans, comeBackAfterAnotherScan, nothingMovedMuch
        case noNetChange, deepestFolderExplains, snapshotUnreadable
        case suggestFolders, suggestFiles, suggestBuild, suggestCaches
        case suggestInstallers, suggestStale, suggestTrash
        case suggestFoldersWhy, suggestFilesWhy, suggestBuildWhy, suggestCachesWhy
        case suggestInstallersWhy, suggestStaleWhy, suggestTrashWhy
        case treemapView, sunburstView, icicleView, colourBy, colourByType, colourByAge
        case colourTypeShort, colourAgeShort, newScanHelp, disksHeader, foldersHeader
        case theDiskSays, finderSays, theGapIsPurgeable, sameDiskTwoAnswers
        case measuredByScan, notAttributed, whatTheScanReached, theNumbers
        case inUseNotPurgeable, finderCountsAsFree
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
        .itemGone: ("That item is no longer there", "Bu öğe artık yok"),
        .nothingToRemove: ("Nothing is ticked", "İşaretli bir şey yok"),
        .selectionChanged: ("The disk changed — check the list again",
                            "Disk değişti, listeyi yeniden kontrol edin"),
        .cannotRemoveScanRoot: ("That is a folder the scan is rooted at",
                                "Bu, taramanın başladığı klasör"),
        .cannotRemoveOutside: ("That is outside what was scanned",
                               "Bu, taranan alanın dışında"),
        .selectExtras: ("Tick the extras", "Fazlalıkları işaretle"),
        .clearSelection: ("Clear", "Temizle"),
        .moveSelectedToTrash: ("Move to Trash…", "Çöp Kutusu'na taşı…"),
        .keepsOneCopy: ("One copy of each is always kept", "Her birinden bir kopya her zaman kalır"),
        .syncWarningTitle: ("Some of these are synced", "Bunların bazıları eşitleniyor"),
        .alsoDeletedFromService: ("Deleting here removes them from the service and from your other devices too. Put Back restores only the local copy.",
                                  "Buradan silmek onları servisten ve diğer cihazlarınızdan da kaldırır. Geri Koy yalnızca yerel kopyayı geri getirir."),
        .reviewBeforeTrashing: ("Everything that will be moved:", "Taşınacak her şey:"),
        .reviewWhatGoes: ("What goes, and what stays", "Ne gidiyor, ne kalıyor"),
        .tickToChange: ("Click any row to change it", "Değiştirmek için satıra tıklayın"),
        .willStay: ("Stays", "Kalıyor"),
        .willBeTrashed: ("Trash", "Çöpe"),
        .keepThisOne: ("Keep this one", "Bunu tut"),
        .sameContentsDifferentNames: ("Same contents, different names",
                                      "Aynı içerik, farklı adlar"),
        .neverSuggest: ("Never suggest", "Asla önerme"),
        .allExcluded: ("Everything picked is on the never-touch list",
                       "Seçilen her şey dokunulmayacaklar listesinde"),
        .exclusions: ("Never touch these", "Bunlara asla dokunma"),
        .exclusionsExplained: ("Folders here are never proposed for deletion and can never be ticked. They are still measured, so the totals stay honest.",
                               "Buradaki klasörler asla silinmek üzere önerilmez ve işaretlenemez. Yine de ölçülürler, böylece toplamlar doğru kalır."),
        .addExclusion: ("Add folder…", "Klasör ekle…"),
        .removeExclusion: ("Remove", "Kaldır"),
        .noExclusions: ("Nothing is excluded yet", "Henüz hiçbir şey hariç tutulmadı"),
        .trashIsRecoverable: ("Goes to the Trash, and ⌘Z puts it all back",
                              "Çöp Kutusu'na gider, ⌘Z hepsini geri alır"),
        .freeUpSpace: ("Free up space", "Yer aç"),
        .lookingForSpace: ("Looking for the easy wins…", "Kolay kazançlar aranıyor…"),
        .nothingObviousToFree: ("Nothing obvious to free up here. The Copies panel and the largest-files list are the places to look next.",
                                "Burada kolayca boşaltılacak bir şey yok. Sırada Kopyalar paneli ve en büyük dosyalar listesi var."),
        .reviewItems: ("Review…", "İncele…"),
        .showInFinder: ("Show in Finder", "Finder'da göster"),
        .suggestionsNeverDelete: ("Nothing is deleted from here — every one opens the full list first",
                                  "Buradan hiçbir şey silinmez, her biri önce tam listeyi açar"),
        .close: ("Close", "Kapat"),
        .whatChanged: ("What changed", "Ne değişti"),
        .noEarlierScans: ("No earlier scan to compare with yet",
                          "Karşılaştırılacak daha önceki bir tarama yok"),
        .comeBackAfterAnotherScan: ("Every scan is remembered. Come back after the next one.",
                                    "Her tarama kaydediliyor. Bir sonrakinden sonra tekrar bakın."),
        .nothingMovedMuch: ("Nothing moved by more than 50 MB",
                            "50 MB'den fazla değişen bir şey yok"),
        .noNetChange: ("No net change", "Net değişiklik yok"),
        .deepestFolderExplains: ("Each change is attributed to the deepest folder that explains it",
                                 "Her değişiklik onu açıklayan en derin klasöre yazılır"),
        .snapshotUnreadable: ("That earlier scan could not be read",
                              "O eski tarama okunamadı"),
        .safetyComesBack: ("comes back on its own", "kendiliğinden geri gelir"),
        .safetyCopyRemains: ("a copy stays", "bir kopya kalır"),
        .safetyYourCall: ("your call", "size kalmış"),
        .suggestFolders: ("Duplicate folders", "Yinelenen klasörler"),
        .suggestFiles: ("Duplicate files", "Yinelenen dosyalar"),
        .suggestBuild: ("Build output and package caches", "Derleme çıktısı ve paket önbellekleri"),
        .suggestCaches: ("Application caches", "Uygulama önbellekleri"),
        .suggestInstallers: ("Installers you already ran", "Çalıştırdığınız kurulum dosyaları"),
        .suggestStale: ("Big files you have not touched in years", "Yıllardır dokunmadığınız büyük dosyalar"),
        .suggestTrash: ("The Trash", "Çöp Kutusu"),
        .suggestFoldersWhy: ("Folders holding the same thing as another folder. One copy of each is always kept.",
                             "Başka bir klasörle aynı şeyi tutan klasörler. Her birinden bir kopya her zaman kalır."),
        .suggestFilesWhy: ("Files with the same name and size as another. One copy of each is always kept.",
                           "Başkasıyla aynı ad ve boyutta olan dosyalar. Her birinden bir kopya her zaman kalır."),
        .suggestBuildWhy: ("node_modules, DerivedData and friends. The toolchain rebuilds them; deleting one costs you an install, not any work.",
                           "node_modules, DerivedData ve benzerleri. Araçlar bunları yeniden üretir; silmek sadece bir kurulum süresine mal olur."),
        .suggestCachesWhy: ("Files apps keep to start faster. They rebuild them; a few apps will be slow once.",
                            "Uygulamaların hızlı açılmak için tuttuğu dosyalar. Yeniden oluştururlar; birkaç uygulama bir kez yavaş açılır."),
        .suggestInstallersWhy: ("Disk images and packages. If the app is installed, the installer has done its job.",
                                "Disk görüntüleri ve kurulum paketleri. Uygulama kuruluysa kurulum dosyası işini yapmış demektir."),
        .suggestStaleWhy: ("Large files with a modification date over two years old. Nothing here says they are unwanted — only that you have not opened them.",
                           "İki yıldan eski değiştirilme tarihine sahip büyük dosyalar. Bu, istenmedikleri anlamına gelmez; yalnızca açılmadıklarını gösterir."),
        .suggestTrashWhy: ("Already deleted, still taking up space. Emptying it cannot be undone, so this app will not do it for you.",
                           "Zaten silinmiş, hâlâ yer kaplıyor. Boşaltmak geri alınamaz, bu yüzden uygulama sizin yerinize yapmaz."),
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
        .colourTypeShort: ("Type", "Tür"),
        .colourAgeShort: ("Age", "Yaş"),
        .newScanHelp: ("Measure something else", "Başka bir şey ölç"),
        .disksHeader: ("DISKS", "DİSKLER"),
        .foldersHeader: ("FOLDERS", "KLASÖRLER"),
        .theDiskSays: ("The disk", "Disk"),
        .finderSays: ("Finder shows", "Finder gösterir"),
        .sameDiskTwoAnswers: ("The same disk, two answers for how much is free",
                              "Aynı disk, boş alan için iki farklı cevap"),
        .theGapIsPurgeable: ("Finder adds purgeable space to the free side. Those bytes are still occupied: macOS only reclaims them when the disk fills up, so a copy can fail on a disk Finder calls empty.",
                             "Finder, temizlenebilir alanı boş tarafa ekler. O baytlar hâlâ dolu: macOS onları ancak disk dolduğunda geri alır, bu yüzden Finder'ın boş dediği bir diskte kopyalama başarısız olabilir."),
        .whatTheScanReached: ("What the scan could account for", "Taramanın hesabını verebildiği"),
        .measuredByScan: ("Measured, file by file", "Dosya dosya ölçüldü"),
        .notAttributed: ("Not attributed to any file", "Hiçbir dosyaya bağlanamadı"),
        .theNumbers: ("The numbers", "Sayılar"),
        .inUseNotPurgeable: ("In use, cannot be reclaimed", "Kullanımda, geri alınamaz"),
        .finderCountsAsFree: ("Counted as free by Finder", "Finder boş sayıyor"),
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
