// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWMacWallpaperCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>
#include <unistd.h>

NSURL *DWMacCachedWallpaper(NSURL *source, CGSize pixels) {
    if(!source.isFileURL||!source.path.length||!isfinite(pixels.width)||!isfinite(pixels.height)
       ||pixels.width<1||pixels.height<1||pixels.width>16384||pixels.height>16384)return nil;
    NSData *path=[source.path dataUsingEncoding:NSUTF8StringEncoding];if(path.length>UINT32_MAX)return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(path.bytes,(CC_LONG)path.length,digest);
    NSMutableString *hash=[NSMutableString stringWithCapacity:64];for(size_t i=0;i<sizeof(digest);i++)[hash appendFormat:@"%02x",digest[i]];
    NSString *prefix=[NSString stringWithFormat:@"%@-%ld-%ld-0-",hash,lround(pixels.width),lround(pixels.height)];
    // Observed macOS 26 image-provider cache, not a public API. Never scan for
    // an arbitrary recent wallpaper: the public API selects the source and its
    // path hash selects only that image. Unknown formats simply return nil.
    NSURL *directory=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image"] isDirectory:YES];
    NSArray<NSURL *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSURL *selected=nil;struct timespec newest={0};
    for(NSURL *file in files){
        NSString *name=file.lastPathComponent;
        if(![name hasPrefix:prefix]||![name hasSuffix:@".bmp"]||name.length!=prefix.length+16+4)continue;
        NSString *version=[name substringWithRange:NSMakeRange(prefix.length,16)];
        if([version rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet]].location!=NSNotFound)continue;
        struct stat info={0};if(lstat(file.fileSystemRepresentation,&info)||!S_ISREG(info.st_mode)||info.st_uid!=getuid()||info.st_size<=0||info.st_size>256*1024*1024)continue;
        if(selected&&(info.st_mtimespec.tv_sec<newest.tv_sec||(info.st_mtimespec.tv_sec==newest.tv_sec&&info.st_mtimespec.tv_nsec<=newest.tv_nsec)))continue;
        CGImageSourceRef image=CGImageSourceCreateWithURL((__bridge CFURLRef)file,NULL);if(!image)continue;
        NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(image,0,NULL));
        // The key names the target display dimensions; the cached bitmap may
        // retain the original image dimensions. Preserve the desktop's scaling
        // and fill options when decoding it, rather than stretching it to fit.
        long width=[properties[(__bridge NSString *)kCGImagePropertyPixelWidth]longValue],height=[properties[(__bridge NSString *)kCGImagePropertyPixelHeight]longValue];
        BOOL matches=CGImageSourceGetCount(image)==1&&width>0&&height>0&&width<=16384&&height<=16384;
        CFRelease(image);if(matches){selected=file;newest=info.st_mtimespec;}
    }
    return selected;
}
