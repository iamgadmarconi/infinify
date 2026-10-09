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
NSDictionary *DWResizeCaptureMetadata(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect) {
    CGSize extent=nativeRect.size;
    if(!sample||!CMSampleBufferIsValid(sample))return nil;
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels)return nil;
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!attachments||CFArrayGetCount(attachments)!=1)return nil;
    id value=(__bridge id)CFArrayGetValueAtIndex(attachments,0);if(![value isKindOfClass:NSDictionary.class])return nil;
    NSDictionary *m=value;id status=m[SCStreamFrameInfoStatus],time=m[SCStreamFrameInfoDisplayTime],scale=m[SCStreamFrameInfoScaleFactor],content=m[SCStreamFrameInfoContentScale];
    if(!number(status)||[status doubleValue]!=SCFrameStatusComplete||!number(time)||[time doubleValue]<=0||floor([time doubleValue])!=[time doubleValue]||[time doubleValue]>=18446744073709551616.0||[time unsignedLongLongValue]<=cutoff||!number(scale)||!number(content)||[scale doubleValue]<=0||[content doubleValue]<=0)return nil;
    id screen=m[SCStreamFrameInfoScreenRect];CGRect screenRect=CGRectZero;
    if(![screen isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)screen,&screenRect)||!CGRectEqualToRect(screenRect,nativeRect))return nil;
    id r=m[SCStreamFrameInfoContentRect];CGRect rect=CGRectZero;
    if(![r isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r,&rect))return nil;
    if(!isfinite(extent.width)||!isfinite(extent.height)||extent.width<=0||extent.height<=0||!isfinite(rect.origin.x)||!isfinite(rect.origin.y)||!isfinite(rect.size.width)||!isfinite(rect.size.height)||rect.size.width<=0||rect.size.height<=0)return nil;
    if(fabs(rect.size.width/[content doubleValue]-extent.width)>1||fabs(rect.size.height/[content doubleValue]-extent.height)>1)return nil;
    CGFloat s=[scale doubleValue];CGRect crop=CGRectMake(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s);
    size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels);
    if(!width||!height||!isfinite(CGRectGetMaxX(crop))||!isfinite(CGRectGetMaxY(crop))||crop.origin.x<0||crop.origin.y<0||CGRectGetMaxX(crop)>width||CGRectGetMaxY(crop)>height)return nil;
    return @{ @"buffer":@{@"width":@(width),@"height":@(height)},@"content_rect":@{@"origin":@{@"x":@(crop.origin.x),@"y":@(crop.origin.y)},@"size":@{@"width":@(crop.size.width),@"height":@(crop.size.height)}} };
}

BOOL DWResizeConfigurationCurrent(id requestedStream,id currentStream,NSNumber *requestedRevision,NSNumber *currentRevision,BOOL detached) {
    return !detached&&requestedStream&&requestedStream==currentStream&&requestedRevision&&[requestedRevision isEqual:currentRevision];
}
