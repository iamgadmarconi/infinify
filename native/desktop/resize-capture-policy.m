// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-capture-policy.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>
static BOOL number(id x) { return [x isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID() && isfinite([x doubleValue]); }
NSNumber *DWResizeCaptureTimestamp(CMSampleBufferRef sample) {
    if(!sample||!CMSampleBufferIsValid(sample))return nil;
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,NO);if(!a||CFArrayGetCount(a)!=1)return nil;
    id m=(__bridge id)CFArrayGetValueAtIndex(a,0);if(![m isKindOfClass:NSDictionary.class])return nil;
    id time=m[SCStreamFrameInfoDisplayTime];
    if(!number(time)||[time doubleValue]<=0||floor([time doubleValue])!=[time doubleValue]||[time doubleValue]>=18446744073709551616.0)return nil;
    return time;
}
NSDictionary *DWResizeCaptureMetadata(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect) { return DWResizeCaptureDescription(sample,cutoff,nativeRect,NULL); }
static NSString *text(CGRect r) { return [NSString stringWithFormat:@"{%g,%g,%g,%g}",r.origin.x,r.origin.y,r.size.width,r.size.height]; }
// Every refusal below returns through here: the checks and their order are DWResizeCaptureMetadata's, unchanged.
static NSDictionary *refused(NSString *__autoreleasing *why,NSString *reason) { if(why)*why=reason;return nil; }
NSDictionary *DWResizeCaptureDescription(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect,NSString *__autoreleasing *why) {
    CGSize extent=nativeRect.size;
    if(!sample||!CMSampleBufferIsValid(sample))return refused(why,@"the sample is not valid");
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels)return refused(why,@"the sample has no pixel buffer");
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!attachments||CFArrayGetCount(attachments)!=1)return refused(why,[NSString stringWithFormat:@"the sample has %ld frame descriptions, not one",attachments?(long)CFArrayGetCount(attachments):0L]);
    id value=(__bridge id)CFArrayGetValueAtIndex(attachments,0);if(![value isKindOfClass:NSDictionary.class])return refused(why,@"the frame description is not a dictionary");
    NSDictionary *m=value;id status=m[SCStreamFrameInfoStatus],time=m[SCStreamFrameInfoDisplayTime],scale=m[SCStreamFrameInfoScaleFactor],content=m[SCStreamFrameInfoContentScale];
    if(!number(status)||[status doubleValue]!=SCFrameStatusComplete||!number(time)||[time doubleValue]<=0||floor([time doubleValue])!=[time doubleValue]||[time doubleValue]>=18446744073709551616.0||[time unsignedLongLongValue]<=cutoff||!number(scale)||!number(content)||[scale doubleValue]<=0||[content doubleValue]<=0)
        return refused(why,[NSString stringWithFormat:@"frame status %@ (a complete frame is %ld), display time %@ against cutoff %llu, scale factor %@, content scale %@",status?:@"missing",(long)SCFrameStatusComplete,time?:@"missing",cutoff,scale?:@"missing",content?:@"missing"]);
    id screen=m[SCStreamFrameInfoScreenRect];CGRect screenRect=CGRectZero;
    if(![screen isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)screen,&screenRect))return refused(why,@"the frame names no screen rectangle");
    if(!CGRectEqualToRect(screenRect,nativeRect))return refused(why,[NSString stringWithFormat:@"the frame's screen rectangle %@ is not the window extent %@",text(screenRect),text(nativeRect)]);
    id r=m[SCStreamFrameInfoContentRect];CGRect rect=CGRectZero;
    if(![r isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r,&rect))return refused(why,@"the frame names no content rectangle");
    if(!isfinite(extent.width)||!isfinite(extent.height)||extent.width<=0||extent.height<=0||!isfinite(rect.origin.x)||!isfinite(rect.origin.y)||!isfinite(rect.size.width)||!isfinite(rect.size.height)||rect.size.width<=0||rect.size.height<=0)
        return refused(why,[NSString stringWithFormat:@"content rectangle %@ or window extent %@ is empty or not finite",text(rect),text(nativeRect)]);
    if(fabs(rect.size.width/[content doubleValue]-extent.width)>1||fabs(rect.size.height/[content doubleValue]-extent.height)>1)
        return refused(why,[NSString stringWithFormat:@"content %gx%g at content scale %@ is not the window extent's %gx%g within a point",rect.size.width,rect.size.height,content,extent.width,extent.height]);
    CGFloat s=[scale doubleValue];CGRect crop=CGRectMake(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s);
    size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels);
    if(!width||!height||!isfinite(CGRectGetMaxX(crop))||!isfinite(CGRectGetMaxY(crop))||crop.origin.x<0||crop.origin.y<0||CGRectGetMaxX(crop)>width||CGRectGetMaxY(crop)>height)
        return refused(why,[NSString stringWithFormat:@"content rectangle %@ at scale factor %@ lies outside the %zux%zu buffer",text(rect),scale,width,height]);
    return @{ @"buffer":@{@"width":@(width),@"height":@(height)},@"content_rect":@{@"origin":@{@"x":@(crop.origin.x),@"y":@(crop.origin.y)},@"size":@{@"width":@(crop.size.width),@"height":@(crop.size.height)}} };
}
