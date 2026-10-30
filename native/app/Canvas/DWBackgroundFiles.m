// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: reading a shader's text and decoding a
// PNG/JPEG (or an inherited macOS still image) into a texture - see
// IFBackgroundProgram.h and BACKGROUND-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/background.rs
// (`load_image_to_texture`), as the comments below cite.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackgroundProgram+Private.h"
#import "IFBGTiffSource.h"

#import <Accelerate/Accelerate.h>
#import <ImageIO/ImageIO.h>

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// MARK: - Files

NSString *IFBGReadText(NSString *path, NSString **error) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) {
        if (error) *error = IFBGOSError(errno);
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) [data appendBytes:buf length:n];
    int readError = ferror(f) ? errno : 0;
    fclose(f);
    if (readError) {
        if (error) *error = IFBGOSError(readError);
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text && error) *error = @"stream did not contain valid UTF-8";
    return text;
}

BOOL IFBGIsTIFFPath(NSString *path) {
    NSString *lower = path.lowercaseString;
    return [lower hasSuffix:@".tif"] || [lower hasSuffix:@".tiff"];
}

// CRC-32 as PNG uses it (ISO 3309, reflected polynomial 0xEDB88320).
static uint32_t IFBGCRC32(const uint8_t *bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t n = 0; n < 256; n++) {
            uint32_t c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
    });
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; i++) c = table[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

/// Walks a PNG file's chunk list and returns what is wrong with it, or nil.
/// ImageIO decodes a truncated or damaged PNG without any sign of trouble: it
/// reports kCGImageStatusComplete before and after decoding and leaves the
/// missing rows empty (measured, BACKGROUND-NOTES.md section 6). Upstream's decoder (the
/// `png` crate behind `image::open`) reports an error for such a file, and the
/// background then falls back, so the container is checked here: every chunk
/// must be present in full up to and including IEND, and a critical chunk
/// (IHDR, PLTE, IDAT, IEND) must carry the CRC of its contents.
static NSString *IFBGPNGDefect(NSData *file) {
    const uint8_t *p = file.bytes;
    NSUInteger n = file.length, o = 8;  // past the signature ImageIO recognised
    NSString *last = nil;
    while (o <= n && n - o >= 8) {
        uint32_t length = ((uint32_t)p[o] << 24) | ((uint32_t)p[o + 1] << 16) | ((uint32_t)p[o + 2] << 8) | p[o + 3];
        const uint8_t *type = p + o + 4;
        BOOL letters = YES;
        for (int i = 0; i < 4; i++) letters = letters && ((type[i] | 0x20) >= 'a' && (type[i] | 0x20) <= 'z');
        NSString *name = letters ? [[NSString alloc] initWithBytes:type length:4 encoding:NSASCIIStringEncoding] : @"?";
        if ((NSUInteger)length > n - o - 8 || n - o - 8 - length < 4) {
            return [NSString stringWithFormat:@"unexpected end of file (the PNG is truncated in its %@ chunk)", name];
        }
        uint32_t stored = ((uint32_t)p[o + 8 + length] << 24) | ((uint32_t)p[o + 9 + length] << 16) |
                          ((uint32_t)p[o + 10 + length] << 8) | p[o + 11 + length];
        BOOL critical = (type[0] & 0x20) == 0;  // an ancillary chunk may be ignored, and so may its damage
        if (critical && IFBGCRC32(type, (size_t)length + 4) != stored) {
            return [NSString stringWithFormat:@"CRC error in the %@ chunk (the PNG is damaged)", name];
        }
        if (memcmp(type, "IEND", 4) == 0) return nil;
        last = name;
        o += 12 + (NSUInteger)length;
    }
    return last ? [NSString stringWithFormat:@"unexpected end of file (the PNG is truncated after its %@ chunk)", last]
                : @"unexpected end of file (the PNG is truncated after its signature)";
}

/// Upstream `load_image_to_texture`: decodes to straight-alpha RGBA8 and
/// uploads the bytes untouched. The file's colour profile is ignored (the
/// `image` crate never reads it); the values are taken to be sRGB. Inherited
/// macOS still images instead use ImageIO's formats, orientation and sRGB
/// conversion. A multi-image asset is not evidence of its active wallpaper.
id<MTLTexture> IFBGLoadImage(id<MTLDevice> device, NSString *path, CGSize *size,
                                    BOOL inherited, BOOL *hasTransparency, NSString **error) {
    NSString *(^fail)(NSString *) = ^(NSString *why) {
        return [NSString stringWithFormat:@"background image '%@': %@", path, why];
    };
    if (access(path.fileSystemRepresentation, R_OK) != 0) {
        if (error) *error = fail(IFBGOSError(errno));
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    NSString *uti = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
    // Upstream builds the `image` crate with PNG and JPEG decoders only.
    if (!source || (!inherited && !([uti isEqualToString:@"public.png"] || [uti isEqualToString:@"public.jpeg"]))) {
        if (error) *error = fail(uti ? [NSString stringWithFormat:@"unsupported image format %@ (PNG/JPEG only)", uti]
                                     : @"The image format could not be determined");
        if (source) CFRelease(source);
        return nil;
    }
    BOOL png = [uti isEqualToString:@"public.png"];
    if (png) {
        NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
        NSString *defect = file ? IFBGPNGDefect(file) : @"the file could not be read";
        if (defect) {
            if (error) *error = fail(defect);
            CFRelease(source);
            return nil;
        }
    }
    NSDictionary *decode = nil;
    if (inherited) {
        if (CGImageSourceGetCount(source) != 1) {
            CFRelease(source);
            if (error) *error = fail(@"the active image of a dynamic or multi-image wallpaper is unavailable");
            return nil;
        }
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        // Reject an oversized still before allocating its decoded pixels. Do
        // not route an ordinary inherited TIFF into the tiled-canvas decoder.
        if (!isfinite(width) || !isfinite(height) || width < 1 || height < 1 ||
            width > kIFBGMaxTextureSide || height > kIFBGMaxTextureSide) {
            CFRelease(source);
            if (error) *error = fail(@"the still image has invalid dimensions or exceeds the texture limit");
            return nil;
        }
        decode = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                   (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                   (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(MAX(width, height)),
                   (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
    }
    CGImageRef image = inherited ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)decode)
                                 : CGImageSourceCreateImageAtIndex(source, 0, NULL);
    if (!image) {
        CFRelease(source);
        if (error) *error = fail(@"the image could not be decoded");
        return nil;
    }
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w == 0 || h == 0 || w > kIFBGMaxTextureSide || h > kIFBGMaxTextureSide) {
        CGImageRelease(image);
        CFRelease(source);
        if (error) *error = fail(@"upload failed (image likely too large) — gigapixel wallpapers need a tiled pyramidal TIFF");
        return nil;
    }

    // Convert without colour management: the destination uses the image's own
    // colour space (or, for palette images, its base space), so vImage only
    // repacks samples. Grey images are widened by hand for the same reason.
    CGColorSpaceRef space = CGImageGetColorSpace(image);
    CGColorSpaceModel model = space ? CGColorSpaceGetModel(space) : kCGColorSpaceModelUnknown;
    CGColorSpaceRef base = space;
    if (model == kCGColorSpaceModelIndexed) {
        base = CGColorSpaceGetBaseColorSpace(space);
        model = base ? CGColorSpaceGetModel(base) : kCGColorSpaceModelUnknown;
    }
    BOOL grey = !inherited && (model == kCGColorSpaceModelMonochrome);
    CGColorSpaceRef fallback = NULL;
    if (inherited || (model != kCGColorSpaceModelRGB && !grey)) {
        // macOS wallpapers retain their colour profile through this conversion;
        // custom CMYK and other exotic models also need an RGB destination.
        base = fallback = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }
    vImage_CGImageFormat format = {
        .bitsPerComponent = 8,
        .bitsPerPixel = grey ? 16 : 32,
        .colorSpace = base,
        .bitmapInfo = (CGBitmapInfo)kCGImageAlphaLast | kCGBitmapByteOrderDefault,
        .version = 0,
        .decode = NULL,
        .renderingIntent = kCGRenderingIntentDefault,
    };
    vImage_Buffer buffer = {0};
    vImage_Error verr = vImageBuffer_InitWithCGImage(&buffer, &format, NULL, image, kvImageNoFlags);
    CGImageRelease(image);
    if (fallback) CGColorSpaceRelease(fallback);
    // The pixels are decoded by the call above, and only then does ImageIO know
    // whether the data ran out: a JPEG cut short reports
    // kCGImageStatusUnexpectedEOF from here on and Complete before (measured).
    // ImageIO fills what is missing with grey and returns the picture anyway.
    CGImageSourceStatus status = CGImageSourceGetStatusAtIndex(source, 0);
    CFRelease(source);
    if (verr != kvImageNoError) {
        free(buffer.data);
        if (error) *error = fail([NSString stringWithFormat:@"the image could not be decoded (vImage error %ld)", (long)verr]);
        return nil;
    }
    if (status != kCGImageStatusComplete) {
        free(buffer.data);
        if (error) *error = fail([NSString stringWithFormat:@"%@ (the %@ is truncated or damaged, ImageIO status %d)",
                                     status == kCGImageStatusUnexpectedEOF ? @"unexpected end of file" : @"the image could not be decoded completely",
                                     png ? @"PNG" : uti, (int)status]);
        return nil;
    }

    // vImage already produced straight RGBA8 for every non-grey image. Metal
    // accepts that buffer's padded row stride directly: do not allocate and
    // copy a second full image just to remove padding. Grey custom images
    // still need their upstream-preserving expansion from grey/alpha to RGBA.
    if (grey) {
        uint8_t *rgba = malloc(w * h * 4);
        if (!rgba) {
            free(buffer.data);
            if (error) *error = fail(@"not enough memory to decode the image");
            return nil;
        }
        for (size_t y = 0; y < h; y++) {
            const uint8_t *row = (const uint8_t *)buffer.data + y * buffer.rowBytes;
            uint8_t *dst = rgba + y * w * 4;
            for (size_t x = 0; x < w; x++) {
                dst[4 * x] = dst[4 * x + 1] = dst[4 * x + 2] = row[2 * x];
                dst[4 * x + 3] = row[2 * x + 1];
            }
        }
        free(buffer.data);
        buffer.data = rgba;
        buffer.rowBytes = w * 4;
    }
    BOOL transparent = NO;
    // Inherited wallpaper has an opaque fill; shader textures derive their
    // output alpha in the shader. Neither consumer needs an image-alpha scan.
    if (hasTransparency) for (size_t y = 0; y < h && !transparent; y++) {
        const uint8_t *row = (const uint8_t *)buffer.data + y * buffer.rowBytes;
        for (size_t x = 0; x < w && !transparent; x++) transparent = row[4 * x + 3] < 255;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    if (texture) [texture replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:buffer.data bytesPerRow:buffer.rowBytes];
    free(buffer.data);
    if (!texture) {
        if (error) *error = fail(@"upload failed (image likely too large) — gigapixel wallpapers need a tiled pyramidal TIFF");
        return nil;
    }
    if (size) *size = CGSizeMake(w, h);
    if (hasTransparency) *hasTransparency = transparent;
    return texture;
}
