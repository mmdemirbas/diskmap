import Darwin

/// Raw `getattrlistbulk(2)` constants. Defined locally because the C macros
/// import inconsistently across SDKs, and their *buffer order* is load-bearing.
enum A {
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let cmnName: UInt32          = 0x0000_0001
    static let cmnObjType: UInt32       = 0x0000_0008
    static let cmnModTime: UInt32       = 0x0000_0400
    static let cmnFlags: UInt32         = 0x0004_0000
    static let cmnFileID: UInt32        = 0x0200_0000
    static let cmnError: UInt32         = 0x2000_0000

    static let fileLinkCount: UInt32    = 0x0000_0001
    static let fileTotalSize: UInt32    = 0x0000_0002
    static let fileAllocSize: UInt32    = 0x0000_0004

    static let bitMapCount: UInt16      = 5
}

/// `fsobj_type_t` values from sys/vnode.h
enum ObjType: UInt32 { case non = 0, reg = 1, dir = 2, blk = 3, chr = 4, lnk = 5, sock = 6, fifo = 7, bad = 8 }

/// Set on iCloud Drive placeholders whose bytes are not on this disk.
/// Reading such a file would trigger a download, so we never open files.
public let SF_DATALESS_FLAG: UInt32 = 0x4000_0000
public let UF_COMPRESSED_FLAG: UInt32 = 0x0000_0020

public struct RawEntry {
    public    var name: UnsafeRawPointer = UnsafeRawPointer(bitPattern: 1)!
    public    var nameLen: Int = 0
    public    var objType: UInt32 = 0
    public    var mtime: Int64 = 0
    public    var stFlags: UInt32 = 0
    public    var fileID: UInt64 = 0
    public    var linkCount: UInt32 = 1
    public    var logicalSize: Int64 = 0
    public    var physicalSize: Int64 = 0
    public    var error: UInt32 = 0

    public     var isDir: Bool { objType == ObjType.dir.rawValue }
    public     var isSymlink: Bool { objType == ObjType.lnk.rawValue }
    public     var isDataless: Bool { stFlags & SF_DATALESS_FLAG != 0 }

    /// What the entry takes on disk. The bulk read's allocation size, except
    /// on a volume that is not local: there the macOS NFS client answers with
    /// the length rounded up to 512 bytes rather than what the server
    /// allocated. A 777-byte file on a Linux share read 1 KB where `lstat`,
    /// and `du` on either side, say 4 KB, and a share of 20,000 small files
    /// came out 17% short. `lstat` carries the server's figure, and is
    /// answered from the attribute cache the listing has just filled: those
    /// 20,000 in 0.24 s. A file in iCloud takes nothing here.
    public func bytesOnDisk(in dirFD: Int32, volumeIsRemote: Bool) -> Int64 {
        if isDataless { return 0 }
        guard volumeIsRemote, !isDir else { return physicalSize }
        var info = stat()
        guard fstatat(dirFD, name.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return physicalSize
        }
        return Int64(info.st_blocks) * 512
    }

    /// Whether the directory open at `fd` is on a volume served from
    /// elsewhere: NFS, SMB, AFP, WebDAV.
    public static func isRemote(dirFD fd: Int32) -> Bool {
        var fs = statfs()
        return fstatfs(fd, &fs) == 0 && fs.f_flags & UInt32(MNT_LOCAL) == 0
    }
}

/// One reusable buffer + attrlist per worker thread.
public final class BulkReader {
    static let bufferSize = 512 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: BulkReader.bufferSize, alignment: 16)
    private var attrList: attrlist

    public init() {
        var al = attrlist()
        al.bitmapcount = A.bitMapCount
        al.commonattr = A.cmnReturnedAttrs | A.cmnError | A.cmnName | A.cmnObjType
                      | A.cmnModTime | A.cmnFlags | A.cmnFileID
        al.volattr = 0
        al.dirattr = 0
        al.fileattr = A.fileLinkCount | A.fileTotalSize | A.fileAllocSize
        al.forkattr = 0
        attrList = al
    }

    deinit { buffer.deallocate() }

    /// Enumerates one directory. Returns 0 on clean EOF, otherwise `errno`.
    /// `body` receives entries pointing into the shared buffer: copy what you keep.
    public func enumerate(dirFD: Int32, _ body: (RawEntry) -> Void) -> Int32 {
        while true {
            let n = withUnsafeMutablePointer(to: &attrList) { alp in
                getattrlistbulk(dirFD, alp, buffer, BulkReader.bufferSize, 0)
            }
            if n == 0 { return 0 }
            if n < 0 { return errno }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(n) {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                var f = entry + 4
                let returned = f.loadUnaligned(as: attribute_set_t.self)
                f += MemoryLayout<attribute_set_t>.size

                var e = RawEntry()

                // ATTR_CMN_ERROR is special-cased: it always follows RETURNED_ATTRS.
                if returned.commonattr & A.cmnError != 0 {
                    e.error = f.loadUnaligned(as: UInt32.self); f += 4
                }
                // Everything else arrives in ascending attribute-bit order.
                if returned.commonattr & A.cmnName != 0 {
                    let off = Int(f.loadUnaligned(as: Int32.self))
                    let len = Int(f.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    e.name = f + off
                    e.nameLen = max(0, len - 1)   // attr_length includes the NUL
                    f += 8
                }
                if returned.commonattr & A.cmnObjType != 0 {
                    e.objType = f.loadUnaligned(as: UInt32.self); f += 4
                }
                if returned.commonattr & A.cmnModTime != 0 {
                    e.mtime = f.loadUnaligned(as: Int64.self); f += 16   // struct timespec
                }
                if returned.commonattr & A.cmnFlags != 0 {
                    e.stFlags = f.loadUnaligned(as: UInt32.self); f += 4
                }
                if returned.commonattr & A.cmnFileID != 0 {
                    e.fileID = f.loadUnaligned(as: UInt64.self); f += 8
                }
                if returned.fileattr & A.fileLinkCount != 0 {
                    e.linkCount = f.loadUnaligned(as: UInt32.self); f += 4
                }
                if returned.fileattr & A.fileTotalSize != 0 {
                    e.logicalSize = f.loadUnaligned(as: Int64.self); f += 8
                }
                if returned.fileattr & A.fileAllocSize != 0 {
                    e.physicalSize = f.loadUnaligned(as: Int64.self); f += 8
                }

                if e.error == 0 && e.nameLen > 0 { body(e) }
                entry += entryLength
            }
        }
    }
}
