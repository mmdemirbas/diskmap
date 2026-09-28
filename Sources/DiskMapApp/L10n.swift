import DiskMapCore
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

    /// Compact enough for a column that repeats on every row, and in the
    /// language the user picked rather than the system one.
    private static var shortDateFormatters: [String: DateFormatter] = [:]
    func shortDate(_ unix: Int32) -> String {
        guard unix > 0 else { return "" }
        let key = locale.identifier
        if let cached = Self.shortDateFormatters[key] {
            return cached.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
        }
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .short
        f.timeStyle = .none
        Self.shortDateFormatters[key] = f
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

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
    func noTrashOnVolume(_ volume: String) -> String {
        active == .tr
            ? "\(volume) biriminde Çöp Kutusu yok. Disk Haritası yalnızca Çöp Kutusu'na taşır, bu yüzden oradaki hiçbir şey kaldırılamaz."
            : "\(volume) has no Trash. Disk Map only ever moves things to the Trash, so nothing there can be removed."
    }
    func macOSDependsOn(_ name: String) -> String {
        active == .tr
            ? "macOS \(name) klasörüne ihtiyaç duyar; klasör kalır. İçindekiler Çöp Kutusu'na taşınabilir."
            : "macOS depends on the \(name) folder, so it stays. What is inside it can go to the Trash."
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
    func passProgress(_ done: Int, _ total: Int) -> String {
        active == .tr ? "\(fmt(total)) öğenin \(fmt(done)) tanesi"
                      : "\(fmt(done)) of \(fmt(total))"
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
    func coveredBy(_ root: String) -> String {
        active == .tr
            ? "Zaten \(root) içinde ölçülüyor"
            : "Already measured as part of \(root)"
    }
    func alsoCovered(_ n: Int) -> String {
        active == .tr
            ? "\(fmt(n)) öğe zaten seçili bir klasörün içinde, ayrıca taşınmayacak"
            : "\(count(n, "more is", "more are")) inside a folder already listed, so not shown separately"
    }
    /// Ticked, then gone before the review screen opened — a download that
    /// finished elsewhere, a folder emptied in Finder. Counting it silently
    /// leaves the reviewer to notice the list is shorter than their selection.
    func alreadyGone(_ n: Int) -> String {
        active == .tr
            ? "\(fmt(n)) öğe artık yerinde yok, listede de yok"
            : "\(count(n, "item is", "items are")) no longer there, so not listed"
    }
    func onNeverTouchList(_ n: Int) -> String {
        active == .tr
            ? "\(fmt(n)) öğe dokunulmayacaklar listesinde, listeye alınmadı"
            : "\(count(n, "item is", "items are")) on the never-touch list, so not listed"
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
            : "This folder holds \(count(items, "item", "items")) totalling \(size). You can put it back from the Trash or with Undo."
    }
    /// What the index knows about a file, on one line.
    ///
    /// Ordered by what tells you most about the file you are looking at:
    /// shape, then length, then when the content was made. The kind comes last
    /// and only when nothing else was known, because "public.jpeg" beside a
    /// name ending in .jpg says nothing new.
    func contentSummary(_ p: ContentProperties) -> String {
        var parts: [String] = []
        if let w = p.pixelWidth, let h = p.pixelHeight { parts.append("\(w) × \(h)") }
        if let seconds = p.durationSeconds, seconds > 0 { parts.append(duration(seconds)) }
        if let created = p.created {
            parts.append(active == .tr ? "çekim \(dateTime(created))" : "made \(dateTime(created))")
        }
        if !p.codecs.isEmpty { parts.append(p.codecs.joined(separator: ", ")) }
        if parts.isEmpty, let type = p.contentType { parts.append(type) }
        return parts.joined(separator: " · ")
    }

    func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// One file says its size; a folder says how many things are inside it,
    /// because that is the part you cannot see from its name.
    func confirmTrashFileBody(_ size: String) -> String {
        active == .tr
            ? "\(size). Çöp Kutusu'ndan ya da Geri Al ile döndürebilirsiniz."
            : "\(size). You can put it back from the Trash or with Undo."
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
    /// The read-only half of the startup disk, which holds macOS itself and
    /// almost nothing a person put there.
    func systemVolume(_ name: String) -> String {
        active == .tr ? "\(name) (Sistem)" : "\(name) (System)"
    }

    /// The two figures macOS publishes for one disk, added up. They cannot
    /// both be true, and the sum says so faster than any explanation.
    func impossibleSum(_ finderFree: String, _ used: String,
                       _ sum: String, _ capacity: String) -> String {
        active == .tr
            ? "\(finderFree) boş + \(used) kullanılan = \(sum), ama disk \(capacity)."
            : "\(finderFree) free + \(used) used = \(sum), on a \(capacity) disk."
    }

    func differencesFound(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) fark" : count(n, "difference", "differences")
    }
    func stepCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) adım" : count(n, "step", "steps")
    }
    func syncFinished(_ done: Int, _ total: Int) -> String {
        active == .tr ? "\(fmt(total)) adımın \(fmt(done)) tanesi bitti"
                      : "\(fmt(done)) of \(fmt(total)) done"
    }
    /// Future tense, and separate from `syncWrote` on purpose: a plan that
    /// describes itself in the past tense reads as something that has already
    /// happened, on the one screen where nothing has.
    func syncWillWrite(_ written: String, _ toTrash: String) -> String {
        active == .tr ? "\(written) yazacak, \(toTrash) Çöp Kutusu'na taşıyacak"
                      : "Writes \(written), moves \(toTrash) to the Trash"
    }
    func syncWrote(_ written: String, _ toTrash: String) -> String {
        active == .tr ? "\(written) yazıldı, \(toTrash) Çöp Kutusu'na taşındı"
                      : "Wrote \(written), moved \(toTrash) to the Trash"
    }
    func syncFailedSteps(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) adım başarısız oldu" : count(n, "step failed", "steps failed")
    }
    func compareVerifyRead(_ items: Int, _ bytes: String) -> String {
        active == .tr ? "\(fmt(items)) öğe okundu (\(bytes))"
                      : "Read \(fmt(items)) items (\(bytes))"
    }
    func compareContentDiffers(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğenin adı ve boyutu aynı ama içeriği farklı"
                      : (n == 1 ? "1 item matches by name and size but not by content"
                                : "\(fmt(n)) items match by name and size but not by content")
    }
    func compareUnresolvedCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) çakışma çözülmedi" : count(n, "conflict left alone", "conflicts left alone")
    }
    /// Said as a finding rather than as a caveat: the caveat belongs on the
    /// button, which is what the caveat is about.
    ///
    /// Both sides are written out rather than built from the "Left"/"Right"
    /// labels. Turkish needs a case suffix on each of them and the labels are
    /// capitalised, so interpolating produces a sentence with a capital in the
    /// middle and a suffix chosen by nobody.
    func compareHoldsNothingExtra(_ side: Side) -> String {
        if active == .tr {
            return side == .right
                ? "Sağdaki klasörde, soldakinde olmayan hiçbir şey yok"
                : "Soldaki klasörde, sağdakinde olmayan hiçbir şey yok"
        }
        return side == .right
            ? "The right folder holds nothing the left one does not"
            : "The left folder holds nothing the right one does not"
    }
    func compareTrashThisCopy(_ side: Side) -> String {
        if active == .tr {
            return side == .right ? "Sağdaki kopyayı Çöp Kutusu'na taşı"
                                  : "Soldaki kopyayı Çöp Kutusu'na taşı"
        }
        return side == .right ? "Move the right copy to the Trash"
                              : "Move the left copy to the Trash"
    }
    /// Rows, not items. The chips above count items — a folder that matched
    /// all the way down is one row and a thousand items — so when a filter is
    /// narrowing the list, the number of lines actually on screen has to be
    /// said in its own words or it reads as a contradiction.
    func rowsShown(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) satır gösteriliyor"
                      : (n == 1 ? "showing 1 row" : "showing \(fmt(n)) rows")
    }
    func compareIgnoredCount(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe yok sayıldı" : count(n, "item ignored", "items ignored")
    }
    func compareKeptDiffering(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe içerikçe farklı çıktı ve yerinde bırakıldı"
                      : (n == 1 ? "1 item turned out to differ and was left alone"
                                : "\(fmt(n)) items turned out to differ and were left alone")
    }
    // placed with the other sync result strings
    func compareKeptUnreadable(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe okunamadı ya da iCloud'dan indirilmedi, yerinde bırakıldı"
                      : (n == 1 ? "1 item was not settled by the check and was left alone"
                                : "\(fmt(n)) items were not settled by the check and were left alone")
    }
    func compareNotSettled(_ n: Int) -> String {
        active == .tr ? "Karşılaştırma tamamlanmadı: \(fmt(n)) öğe karara bağlanamadı"
                      : (n == 1 ? "Not settled: 1 item was not read"
                                : "Not settled: \(fmt(n)) items were not read")
    }
    func compareLeftInCloud(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe hâlâ iCloud'da; içeriği okumak onları indirmek olurdu"
                      : (n == 1 ? "1 item is still in iCloud — reading it would download it"
                                : "\(fmt(n)) items are still in iCloud — reading them would download them")
    }
    func compareRemovesIgnored(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) öğe, yok sayılan adlar da içinde olmak üzere Çöp'e taşınıyor"
                      : (n == 1 ? "1 item goes to the Trash with ignored names still inside it"
                                : "\(fmt(n)) items go to the Trash with ignored names still inside them")
    }
    func compareIncluded(_ included: Int, _ total: Int) -> String {
        active == .tr ? "\(fmt(total)) karardan \(fmt(included)) tanesi seçili"
                      : "\(fmt(included)) of \(fmt(total)) decisions included"
    }
    func compareSkipped(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) karar dışarıda bırakıldı" : count(n, "decision left out", "decisions left out")
    }
    func compareSideSummary(_ size: String, _ items: Int) -> String {
        active == .tr ? "\(size) · \(fmt(items)) öğe" : "\(size) · \(fmt(items)) items"
    }

    func matchCount(_ n: Int) -> String {
        active == .tr ? "\(n) eşleşme" : count(n, "match", "matches")
    }

    func showingOfMatches(_ shown: Int, _ total: Int) -> String {
        active == .tr ? "\(total) eşleşmenin en büyük \(shown) tanesi"
                      : "Largest \(shown) of \(total) matches"
    }

    func exportedTo(_ name: String, _ size: String) -> String {
        active == .tr ? "\(name) yazıldı (\(size))" : "Wrote \(name) (\(size))"
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
    /// Never lets the rows on screen stand for the whole answer, and says how
    /// much disk the whole answer accounts for rather than only what fits.
    func filesShown(_ shown: Int, _ total: Int, _ bytes: String) -> String {
        if shown >= total {
            return active == .tr ? "\(fmt(total)) satır · \(bytes)"
                                 : "\(fmt(total)) rows · \(bytes)"
        }
        return active == .tr ? "\(fmt(total)) satırın \(fmt(shown)) tanesi · toplam \(bytes)"
                             : "\(fmt(shown)) of \(fmt(total)) rows · \(bytes) in all"
    }

    func showMoreRows(_ n: Int) -> String {
        active == .tr ? "\(fmt(n)) satır daha" : "\(fmt(n)) more"
    }

    func kindsChosen(_ n: Int) -> String {
        active == .tr ? "\(n) tür" : count(n, "kind", "kinds")
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
        case tabMap, tabFiles, tabDuplicates, tabCompare, tabSearch, closeTab
        case filesSubtitle, kind, folder, modified, marks, showInMap
        case filterByName, filterByKind, filterBySize, filterByDate
        case everyKind, includeFolders, clearFilters
        case anySize, underOneMB, atLeast1MB, atLeast10MB, atLeast100MB, atLeast1GB
        case anyTime, lastWeek, lastMonth, lastYear, olderThanAYear, olderThanTwoYears
        case hardlinkMark, symlinkMark, compressedMark, unreadableMark
        case closePane, addPane, dragToRearrange
        case noExtraDetails, notIndexed, notIndexedHelp
        case anyContent, largePictures, longRecordings, screenshots, olderThanFiveYears
        case filterByContent, askingTheIndex, indexHasNothingHere
        case needsAScan, chooseWhatToScan, copiesSubtitle
        case startOverTitle, startOverBody, startOverConfirm
        case alreadyCovered, forgetFolder
        case whereSpaceIs, whereSpaceIsSubtitle, capacity, used, freeReally, freeFinder
        case purgeableNote, writableNow, includesPurgeable
        case scanVsFilesystem, volumeReportsUsed, scanAttributed, unaccounted, done
        case filter, onDisk, apparent, rescan, enclosingFolder, sizeMetricHelp
        case watching, notWatching, watchHelp, undoTrash, tryAgain
        case chooseTarget, volume, scanVolume, addHome, fdaWarning, openPrivacy
        case cancel, size, share, name, emptyFolder, noMatches
        case nothingSelected, nothingSelectedHint, ofVolume, reveal, trash
        case apparentMismatch, openHere, revealInFinder, quickLook, quickLookInICloud, copyPath, moveToTrash
        case icloudZero, pathCopied, scanMenu, appearance, language
        case appearanceSystem, appearanceLight, appearanceDark, cancelScan, scanning
        case showDiagnostics, itemGone
        case nothingToRemove, selectionChanged, cannotRemoveScanRoot, cannotRemoveOutside
        case selectExtras, clearSelection, moveSelectedToTrash, keepsOneCopy
        case syncWarningTitle, alsoDeletedFromService, reviewBeforeTrashing, trashIsRecoverable
        case reviewWhatGoes, tickToChange, willStay, willBeTrashed, keepThisOne
        case sameContentsDifferentNames, neverSuggest, allExcluded, exclusions
        case exclusionsExplained, addExclusion, removeExclusion, noExclusions, neverTouchBadge
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
        case exportResults, nothingToExport, exportFailed
        case findTitle, findPlaceholder, findHint, findNothing, showIt
        case theDiskSays, finderSays, theGapIsPurgeable, sameDiskTwoAnswers
        case measuredByScan, notAttributed, whatTheScanReached, theNumbers
        case inUseNotPurgeable, finderCountsAsFree
        case panelContents, panelLargest, panelTypes, panelDuplicates, computing, ofSubtree
        case phaseMeasuring, phaseSigning, phaseFolders, phaseFiles
        case tabHome, homeTitle, homeSubtitle, homeOpen, homeNeedsAScan
        case blurbMap, blurbFiles, blurbSpace, blurbDuplicates
        case blurbCompare, blurbSearch, blurbChanges
        case duplicatesNote, duplicatesEmpty, reclaimable, sectionFolders, sectionFiles
        case matchExact, verify, verifyAgain, verifyIdentical, verifyStopped
        case ageWeek, ageMonth, ageHalfYear, ageYear, ageTwoYears, ageOlder, staleNote
        case goBack, goForward, expandFolder, collapseFolder, foldersOnlyNote, chooseFolders, choosePanelMessage, dropFolders, orWord, scanWholeDisk
        case clearTargets, addMore, skippedTargets, multipleVolumesNote, targetsHeader
        case compareTitle, compareSubtitle, compareChoose, compareChooseMessage, compareWith
        case compareRun, compareLeftSide, compareRightSide, compareSwap, comparePickBoth
        case compareWaitingForTheOther
        case compareInSync, compareWorking
        case diffIdentical, diffDiffers, diffOnlyLeft, diffOnlyRight, diffClash
        case compareVerifyContents, compareVerified
        case dirMirrorRight, dirMirrorLeft, dirMerge
        case dirUpdateRight, dirUpdateLeft, dirFreeLeft, dirFreeRight
        case dirUpdateRightWhy, dirUpdateLeftWhy, dirFreeLeftWhy, dirFreeRightWhy
        case dirGroupCopy, dirGroupFree
        case compareContentNotChecked, compareContentChecked, compareCheckFirst
        case compareIgnoreTitle, compareIgnoreExplained, compareIgnorePlaceholder
        case compareIgnoreAdd, compareIgnoreReset, compareIgnoreNone, compareIgnoreButton
        case dateExact, dateNearest2, dateNearestHour, dateToleranceHelp
        case selectAll, selectNone, compareRecent, compareNoRecent
        case dirMirrorRightWhy, dirMirrorLeftWhy, dirMergeWhy
        case comparePreview, compareApply, compareWhatWillHappen, compareNothingWritten
        case stepCopy, stepReplace, stepRemove, compareTargetFolder
        case compareUnresolved, compareNotEnoughRoom, compareDownloadsFromCloud
        case compareRedundantHint, syncStopped, syncRefused, syncShowInTrash
        case filterDifferences, filterAll, dateAny, dateLeftNewer, dateRightNewer, dateSame
        case columnDate, nothingMatchesFilter
        case compareAgain, refuseNotAFolder, refuseSameFolder, refuseNested
        case refuseVolumeRoot, refuseExcluded, refuseNothingToDo, refuseNotRedundant
        case refuseComparisonIncomplete, refuseVolumeInside, reviewNotRead
        case refuseUnreadable, compareUnreadableWarning
        case folderLabel, videoLabel, imageLabel, audioLabel, archiveLabel, documentLabel
        case codeLabel, appLabel, diskImageLabel, vmLabel, modelLabel, databaseLabel, cacheLabel, otherLabel
    }

    static let table: [K: (String, String)] = [
        .appName: ("Disk Map", "Disk Haritası"),
        // Short forms, because these sit in a row of tabs rather than at the
        // top of a sheet with the width to explain themselves.
        .tabMap: ("Disk map", "Disk haritası"),
        .tabFiles: ("All files", "Tüm dosyalar"),
        .tabDuplicates: ("Copies", "Kopyalar"),
        .filesSubtitle: ("Every file in the scan on one list, however deep it sits. Sort by a column, or narrow it down, to ask a question the map cannot answer.",
                         "Taramadaki her dosya, ne kadar derinde olursa olsun, tek listede. Haritanın yanıtlayamadığı bir soruyu sormak için bir sütuna göre sıralayın ya da listeyi daraltın."),
        .kind: ("Kind", "Tür"),
        .folder: ("Folder", "Klasör"),
        .modified: ("Modified", "Değiştirilme"),
        // The column of small marks at the end of a row: in iCloud only, a
        // second link, compressed, unreadable.
        .marks: ("Notes", "Notlar"),
        .showInMap: ("Show in the map", "Haritada göster"),
        .filterByName: ("Name contains", "Ad şunu içeriyor"),
        .filterByKind: ("Only these kinds", "Yalnızca bu türler"),
        .filterBySize: ("Only these sizes", "Yalnızca bu boyutlar"),
        .filterByDate: ("Only these dates", "Yalnızca bu tarihler"),
        .everyKind: ("Every kind", "Her tür"),
        .includeFolders: ("Folders too", "Klasörler de"),
        .clearFilters: ("Clear", "Temizle"),
        .anySize: ("Any size", "Her boyut"),
        .underOneMB: ("Under 1 MB", "1 MB'ın altı"),
        .atLeast1MB: ("1 MB and up", "1 MB ve üstü"),
        .atLeast10MB: ("10 MB and up", "10 MB ve üstü"),
        .atLeast100MB: ("100 MB and up", "100 MB ve üstü"),
        .atLeast1GB: ("1 GB and up", "1 GB ve üstü"),
        .anyTime: ("Any date", "Her tarih"),
        .lastWeek: ("Last 7 days", "Son 7 gün"),
        .lastMonth: ("Last 30 days", "Son 30 gün"),
        .lastYear: ("Last year", "Son bir yıl"),
        .olderThanAYear: ("Untouched for a year", "Bir yıldır dokunulmamış"),
        .olderThanTwoYears: ("Untouched for two years", "İki yıldır dokunulmamış"),
        .hardlinkMark: ("A second link to bytes already counted somewhere else",
                        "Başka bir yerde zaten sayılmış baytlara ikinci bağlantı"),
        .symlinkMark: ("A symbolic link, not the file itself",
                       "Sembolik bağlantı, dosyanın kendisi değil"),
        .compressedMark: ("Stored compressed by the filesystem",
                          "Dosya sistemi tarafından sıkıştırılmış olarak saklanıyor"),
        .unreadableMark: ("Could not be read", "Okunamadı"),
        .noExtraDetails: ("Nothing further about this file", "Bu dosya hakkında başka bilgi yok"),
        .notIndexed: ("Not in Spotlight's index", "Spotlight dizininde yok"),
        .notIndexedHelp: ("Dimensions, length and capture dates come from Spotlight. This volume, or this folder, is not indexed — so there is nothing to read rather than nothing to say.",
                          "Boyut, süre ve çekim tarihi Spotlight'tan gelir. Bu birim ya da bu klasör dizine alınmamış; yani söylenecek bir şey yok değil, okunacak bir şey yok."),
        .anyContent: ("Anything inside", "İçeriği fark etmez"),
        // Not "pictures": a video has pixel dimensions too, and on this disk the
        // biggest things this question finds are films. The label says what the
        // question actually asks.
        .largePictures: ("2000 pixels wide or more", "2000 piksel ve daha geniş"),
        .longRecordings: ("Recordings over 10 minutes", "10 dakikadan uzun kayıtlar"),
        .screenshots: ("Screenshots", "Ekran görüntüleri"),
        .olderThanFiveYears: ("Taken more than 5 years ago", "5 yıldan eski çekimler"),
        .filterByContent: ("Only files whose contents match. Answered by Spotlight, which has already read them — nothing is opened here.",
                           "Yalnızca içeriği eşleşen dosyalar. Yanıt, bu dosyaları zaten okumuş olan Spotlight'tan gelir; burada hiçbir dosya açılmaz."),
        .askingTheIndex: ("Asking Spotlight…", "Spotlight'a soruluyor…"),
        .indexHasNothingHere: ("Spotlight has not indexed what was scanned, so this question cannot be answered here — which is not the same as nothing matching.",
                               "Spotlight taranan yeri dizine almamış, bu yüzden bu soru burada yanıtlanamıyor. Bu, hiçbir şeyin eşleşmediği anlamına gelmez."),
        .closePane: ("Close this view", "Bu görünümü kapat"),
        .addPane: ("Add a view here", "Buraya bir görünüm ekle"),
        .dragToRearrange: ("Drag onto another view to place it beside or behind it",
                           "Yerleştirmek için başka bir görünümün üzerine sürükleyin"),
        .tabCompare: ("Compare", "Karşılaştır"),
        .tabSearch: ("Find", "Bul"),
        .closeTab: ("Close tab", "Sekmeyi kapat"),
        .needsAScan: ("This tool reads a scan, and nothing has been scanned yet",
                      "Bu araç bir tarama okur, henüz hiçbir şey taranmadı"),
        .chooseWhatToScan: ("Choose what to scan", "Ne taranacağını seçin"),
        .startOverTitle: ("Measure something else?", "Başka bir şey ölçülsün mü?"),
        .startOverBody: ("This throws away the scan and everything open with it, including the list of what was moved to the Trash — those items stay in the Trash, but this app can no longer put them back.",
                         "Bu, taramayı ve onunla birlikte açık olan her şeyi atar; Çöp Kutusu'na taşınanların listesi de buna dahildir — o öğeler Çöp Kutusu'nda kalır, ancak bu uygulama artık onları geri koyamaz."),
        .startOverConfirm: ("Start over", "Baştan başla"),
        .alreadyCovered: ("in a ticked disk", "işaretli bir diskin içinde"),
        .forgetFolder: ("Remove from the list", "Listeden çıkar"),
        .copiesSubtitle: ("Folders and files that appear more than once. Nothing is removed from here — every row opens the full list first.",
                          "Birden fazla kez görünen klasörler ve dosyalar. Buradan hiçbir şey silinmez — her satır önce tam listeyi açar."),
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
        .addHome: ("Home Folder", "Ana klasör"),
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
        // On a row that cannot be ticked, where the reason has to fit beside a
        // path and be readable without hovering for a tooltip.
        .neverTouchBadge: ("Never touch", "Dokunma"),
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
        .quickLook: ("Quick Look", "Hızlı Bakış"),
        .quickLookInICloud: ("This file is in iCloud only. Showing it would download it.",
                             "Bu dosya yalnızca iCloud'da. Göstermek için indirilmesi gerekir."),
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
        .exportResults: ("Export Results…", "Sonuçları Dışa Aktar…"),
        .nothingToExport: ("Measure something first", "Önce bir şey ölçün"),
        .exportFailed: ("Could not write the file", "Dosya yazılamadı"),
        .findTitle: ("Find…", "Bul…"),
        .findPlaceholder: ("Type part of a name, or a path", "Adın bir parçasını veya bir yol yazın"),
        .findHint: ("Biggest matches first. Double-click to go there.",
                    "Önce en büyük eşleşmeler. Gitmek için çift tıklayın."),
        .findNothing: ("Nothing matched", "Eşleşen bir şey yok"),
        .showIt: ("Show", "Göster"),
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
        .tabHome: ("Tools", "Araçlar"),
        .homeTitle: ("Every tool in here", "Buradaki bütün araçlar"),
        .homeSubtitle: ("Pick one. Opening a tool does not close another.",
                        "Birini seçin. Bir aracı açmak diğerini kapatmaz."),
        .homeOpen: ("open", "açık"),
        .homeNeedsAScan: ("needs a scan", "tarama gerekir"),
        .blurbMap: ("Where the space went, as a picture you can walk into",
                    "Alanın nereye gittiği, içine girebileceğiniz bir resim olarak"),
        .blurbFiles: ("Every file at once, in one sortable, filterable table",
                      "Bütün dosyalar tek tabloda; sıralanır, süzülür"),
        .blurbSpace: ("The easy wins, ranked by what deleting them would free",
                      "Kolay kazançlar, silmenin boşaltacağı yere göre sıralı"),
        .blurbDuplicates: ("Folders and files that hold the same thing twice",
                           "Aynı şeyi iki kez tutan klasörler ve dosyalar"),
        .blurbCompare: ("Two folders side by side, item by item",
                        "İki klasör yan yana, madde madde"),
        .blurbSearch: ("Find anything by name, ranked by how well it matches",
                       "Adına göre arayın; eşleşme kalitesine göre sıralanır"),
        .blurbChanges: ("What grew, shrank, appeared or went since the scan",
                        "Taramadan bu yana ne büyüdü, küçüldü, geldi, gitti"),
        .phaseMeasuring: ("Adding up the folder", "Klasör toplamı çıkarılıyor"),
        .phaseSigning: ("Fingerprinting folders", "Klasörlerin parmak izi alınıyor"),
        .phaseFolders: ("Matching folders", "Klasörler eşleştiriliyor"),
        .phaseFiles: ("Matching files", "Dosyalar eşleştiriliyor"),
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
        .compareTitle: ("Compare two folders", "İki klasörü karşılaştır"),
        .compareSubtitle: ("The same name at the same size counts as a match, and nothing is read — so a file changed without changing size looks the same here. The content check settles that.",
                           "Aynı boyuttaki aynı ad eşleşme sayılır ve hiçbir dosya okunmaz; boyutu değişmeden içeriği değişen bir dosya burada aynı görünür. İçerik denetimi bunu çözer."),
        .compareChoose: ("Choose", "Seç"),
        .compareChooseMessage: ("Pick the folder to compare", "Karşılaştırılacak klasörü seçin"),
        .compareWith: ("Compare with…", "Şununla karşılaştır…"),
        .compareRun: ("Compare", "Karşılaştır"),
        .compareLeftSide: ("Left", "Sol"),
        .compareRightSide: ("Right", "Sağ"),
        .compareSwap: ("Swap sides", "Tarafları değiştir"),
        .comparePickBoth: ("Pick two folders", "İki klasör seçin"),
        .compareWaitingForTheOther: (
            "Drop one here, or right-click it in the Finder \u{2192} Compare in Disk Map",
            "Buraya sürükleyin ya da Finder'da sağ tıklayıp \u{2192} Disk Map ile karşılaştır"),
        .compareInSync: ("Both folders hold the same thing", "İki klasör de aynı şeyi tutuyor"),
        .compareWorking: ("Reading both folders…", "İki klasör de okunuyor…"),
        .diffIdentical: ("Same", "Aynı"),
        .diffDiffers: ("Different", "Farklı"),
        .diffOnlyLeft: ("Only left", "Yalnızca solda"),
        .diffOnlyRight: ("Only right", "Yalnızca sağda"),
        .diffClash: ("Folder against file", "Klasöre karşı dosya"),
        .compareVerifyContents: ("Check the contents", "İçerikleri denetle"),
        .compareVerified: ("Every item called the same really is",
                           "Aynı denilen her öğe gerçekten aynı"),
        .dirMirrorRight: ("Mirror left → right", "Soldan sağa yansıt"),
        .dirMirrorLeft: ("Mirror right → left", "Sağdan sola yansıt"),
        .dirMerge: ("Give each side everything", "Her iki tarafa da tümünü ver"),
        .dirUpdateRight: ("Update right (never delete)", "Sağı güncelle (hiç silmeden)"),
        .dirUpdateLeft: ("Update left (never delete)", "Solu güncelle (hiç silmeden)"),
        .dirFreeLeft: ("Free space on the left", "Solda yer aç"),
        .dirFreeRight: ("Free space on the right", "Sağda yer aç"),
        .dirUpdateRightWhy: ("Copies what the right is missing, and replaces a file only where the left is the newer one. Nothing is ever removed.",
                             "Sağda olmayanları kopyalar; bir dosyayı yalnızca sol daha yeniyse değiştirir. Hiçbir şey kaldırılmaz."),
        .dirUpdateLeftWhy: ("Copies what the left is missing, and replaces a file only where the right is the newer one. Nothing is ever removed.",
                            "Solda olmayanları kopyalar; bir dosyayı yalnızca sağ daha yeniyse değiştirir. Hiçbir şey kaldırılmaz."),
        .dirFreeLeftWhy: ("Moves to the Trash everything on the left that the right already holds. What is only on the left stays where it is.",
                          "Sağda zaten bulunan her şeyi soldan Çöp Kutusu'na taşır. Yalnızca solda olanlar yerinde kalır."),
        .dirFreeRightWhy: ("Moves to the Trash everything on the right that the left already holds. What is only on the right stays where it is.",
                           "Solda zaten bulunan her şeyi sağdan Çöp Kutusu'na taşır. Yalnızca sağda olanlar yerinde kalır."),
        .dirGroupCopy: ("Copy and mirror", "Kopyala ve yansıt"),
        .dirGroupFree: ("Free up space", "Yer aç"),
        .reviewNotRead: ("Not read", "Okunmadı"),
        .compareContentNotChecked: ("Nothing has been read. Same name and same size is not the same bytes — check the contents before removing anything on this basis.",
                                    "Hiçbir dosya okunmadı. Aynı ad ve aynı boyut, aynı bayt demek değildir; buna dayanarak bir şey kaldırmadan önce içerikleri denetleyin."),
        .compareContentChecked: ("The contents were read and agree", "İçerikler okundu ve eşleşti"),
        .compareCheckFirst: ("Check the contents first", "Önce içerikleri denetle"),
        .compareIgnoreTitle: ("Names to leave out", "Dışarıda bırakılacak adlar"),
        .compareIgnoreExplained: ("Shell patterns matched against the name alone, on both sides — *.tmp, node_modules, .git. Ignored items are counted on the comparison screen, never hidden silently.",
                                  "Her iki tarafta da yalnızca ada uygulanan kabuk kalıpları: *.tmp, node_modules, .git. Atlanan öğeler karşılaştırma ekranında sayılır, sessizce gizlenmez."),
        .compareIgnorePlaceholder: ("*.tmp", "*.tmp"),
        .compareIgnoreAdd: ("Add", "Ekle"),
        .compareIgnoreReset: ("Back to the defaults", "Varsayılanlara dön"),
        .compareIgnoreNone: ("Nothing is being left out", "Hiçbir şey dışarıda bırakılmıyor"),
        .compareIgnoreButton: ("Ignore…", "Yok say…"),
        .dateExact: ("Exact dates", "Tarihler birebir"),
        .dateNearest2: ("Within 2 seconds", "2 saniyeye kadar aynı"),
        .dateNearestHour: ("Within an hour", "1 saate kadar aynı"),
        .dateToleranceHelp: ("exFAT rounds to 2 seconds, and a daylight-saving shift moves everything by an hour.",
                             "exFAT 2 saniyeye yuvarlar; yaz saati geçişi de her şeyi bir saat kaydırır."),
        .selectAll: ("All", "Tümü"),
        .selectNone: ("None", "Hiçbiri"),
        .compareRecent: ("Recent pairs", "Son karşılaştırmalar"),
        .compareNoRecent: ("No earlier comparisons yet", "Henüz eski bir karşılaştırma yok"),
        .dirMirrorRightWhy: ("The right folder ends up exactly like the left one. What only the right has goes to the Trash.",
                             "Sağdaki klasör tıpatıp soldaki gibi olur. Yalnızca sağda olanlar Çöp Kutusu'na gider."),
        .dirMirrorLeftWhy: ("The left folder ends up exactly like the right one. What only the left has goes to the Trash.",
                            "Soldaki klasör tıpatıp sağdaki gibi olur. Yalnızca solda olanlar Çöp Kutusu'na gider."),
        .dirMergeWhy: ("Each side gets what the other has. Nothing is removed.",
                       "Her taraf ötekinde olanı alır. Hiçbir şey silinmez."),
        .comparePreview: ("See what would happen…", "Ne olacağını gör…"),
        .compareApply: ("Do it", "Uygula"),
        .compareWhatWillHappen: ("What will happen", "Ne olacak"),
        .compareNothingWritten: ("Nothing has been written yet", "Henüz hiçbir şey yazılmadı"),
        .stepCopy: ("Copy", "Kopyala"),
        .stepReplace: ("Replace", "Değiştir"),
        .stepRemove: ("To Trash", "Çöpe"),
        .compareTargetFolder: ("Everything happens inside", "Her şey şunun içinde olur"),
        .compareUnresolved: ("Left alone: the two sides disagree and neither is clearly newer",
                             "Dokunulmadı: iki taraf ayrışıyor ve hangisinin daha yeni olduğu belli değil"),
        .compareNotEnoughRoom: ("There is not enough free space for what this writes",
                                "Bunun yazacağı kadar boş yer yok"),
        .compareDownloadsFromCloud: ("Some of these live only in iCloud. Copying them downloads them.",
                                     "Bunların bazıları yalnızca iCloud'da duruyor. Kopyalamak onları indirir."),
        .compareRedundantHint: ("Offered only while the other folder holds everything this one does",
                                "Yalnızca öteki klasör bunun tuttuğu her şeyi tuttuğu sürece sunulur"),
        .filterDifferences: ("Differences", "Farklar"),
        .filterAll: ("All", "Tümü"),
        .dateAny: ("Any date", "Tarihe bakma"),
        .dateLeftNewer: ("Left is newer", "Sol daha yeni"),
        .dateRightNewer: ("Right is newer", "Sağ daha yeni"),
        .dateSame: ("Same date", "Aynı tarih"),
        .columnDate: ("Date", "Tarih"),
        .nothingMatchesFilter: ("Nothing here matches that filter",
                                "Bu süzgece uyan bir şey yok"),
        .syncStopped: ("Stopped part-way", "Yarıda durduruldu"),
        .syncRefused: ("Nothing was done", "Hiçbir şey yapılmadı"),
        .syncShowInTrash: ("Show what went to the Trash", "Çöpe gidenleri göster"),
        .compareAgain: ("Compare again", "Yeniden karşılaştır"),
        .refuseNotAFolder: ("That is not a folder", "Bu bir klasör değil"),
        .refuseSameFolder: ("Those are the same folder", "Bunlar aynı klasör"),
        .refuseNested: ("One of those is inside the other", "Bunlardan biri ötekinin içinde"),
        .refuseVolumeRoot: ("That target is a whole disk. Mirroring onto one would propose deleting everything the source does not have.",
                            "Hedef bütün bir disk. Bir diske yansıtmak, kaynakta olmayan her şeyi silmeyi önerirdi."),
        .refuseExcluded: ("That folder is on the never-touch list",
                          "O klasör dokunulmayacaklar listesinde"),
        .refuseNothingToDo: ("Nothing to do — they already match", "Yapacak bir şey yok, zaten eşleşiyorlar"),
        .refuseVolumeInside: (
            "Another disk is mounted inside this folder, and nothing under it was compared:",
            "Bu klasörün içinde başka bir disk bağlı ve altındaki hiçbir şey karşılaştırılmadı:"),
        .refuseComparisonIncomplete: (
            "The comparison was stopped before it finished, so compare again first",
            "Karşılaştırma tamamlanmadan durduruldu, önce yeniden karşılaştırın"),
        .refuseNotRedundant: ("This copy holds something the other one does not",
                              "Bu kopyada ötekinde olmayan bir şey var"),
        .refuseUnreadable: ("Some folders could not be read, so a mirror would propose deleting what it never saw. Grant Full Disk Access and compare again.",
                            "Bazı klasörler okunamadı; yansıtma, hiç görmediği şeyleri silmeyi önerirdi. Tam Disk Erişimi verip yeniden karşılaştırın."),
        .compareUnreadableWarning: ("Some folders could not be read, so this comparison is not complete",
                                    "Bazı klasörler okunamadı, bu karşılaştırma eksik"),
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
