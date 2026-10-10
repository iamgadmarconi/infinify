// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tiled pyramidal TIFF source and decode pool — see background-tiff.h and
// BACKGROUND-NOTES.md, section 17.
//
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/render/tile_chunks_tiff.rs and src/render/tile_worker.rs. New code: the
// walk over the file's directories (classic TIFF and BigTIFF, either byte
// order) and the decode of one tile, which hands ImageIO the tile's own
// compressed bytes inside a one-strip TIFF built in memory. A TIFF tile is
// encoded exactly like a strip of the tile's size, so every compression
// ImageIO reads in a TIFF it reads in a tile, and only the tiles a block
// covers are ever touched: asking ImageIO for a region of a level instead
// decodes every tile of the rows the region crosses (measured, section 17).

#import "background-tiff.h"

#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <errno.h>
#include <fcntl.h>
#include <os/lock.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// tile_worker.rs `N_WORKERS`.
static const NSUInteger kIFBGTileWorkers = 6;

// Rust's `io::Error` as upstream prints it.
static NSString *IFBGTiffOSError(int code) {
    return [NSString stringWithFormat:@"%s (os error %d)", strerror(code), code];
}

static BOOL IFBGTiffRead(int fd, void *buffer, size_t length, uint64_t offset) {
    uint8_t *p = buffer;
    while (length) {
        ssize_t n = pread(fd, p, length, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n;
        offset += (uint64_t)n;
        length -= (size_t)n;
    }
    return YES;
}

static uint64_t IFBGTiffUInt(const uint8_t *p, size_t size, BOOL bigEndian) {
    uint64_t v = 0;
    for (size_t i = 0; i < size; i++) v |= (uint64_t)p[i] << 8 * (bigEndian ? size - 1 - i : i);
    return v;
}

// One directory of the file, with what a tile's decode needs.
@interface IFBGTiffPage : NSObject {
  @public
    IFBGTiffLevel level;
    uint16_t samples, compression, photometric, fillOrder, predictor, sampleFormat;
    uint64_t tileCount;
    NSData *offsets, *byteCounts;  // uint64_t each
    NSData *jpegTables;
}
@end
@implementation IFBGTiffPage
@end

@interface IFBGTiffBlock ()
- (instancetype)initWithRGBA:(NSData *)rgba width:(uint32_t)width height:(uint32_t)height
             hasTransparency:(BOOL)hasTransparency failed:(NSUInteger)failed;
@end
@implementation IFBGTiffBlock
- (instancetype)initWithRGBA:(NSData *)rgba width:(uint32_t)width height:(uint32_t)height
             hasTransparency:(BOOL)hasTransparency failed:(NSUInteger)failed {
    if ((self = [super init])) {
        _rgba = rgba;
        _width = width;
        _height = height;
        _hasTransparency = hasTransparency;
        _failedTileCount = failed;
    }
    return self;
}
@end

// MARK: - Source

@implementation IFBGTiffSource {
    int _fd;
    uint64_t _fileSize;
    NSArray<IFBGTiffPage *> *_pages;
}

- (void)dealloc {
    if (_fd >= 0) close(_fd);
}

- (NSUInteger)levelCount {
    return _pages.count;
}

- (IFBGTiffLevel)levelAtIndex:(NSUInteger)index {
    return _pages[index]->level;
}

// The values of one directory entry as unsigned integers, or nil. `field` is
// the entry's value-or-offset field.
static NSData *IFBGTiffValues(int fd, uint64_t fileSize, BOOL bigEndian, uint16_t type, uint64_t count,
                              const uint8_t *field, size_t fieldSize) {
    size_t size;
    switch (type) {
        case 1: case 6: case 7: size = 1; break;  // BYTE, SBYTE, UNDEFINED
        case 3: size = 2; break;                  // SHORT
        case 4: case 13: size = 4; break;         // LONG, IFD
        case 16: case 18: size = 8; break;        // LONG8, IFD8
        default: return nil;
    }
    if (count == 0 || count > (1u << 28)) return nil;
    NSMutableData *raw = [NSMutableData dataWithLength:(NSUInteger)(count * size)];
    if (count * size <= fieldSize) {
        memcpy(raw.mutableBytes, field, (size_t)(count * size));
    } else {
        uint64_t offset = IFBGTiffUInt(field, fieldSize, bigEndian);
        if (offset > fileSize || count * size > fileSize - offset) return nil;
        if (!IFBGTiffRead(fd, raw.mutableBytes, (size_t)(count * size), offset)) return nil;
    }
    NSMutableData *values = [NSMutableData dataWithLength:(NSUInteger)(count * sizeof(uint64_t))];
    uint64_t *v = values.mutableBytes;
    const uint8_t *p = raw.bytes;
    for (uint64_t i = 0; i < count; i++) v[i] = IFBGTiffUInt(p + i * size, size, bigEndian);
    return values;
}

// The `tiff` crate's `ColorType` as Rust's `{:?}` prints it.
static NSString *IFBGTiffColorType(uint16_t photometric, uint16_t samples, uint16_t bits) {
    NSString *name = nil;
    switch (photometric) {
        case 0: case 1: name = samples == 1 ? @"Gray" : samples == 2 ? @"GrayA" : nil; break;
        case 2: name = samples == 3 ? @"RGB" : samples == 4 ? @"RGBA" : nil; break;
        case 3: name = samples == 1 ? @"Palette" : nil; break;
        case 5: name = samples == 4 ? @"CMYK" : samples == 5 ? @"CMYKA" : nil; break;
        case 6: name = samples == 3 ? @"YCbCr" : nil; break;
        default: break;
    }
    if (name) return [NSString stringWithFormat:@"%@(%u)", name, (unsigned)bits];
    return [NSString stringWithFormat:@"Multiband { bit_depth: %u, num_samples: %u }", (unsigned)bits, (unsigned)samples];
}

// `read_lod_metadata`, in upstream's order, over the directory at `offset`.
// Returns nil and sets `*error`; `*next` receives the next directory's offset.
// `*damaged` says the directory itself could not be read, which upstream's
// decoder reports before any of `read_lod_metadata`'s own refusals.
static IFBGTiffPage *IFBGTiffReadPage(int fd, uint64_t fileSize, BOOL bigEndian, BOOL big, uint64_t offset,
                                      uint64_t *next, BOOL *damaged, NSString **error) {
    size_t countSize = big ? 8 : 2, entrySize = big ? 20 : 12, fieldSize = big ? 8 : 4;
    uint8_t head[8];
    *damaged = YES;
    if (offset > fileSize || fileSize - offset < countSize || !IFBGTiffRead(fd, head, countSize, offset)) {
        *error = @"the image directory lies outside the file";
        return nil;
    }
    uint64_t entries = IFBGTiffUInt(head, countSize, bigEndian);
    if (entries == 0 || entries > 4096 || entries * entrySize + fieldSize > fileSize - offset - countSize) {
        *error = @"the image directory is damaged";
        return nil;
    }
    NSMutableData *table = [NSMutableData dataWithLength:(NSUInteger)(entries * entrySize + fieldSize)];
    if (!IFBGTiffRead(fd, table.mutableBytes, table.length, offset + countSize)) {
        *error = @"the image directory could not be read";
        return nil;
    }
    const uint8_t *t = table.bytes;
    *next = IFBGTiffUInt(t + entries * entrySize, fieldSize, bigEndian);

    IFBGTiffPage *page = [IFBGTiffPage new];
    uint64_t width = 0, height = 0, tileWidth = 0, tileHeight = 0, planar = 1, samples = 1, bits = 1;
    uint64_t compression = 1, photometric = UINT64_MAX;
    BOOL tiled = NO, sameBits = YES;
    for (uint64_t i = 0; i < entries; i++) {
        const uint8_t *e = t + i * entrySize;
        uint16_t tag = (uint16_t)IFBGTiffUInt(e, 2, bigEndian), type = (uint16_t)IFBGTiffUInt(e + 2, 2, bigEndian);
        uint64_t count = IFBGTiffUInt(e + 4, big ? 8 : 4, bigEndian);
        const uint8_t *field = e + (big ? 12 : 8);
        BOOL wanted = (tag >= 256 && tag <= 259) || tag == 262 || tag == 266 || tag == 277 || tag == 284 || tag == 317 ||
                      (tag >= 322 && tag <= 325) || tag == 339 || tag == 347;
        if (!wanted) continue;
        NSData *values = IFBGTiffValues(fd, fileSize, bigEndian, type, count, field, fieldSize);
        const uint64_t *v = values.bytes;
        if (!values) {
            *error = [NSString stringWithFormat:@"tag %u cannot be read", (unsigned)tag];
            return nil;
        }
        switch (tag) {
            case 256: width = v[0]; break;
            case 257: height = v[0]; break;
            case 258:
                bits = v[0];
                for (uint64_t k = 1; k < count; k++) sameBits = sameBits && v[k] == v[0];
                break;
            case 259: compression = v[0]; break;
            case 262: photometric = v[0]; break;
            case 266: page->fillOrder = (uint16_t)v[0]; break;
            case 277: samples = v[0]; break;
            case 284: planar = v[0]; break;
            case 317: page->predictor = (uint16_t)v[0]; break;
            case 322: tileWidth = v[0]; tiled = YES; break;
            case 323: tileHeight = v[0]; tiled = YES; break;
            case 324: page->offsets = values; tiled = YES; break;
            case 325: page->byteCounts = values; tiled = YES; break;
            case 339: page->sampleFormat = (uint16_t)v[0]; break;
            case 347: {
                // The bytes themselves, not their values.
                NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)count];
                uint8_t *b = bytes.mutableBytes;
                for (uint64_t k = 0; k < count; k++) b[k] = (uint8_t)v[k];
                page->jpegTables = bytes;
                break;
            }
            default: break;
        }
    }
    *damaged = NO;
    if (!tiled) {
        *error = @"TIFF is stripped, not tiled — needs a tiled, pyramidal TIFF";
        return nil;
    }
    if (planar != 1) {
        *error = @"planar TIFF (PlanarConfiguration=Planar) not supported";
        return nil;
    }
    if (width > UINT32_MAX || height > UINT32_MAX || tileWidth > UINT32_MAX || tileHeight > UINT32_MAX) {
        *error = @"dimensions: the image is too large";
        return nil;
    }
    if (width == 0 || height == 0) {
        *error = [NSString stringWithFormat:@"zero image dimension (%llu, %llu)", width, height];
        return nil;
    }
    if (tileWidth == 0 || tileHeight == 0) {
        *error = [NSString stringWithFormat:@"zero tile dimension (%llu, %llu)", tileWidth, tileHeight];
        return nil;
    }
    if (photometric == UINT64_MAX || !sameBits || samples > UINT16_MAX || bits > UINT16_MAX) {
        *error = @"colortype: the image's photometric interpretation or sample layout cannot be read";
        return nil;
    }
    if (photometric != 2 || bits != 8 || (samples != 3 && samples != 4)) {
        *error = [NSString stringWithFormat:@"unsupported color type %@ (need RGB8 or RGBA8)",
                                            IFBGTiffColorType((uint16_t)photometric, (uint16_t)samples, (uint16_t)bits)];
        return nil;
    }
    uint64_t across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight;
    if (!page->offsets || !page->byteCounts || page->offsets.length != page->byteCounts.length ||
        page->offsets.length / sizeof(uint64_t) < across * down) {
        *error = @"the tile offsets of the image cannot be read";
        return nil;
    }
    page->level = (IFBGTiffLevel){(uint32_t)width, (uint32_t)height, (uint32_t)tileWidth, (uint32_t)tileHeight, samples == 4};
    page->samples = (uint16_t)samples;
    page->compression = (uint16_t)compression;
    page->photometric = (uint16_t)photometric;
    page->tileCount = across * down;
    return page;
}

+ (instancetype)sourceWithPath:(NSString *)path error:(NSString **)error {
    NSString *why = nil;
    IFBGTiffSource *source = [[IFBGTiffSource alloc] initWithPath:path error:&why];
    if (!source && error) *error = why;
    return source;
}

// `scan_lods`: every directory of the chain is one level and must pass.
- (instancetype)initWithPath:(NSString *)path error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _path = [path copy];
    _fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (_fd < 0) {
        *error = [NSString stringWithFormat:@"open %@: %@", path, IFBGTiffOSError(errno)];
        return nil;
    }
    struct stat st;
    uint8_t header[16] = {0};
    _fileSize = fstat(_fd, &st) == 0 && st.st_size > 0 ? (uint64_t)st.st_size : 0;
    BOOL read = _fileSize >= 8 && IFBGTiffRead(_fd, header, (size_t)MIN(_fileSize, (uint64_t)16), 0);
    BOOL little = header[0] == 'I' && header[1] == 'I', bigEndian = header[0] == 'M' && header[1] == 'M';
    uint64_t magic = read && (little || bigEndian) ? IFBGTiffUInt(header + 2, 2, bigEndian) : 0;
    BOOL big = magic == 43;
    if ((magic != 42 && magic != 43) ||
        (big && (_fileSize < 16 || IFBGTiffUInt(header + 4, 2, bigEndian) != 8 || IFBGTiffUInt(header + 6, 2, bigEndian) != 0))) {
        *error = [NSString stringWithFormat:@"not a TIFF (%@): %@", path,
                                            read ? @"the file does not begin with a TIFF signature" : @"the file is too short"];
        return nil;
    }
    uint64_t offset = big ? IFBGTiffUInt(header + 8, 8, bigEndian) : IFBGTiffUInt(header + 4, 4, bigEndian);
    NSMutableArray<IFBGTiffPage *> *pages = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    while (offset) {
        if ([seen containsObject:@(offset)] || pages.count >= 64) {
            *error = @"next_image during scan: the image directories form a loop";
            return nil;
        }
        [seen addObject:@(offset)];
        NSString *why = nil;
        uint64_t next = 0;
        BOOL damaged = NO;
        IFBGTiffPage *page = IFBGTiffReadPage(_fd, _fileSize, bigEndian, big, offset, &next, &damaged, &why);
        if (!page) {
            // `Decoder::new` reads the first directory, `next_image` each later one.
            *error = !damaged ? why
                     : pages.count ? [NSString stringWithFormat:@"next_image during scan: %@", why]
                                   : [NSString stringWithFormat:@"not a TIFF (%@): %@", path, why];
            return nil;
        }
        [pages addObject:page];
        offset = next;
    }
    if (!pages.count) {
        *error = [NSString stringWithFormat:@"not a TIFF (%@): the file holds no image", path];
        return nil;
    }
    _pages = pages;
    return self;
}

static void IFBGTiffPut(NSMutableData *data, uint64_t value, size_t size) {
    uint8_t bytes[8];
    for (size_t i = 0; i < size; i++) bytes[i] = (uint8_t)(value >> 8 * i);
    [data appendBytes:bytes length:size];
}

static void IFBGTiffEntry(NSMutableData *data, uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
    IFBGTiffPut(data, tag, 2);
    IFBGTiffPut(data, type, 2);
    IFBGTiffPut(data, count, 4);
    IFBGTiffPut(data, value, 4);
}

// One whole tile as RGBA8, `tileWidth * tileHeight * 4` bytes, or NULL (free
// the result). The tile's bytes are wrapped in a little-endian classic TIFF
// that declares one strip of the tile's size, with the page's own compression,
// predictor, fill order and JPEG tables, and ImageIO decodes that. The fourth
// sample is declared unassociated whatever the file says, so that ImageIO
// passes the stored samples through untouched, as the `tiff` crate does.
- (uint8_t *)newTile:(uint64_t)index page:(IFBGTiffPage *)page lod:(NSUInteger)lod error:(NSString **)error {
    uint32_t tw = page->level.tileWidth, th = page->level.tileHeight;
    uint16_t spp = page->samples;
    if (page->sampleFormat > 1) {
        *error = [NSString stringWithFormat:@"non-u8 sample type at LOD %lu", (unsigned long)lod];
        return NULL;
    }
    uint64_t offset = ((const uint64_t *)page->offsets.bytes)[index], length = ((const uint64_t *)page->byteCounts.bytes)[index];
    if (length == 0 || length > (1u << 30) || offset > _fileSize || length > _fileSize - offset) {
        *error = [NSString stringWithFormat:@"read_chunk(%llu) at LOD %lu: the tile's data lies outside the file", index, (unsigned long)lod];
        return NULL;
    }
    uint32_t entries = 10 + (page->fillOrder ? 1 : 0) + (page->predictor ? 1 : 0) + (spp == 4 ? 1 : 0) + (page->jpegTables ? 1 : 0);
    uint32_t bitsAt = 8 + 2 + entries * 12 + 4, tablesAt = bitsAt + 8;
    uint32_t dataAt = tablesAt + (uint32_t)page->jpegTables.length + ((uint32_t)page->jpegTables.length & 1);
    NSMutableData *file = [NSMutableData dataWithCapacity:dataAt + (NSUInteger)length];
    [file appendBytes:"II" length:2];
    IFBGTiffPut(file, 42, 2);
    IFBGTiffPut(file, 8, 4);
    IFBGTiffPut(file, entries, 2);
    IFBGTiffEntry(file, 256, 4, 1, tw);
    IFBGTiffEntry(file, 257, 4, 1, th);
    IFBGTiffEntry(file, 258, 3, spp, bitsAt);
    IFBGTiffEntry(file, 259, 3, 1, page->compression);
    IFBGTiffEntry(file, 262, 3, 1, page->photometric);
    if (page->fillOrder) IFBGTiffEntry(file, 266, 3, 1, page->fillOrder);
    IFBGTiffEntry(file, 273, 4, 1, dataAt);
    IFBGTiffEntry(file, 277, 3, 1, spp);
    IFBGTiffEntry(file, 278, 4, 1, th);
    IFBGTiffEntry(file, 279, 4, 1, (uint32_t)length);
    IFBGTiffEntry(file, 284, 3, 1, 1);
    if (page->predictor) IFBGTiffEntry(file, 317, 3, 1, page->predictor);
    if (spp == 4) IFBGTiffEntry(file, 338, 3, 1, 2);
    if (page->jpegTables) IFBGTiffEntry(file, 347, 7, (uint32_t)page->jpegTables.length, tablesAt);
    IFBGTiffPut(file, 0, 4);
    for (int i = 0; i < 4; i++) IFBGTiffPut(file, 8, 2);
    if (page->jpegTables) [file appendData:page->jpegTables];
    file.length = dataAt + (NSUInteger)length;
    if (!IFBGTiffRead(_fd, (uint8_t *)file.mutableBytes + dataAt, (size_t)length, offset)) {
        *error = [NSString stringWithFormat:@"read_chunk(%llu) at LOD %lu: %@", index, (unsigned long)lod, IFBGTiffOSError(errno ?: EIO)];
        return NULL;
    }

    NSDictionary *hint = @{(id)kCGImageSourceTypeIdentifierHint: @"public.tiff"};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)file, (__bridge CFDictionaryRef)hint);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO}) : NULL;
    uint8_t *rgba = NULL;
    if (image && CGImageGetWidth(image) == tw && CGImageGetHeight(image) == th) {
        rgba = [self newSamplesOfImage:image samples:spp];
    }
    // As for a PNG or a JPEG (background.m, IFBGLoadImage): only once the pixels
    // have been produced does ImageIO know whether the data ran out.
    CGImageSourceStatus status = source ? CGImageSourceGetStatusAtIndex(source, 0) : kCGImageStatusInvalidData;
    if (image) CGImageRelease(image);
    if (source) CFRelease(source);
    if (rgba && status != kCGImageStatusComplete) {
        free(rgba);
        rgba = NULL;
    }
    if (!rgba) {
        *error = [NSString stringWithFormat:@"read_chunk(%llu) at LOD %lu: the tile could not be decoded (ImageIO status %d)", index,
                                            (unsigned long)lod, (int)status];
    }
    return rgba;
}

// The decoded samples of a tile as RGBA8. ImageIO hands an 8-bit RGB or RGBA
// TIFF back in the file's own sample order, three or four bytes a pixel; that
// buffer is taken as it is. Any other layout goes through vImage, which
// repacks without colour management (the image's own colour space).
- (uint8_t *)newSamplesOfImage:(CGImageRef)image samples:(uint16_t)spp {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image), bpp = CGImageGetBitsPerPixel(image), row = CGImageGetBytesPerRow(image);
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    CGBitmapInfo order = CGImageGetBitmapInfo(image) & kCGBitmapByteOrderMask;
    uint8_t *rgba = malloc(w * h * 4);
    if (!rgba) return NULL;
    BOOL plainOrder = order == kCGBitmapByteOrderDefault || order == kCGBitmapByteOrder32Big;
    BOOL four = bpp == 32 && (alpha == kCGImageAlphaLast || alpha == kCGImageAlphaNoneSkipLast || alpha == kCGImageAlphaPremultipliedLast);
    BOOL three = bpp == 24 && alpha == kCGImageAlphaNone;
    CFDataRef data = (CGImageGetBitsPerComponent(image) == 8 && plainOrder && (four || three) && !CGImageGetDecode(image))
                         ? CGDataProviderCopyData(CGImageGetDataProvider(image)) : NULL;
    size_t pixel = bpp / 8;
    if (data && row >= w * pixel && (size_t)CFDataGetLength(data) >= row * (h - 1) + w * pixel) {
        const uint8_t *bytes = CFDataGetBytePtr(data);
        BOOL keepAlpha = four && spp == 4 && alpha != kCGImageAlphaNoneSkipLast;
        for (size_t y = 0; y < h; y++) {
            const uint8_t *src = bytes + y * row;
            uint8_t *dst = rgba + y * w * 4;
            if (keepAlpha) {
                memcpy(dst, src, w * 4);
            } else {
                for (size_t x = 0; x < w; x++, src += pixel, dst += 4) {
                    dst[0] = src[0];
                    dst[1] = src[1];
                    dst[2] = src[2];
                    dst[3] = 255;
                }
            }
        }
        CFRelease(data);
        return rgba;
    }
    if (data) CFRelease(data);
    vImage_CGImageFormat format = {
        .bitsPerComponent = 8,
        .bitsPerPixel = 32,
        .colorSpace = CGImageGetColorSpace(image),
        .bitmapInfo = (CGBitmapInfo)kCGImageAlphaLast | kCGBitmapByteOrderDefault,
        .version = 0,
        .decode = NULL,
        .renderingIntent = kCGRenderingIntentDefault,
    };
    vImage_Buffer buffer = {0};
    if (vImageBuffer_InitWithCGImage(&buffer, &format, NULL, image, kvImageNoFlags) != kvImageNoError) {
        free(rgba);
        return NULL;
    }
    for (size_t y = 0; y < h; y++) memcpy(rgba + y * w * 4, (const uint8_t *)buffer.data + y * buffer.rowBytes, w * 4);
    free(buffer.data);
    if (spp != 4) {
        for (size_t i = 0; i < w * h; i++) rgba[4 * i + 3] = 255;
    }
    return rgba;
}

- (IFBGTiffBlock *)readBlockAtLevel:(NSUInteger)lod gx:(uint32_t)gx gy:(uint32_t)gy aggregation:(uint32_t)n error:(NSString **)error {
    NSString *why = nil;
    IFBGTiffBlock *block = [self blockAtLevel:lod gx:gx gy:gy aggregation:n tolerant:NO error:&why];
    if (!block && error) *error = why;
    return block;
}

- (IFBGTiffBlock *)readWholeLevel:(NSUInteger)lod error:(NSString **)error {
    NSString *why = nil;
    IFBGTiffBlock *block = nil;
    if (lod >= _pages.count) {
        why = [NSString stringWithFormat:@"LOD %lu out of range", (unsigned long)lod];
    } else {
        IFBGTiffLevel level = _pages[lod]->level;
        uint32_t across = (level.imageWidth + level.tileWidth - 1) / level.tileWidth;
        uint32_t down = (level.imageHeight + level.tileHeight - 1) / level.tileHeight;
        block = [self blockAtLevel:lod gx:0 gy:0 aggregation:MAX(across, down) tolerant:YES error:&why];
    }
    if (!block && error) *error = why;
    return block;
}

// `read_block`, and with `tolerant` `read_whole_lod`: the tiles of the block
// stitched row by row, each cropped to the part of it inside the image.
- (IFBGTiffBlock *)blockAtLevel:(NSUInteger)lod gx:(uint32_t)gx gy:(uint32_t)gy aggregation:(uint32_t)n
                       tolerant:(BOOL)tolerant error:(NSString **)error {
    if (n == 0) {
        *error = @"read_block: aggregation factor n must be >= 1";
        return nil;
    }
    if (lod >= _pages.count) {
        *error = [NSString stringWithFormat:@"LOD %lu out of range (have %lu)", (unsigned long)lod, (unsigned long)_pages.count];
        return nil;
    }
    IFBGTiffPage *page = _pages[lod];
    uint64_t imageW = page->level.imageWidth, imageH = page->level.imageHeight, tileW = page->level.tileWidth, tileH = page->level.tileHeight;
    uint64_t across = (imageW + tileW - 1) / tileW, down = (imageH + tileH - 1) / tileH;
    uint64_t startX = (uint64_t)gx * n, startY = (uint64_t)gy * n;
    if (startX >= across || startY >= down) {
        *error = [NSString stringWithFormat:@"block (%u,%u) n=%u starts past tile grid at LOD %lu (%llu×%llu)", gx, gy, n,
                                            (unsigned long)lod, across, down];
        return nil;
    }
    uint64_t endX = MIN(startX + n, across), endY = MIN(startY + n, down);
    uint64_t blockW = MIN(endX * tileW, imageW) - startX * tileW, blockH = MIN(endY * tileH, imageH) - startY * tileH;
    if (blockW > 32768 || blockH > 32768) {
        *error = [NSString stringWithFormat:@"block (%u,%u) n=%u at LOD %lu is too large (%llu×%llu)", gx, gy, n, (unsigned long)lod,
                                            blockW, blockH];
        return nil;
    }
    NSMutableData *stitched = [NSMutableData dataWithLength:(NSUInteger)(blockW * blockH * 4)];
    if (!stitched) {
        *error = @"out of memory";
        return nil;
    }
    uint8_t *out = stitched.mutableBytes;
    // read_whole_lod leaves a failed tile zeroed, and an RGB8 level then gains
    // its opaque alpha everywhere: the hole is opaque black.
    if (tolerant && page->samples != 4) {
        for (uint64_t i = 0; i < blockW * blockH; i++) out[4 * i + 3] = 255;
    }
    NSUInteger ok = 0, failed = 0;
    BOOL transparent = NO;
    for (uint64_t ty = startY; ty < endY; ty++) {
        for (uint64_t tx = startX; tx < endX; tx++) {
            @autoreleasepool {
                NSString *why = nil;
                uint8_t *tile = [self newTile:ty * across + tx page:page lod:lod error:&why];
                if (!tile) {
                    if (!tolerant) {
                        *error = why;
                        return nil;
                    }
                    failed++;
                    continue;
                }
                uint64_t actualW = MIN(imageW - tx * tileW, tileW), actualH = MIN(imageH - ty * tileH, tileH);
                uint64_t dstX = (tx - startX) * tileW, dstY = (ty - startY) * tileH;
                for (uint64_t row = 0; row < actualH; row++) {
                    const uint8_t *src = tile + row * tileW * 4;
                    memcpy(out + ((dstY + row) * blockW + dstX) * 4, src, (size_t)actualW * 4);
                    if (page->samples == 4 && !transparent) {
                        for (uint64_t x = 0; x < actualW && !transparent; x++) transparent = src[4 * x + 3] < 255;
                    }
                }
                free(tile);
                ok++;
            }
        }
    }
    if (tolerant && ok == 0) {
        *error = [NSString stringWithFormat:@"LOD %lu: every tile failed to decode", (unsigned long)lod];
        return nil;
    }
    if (failed) {
        NSLog(@"background: LOD %lu: %lu of %lu tiles failed; fallback plane has holes", (unsigned long)lod, (unsigned long)failed,
              (unsigned long)(ok + failed));
    }
    return [[IFBGTiffBlock alloc] initWithRGBA:stitched width:(uint32_t)blockW height:(uint32_t)blockH hasTransparency:transparent failed:failed];
}
@end

// MARK: - Worker pool

@interface IFBGTileResponse ()
- (instancetype)initWithLevel:(uint32_t)level cx:(uint32_t)cx cy:(uint32_t)cy block:(IFBGTiffBlock *)block error:(NSString *)error;
@end
@implementation IFBGTileResponse
- (instancetype)initWithLevel:(uint32_t)level cx:(uint32_t)cx cy:(uint32_t)cy block:(IFBGTiffBlock *)block error:(NSString *)error {
    if ((self = [super init])) {
        _level = level;
        _cx = cx;
        _cy = cy;
        _block = block;
        _error = [error copy];
    }
    return self;
}
@end

typedef struct {
    uint32_t level, cx, cy, aggregation;
} IFBGTileRequest;

// What the decodes share with the pool. A decode retains this, not the pool,
// so a pool that is released while one runs is gone at once.
@interface IFBGTileQueue : NSObject {
  @public
    os_unfair_lock lock;
    NSMutableData *pending;                          // IFBGTileRequest, oldest first (`VecDeque`)
    NSMutableArray<IFBGTileResponse *> *responses;   // oldest first (the mpsc channel)
    NSUInteger running;                              // decoders alive, at most kIFBGTileWorkers
    NSUInteger decoding;                             // requests taken and not yet answered
    BOOL shutdown;
    IFBGTiffSource *source;
    dispatch_block_t wake;
}
@end
@implementation IFBGTileQueue
// `worker_loop`: takes requests until none is left, then ends.
- (void)work {
    for (;;) {
        IFBGTileRequest request;
        os_unfair_lock_lock(&lock);
        if (shutdown || pending.length == 0) {
            running--;
            os_unfair_lock_unlock(&lock);
            return;
        }
        memcpy(&request, pending.bytes, sizeof request);
        [pending replaceBytesInRange:NSMakeRange(0, sizeof request) withBytes:NULL length:0];
        decoding++;
        os_unfair_lock_unlock(&lock);

        IFBGTileResponse *response = nil;
        @autoreleasepool {
            NSString *error = nil;
            IFBGTiffBlock *block = [source readBlockAtLevel:request.level gx:request.cx gy:request.cy aggregation:request.aggregation error:&error];
            response = [[IFBGTileResponse alloc] initWithLevel:request.level cx:request.cx cy:request.cy block:block error:error];
        }
        os_unfair_lock_lock(&lock);
        decoding--;
        BOOL deliver = !shutdown;
        if (deliver) [responses addObject:response];
        dispatch_block_t notify = deliver ? wake : nil;
        os_unfair_lock_unlock(&lock);
        if (notify) notify();
    }
}
@end

@implementation IFBGTileWorkerPool {
    IFBGTileQueue *_queue;
    dispatch_queue_t _workers;
}

- (instancetype)initWithSource:(IFBGTiffSource *)source wake:(dispatch_block_t)wake {
    if (!(self = [super init])) return nil;
    _queue = [IFBGTileQueue new];
    _queue->lock = OS_UNFAIR_LOCK_INIT;
    _queue->pending = [NSMutableData data];
    _queue->responses = [NSMutableArray array];
    _queue->source = source;
    _queue->wake = [wake copy];
    _workers = dispatch_queue_create("space.marengo.infinify.background.tiles",
                                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (void)enqueueLevel:(uint32_t)level cx:(uint32_t)cx cy:(uint32_t)cy aggregation:(uint32_t)aggregation {
    IFBGTileRequest request = {level, cx, cy, aggregation};
    IFBGTileQueue *queue = _queue;
    os_unfair_lock_lock(&queue->lock);
    BOOL start = NO;
    if (!queue->shutdown) {
        [queue->pending appendBytes:&request length:sizeof request];
        start = queue->running < kIFBGTileWorkers;
        if (start) queue->running++;
    }
    os_unfair_lock_unlock(&queue->lock);
    if (start) dispatch_async(_workers, ^{ [queue work]; });
}

- (IFBGTileResponse *)tryReceive {
    IFBGTileResponse *response = nil;
    os_unfair_lock_lock(&_queue->lock);
    if (_queue->responses.count) {
        response = _queue->responses.firstObject;
        [_queue->responses removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&_queue->lock);
    return response;
}

- (void)drainPending {
    os_unfair_lock_lock(&_queue->lock);
    _queue->pending.length = 0;
    os_unfair_lock_unlock(&_queue->lock);
}

- (void)shutdown {
    os_unfair_lock_lock(&_queue->lock);
    _queue->shutdown = YES;
    _queue->pending.length = 0;
    [_queue->responses removeAllObjects];
    _queue->wake = nil;
    os_unfair_lock_unlock(&_queue->lock);
}

- (NSUInteger)outstandingCount {
    os_unfair_lock_lock(&_queue->lock);
    NSUInteger count = _queue->pending.length / sizeof(IFBGTileRequest) + _queue->decoding + _queue->responses.count;
    os_unfair_lock_unlock(&_queue->lock);
    return count;
}
@end
