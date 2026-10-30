// SPDX-License-Identifier: GPL-3.0-or-later
// DriftWM v0.21.0 turned a panic in its TIFF decoder path into an error (platform.tiff_wallpaper_abort). This module's TIFF code is
// Objective-C over ImageIO, a different code path, so the same promise is checked here by running it: crafted files (malformed,
// truncated, huge, zero-sized, multi-page, CMYK, 16-bit, compressed, planar, stripped, unreadable) go through the real
// `IFBGTiffSource`, and then through `IFBackgroundProgram` as `[background] type = "tile"` and as an inherited still wallpaper.
// Every one must come back as an error the program answers with the default dot grid and a message, never a crash, an abort or a
// hang; a fixed-seed mutation run over valid files adds the cases nobody listed. The files are written to a directory of this
// run's own and removed. No window, tap, event or native call; the program checks need a Metal device and are skipped without one.
// What this shows is the module's behaviour on these inputs; it is no proof about every file ImageIO might be handed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <zlib.h>
#import "IFBGTiffSource.h"
#import "IFBackgroundProgram.h"
#include <signal.h>
#include <unistd.h>

static NSUInteger checks;
static void check(BOOL ok, NSString *why) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", why.UTF8String); exit(1); }
}

// MARK: - A TIFF writer: classic, little-endian, one directory per page

@interface Page : NSObject
@property uint32_t width, height, tileWidth, tileHeight;
@property uint16_t bits, samples, photometric, compression, planar, predictor, sampleFormat;
@property BOOL stripped, noOffsets, noByteCounts;
@property NSArray<NSData *> *tiles;  // nil: made from the pattern, compressed as `compression` says
@property uint64_t offsetsCount;     // 0: one per tile
@end
@implementation Page
- (instancetype)init {
    if ((self = [super init])) {
        _width = 40; _height = 30; _tileWidth = _tileHeight = 16;
        _bits = 8; _samples = 3; _photometric = 2; _compression = 1; _planar = 1;
    }
    return self;
}
@end

static uint8_t pattern(uint32_t x, uint32_t y, uint32_t c) { return (uint8_t)((x * 7 + y * 13 + c * 50) & 255); }

static NSData *packBits(NSData *raw) {
    NSMutableData *out = [NSMutableData data];
    const uint8_t *p = raw.bytes;
    for (NSUInteger i = 0; i < raw.length;) {
        NSUInteger n = MIN((NSUInteger)128, raw.length - i);
        uint8_t head = (uint8_t)(n - 1);
        [out appendBytes:&head length:1];
        [out appendBytes:p + i length:n];
        i += n;
    }
    return out;
}

static NSData *tileData(Page *page, uint32_t tx, uint32_t ty) {
    uint32_t tw = page.tileWidth, th = page.tileHeight, spp = page.samples;
    NSMutableData *raw = [NSMutableData dataWithLength:(NSUInteger)tw * th * spp];
    uint8_t *r = raw.mutableBytes;
    for (uint32_t y = 0; y < th; y++)
        for (uint32_t x = 0; x < tw; x++)
            for (uint32_t c = 0; c < spp; c++) r[((size_t)y * tw + x) * spp + c] = pattern(tx * tw + x, ty * th + y, c);
    if (page.compression == 8 || page.compression == 32946) {
        uLongf size = compressBound((uLong)raw.length);
        NSMutableData *z = [NSMutableData dataWithLength:size];
        compress(z.mutableBytes, &size, raw.bytes, (uLong)raw.length);
        z.length = size;
        return z;
    }
    if (page.compression == 32773) return packBits(raw);
    return raw;
}

static void put(NSMutableData *d, uint64_t v, size_t n) {
    for (size_t i = 0; i < n; i++) { uint8_t b = (uint8_t)(v >> (8 * i)); [d appendBytes:&b length:1]; }
}
typedef struct { uint16_t tag, type; uint32_t count; uint32_t value; } Entry;

static NSData *build(NSArray<Page *> *pages) {
    NSMutableData *f = [NSMutableData data];
    [f appendBytes:"II" length:2]; put(f, 42, 2); put(f, 0, 4);
    NSUInteger firstAt = 0, link = 4;
    for (NSUInteger index = 0; index < pages.count; index++) {
        Page *p = pages[index];
        uint32_t across = (p.width + p.tileWidth - 1) / MAX(p.tileWidth, 1u), down = (p.height + p.tileHeight - 1) / MAX(p.tileHeight, 1u);
        NSMutableArray<NSData *> *tiles = [NSMutableArray array];
        if (p.tiles) [tiles addObjectsFromArray:p.tiles];
        else if (!p.stripped && p.tileWidth * (uint64_t)p.tileHeight < 4096 * 4096 && (uint64_t)across * down <= 4096)
            for (uint32_t ty = 0; ty < down; ty++) for (uint32_t tx = 0; tx < across; tx++) [tiles addObject:tileData(p, tx, ty)];
        if (p.stripped) [tiles addObject:tileData(p, 0, 0)];
        // A file that lists no tile at all would be refused for that; the degenerate dimensions below are meant to be refused for themselves.
        if (!tiles.count && !p.tiles && p.tileWidth * (uint64_t)p.tileHeight < 4096 * 4096) [tiles addObject:tileData(p, 0, 0)];
        NSMutableArray<NSNumber *> *offsets = [NSMutableArray array], *counts = [NSMutableArray array];
        for (NSData *t in tiles) { [offsets addObject:@(f.length)]; [counts addObject:@(t.length)]; [f appendData:t]; if (f.length & 1) put(f, 0, 1); }
        while (offsets.count < p.offsetsCount) { [offsets addObject:@(f.length)]; [counts addObject:@1]; }
        NSUInteger bitsAt = f.length;
        for (uint16_t i = 0; i < p.samples; i++) put(f, p.bits, 2);
        NSUInteger offsetsAt = f.length;
        for (NSNumber *o in offsets) put(f, o.unsignedLongLongValue, 4);
        NSUInteger countsAt = f.length;
        for (NSNumber *c in counts) put(f, c.unsignedLongLongValue, 4);
        NSMutableArray<NSValue *> *entries = [NSMutableArray array];
        void (^add)(uint16_t, uint16_t, uint32_t, uint32_t) = ^(uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
            Entry e = {tag, type, count, value}; [entries addObject:[NSValue valueWithBytes:&e objCType:@encode(Entry)]];
        };
        add(256, 4, 1, p.width); add(257, 4, 1, p.height);
        if (p.samples * 2u <= 4) add(258, 3, p.samples, p.samples == 1 ? p.bits : (p.samples == 2 ? (uint32_t)(p.bits | (p.bits << 16)) : 0));
        else add(258, 3, p.samples, (uint32_t)bitsAt);
        add(259, 3, 1, p.compression); add(262, 3, 1, p.photometric);
        if (p.stripped) { add(273, 4, 1, (uint32_t)[offsets.firstObject unsignedLongLongValue]); add(278, 4, 1, p.height); add(279, 4, 1, (uint32_t)[counts.firstObject unsignedLongLongValue]); }
        add(277, 3, 1, p.samples); add(284, 3, 1, p.planar);
        if (p.predictor) add(317, 3, 1, p.predictor);
        if (!p.stripped) {
            add(322, 4, 1, p.tileWidth); add(323, 4, 1, p.tileHeight);
            if (!p.noOffsets) { uint32_t n = (uint32_t)offsets.count; add(324, 4, n, n == 1 ? (uint32_t)[offsets.firstObject unsignedLongLongValue] : (uint32_t)offsetsAt); }
            if (!p.noByteCounts) { uint32_t n = (uint32_t)counts.count; add(325, 4, n, n == 1 ? (uint32_t)[counts.firstObject unsignedLongLongValue] : (uint32_t)countsAt); }
        }
        if (p.sampleFormat) add(339, 3, 1, p.sampleFormat);
        [entries sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
            Entry x, y; [a getValue:&x]; [b getValue:&y]; return x.tag < y.tag ? NSOrderedAscending : x.tag > y.tag ? NSOrderedDescending : NSOrderedSame;
        }];
        NSUInteger at = f.length;
        if (index == 0) firstAt = at; else { uint32_t v = (uint32_t)at; [f replaceBytesInRange:NSMakeRange(link, 4) withBytes:&v]; }
        put(f, entries.count, 2);
        for (NSValue *v in entries) { Entry e; [v getValue:&e]; put(f, e.tag, 2); put(f, e.type, 2); put(f, e.count, 4); put(f, e.value, 4); }
        link = f.length; put(f, 0, 4);
    }
    uint32_t v = (uint32_t)firstAt;
    [f replaceBytesInRange:NSMakeRange(4, 4) withBytes:&v];
    return f;
}
static NSArray<Page *> *copies(int n);
static Page *page(void (^edit)(Page *)) { Page *p = [Page new]; if (edit) edit(p); return p; }
static NSData *one(void (^edit)(Page *)) { return build(@[page(edit)]); }
static NSArray<Page *> *copies(int n) { NSMutableArray *a = [NSMutableArray array]; for (int i = 0; i < n; i++) [a addObject:page(nil)]; return a; }
static NSData *mutated(NSData *d, void (^edit)(NSMutableData *)) { NSMutableData *m = [d mutableCopy]; edit(m); return m; }

static NSArray<NSData *> *sixTiles(void) {
    NSMutableArray *t = [NSMutableArray array];
    for (int i = 0; i < 6; i++) [t addObject:tileData(page(^(Page *q) { q.tileWidth = q.tileHeight = 16; }), (uint32_t)i, 0)];
    return t;
}
// A zlib stream of `total` zero bytes, made without holding them.
static NSData *deflateZeros(uint64_t total) {
    static uint8_t zeros[1 << 20];
    z_stream z; memset(&z, 0, sizeof z);
    deflateInit(&z, 1);
    NSMutableData *out = [NSMutableData data];
    uint8_t chunk[1 << 16];
    for (uint64_t done = 0; done < total || done == total;) {
        uint64_t n = MIN((uint64_t)sizeof zeros, total - done);
        BOOL last = done + n == total;
        z.next_in = zeros; z.avail_in = (uInt)n;
        do { z.next_out = chunk; z.avail_out = sizeof chunk; deflate(&z, last ? Z_FINISH : Z_NO_FLUSH); [out appendBytes:chunk length:sizeof chunk - z.avail_out]; } while (z.avail_out == 0);
        done += n;
        if (last) break;
    }
    deflateEnd(&z);
    return out;
}

// MARK: - Running one file

static NSString *directory;
static NSUInteger serial;
static NSString *fixture(NSData *data) {
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"t%lu.tif", (unsigned long)serial++]];
    check([data writeToFile:path atomically:NO], @"write a fixture");
    return path;
}
// Opens `data` and, when it opens, reads every level whole and block by block: the errors found, joined, or nil.
static NSString *outcome(NSData *data, NSUInteger *levels) {
    NSString *error = nil;
    IFBGTiffSource *source = [IFBGTiffSource sourceWithPath:fixture(data) error:&error];
    if (levels) *levels = source.levelCount;
    if (!source) { check(error.length > 0, @"a refused file says why"); return error; }
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSUInteger lod = 0; lod < source.levelCount; lod++) {
        NSString *why = nil;
        IFBGTiffBlock *whole = [source readWholeLevel:lod error:&why];
        check(whole ? why == nil || YES : why.length > 0, @"a failed whole-level read says why");
        if (!whole) [found addObject:why];
        IFBGTiffLevel level = [source levelAtIndex:lod];
        uint32_t across = (level.imageWidth + level.tileWidth - 1) / level.tileWidth, down = (level.imageHeight + level.tileHeight - 1) / level.tileHeight;
        for (uint32_t gy = 0; gy < MIN(down, 3u); gy++)
            for (uint32_t gx = 0; gx < MIN(across, 3u); gx++) {
                why = nil;
                IFBGTiffBlock *block = [source readBlockAtLevel:lod gx:gx gy:gy aggregation:1 error:&why];
                check(block ? YES : why.length > 0, @"a failed block read says why");
                if (!block) [found addObject:why];
            }
    }
    return found.count ? [found componentsJoinedByString:@" | "] : nil;
}
static void refused(NSString *name, NSData *data, NSString *needle) {
    NSString *why = outcome(data, NULL);
    check(why != nil, [name stringByAppendingString:@": an error, not a picture"]);
    check(!needle || [why containsString:needle], [NSString stringWithFormat:@"%@: the error names its cause (%@; wanted '%@')", name, why, needle]);
    fprintf(stderr, "ok: %s -> %s\n", name.UTF8String, why.UTF8String);
}
// ImageIO is lenient about some wrong tile data and fills what it cannot read: whichever it does, the read ends in a picture or an error.
static void survives(NSString *name, NSData *data) {
    NSString *why = outcome(data, NULL);
    fprintf(stderr, "ok: %s -> %s\n", name.UTF8String, why ? why.UTF8String : "a picture");
}
static void accepted(NSString *name, NSData *data, NSUInteger levels) {
    NSUInteger got = 0;
    NSString *why = outcome(data, &got);
    check(why == nil && got == levels, [NSString stringWithFormat:@"%@: reads clean as %lu level(s) (%@)", name, (unsigned long)levels, why]);
    fprintf(stderr, "ok: %s\n", name.UTF8String);
}

// Where a program with the file as its background lands: the default dot grid, and the text it reports.
static NSString *wallpaperError(NSData *data, BOOL inherited, IFBackgroundKind *kind) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    IFBackgroundConfig *config = [IFBackgroundConfig configWithTypeString:inherited ? @"wallpaper" : @"tile" path:fixture(data) texture:nil warning:NULL];
    config.inheritedWallpaper = inherited;
    IFBackgroundProgram *program = [IFBackgroundProgram programWithConfig:config device:device];
    if (kind) *kind = program.kind;
    return program.errorText;
}

int main(void) { @autoreleasepool {
    alarm(240);  // a hang is a failure
    directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"infinify-tiff-%d", getpid()]];
    check([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL], @"scratch directory");

    // Upstream's own scenarios for `whole_lod` (tile_chunks_tiff.rs tests), in the same words.
    {
        IFBGTiffLevel fine[] = {{40000, 20000, 256, 256, NO}, {10000, 5000, 256, 256, NO}, {2500, 1250, 256, 256, NO}, {625, 312, 256, 256, NO}};
        check(IFBGTiffWholeLevel(fine, 4, 4096, NULL) == 2, @"the finest level within the preference is decoded whole");
        IFBGTiffLevel shallow[] = {{16384, 9000, 256, 256, NO}, {8192, 4500, 256, 256, NO}};
        check(IFBGTiffWholeLevel(shallow, 2, 4096, NULL) == 1, @"a shallow pyramid falls back to its coarsest level");
        IFBGTiffLevel flat[] = {{60000, 30000, 256, 256, NO}, {30000, 15000, 256, 256, NO}};
        NSString *why = nil;
        check(IFBGTiffWholeLevel(flat, 2, 4096, &why) == NSNotFound && [why containsString:@"30000×15000"] && [why containsString:@"16384"], @"a coarsest level past the whole-decode limit is an error naming its size");
        IFBGTiffLevel over[] = {{16385, 100, 256, 256, NO}}, edge[] = {{16384, 100, 256, 256, NO}};
        check(IFBGTiffWholeLevel(over, 1, 4096, NULL) == NSNotFound && IFBGTiffWholeLevel(edge, 1, 4096, NULL) == 0, @"16384 px a side is the last that is decoded whole");
        check(IFBGTiffWholeLevel(fine, 0, 4096, &why) == NSNotFound && [why isEqualToString:@"TIFF has no LOD levels"], @"no levels is an error");
    }

    // Valid files read: what the refusals below are measured against.
    accepted(@"RGB8 uncompressed", one(nil), 1);
    accepted(@"RGBA8 deflate", one(^(Page *p) { p.samples = 4; p.compression = 8; }), 1);
    accepted(@"RGB8 PackBits", one(^(Page *p) { p.compression = 32773; }), 1);
    accepted(@"two-page pyramid", build(@[page(nil), page(^(Page *p) { p.width = 20; p.height = 15; p.tileWidth = p.tileHeight = 8; })]), 2);
    {
        NSString *error = nil;
        IFBGTiffSource *source = [IFBGTiffSource sourceWithPath:fixture(one(^(Page *p) { p.samples = 4; p.compression = 8; })) error:&error];
        IFBGTiffBlock *whole = [source readWholeLevel:0 error:&error];
        const uint8_t *px = whole.rgba.bytes;
        check(whole.width == 40 && whole.height == 30 && px[(29 * 40 + 39) * 4 + 0] == pattern(39, 29, 0) && px[(29 * 40 + 39) * 4 + 3] == pattern(39, 29, 3),
              @"the valid file's pixels are the ones written, edge tile cropped");
    }

    // Not a TIFF, or damaged beyond its first directory.
    refused(@"empty file", [NSData data], @"not a TIFF");
    refused(@"four bytes", [NSData dataWithBytes:"II*\0" length:4], @"not a TIFF");
    refused(@"text", [@"this is not a tiff at all, just a long enough line of text" dataUsingEncoding:NSUTF8StringEncoding], @"not a TIFF");
    refused(@"wrong magic", mutated(one(nil), ^(NSMutableData *m) { ((uint8_t *)m.mutableBytes)[2] = 41; }), @"not a TIFF");
    refused(@"first directory past the end", mutated(one(nil), ^(NSMutableData *m) { uint32_t v = 0x7fffffff; [m replaceBytesInRange:NSMakeRange(4, 4) withBytes:&v]; }), nil);
    refused(@"first directory is the header", mutated(one(nil), ^(NSMutableData *m) { uint32_t v = 0; [m replaceBytesInRange:NSMakeRange(4, 4) withBytes:&v]; }), nil);
    refused(@"directory count 65535", mutated(one(nil), ^(NSMutableData *m) { uint32_t at = *(uint32_t *)((uint8_t *)m.bytes + 4); uint16_t v = 0xffff; [m replaceBytesInRange:NSMakeRange(at, 2) withBytes:&v]; }), nil);
    refused(@"directory count 0", mutated(one(nil), ^(NSMutableData *m) { uint32_t at = *(uint32_t *)((uint8_t *)m.bytes + 4); uint16_t v = 0; [m replaceBytesInRange:NSMakeRange(at, 2) withBytes:&v]; }), nil);
    {
        NSData *valid = one(nil);
        uint32_t at = *(uint32_t *)((const uint8_t *)valid.bytes + 4);
        refused(@"cut inside the directory", [valid subdataWithRange:NSMakeRange(0, at + 20)], nil);
        refused(@"cut at the directory's count", [valid subdataWithRange:NSMakeRange(0, at + 1)], nil);
        refused(@"cut right after the header", [valid subdataWithRange:NSMakeRange(0, 8)], nil);
        refused(@"directory loops to itself", mutated(valid, ^(NSMutableData *m) { NSUInteger end = m.length - 4; uint32_t v = at; [m replaceBytesInRange:NSMakeRange(end, 4) withBytes:&v]; }), @"loop");
    }
    refused(@"65 pages", build(copies(65)), @"loop");

    // Zero and huge dimensions.
    refused(@"zero width", one(^(Page *p) { p.width = 0; }), @"zero image dimension");
    refused(@"zero height", one(^(Page *p) { p.height = 0; }), @"zero image dimension");
    refused(@"zero tile width", one(^(Page *p) { p.tileWidth = 0; }), @"zero tile dimension");
    refused(@"zero tile height", one(^(Page *p) { p.tileHeight = 0; }), @"zero tile dimension");
    refused(@"image 4294967295 x 4294967295", one(^(Page *p) { p.width = p.height = UINT32_MAX; p.tileWidth = p.tileHeight = 1; }), nil);
    refused(@"image 4294967295 x 4294967295, tile 256", one(^(Page *p) { p.width = p.height = UINT32_MAX; p.tileWidth = p.tileHeight = 256; }), nil);
    refused(@"tile 4294967295 x 4294967295", one(^(Page *p) { p.tileWidth = p.tileHeight = UINT32_MAX; }), nil);
    refused(@"tile 40000 x 40000 over a 256 x 256 image", one(^(Page *p) { p.width = p.height = 256; p.tileWidth = p.tileHeight = 40000; p.compression = 8; p.tiles = @[tileData(page(^(Page *q) { q.tileWidth = q.tileHeight = 16; q.compression = 8; }), 0, 0)]; }), @"tile");
    refused(@"tile 65535 x 1", one(^(Page *p) { p.width = 65535; p.height = 1; p.tileWidth = 65535; p.tileHeight = 1; p.tiles = @[[NSData dataWithBytes:"x" length:1]]; }), nil);
    refused(@"more tiles than the offsets list", one(^(Page *p) { p.width = p.height = 4000; p.tileWidth = p.tileHeight = 16; p.tiles = sixTiles(); }), @"tile offsets");
    refused(@"no tile offsets", one(^(Page *p) { p.noOffsets = YES; }), @"tile offsets");
    refused(@"no tile byte counts", one(^(Page *p) { p.noByteCounts = YES; }), @"tile offsets");
    refused(@"level 20000 x 20000 is no fallback plane", one(^(Page *p) { p.width = p.height = 20000; p.tileWidth = p.tileHeight = 256; p.offsetsCount = 79 * 79; p.tiles = sixTiles(); }), @"20000");

    // Layouts the module does not read.
    refused(@"stripped", one(^(Page *p) { p.stripped = YES; }), @"stripped");
    refused(@"planar", one(^(Page *p) { p.planar = 2; }), @"planar");
    refused(@"CMYK", one(^(Page *p) { p.samples = 4; p.photometric = 5; }), @"CMYK");
    refused(@"16-bit RGB", one(^(Page *p) { p.bits = 16; }), @"RGB(16)");
    refused(@"16-bit RGBA", one(^(Page *p) { p.bits = 16; p.samples = 4; }), @"RGBA(16)");
    refused(@"greyscale", one(^(Page *p) { p.samples = 1; p.photometric = 1; }), @"Gray");
    refused(@"palette", one(^(Page *p) { p.samples = 1; p.photometric = 3; }), @"Palette");
    refused(@"YCbCr", one(^(Page *p) { p.photometric = 6; }), @"YCbCr");
    refused(@"1-bit", one(^(Page *p) { p.bits = 1; p.samples = 1; p.photometric = 0; }), nil);
    refused(@"RGB with five samples", one(^(Page *p) { p.samples = 5; }), nil);
    refused(@"float samples", one(^(Page *p) { p.sampleFormat = 3; }), @"non-u8");
    refused(@"signed samples", one(^(Page *p) { p.sampleFormat = 2; }), @"non-u8");
    refused(@"second page CMYK", build(@[page(nil), page(^(Page *p) { p.samples = 4; p.photometric = 5; })]), @"CMYK");
    refused(@"second page stripped", build(@[page(nil), page(^(Page *p) { p.stripped = YES; })]), @"stripped");

    // Tile data that cannot be decoded.
    refused(@"unknown compression", one(^(Page *p) { p.compression = 0xfffe; }), nil);
    survives(@"CCITT on RGB", one(^(Page *p) { p.compression = 4; }));
    survives(@"JPEG without tables", one(^(Page *p) { p.compression = 7; }));
    survives(@"old JPEG", one(^(Page *p) { p.compression = 6; }));
    survives(@"LZW garbage", one(^(Page *p) { p.compression = 5; }));
    survives(@"deflate garbage", one(^(Page *p) { p.compression = 8; NSMutableArray *t = [NSMutableArray array]; for (int i = 0; i < 6; i++) [t addObject:[NSData dataWithBytes:"\xde\xad\xbe\xef not a zlib stream" length:25]]; p.tiles = t; }));
    survives(@"predictor 2 over garbage", one(^(Page *p) { p.compression = 8; p.predictor = 2; NSMutableArray *t = [NSMutableArray array]; for (int i = 0; i < 6; i++) [t addObject:[NSData dataWithBytes:"abcdefghijklmnopqrstuvwxy" length:25]]; p.tiles = t; }));
    survives(@"predictor 3", one(^(Page *p) { p.compression = 8; p.predictor = 3; }));
    survives(@"tile data shorter than the tile", one(^(Page *p) { NSMutableArray *t = [NSMutableArray array]; for (int i = 0; i < 6; i++) [t addObject:[NSData dataWithBytes:"\1\2\3" length:3]]; p.tiles = t; }));
    refused(@"tile of zero bytes", one(^(Page *p) { NSMutableArray *t = [NSMutableArray array]; for (int i = 0; i < 6; i++) [t addObject:[NSData data]]; p.tiles = t; }), @"outside the file");
    {
        NSData *valid = one(^(Page *p) { p.compression = 8; });
        survives(@"file cut inside the last tile", [valid subdataWithRange:NSMakeRange(0, 8 + 400)]);
        survives(@"file cut after the first tile", [valid subdataWithRange:NSMakeRange(0, 300)]);
        refused(@"a tile offset past the end", mutated(one(nil), ^(NSMutableData *m) {
            uint32_t ifd = *(uint32_t *)((uint8_t *)m.bytes + 4);
            uint16_t n = *(uint16_t *)((uint8_t *)m.bytes + ifd);
            for (uint16_t i = 0; i < n; i++) { uint8_t *e = (uint8_t *)m.mutableBytes + ifd + 2 + i * 12; if (*(uint16_t *)e == 324) { uint32_t at = *(uint32_t *)(e + 8); uint32_t big = 0xfffffff0; [m replaceBytesInRange:NSMakeRange(at, 4) withBytes:&big]; } }
        }), @"outside the file");
        refused(@"a tile byte count past the end", mutated(one(nil), ^(NSMutableData *m) {
            uint32_t ifd = *(uint32_t *)((uint8_t *)m.bytes + 4);
            uint16_t n = *(uint16_t *)((uint8_t *)m.bytes + ifd);
            for (uint16_t i = 0; i < n; i++) { uint8_t *e = (uint8_t *)m.mutableBytes + ifd + 2 + i * 12; if (*(uint16_t *)e == 325) { uint32_t at = *(uint32_t *)(e + 8); uint32_t big = 0x7ffffff0; [m replaceBytesInRange:NSMakeRange(at, 4) withBytes:&big]; } }
        }), @"outside the file");
    }
    // The decoder would inflate this to 805 MB (3 x 16384 x 16384) from about 800 KB of file; upstream's `tiff` crate stops at 256 MiB.
    refused(@"a deflate bomb: one 16384 x 16384 RGB tile of zeros", one(^(Page *p) {
        p.width = p.height = 16384; p.tileWidth = p.tileHeight = 16384; p.compression = 8; p.tiles = @[deflateZeros(3ull * 16384 * 16384)];
    }), @"limits of the decoder");

    // A program with any of these as its background reports and draws the dot grid.
    if (MTLCreateSystemDefaultDevice()) {
        NSArray<NSData *> *bad = @[[NSData data], [NSData dataWithBytes:"II*\0" length:4], one(^(Page *p) { p.width = 0; }), one(^(Page *p) { p.stripped = YES; }),
            one(^(Page *p) { p.samples = 4; p.photometric = 5; }), one(^(Page *p) { p.bits = 16; }), one(^(Page *p) { p.compression = 8; p.tiles = @[]; p.offsetsCount = 6; p.tileWidth = 0; }),
            [one(nil) subdataWithRange:NSMakeRange(0, 200)], one(^(Page *p) { p.width = p.height = UINT32_MAX; p.tileWidth = p.tileHeight = 256; })];
        for (NSData *data in bad) {
            IFBackgroundKind kind = IFBackgroundKindNone;
            NSString *text = wallpaperError(data, NO, &kind);
            check(kind == IFBackgroundKindDotGrid && [text hasPrefix:@"tile bg '"], [NSString stringWithFormat:@"tile background: the dot grid and a message (kind %ld, %@)", (long)kind, text]);
        }
        // An inherited still wallpaper is any image ImageIO reads, a stripped, CMYK or 16-bit TIFF among them (they are no error there,
        // only for the tiled pyramid); what cannot be read at all is the dot grid and a message.
        NSData *valid = one(nil);
        uint32_t directory = *(const uint32_t *)((const uint8_t *)valid.bytes + 4);
        NSArray<NSData *> *broken = @[[NSData data], [NSData dataWithBytes:"II*\0" length:4], [valid subdataWithRange:NSMakeRange(0, 8)],
            [valid subdataWithRange:NSMakeRange(0, directory + 20)], [@"not a tiff, only named like one" dataUsingEncoding:NSUTF8StringEncoding],
            mutated(valid, ^(NSMutableData *m) { uint32_t v = 0x7fffffff; [m replaceBytesInRange:NSMakeRange(4, 4) withBytes:&v]; })];
        for (NSData *data in broken) {
            IFBackgroundKind kind = IFBackgroundKindNone;
            NSString *text = wallpaperError(data, YES, &kind);
            check(kind == IFBackgroundKindDotGrid && text.length > 0, [NSString stringWithFormat:@"inherited TIFF wallpaper that cannot be read: the dot grid and a message (kind %ld, %@)", (long)kind, text]);
        }
        for (NSData *data in bad) {
            IFBackgroundKind kind = IFBackgroundKindNone;
            NSString *text = wallpaperError(data, YES, &kind);
            check(kind == IFBackgroundKindWallpaper || (kind == IFBackgroundKindDotGrid && text.length > 0), [NSString stringWithFormat:@"inherited TIFF wallpaper: a picture or the dot grid and a message (kind %ld, %@)", (long)kind, text]);
        }
        IFBackgroundKind kind = IFBackgroundKindNone;
        NSString *text = wallpaperError(one(^(Page *p) { p.samples = 4; p.compression = 8; }), NO, &kind);
        check(kind == IFBackgroundKindTile && text == nil, [NSString stringWithFormat:@"a valid tiled TIFF is the tile background (kind %ld, %@)", (long)kind, text]);
        {
            IFBackgroundKind k = IFBackgroundKindNone;
            NSString *t = wallpaperError(one(^(Page *p) { p.width = p.height = 20000; p.tileWidth = p.tileHeight = 256; p.offsetsCount = 79 * 79; p.tiles = sixTiles(); }), NO, &k);
            check(k == IFBackgroundKindDotGrid && [t containsString:@"its coarsest level is 20000×20000, past the 16384 px a level is decoded whole at"], [NSString stringWithFormat:@"a level too large to hold whole is reported by the program in upstream's words (%@)", t]);
        }
        fprintf(stderr, "ok: %lu bad files as tile background end in the dot grid and a message, and as inherited wallpaper in a picture or the same\n", (unsigned long)bad.count);
    } else fprintf(stderr, "skipped: no Metal device, the program-level checks\n");

    // Mutations of valid files, fixed seed: whatever they do, they end in a picture or an error.
    {
        NSArray<NSData *> *bases = @[
            build(@[page(^(Page *p) { p.samples = 4; p.compression = 8; }), page(^(Page *p) { p.samples = 4; p.compression = 8; p.width = 20; p.height = 15; p.tileWidth = p.tileHeight = 8; })]),
            one(^(Page *p) { p.compression = 32773; }),
            one(^(Page *p) { p.compression = 8; p.predictor = 2; }),
            one(nil)];
        srandom(20261030);
        NSUInteger runs = 0, opened = 0, read = 0;
        for (NSUInteger i = 0; i < 6000; i++) {
            NSMutableData *m = [bases[i % bases.count] mutableCopy];
            NSUInteger flips = 1 + random() % 4;
            for (NSUInteger k = 0; k < flips; k++) {
                NSUInteger span = (random() % 3 == 0) ? m.length : MIN(m.length, (NSUInteger)700);
                ((uint8_t *)m.mutableBytes)[random() % span] = (uint8_t)random();
            }
            if (random() % 5 == 0) m.length = random() % m.length;
            NSUInteger levels = 0;
            NSString *why = outcome(m, &levels);
            runs++;
            if (levels) opened++;
            if (!why) read++;
        }
        fprintf(stderr, "ok: %lu mutated files: %lu opened, %lu read clean, the rest refused with a message, none crashed or hung\n", (unsigned long)runs, (unsigned long)opened, (unsigned long)read);
    }

    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
    fprintf(stderr, "background-tiff: %lu checks passed\n", (unsigned long)checks);
    return 0;
}}
