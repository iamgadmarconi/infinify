// SPDX-License-Identifier: GPL-3.0-or-later
// Parent creation and failure stages match malbiruk/driftwm
// 352333a8fa1b22171492d4b71a54102045c9a19d,
// src/render/screenshot.rs:117-122 (capture_region_to_png).
#import "screenshot-writer.h"
#import <ImageIO/ImageIO.h>
#include <fcntl.h>
#include <unistd.h>

static NSDictionary *refusal(NSString *message) { return @{@"error":message}; }

NSDictionary *DWWriteScreenshotPixels(NSDictionary *pixels) {
    if(pixels[@"error"])return pixels;
    NSString *path=pixels[@"path"];CGImageRef image=(__bridge CGImageRef)pixels[@"image"];
    NSMutableData *png=[NSMutableData data];CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
    BOOL encoded=NO;if(destination){CGImageDestinationAddImage(destination,image,NULL);encoded=CGImageDestinationFinalize(destination);CFRelease(destination);}
    if(!encoded)return refusal([NSString stringWithFormat:@"cannot write %@: the image could not be encoded",path]);
    NSString *parent=path.stringByDeletingLastPathComponent;NSError *error=nil;
    if(parent.length&&![NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&error]){
        NSError *cause=error;while(cause.userInfo[NSUnderlyingErrorKey]&&![cause.domain isEqual:NSPOSIXErrorDomain])cause=cause.userInfo[NSUnderlyingErrorKey];
        NSString *why=[cause.domain isEqual:NSPOSIXErrorDomain]?[NSString stringWithFormat:@"%s (os error %ld)",strerror((int)cause.code),(long)cause.code]:error.localizedDescription;
        return refusal([NSString stringWithFormat:@"cannot create %@: %@",parent,why]);
    }
    int file=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0666),failure=file<0?errno:0;const char *bytes=png.bytes;
    for(size_t left=png.length;!failure&&left;){ssize_t n=write(file,bytes,left);if(n>0){bytes+=n;left-=(size_t)n;}else if(n==0||errno!=EINTR)failure=n?errno:EIO;}
    if(file>=0&&close(file)&&!failure)failure=errno;
    if(failure)return refusal([NSString stringWithFormat:@"cannot write %@: %s (os error %d)",path,strerror(failure),failure]);
    return @{@"path":path,@"width":pixels[@"width"],@"height":pixels[@"height"]};
}
