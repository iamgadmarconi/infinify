// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-decorations.h"
#import "native-presenter.h"
#import "native-placement-validation.h"
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
static id decorationAttribute(AXUIElementRef element,CFStringRef name,AXError *error){
    CFTypeRef value=NULL;AXError result=AXUIElementCopyAttributeValue(element,name,&value);if(error)*error=result;
    if(result){if(value)CFRelease(value);return nil;}return CFBridgingRelease(value);
}
static CGRect decorationLocal(CGRect frame,CGRect own){frame.origin.x-=own.origin.x;frame.origin.y-=own.origin.y;return frame;}
// Standard AppKit frames expose their title, traffic lights and document proxy
// as convenience attributes, separate from their content/toolbar children. Only
// accept that complete layout: its first other child is the lower boundary, not
// a guessed title-bar height. Unified/custom content extending into this area
// has no inferred draggable strip. Controls and the document proxy stay native.
static NSDictionary *decorationTitle(AXUIElementRef window,CGRect own,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline){
    if(![decorationAttribute(window,kAXRoleAttribute,NULL)isEqual:(__bridge NSString *)kAXWindowRole]
        ||![decorationAttribute(window,kAXSubroleAttribute,NULL)isEqual:(__bridge NSString *)kAXStandardWindowSubrole])return nil;
    Boolean movable=false;if(AXUIElementIsAttributeSettable(window,kAXPositionAttribute,&movable)||!movable)return nil;
    NSMutableArray *chrome=[NSMutableArray array],*excluded=[NSMutableArray array];CGRect lights=CGRectNull,title=CGRectNull;
    NSArray *attributes=@[(__bridge NSString *)kAXCloseButtonAttribute,(__bridge NSString *)kAXMinimizeButtonAttribute,(__bridge NSString *)kAXZoomButtonAttribute,(__bridge NSString *)kAXTitleUIElementAttribute,(__bridge NSString *)kAXProxyAttribute];
    for(NSUInteger index=0;index<attributes.count;index++){
        if(CACurrentMediaTime()>=deadline)return nil;
        AXError error=kAXErrorSuccess;id value=decorationAttribute(window,(__bridge CFStringRef)attributes[index],&error);
        if(!value){if(index<4||(error!=kAXErrorNoValue&&error!=kAXErrorAttributeUnsupported))return nil;continue;}
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return nil;
        AXUIElementRef element=(__bridge AXUIElementRef)value;CGRect frame;uint32_t childWindow=0;
        if(AXUIElementSetMessagingTimeout(element,.02)||getWindow(element,&childWindow)||childWindow!=wid
            ||!decorationFrame(element,&frame)||!CGRectContainsRect(CGRectInset(own,-1,-1),frame))return nil;
        NSString *role=decorationAttribute(element,kAXRoleAttribute,NULL);
        if(index<3){
            if(![role isEqual:(__bridge NSString *)kAXButtonRole])return nil;
            NSString *subrole=decorationAttribute(element,kAXSubroleAttribute,NULL);
            NSArray *expected=index==0?@[@"AXCloseButton"]:index==1?@[@"AXMinimizeButton"]:@[@"AXZoomButton",@"AXFullScreenButton"];
            if(![expected containsObject:subrole])return nil;
            if(!CGRectIsNull(lights)&&(fabs(frame.origin.y-lights.origin.y)>1||fabs(frame.size.height-lights.size.height)>1))return nil;
            lights=CGRectUnion(lights,frame);
        }else if(index==3){
            if(![role isEqual:(__bridge NSString *)kAXStaticTextRole])return nil;title=frame;
        }
        [chrome addObject:value];
        if(index!=3)[excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(CGRectIsNull(lights)||CGRectIsNull(title)||CGRectGetMinY(title)>CGRectGetMaxY(lights)||CGRectGetMaxY(title)<CGRectGetMinY(lights))return nil;
    id children=decorationAttribute(window,kAXChildrenAttribute,NULL);
    if(![children isKindOfClass:NSArray.class]||![children count]||[children count]>64)return nil;
    CGFloat bottom=CGRectGetMaxY(own);BOOL content=NO;
    for(id value in children){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return nil;
        if([chrome containsObject:value])continue;
        AXUIElementRef child=(__bridge AXUIElementRef)value;CGRect frame;uint32_t childWindow=0;
        if(AXUIElementSetMessagingTimeout(child,.02)||getWindow(child,&childWindow)||childWindow!=wid||!decorationFrame(child,&frame))return nil;
        frame=CGRectIntersection(frame,own);if(CGRectIsNull(frame)||CGRectIsEmpty(frame))continue;
        // AppKit document actions (for example TextEdit's title menu) are
        // title-row siblings, not content. Preserve their native hit area
        // without making the entire observed title strip non-draggable.
        if([decorationAttribute(child,kAXRoleAttribute,NULL)isEqual:(__bridge NSString *)kAXMenuButtonRole]
            &&CGRectGetMinY(frame)>=fmin(CGRectGetMinY(lights),CGRectGetMinY(title))-1
            &&CGRectGetMaxY(frame)<=fmax(CGRectGetMaxY(lights),CGRectGetMaxY(title))+1){
            [excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];continue;
        }
        bottom=fmin(bottom,CGRectGetMinY(frame));content=YES;
        [excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(!content||bottom<=fmax(CGRectGetMaxY(lights),CGRectGetMaxY(title)))return nil;
    return @{@"region":decorationRect(CGRectMake(0,0,own.size.width,bottom-own.origin.y)),@"excluded":excluded};
}
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
    if(CACurrentMediaTime()>=deadline){CFRelease(window);return nil;}
    NSDictionary *title=decorationTitle(window,own,selected.window,getWindow,deadline);
    // Title support is optional. A timed-out title/child query must not withdraw
    // an already successful green-button lookup from this unchanged window.
    if(CACurrentMediaTime()>=deadline)title=nil;
    CFRelease(window);CGRect after;
    if(!dw_focus_owner(selected,&after)||!CGRectEqualToRect(own,after))return nil;
    return @{@"identity":[identity copy],@"native_bounds":decorationRect(own),@"buttons":buttons.copy,@"title":title?:@{},@"sampled_at":@(CACurrentMediaTime())};
}
BOOL DWNativeDecorationHit(NSDictionary *report,NSDictionary *identity,CGRect own,CGRect displayed,CGPoint point){
    if(![report[@"identity"]isEqual:identity]||own.size.width<=0||own.size.height<=0||displayed.size.width<=0||displayed.size.height<=0)return NO;
    NSDictionary *size=report[@"native_bounds"][@"size"];if([size[@"width"]doubleValue]!=own.size.width||[size[@"height"]doubleValue]!=own.size.height)return NO;
    CGPoint local=CGPointMake((point.x-displayed.origin.x)*own.size.width/displayed.size.width,(point.y-displayed.origin.y)*own.size.height/displayed.size.height);
    for(NSDictionary *button in report[@"buttons"]){NSDictionary *origin=button[@"origin"],*extent=button[@"size"];CGRect r=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[extent[@"width"]doubleValue],[extent[@"height"]doubleValue]);if(CGRectContainsPoint(r,local))return YES;}
    return NO;
}
static CGRect decorationReadRect(NSDictionary *value){
    return CGRectMake([value[@"origin"][@"x"]doubleValue],[value[@"origin"][@"y"]doubleValue],[value[@"size"][@"width"]doubleValue],[value[@"size"][@"height"]doubleValue]);
}
BOOL DWNativeWindowDragHit(NSDictionary *identity,NSDictionary *report,CGPoint point){
    if(!NSThread.isMainThread||![report[@"identity"]isEqual:identity]||CACurrentMediaTime()-[report[@"sampled_at"]doubleValue]>.5)return NO;
    NSDictionary *title=report[@"title"];CGRect region=decorationReadRect(title[@"region"]);if(CGRectIsEmpty(region))return NO;
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(!identity[key]||![identity[key]isEqual:recipient[key]])return NO;
    DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
    CGRect own;if(!dw_focus_owner(selected,&own)||!CGRectEqualToRect(own,decorationReadRect(report[@"native_bounds"])))return NO;
    NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,selected.window));
    if(rows.count!=1)return NO;NSDictionary *row=rows[0];CGRect displayed;
    if([row[(id)kCGWindowOwnerPID]intValue]!=selected.pid||![row[(id)kCGWindowIsOnscreen]boolValue]||[row[(id)kCGWindowAlpha]doubleValue]<=0
        ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)||CGRectIsEmpty(displayed)||!CGRectContainsPoint(displayed,point))return NO;
    CGPoint local=CGPointMake((point.x-displayed.origin.x)*own.size.width/displayed.size.width,(point.y-displayed.origin.y)*own.size.height/displayed.size.height);
    if(!CGRectContainsPoint(region,local))return NO;
    for(NSDictionary *excluded in title[@"excluded"])if(CGRectContainsPoint(decorationReadRect(excluded),local))return NO;
    CGRect after;return dw_focus_owner(selected,&after)&&CGRectEqualToRect(own,after)
        &&[recipient isEqual:DWNativeEventRecipientAtPoint(point)];
}
