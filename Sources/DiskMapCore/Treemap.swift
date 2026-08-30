import CoreGraphics
import Foundation

public struct TreemapCell: Sendable {
    public let node: Int32
    public let rect: CGRect
    public let depth: Int
    public let isDirectory: Bool
    /// Set on the synthetic cell that stands in for a tail of items too small to draw.
    public let aggregatedCount: Int
}

public enum Treemap {
    /// Squarified treemap (Bruls, Huizing & van Wijk 2000). Rectangles are kept
    /// near-square because long slivers are impossible to compare by eye or to click.
    public static func squarify(areas: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: areas.count)
        var free = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(free.width, free.height))
            if side <= 0.0001 { break }

            var sum = 0.0, lo = Double.infinity, hi = 0.0
            var bestWorst = Double.infinity
            var count = 0
            var j = i
            while j < areas.count {
                let v = max(areas[j], 0)
                let nsum = sum + v
                if nsum <= 0 { j += 1; count += 1; continue }
                let nlo = Swift.min(lo, v), nhi = Swift.max(hi, v)
                let sq = side * side
                let worst = Swift.max(sq * nhi / (nsum * nsum),
                                      nlo > 0 ? (nsum * nsum) / (sq * nlo) : .infinity)
                if worst > bestWorst { break }
                bestWorst = worst; sum = nsum; lo = nlo; hi = nhi
                count += 1; j += 1
            }
            if count == 0 { count = 1; sum = max(areas[i], 0) }

            let end = i + count
            if sum <= 0 {
                for k in i..<end { out[k] = .zero }
            } else if free.width >= free.height {
                let colW = CGFloat(sum) / free.height
                var y = free.minY
                for k in i..<end {
                    let h = CGFloat(max(areas[k], 0) / sum) * free.height
                    out[k] = CGRect(x: free.minX, y: y, width: colW, height: h)
                    y += h
                }
                free = CGRect(x: free.minX + colW, y: free.minY,
                              width: max(0, free.width - colW), height: free.height)
            } else {
                let rowH = CGFloat(sum) / free.width
                var x = free.minX
                for k in i..<end {
                    let w = CGFloat(max(areas[k], 0) / sum) * free.width
                    out[k] = CGRect(x: x, y: free.minY, width: w, height: rowH)
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + rowH,
                              width: free.width, height: max(0, free.height - rowH))
            }
            i = end
        }
        return out
    }

    /// Lays out `root`'s subtree. Recursion stops where a cell is too small to
    /// see, so cost tracks the pixels on screen, not the millions of nodes below.
    public static func layout(store: NodeStore, root: Int32, in rect: CGRect,
                              usePhysicalSize: Bool = true,
                              minCellArea: CGFloat = 26,
                              maxDepth: Int = 6,
                              includeAtRoot: ((Int32) -> Bool)? = nil) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        cells.reserveCapacity(4096)
        var stack: [(node: Int32, rect: CGRect, depth: Int)] = [(root, rect, 0)]
        let sizes = usePhysicalSize ? store.totalPhysical : store.totalLogical

        while let frame = stack.popLast() {
            guard frame.depth < maxDepth,
                  frame.rect.width > 1, frame.rect.height > 1 else { continue }

            var kids = Array(store.children(frame.node))
            // A filter applies to the level the user is looking at, so the map
            // and the list on the right always describe the same set.
            if frame.depth == 0, let include = includeAtRoot {
                kids = kids.filter(include)
            }
            guard !kids.isEmpty else { continue }

            // Total first, so the visibility threshold can be expressed in
            // bytes and applied in one pass. A directory with a million entries
            // then sorts only the handful that could occupy a visible cell,
            // instead of sorting a million ids on every resize.
            var total = 0.0
            for id in kids where !store.flagSet(id).contains(.removed) {
                let b = sizes[Int(id)]
                if b > 0 { total += Double(b) }
            }
            guard total > 0 else { continue }
            let area = Double(frame.rect.width * frame.rect.height)
            let scale = area / total
            let minBytes = Double(minCellArea) / scale

            var visible: [Int32] = []
            var tailBytes = 0.0
            var tailCount = 0
            var largestBelow: Int32 = -1
            for id in kids where !store.flagSet(id).contains(.removed) {
                let b = Double(sizes[Int(id)])
                if b <= 0 { continue }
                if b < minBytes {
                    tailBytes += b
                    tailCount += 1
                    if largestBelow < 0 || b > Double(sizes[Int(largestBelow)]) { largestBelow = id }
                } else {
                    visible.append(id)
                }
            }
            // Never render a folder as nothing but an anonymous tail.
            if visible.isEmpty, largestBelow >= 0 {
                visible.append(largestBelow)
                tailBytes -= Double(sizes[Int(largestBelow)])
                tailCount -= 1
            }
            guard !visible.isEmpty else { continue }
            visible.sort { sizes[Int($0)] > sizes[Int($1)] }

            var areas = visible.map { Double(sizes[Int($0)]) * scale }
            if tailCount > 0 { areas.append(tailBytes * scale) }

            let rects = squarify(areas: areas, in: frame.rect)
            for (k, id) in visible.enumerated() {
                let r = rects[k]
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let isDir = store.isDirectory(id)
                cells.append(TreemapCell(node: id, rect: r, depth: frame.depth + 1,
                                         isDirectory: isDir, aggregatedCount: 0))
                if isDir, r.width * r.height > minCellArea * 8 {
                    // Shallow levels get a wider margin so the folder that owns
                    // a block is visible as a frame around it.
                    let inset: CGFloat = frame.depth == 0 ? 4 : (frame.depth == 1 ? 3 : 1.5)
                    let head: CGFloat = (frame.depth < 2 && r.height > 46) ? 15 : 0
                    var child = r.insetBy(dx: inset, dy: inset)
                    child.origin.y += head
                    child.size.height -= head
                    if child.width > 2, child.height > 2 {
                        stack.append((id, child, frame.depth + 1))
                    }
                }
            }
            if tailCount > 0, rects.count == areas.count, let r = rects.last,
               r.width > 0.5, r.height > 0.5 {
                cells.append(TreemapCell(node: -1, rect: r, depth: frame.depth + 1,
                                         isDirectory: false, aggregatedCount: tailCount))
            }
        }
        return cells
    }
}

public enum FileCategory: Int, Sendable, CaseIterable {
    case folder, video, image, audio, archive, document, code, application
    case diskImage, virtualMachine, model, cache, other

    public var label: String {
        switch self {
        case .folder: "Folder";           case .video: "Video"
        case .image: "Image";             case .audio: "Audio"
        case .archive: "Archive";         case .document: "Document"
        case .code: "Code";               case .application: "App"
        case .diskImage: "Disk image";    case .virtualMachine: "Virtual machine"
        case .model: "AI model";          case .cache: "Cache"
        case .other: "Other"
        }
    }
}

public enum Categorizer {
    private static let table: [String: FileCategory] = {
        var m: [String: FileCategory] = [:]
        let groups: [(FileCategory, [String])] = [
            (.video, ["mov","mp4","m4v","avi","mkv","insv","mts","m2ts","webm","mpg","mpeg","braw","r3d","prores"]),
            (.image, ["jpg","jpeg","png","gif","heic","heif","tif","tiff","raw","cr2","cr3","nef","arw","dng","webp","psd","svg","bmp"]),
            (.audio, ["mp3","aac","m4a","wav","aiff","flac","ogg","opus","caf"]),
            (.archive,["zip","tar","gz","bz2","xz","7z","rar","zst","tgz","pkg","jar"]),
            (.document,["pdf","doc","docx","xls","xlsx","ppt","pptx","key","numbers","pages","txt","md","epub","csv"]),
            (.code, ["swift","c","h","cpp","hpp","m","mm","java","kt","scala","go","rs","py","js","ts","tsx","jsx","rb","sh","sql","json","yaml","yml","xml","html","css"]),
            (.diskImage,["dmg","iso","sparsebundle","sparseimage","img","raw"]),
            (.virtualMachine,["hds","pvm","vmdk","vdi","qcow2","utm"]),
            (.model, ["gguf","safetensors","ckpt","pt","pth","onnx","mlmodel","mlpackage","bin"]),
        ]
        for (cat, exts) in groups { for e in exts { m[e] = cat } }
        return m
    }()

    public static func of(name: String, isDirectory: Bool, path: String? = nil) -> FileCategory {
        if isDirectory {
            let lower = name.lowercased()
            if lower.hasSuffix(".app") { return .application }
            if lower.hasSuffix(".pvm") || lower.hasSuffix(".utm") { return .virtualMachine }
            if lower == "caches" || lower == "cache" || lower == ".cache" { return .cache }
            return .folder
        }
        if let p = path, p.contains("/Caches/") || p.contains("/Library/Caches") { return .cache }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return table[ext] ?? .other
    }
}
