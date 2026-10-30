// SPDX-License-Identifier: GPL-3.0-or-later
// The worker-to-main mailbox of one root capture stream, and the stream's crop contract.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "DWTypedValue.h"
@class Desktop, DesktopView, LiveSource;
// A distinct output object fences each stream lifetime. Only retained samples
// and their metadata cross this worker; the source and renderer stay on main.
@interface DWRootCaptureMailbox : NSObject <SCStreamOutput>
- (instancetype)initWithSource:(LiveSource *)source stream:(SCStream *)stream;
@property(readonly) dispatch_queue_t queue;
// Transport availability of an actually published image in this exact stream.
// This is not a pixel-quality, native placement or input-admission proof.
@property(readonly) BOOL currentImageAvailable;
- (void)cancel;
@end
// ScreenCaptureKit's ContentRect is in surface points; ScaleFactor converts it
// to pixels. ContentScale describes original-content scaling, not a second
// pixel multiplier. Match the child capture crop contract without guessing a
// native extent from an output raster or treating padding as window content.
static inline BOOL DWRootCaptureCrop(NSDictionary *info,CVPixelBufferRef pixels,CGRect *crop) {
    if(!pixels||![info isKindOfClass:NSDictionary.class])return NO;
    id scale=info[SCStreamFrameInfoScaleFactor],contentScale=info[SCStreamFrameInfoContentScale];
    for(id value in @[scale?:NSNull.null,contentScale?:NSNull.null])
        if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()
            ||!isfinite([value doubleValue])||[value doubleValue]<=0)return NO;
    NSDictionary *value=DWTyped(info[SCStreamFrameInfoContentRect],NSDictionary.class);
    for(NSString *key in @[@"X",@"Y",@"Width",@"Height"]){id number=value[key];
        if(![number isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID()||!isfinite([number doubleValue]))return NO;}
    CGRect content=CGRectZero;
    if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value,&content))return NO;
    double s=[scale doubleValue];CGRect result=CGRectMake(content.origin.x*s,content.origin.y*s,content.size.width*s,content.size.height*s);
    if(!isfinite(result.origin.x)||!isfinite(result.origin.y)||!isfinite(result.size.width)||!isfinite(result.size.height)
        ||!isfinite(CGRectGetMaxX(result))||!isfinite(CGRectGetMaxY(result))||result.origin.x<0||result.origin.y<0
        ||result.size.width<=0||result.size.height<=0||CGRectGetMaxX(result)>CVPixelBufferGetWidth(pixels)||CGRectGetMaxY(result)>CVPixelBufferGetHeight(pixels))return NO;
    *crop=result;return YES;
}
