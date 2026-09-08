import AppKit
import DiskMapCore
import SwiftUI

/// Reaching the app from the Finder, without leaving the Finder first.
///
/// Selecting two folders, right-clicking and choosing a comparison is how
/// somebody who has just noticed two similar folders actually wants to start —
/// not by switching app, then finding the tool, then typing both paths in.
///
/// This is the Services half. It needs nothing but an `NSServices` entry in the
/// bundle's Info.plist, which the build script already writes and signs. The
/// entries land under the *Services* submenu rather than at the top level of
/// the context menu; putting them at the top level needs a Finder Sync app
/// extension, which is a separate bundle with its own signing and cannot be
/// produced by a Swift package at all.
@MainActor
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    /// Set once the window exists. A service can arrive before anything is on
    /// screen, because choosing one launches the app.
    weak var model: AppModel?

    /// Compares the two selected folders.
    ///
    /// Finder allows the service on any number of folders; two is the only
    /// count that means anything here, so one is filled into the left side and
    /// left waiting, and more than two takes the first two rather than refusing
    /// a selection the user has already made.
    @objc func compareFolders(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let folders = self.folders(on: pasteboard)
        guard let model, !folders.isEmpty else {
            error.pointee = "Select one or two folders." as NSString
            return
        }
        model.setCompareSide(.left, folders[0])
        if folders.count > 1 { model.setCompareSide(.right, folders[1]) }
        model.open(.compare)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Measures the selected folders, as one total.
    @objc func measureFolders(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let folders = self.folders(on: pasteboard)
        guard let model, !folders.isEmpty else {
            error.pointee = "Select a folder." as NSString
            return
        }
        model.clearTargets()
        model.addTargets(folders)
        model.activeTab = .map
        model.scan()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func folders(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: options) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path,
                                                        isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }
}
