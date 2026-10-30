// Writes the DMG window's layout, <volume>/.DS_Store, as Finder would have saved it: the window's size and
// place, icon view at 128 px with the background picture, and where Sunlight and Applications sit, so the
// disk image opens laid out on any Mac. scripts/package.sh runs it on the read-write image before
// compressing it; the background is referred to by a bookmark made on that very volume, in the folder's
// pBBk record (Finder reads a bookmark only there: in icvp's backgroundImageAlias it wants an old-style
// alias record, which today's SDK can no longer make, and it ignores a bookmark put there instead).
//   swift scripts/make-dmg-layout.swift /path/to/mounted/volume
// The file is the Finder's "Bud1" buddy-allocator format holding one B-tree page of records.
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-dmg-layout.swift <mounted volume>\n".data(using: .utf8)!)
    exit(1)
}
let volume = URL(fileURLWithPath: args[1])
// The window frame, in points, title bar included (so 28 taller than the 660 × 420 background), measured
// from the bottom left of the screen: a y this big lands the window at the top on any screen, since Finder
// keeps it on the screen, and 200 in from the left.
let window = (x: 200, y: 760, width: 660, height: 448)
let iconSize = 128.0, textSize = 12.0
let icons = [("Sunlight.app", 165, 200), ("Applications", 495, 200)]   // icon centres, in points

// Big-endian helpers.
extension Data {
    mutating func u32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func ascii(_ s: String) { append(contentsOf: Array(s.utf8)) }
    mutating func utf16(_ s: String) { for u in s.utf16 { u16(u) } }
    mutating func put(_ d: Data, at offset: Int) { replaceSubrange(offset..<offset + d.count, with: d) }
}

// A record: the file's name, a four-letter kind, and a typed value.
enum Value { case long(UInt32), type(String), blob(Data) }
struct Record { let name: String, code: String, value: Value }
func encode(_ r: Record) -> Data {
    var d = Data()
    d.u32(UInt32(r.name.utf16.count)); d.utf16(r.name); d.ascii(r.code)
    switch r.value {
    case .long(let v): d.ascii("long"); d.u32(v)
    case .type(let s): d.ascii("type"); d.ascii(s)
    case .blob(let b): d.ascii("blob"); d.u32(UInt32(b.count)); d.append(b)
    }
    return d
}
func plist(_ dict: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
}

// The records Finder keeps for the folder itself (".") and for each icon.
let background = volume.appendingPathComponent(".background/background.tiff")
let bookmark = try background.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
var records: [Record] = [
    Record(name: ".", code: "bwsp", value: .blob(try plist([
        "WindowBounds": "{{\(window.x), \(window.y)}, {\(window.width), \(window.height)}}",
        "ShowToolbar": false, "ShowSidebar": false, "ShowStatusBar": false, "ShowPathbar": false,
        "ShowTabView": false, "ContainerShowSidebar": false, "PreviewPaneVisibility": false, "SidebarWidth": 0,
    ]))),
    Record(name: ".", code: "icvp", value: .blob(try plist([
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "iconSize": iconSize, "textSize": textSize, "labelOnBottom": true, "arrangeBy": "none",
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "showIconPreview": true, "showItemInfo": false, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    ]))),
    Record(name: ".", code: "fwi0", value: .blob({   // the pre-10.5 window record, still written by Finder
        var d = Data()
        d.u16(UInt16(window.y)); d.u16(UInt16(window.x))
        d.u16(UInt16(window.y + window.height)); d.u16(UInt16(window.x + window.width))
        d.ascii("icnv"); d.u32(0)
        return d
    }())),
    Record(name: ".", code: "icvl", value: .type("icnv")),
    Record(name: ".", code: "pBBk", value: .blob(bookmark)),
    Record(name: ".", code: "vSrn", value: .long(1)),
]
for (name, x, y) in icons {
    var d = Data()
    d.u32(UInt32(x)); d.u32(UInt32(y)); d.u32(0xFFFF_FFFF); d.u32(0xFFFF_0000)
    records.append(Record(name: name, code: "Iloc", value: .blob(d)))
}
// The tree is sorted by name, case-insensitively, then by kind.
records.sort { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }

// One leaf page holds every record.
let pageSize = 4096
var page = Data()
page.u32(0)                              // no child pages
page.u32(UInt32(records.count))
for r in records { page.append(encode(r)) }
guard page.count <= pageSize else {
    FileHandle.standardError.write("The layout doesn't fit one page (\(page.count) bytes)\n".data(using: .utf8)!)
    exit(1)
}

// The buddy allocator's layout, as in a fresh Finder file: the 32-byte header at 0, the tree's superblock
// (block 1, 32 bytes) at 64, the bookkeeping block (block 0, 2 KB) at 2048 and the page (block 2, 4 KB)
// at 4096, in a 2 GB address space of which the rest is on the free lists. Addresses are offset | log2(size).
let superblock = 64, root = 2048, pageOffset = 4096
var free = [[Int]](repeating: [], count: 32)
free[5] = [32, 96]; free[7] = [128]; free[8] = [256]; free[9] = [512]; free[10] = [1024]
for n in 13...30 { free[n] = [1 << n] }

var rootBlock = Data()
rootBlock.u32(3); rootBlock.u32(0)
rootBlock.u32(UInt32(root | 11)); rootBlock.u32(UInt32(superblock | 5)); rootBlock.u32(UInt32(pageOffset | 12))
rootBlock.append(Data(count: (256 - 3) * 4))
rootBlock.u32(1); rootBlock.append(4); rootBlock.ascii("DSDB"); rootBlock.u32(1)   // the directory: DSDB → block 1
for list in free { rootBlock.u32(UInt32(list.count)); for offset in list { rootBlock.u32(UInt32(offset)) } }

var super_ = Data()
super_.u32(2)                            // the tree's root page is block 2
super_.u32(0)                            // levels below it
super_.u32(UInt32(records.count))
super_.u32(1)                            // pages
super_.u32(UInt32(pageSize))

var body = Data(count: 8192)
var header = Data()
header.ascii("Bud1"); header.u32(UInt32(root)); header.u32(UInt32(rootBlock.count)); header.u32(UInt32(root))
header.append(contentsOf: [0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00])
body.put(header, at: 0)
body.put(super_, at: superblock)
body.put(rootBlock, at: root)
body.put(page, at: pageOffset)

var file = Data([0, 0, 0, 1])
file.append(body)
try file.write(to: volume.appendingPathComponent(".DS_Store"))
print("Wrote \(volume.path)/.DS_Store: \(records.count) records, \(page.count) bytes of page")
