// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-decorations.h"
#import "native-presenter.h"
#import "native-placement-validation.h"
#import "../focus/focus.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>

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
// Retain the first rejection for the next debug press, without another AX read
// or a log line on every background refresh. No title or document text is kept.
static NSDictionary *decorationRejected(NSString **reason,NSString *value){if(reason)*reason=value;return nil;}
// A modern AppKit unified toolbar can contain or omit AXTitleUIElement. Its measured
// toolbar rectangle supplies the chrome boundary; whole child rectangles,
// including groups, remain native. Never infer empty space inside a group.
static NSDictionary *decorationToolbar(AXUIElementRef window,CGRect own,CGRect lights,CGRect title,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline,NSArray *chrome,NSMutableArray *excluded,NSString **reason){
    id children=decorationAttribute(window,kAXChildrenAttribute,NULL);
    if(![children isKindOfClass:NSArray.class]||![children count]||[children count]>64)return decorationRejected(reason,@"toolbar_children_unavailable_or_unbounded");
    AXUIElementRef toolbar=NULL;CGRect toolbarFrame=CGRectNull;NSMutableArray *otherFrames=[NSMutableArray array];
    for(id value in children){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return decorationRejected(reason,@"toolbar_root_deadline_or_type");
        if([chrome containsObject:value])continue;
        AXUIElementRef child=(__bridge AXUIElementRef)value;CGRect frame;uint32_t childWindow=0;
        if(AXUIElementSetMessagingTimeout(child,.02)||getWindow(child,&childWindow)||childWindow!=wid||!decorationFrame(child,&frame))return decorationRejected(reason,@"toolbar_root_geometry_or_owner");
        id role=decorationAttribute(child,kAXRoleAttribute,NULL);
        if([role isEqual:(__bridge NSString *)kAXToolbarRole]){
            if(toolbar||fabs(frame.origin.x-own.origin.x)>1||fabs(frame.origin.y-own.origin.y)>1||fabs(frame.size.width-own.size.width)>1
                ||!CGRectContainsRect(CGRectInset(own,-1,-1),frame)||!CGRectContainsRect(CGRectInset(frame,-1,-1),lights)
                ||(!CGRectIsNull(title)&&!CGRectContainsRect(CGRectInset(frame,-1,-1),title)))return decorationRejected(reason,@"toolbar_ambiguous_or_not_top_chrome");
            toolbar=child;toolbarFrame=frame;continue;
        }
        // Safari's full-window split wrapper and SwiftUI's full-window hosting
        // wrapper also cover the separately exposed toolbar. No other overlap
        // is ignored; an ordinary content/control rectangle stays excluded.
        BOOL wrapper=CGRectEqualToRect(frame,own)&&([role isEqual:(__bridge NSString *)kAXSplitGroupRole]
            ||([role isEqual:(__bridge NSString *)kAXGroupRole]&&[decorationAttribute(child,kAXSubroleAttribute,NULL)isEqual:@"AXHostingView"]));
        if(!wrapper)[otherFrames addObject:decorationRect(frame)];
    }
    if(!toolbar)return decorationRejected(reason,@"missing_top_toolbar");
    for(NSDictionary *value in otherFrames){
        CGRect frame=CGRectMake([value[@"origin"][@"x"]doubleValue],[value[@"origin"][@"y"]doubleValue],[value[@"size"][@"width"]doubleValue],[value[@"size"][@"height"]doubleValue]);
        frame=CGRectIntersection(frame,toolbarFrame);if(!CGRectIsNull(frame)&&!CGRectIsEmpty(frame))[excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(CACurrentMediaTime()>=deadline)return decorationRejected(reason,@"toolbar_deadline");
    id items=decorationAttribute(toolbar,kAXChildrenAttribute,NULL);
    if(![items isKindOfClass:NSArray.class]||![items count]||[items count]>64)return decorationRejected(reason,@"toolbar_items_unavailable_or_unbounded");
    for(id value in items){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return decorationRejected(reason,@"toolbar_item_deadline_or_type");
        AXUIElementRef item=(__bridge AXUIElementRef)value;CGRect frame;uint32_t itemWindow=0;
        if(AXUIElementSetMessagingTimeout(item,.02)||getWindow(item,&itemWindow)||itemWindow!=wid||!decorationFrame(item,&frame)
            ||!CGRectContainsRect(CGRectInset(toolbarFrame,-1,-1),frame))return decorationRejected(reason,@"toolbar_item_geometry_or_owner");
        [excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(reason)*reason=@"accepted_unified_toolbar";
    return @{@"region":decorationRect(decorationLocal(toolbarFrame,own)),@"excluded":excluded};
}
// Standard AppKit frames expose their title, traffic lights and document proxy
// separately from content. Their first content child is the lower boundary,
// never a guessed title-bar height. A missing title or overlapping content
// requires the independently measured unified-toolbar path above. Controls and
// the document proxy stay native.
static NSDictionary *decorationTitle(AXUIElementRef window,CGRect own,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline,NSString **reason,NSDictionary **detail){
    if(![decorationAttribute(window,kAXRoleAttribute,NULL)isEqual:(__bridge NSString *)kAXWindowRole]
        ||![decorationAttribute(window,kAXSubroleAttribute,NULL)isEqual:(__bridge NSString *)kAXStandardWindowSubrole])return decorationRejected(reason,@"window_role_or_subrole");
    Boolean movable=false;if(AXUIElementIsAttributeSettable(window,kAXPositionAttribute,&movable)||!movable)return decorationRejected(reason,@"position_not_settable");
    NSMutableArray *chrome=[NSMutableArray array],*excluded=[NSMutableArray array];CGRect lights=CGRectNull,title=CGRectNull;
    NSArray *attributes=@[(__bridge NSString *)kAXCloseButtonAttribute,(__bridge NSString *)kAXMinimizeButtonAttribute,(__bridge NSString *)kAXZoomButtonAttribute,(__bridge NSString *)kAXTitleUIElementAttribute,(__bridge NSString *)kAXProxyAttribute];
    for(NSUInteger index=0;index<attributes.count;index++){
        if(CACurrentMediaTime()>=deadline)return decorationRejected(reason,@"chrome_deadline");
        AXError error=kAXErrorSuccess;id value=decorationAttribute(window,(__bridge CFStringRef)attributes[index],&error);
        if(!value){if(index<3||(error!=kAXErrorNoValue&&error!=kAXErrorAttributeUnsupported))return decorationRejected(reason,[NSString stringWithFormat:@"missing_%@_error_%d",attributes[index],(int)error]);continue;}
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return decorationRejected(reason,[NSString stringWithFormat:@"invalid_%@",attributes[index]]);
        AXUIElementRef element=(__bridge AXUIElementRef)value;CGRect frame;uint32_t childWindow=0;
        if(AXUIElementSetMessagingTimeout(element,.02)||getWindow(element,&childWindow)||childWindow!=wid
            ||!decorationFrame(element,&frame)||!CGRectContainsRect(CGRectInset(own,-1,-1),frame))return decorationRejected(reason,[NSString stringWithFormat:@"geometry_or_owner_%@",attributes[index]]);
        NSString *role=decorationAttribute(element,kAXRoleAttribute,NULL);
        if(index<3){
            if(![role isEqual:(__bridge NSString *)kAXButtonRole])return decorationRejected(reason,[NSString stringWithFormat:@"role_%@",attributes[index]]);
            NSString *subrole=decorationAttribute(element,kAXSubroleAttribute,NULL);
            NSArray *expected=index==0?@[@"AXCloseButton"]:index==1?@[@"AXMinimizeButton"]:@[@"AXZoomButton",@"AXFullScreenButton"];
            if(![expected containsObject:subrole])return decorationRejected(reason,[NSString stringWithFormat:@"subrole_%@",attributes[index]]);
            if(!CGRectIsNull(lights)&&(fabs(frame.origin.y-lights.origin.y)>1||fabs(frame.size.height-lights.size.height)>1))return decorationRejected(reason,@"traffic_lights_misaligned");
            lights=CGRectUnion(lights,frame);
        }else if(index==3){
            if(![role isEqual:(__bridge NSString *)kAXStaticTextRole])return decorationRejected(reason,@"title_not_static_text");title=frame;
        }
        [chrome addObject:value];
        if(index!=3)[excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(CGRectIsNull(lights))return decorationRejected(reason,@"missing_traffic_lights");
    if(CGRectIsNull(title))return decorationToolbar(window,own,lights,title,wid,getWindow,deadline,chrome,excluded,reason);
    if(CGRectGetMinY(title)>CGRectGetMaxY(lights)||CGRectGetMaxY(title)<CGRectGetMinY(lights))return decorationRejected(reason,@"title_traffic_lights_no_overlap");
    id children=decorationAttribute(window,kAXChildrenAttribute,NULL);
    if(![children isKindOfClass:NSArray.class]||![children count]||[children count]>64)return decorationRejected(reason,@"children_unavailable_or_unbounded");
    NSArray *chromeExcluded=excluded.copy;
    CGFloat bottom=CGRectGetMaxY(own);BOOL content=NO;NSDictionary *boundary=nil;
    for(id value in children){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return decorationRejected(reason,@"child_deadline_or_type");
        if([chrome containsObject:value])continue;
        AXUIElementRef child=(__bridge AXUIElementRef)value;CGRect frame;uint32_t childWindow=0;
        if(AXUIElementSetMessagingTimeout(child,.02)||getWindow(child,&childWindow)||childWindow!=wid||!decorationFrame(child,&frame))return decorationRejected(reason,@"child_geometry_or_owner");
        frame=CGRectIntersection(frame,own);if(CGRectIsNull(frame)||CGRectIsEmpty(frame))continue;
        // AppKit document actions and edited-title text can be siblings of
        // the primary title, rather than content. Accept only their observed
        // title row, and retain their native hit areas: a secondary label's
        // role alone does not prove that clicking its surrounding UI is inert.
        id role=decorationAttribute(child,kAXRoleAttribute,NULL);
        if(([role isEqual:(__bridge NSString *)kAXMenuButtonRole]||[role isEqual:(__bridge NSString *)kAXStaticTextRole])
            &&CGRectGetMinY(frame)>=fmin(CGRectGetMinY(lights),CGRectGetMinY(title))-1
            &&CGRectGetMaxY(frame)<=fmax(CGRectGetMaxY(lights),CGRectGetMaxY(title))+1){
            [excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];continue;
        }
        if(detail&&CGRectGetMinY(frame)<bottom)boundary=@{@"role":[role isKindOfClass:NSString.class]?role:@"unavailable",@"frame":decorationRect(decorationLocal(frame,own))};
        bottom=fmin(bottom,CGRectGetMinY(frame));content=YES;
        [excluded addObject:decorationRect(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(!content||bottom<=fmax(CGRectGetMaxY(lights),CGRectGetMaxY(title))){
        if(detail)*detail=@{@"lights":decorationRect(decorationLocal(lights,own)),@"title":decorationRect(decorationLocal(title,own)),@"boundary":boundary?:@{}};
        // Finder exposes a real title inside its unified toolbar, alongside
        // a full-window content wrapper. Re-audit through the same toolbar
        // path, requiring that toolbar to contain the primary title too. Its
        // exclusion list must start before the rejected content rectangles.
        if(content)return decorationToolbar(window,own,lights,title,wid,getWindow,deadline,chrome,[chromeExcluded mutableCopy],reason);
        return decorationRejected(reason,@"no_content_boundary");
    }
    if(reason)*reason=@"accepted";
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
    NSString *titleReason=nil;NSDictionary *titleDetail=nil;BOOL debug=getenv("INFINIFY_DEBUG")!=NULL;
    NSDictionary *title=decorationTitle(window,own,selected.window,getWindow,deadline,debug?&titleReason:NULL,debug?&titleDetail:NULL);
    // Title support is optional. A timed-out title/child query must not withdraw
    // an already successful green-button lookup from this unchanged window.
    if(CACurrentMediaTime()>=deadline){title=nil;if(debug)titleReason=@"title_deadline";}
    CFRelease(window);CGRect after;
    if(!dw_focus_owner(selected,&after)||!CGRectEqualToRect(own,after))return nil;
    NSMutableDictionary *report=[@{@"identity":[identity copy],@"native_bounds":decorationRect(own),@"buttons":buttons.copy,@"title":title?:@{},@"sampled_at":@(CACurrentMediaTime())}mutableCopy];
    if(debug)report[@"title_reason"]=titleReason?:@"unavailable";
    if(debug&&titleDetail)report[@"title_detail"]=titleDetail;
    return report;
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
static BOOL decorationDragMiss(NSDictionary *identity,CGPoint point,const char *reason){
    if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss pid=%d wid=%u point=%g,%g reason=%s\n",[identity[@"pid"]intValue],[identity[@"wid"]unsignedIntValue],point.x,point.y,reason);
    return NO;
}
BOOL DWNativeWindowDragHit(NSDictionary *identity,NSDictionary *report,CGPoint point){
    if(!NSThread.isMainThread||![report[@"identity"]isEqual:identity]||CACurrentMediaTime()-[report[@"sampled_at"]doubleValue]>.5)return decorationDragMiss(identity,point,"stale_report");
    NSDictionary *title=report[@"title"];CGRect region=decorationReadRect(title[@"region"]);if(CGRectIsEmpty(region))return decorationDragMiss(identity,point,"no_region");
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(!identity[key]||![identity[key]isEqual:recipient[key]])return decorationDragMiss(identity,point,"recipient_changed");
    DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
    CGRect own;if(!dw_focus_owner(selected,&own))return decorationDragMiss(identity,point,"native_unavailable");
    CGRect cached=decorationReadRect(report[@"native_bounds"]);
    if(!CGRectEqualToRect(own,cached)){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss native=%g,%g,%g,%g cached=%g,%g,%g,%g\n",own.origin.x,own.origin.y,own.size.width,own.size.height,cached.origin.x,cached.origin.y,cached.size.width,cached.size.height);
        return decorationDragMiss(identity,point,"native_changed");
    }
    NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,selected.window));
    if(rows.count!=1)return decorationDragMiss(identity,point,"window_list_changed");NSDictionary *row=rows[0];CGRect displayed;
    if([row[(id)kCGWindowOwnerPID]intValue]!=selected.pid||![row[(id)kCGWindowIsOnscreen]boolValue]||[row[(id)kCGWindowAlpha]doubleValue]<=0
        ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)||CGRectIsEmpty(displayed)||!CGRectContainsPoint(displayed,point))return decorationDragMiss(identity,point,"not_in_displayed_window");
    CGPoint local=CGPointMake((point.x-displayed.origin.x)*own.size.width/displayed.size.width,(point.y-displayed.origin.y)*own.size.height/displayed.size.height);
    if(!CGRectContainsPoint(region,local)){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss local=%g,%g title=%g,%g,%g,%g displayed=%g,%g,%g,%g\n",local.x,local.y,region.origin.x,region.origin.y,region.size.width,region.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height);
        return decorationDragMiss(identity,point,"outside_title");
    }
    for(NSDictionary *excluded in title[@"excluded"])if(CGRectContainsPoint(decorationReadRect(excluded),local)){
        if(getenv("INFINIFY_DEBUG")){CGRect frame=decorationReadRect(excluded);fprintf(stderr,"debug: native title miss local=%g,%g excluded=%g,%g,%g,%g\n",local.x,local.y,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height);}
        return decorationDragMiss(identity,point,"native_control");
    }
    CGRect after;if(!dw_focus_owner(selected,&after)||!CGRectEqualToRect(own,after)
        ||![recipient isEqual:DWNativeEventRecipientAtPoint(point)])return decorationDragMiss(identity,point,"changed_during_hit");
    return YES;
}
