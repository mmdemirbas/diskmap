import AppKit
import DiskMapCore
import SwiftUI

/// Renders the real UI to a PNG without a window server or Screen Recording
/// permission, so the interface can be checked in CI or over SSH.
///
///   DISKMAP_RENDER="<paths>|<w>|<h>|<out.png>[|<subdir>[|light|dark[|en|tr]]]"
///
/// `paths` may be several folders separated by commas, which renders a
/// multi-folder scan. Prefix it with `start:` to render the start screen with
/// those folders queued instead of scanning them.
@MainActor
enum OffscreenRenderer {
    static func runIfRequested() -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["DISKMAP_RENDER"] else { return false }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let width = Double(parts[1]), let height = Double(parts[2]) else {
            FileHandle.standardError.write(Data("DISKMAP_RENDER needs path|w|h|out.png\n".utf8))
            return true
        }

        let model = AppModel()
        model.renderMode = true
        if parts.count >= 6, let mode = Appearance(rawValue: parts[5]) { model.appearance = mode }
        if parts.count >= 7, let lang = L10n.Language(rawValue: parts[6]) {
            L10n.shared.preference = lang
        }

        let startOnly = parts[0].hasPrefix("start:")
        let targetSpec = startOnly ? String(parts[0].dropFirst("start:".count)) : parts[0]
        let paths = targetSpec.split(separator: ",").map(String.init)

        if paths.count > 1 || startOnly {
            model.addTargets(paths.map { URL(fileURLWithPath: $0) })
        }
        if let first = paths.first { model.selectedVolumePath = first }
        model.refreshVolume()
        if !startOnly { model.scanSynchronously() }

        if parts.count >= 5, !parts[4].isEmpty, let tree = model.tree {
            // Accept either a path relative to the first root or an absolute one.
            let target = parts[4].hasPrefix("/")
                ? parts[4]
                : (parts[0] == "/" ? "" : parts[0]) + "/" + parts[4]
            if let node = tree.withStore({ $0.find(path: target) }) {
                model.enter(node)
            }
        }
        if let biggest = model.rows.first { model.select(biggest.id) }

        let scheme: ColorScheme = model.appearance == .dark ? .dark : .light
        let view = ContentView(model: model)
            .environment(\.colorScheme, scheme)
            .frame(width: width, height: height)

        // System colours resolve through NSAppearance, not the SwiftUI
        // environment, so both have to be set for an offscreen render.
        let nsAppearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        var image: CGImage?
        nsAppearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            image = renderer.cgImage
        }
        guard let cg = image else {
            FileHandle.standardError.write(Data("render produced no image\n".utf8))
            return true
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return true }
        try? png.write(to: URL(fileURLWithPath: parts[3]))
        FileHandle.standardError.write(Data("wrote \(parts[3]) (\(cg.width)x\(cg.height))\n".utf8))
        return true
    }
}
