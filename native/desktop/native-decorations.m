// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-decorations.h"
#import "native-presenter.h"
#import "../focus/focus.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>

static NSDictionary *decorationRect(CGRect r){return @{ @"origin":@{@"x":@(r.origin.x),@"y":@(r.origin.y)},@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}};}
static BOOL decorationFrame(AXUIElementRef element,CGRect *out){
    CFTypeRef position=NULL,size=NULL;CGPoint p;CGSize s;BOOL valid=NO;
    if(!AXUIElementCopyAttributeValue(element,kAXPositionAttribute,&position)&&position&&CFGetTypeID(position)==AXValueGetTypeID()
        &&!AXUIElementCopyAttributeValue(element,kAXSizeAttribute,&size)&&size&&CFGetTypeID(size)==AXValueGetTypeID()
        &&AXValueGetValue(position,kAXValueCGPointType,&p)&&AXValueGetValue(size,kAXValueCGSizeType,&s)
        &&isfinite(p.x)&&isfinite(p.y)&&isfinite(s.width)&&isfinite(s.height)&&s.width>0&&s.height>0){*out=CGRectMake(p.x,p.y,s.width,s.height);valid=YES;}
    if(position)CFRelease(position);if(size)CFRelease(size);return valid;
}
static BOOL decorationNear(CGRect a,CGRect b){return fabs(a.origin.x-b.origin.x)<=1&&fabs(a.origin.y-b.origin.y)<=1&&fabs(a.size.width-b.size.width)<=1&&fabs(a.size.height-b.size.height)<=1;}
NSDictionary *DWNativeDecorationButtons(NSDictionary *identity){
    if(!AXIsProcessTrusted())return nil;
    DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
    CGRect own;if(!dw_focus_owner(selected,&own))return nil;
    AXError (*getWindow)(AXUIElementRef,uint32_t *)=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");if(!getWindow)return nil;
    CFTimeInterval deadline=CACurrentMediaTime()+.15;AXUIElementRef app=AXUIElementCreateApplication(selected.pid),window=NULL;CFTypeRef list=NULL;
    if(AXUIElementSetMessagingTimeout(app,.02)||AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list)||!list||CFGetTypeID(list)!=CFArrayGetTypeID()||CFArrayGetCount(list)>256){if(list)CFRelease(list);CFRelease(app);return nil;}
    BOOL ambiguous=NO;
    for(CFIndex i=0;i<CFArrayGetCount(list)&&CACurrentMediaTime()<deadline;i++){
        AXUIElementRef candidate=(AXUIElementRef)CFArrayGetValueAtIndex(list,i);uint32_t wid=0;
        if(CFGetTypeID(candidate)!=AXUIElementGetTypeID()||AXUIElementSetMessagingTimeout(candidate,.02)||getWindow(candidate,&wid))continue;
        if(wid!=selected.window)continue;if(window){ambiguous=YES;break;}window=(AXUIElementRef)CFRetain(candidate);
    }
    CFRelease(list);CFRelease(app);if(!window||ambiguous||CACurrentMediaTime()>=deadline){if(window)CFRelease(window);return nil;}
    CGRect ax;if(!decorationFrame(window,&ax)||!decorationNear(ax,own)){CFRelease(window);return nil;}
    NSMutableArray *buttons=[NSMutableArray array];
    for(NSString *attribute in @[(__bridge NSString *)kAXFullScreenButtonAttribute,(__bridge NSString *)kAXZoomButtonAttribute]){
        if(CACurrentMediaTime()>=deadline)break;CFTypeRef value=NULL,role=NULL,enabled=NULL;
        AXError error=AXUIElementCopyAttributeValue(window,(__bridge CFStringRef)attribute,&value);
        if(!error&&value&&CFGetTypeID(value)==AXUIElementGetTypeID()){
            AXUIElementRef button=(AXUIElementRef)value;CGRect frame;
            if(!AXUIElementSetMessagingTimeout(button,.02)&&!AXUIElementCopyAttributeValue(button,kAXRoleAttribute,&role)&&role&&CFEqual(role,kAXButtonRole)
                &&!AXUIElementCopyAttributeValue(button,kAXEnabledAttribute,&enabled)&&enabled&&CFGetTypeID(enabled)==CFBooleanGetTypeID()&&CFBooleanGetValue(enabled)
                &&decorationFrame(button,&frame)&&CGRectContainsRect(CGRectInset(own,-1,-1),frame)){
                frame.origin.x-=own.origin.x;frame.origin.y-=own.origin.y;NSDictionary *rect=decorationRect(frame);if(![buttons containsObject:rect])[buttons addObject:rect];
            }
        }
        if(enabled)CFRelease(enabled);if(role)CFRelease(role);if(value)CFRelease(value);
    }
    CFRelease(window);CGRect after;
    if(CACurrentMediaTime()>=deadline||!dw_focus_owner(selected,&after)||!CGRectEqualToRect(own,after))return nil;
    return @{@"identity":[identity copy],@"native_bounds":decorationRect(own),@"buttons":buttons.copy,@"sampled_at":@(CACurrentMediaTime())};
}
BOOL DWNativeDecorationHit(NSDictionary *report,NSDictionary *identity,CGRect own,CGRect displayed,CGPoint point){
    if(![report[@"identity"]isEqual:identity]||own.size.width<=0||own.size.height<=0||displayed.size.width<=0||displayed.size.height<=0)return NO;
    NSDictionary *size=report[@"native_bounds"][@"size"];if([size[@"width"]doubleValue]!=own.size.width||[size[@"height"]doubleValue]!=own.size.height)return NO;
    CGPoint local=CGPointMake((point.x-displayed.origin.x)*own.size.width/displayed.size.width,(point.y-displayed.origin.y)*own.size.height/displayed.size.height);
    for(NSDictionary *button in report[@"buttons"]){NSDictionary *origin=button[@"origin"],*extent=button[@"size"];CGRect r=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[extent[@"width"]doubleValue],[extent[@"height"]doubleValue]);if(CGRectContainsPoint(r,local))return YES;}
    return NO;
}
