import AppKit
import DiskMapCore
import SwiftUI

/// Renders the real UI to a PNG without a window server or Screen Recording
/// permission, so the interface can be checked in CI or over SSH.
///
///   DISKMAP_RENDER="<scanPath>|<width>|<height>|<out.png>[|<relative/subdir>]"
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
        model.selectedVolumePath = parts[0]
        model.refreshVolume()
        model.scanSynchronously()

        if parts.count >= 5, !parts[4].isEmpty, let tree = model.tree {
            let target = parts[0] + "/" + parts[4]
            if let node = tree.withStore({ $0.find(path: target, rootPath: tree.rootPath) }) {
                model.enter(node)
            }
        }
        if let biggest = model.rows.first { model.select(biggest.id) }

        let view = ContentView(model: model).frame(width: width, height: height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
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
