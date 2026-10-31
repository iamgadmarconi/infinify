// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativeDecorations.h"
#import "DWNativePresenter.h"
#import "DWNativePlacementValidation.h"
#import "DWNativeToolbarExtent.h"
#import "DWGeometryJSON.h"
#import "DWNativeFocus.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>

static BOOL decorationFrameRead(AXUIElementRef element,CGRect *out,BOOL allowEmpty){
    // Chrome refresh visits several elements every 200 ms. Fetch each frame in
    // one AX message instead of two; no geometry or freshness result is cached.
    static CFArrayRef attributes;static dispatch_once_t once;
    dispatch_once(&once,^{const void *names[]={kAXPositionAttribute,kAXSizeAttribute};attributes=CFArrayCreate(NULL,names,2,&kCFTypeArrayCallBacks);});
    CFArrayRef values=NULL;CFTypeRef position=NULL,size=NULL;CGPoint p;CGSize s;BOOL valid=NO;
    AXError error=AXUIElementCopyMultipleAttributeValues(element,attributes,kAXCopyMultipleAttributeOptionStopOnError,&values);
    if(!error&&values&&CFGetTypeID(values)==CFArrayGetTypeID()&&CFArrayGetCount(values)==2){position=CFArrayGetValueAtIndex(values,0);size=CFArrayGetValueAtIndex(values,1);}
    // A provider may implement individual attributes without implementing the
    // batch API. Preserve that compatibility, but never retry failed/timed-out
    // batches or mix partial observations into a successful frame.
    if(error==kAXErrorNotImplemented){
        if(values){CFRelease(values);values=NULL;}
        if(AXUIElementCopyAttributeValue(element,kAXPositionAttribute,&position)){if(position)CFRelease(position);position=NULL;}
        if(position&&CFGetTypeID(position)==AXValueGetTypeID()&&AXValueGetType(position)==kAXValueCGPointType
            &&AXUIElementCopyAttributeValue(element,kAXSizeAttribute,&size)){if(size)CFRelease(size);size=NULL;}
    }
    if(position&&size&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()
        &&AXValueGetType(position)==kAXValueCGPointType&&AXValueGetType(size)==kAXValueCGSizeType
        &&AXValueGetValue(position,kAXValueCGPointType,&p)&&AXValueGetValue(size,kAXValueCGSizeType,&s)
        &&isfinite(p.x)&&isfinite(p.y)&&isfinite(s.width)&&isfinite(s.height)&&(allowEmpty?s.width>=0&&s.height>=0:s.width>0&&s.height>0)){*out=CGRectMake(p.x,p.y,s.width,s.height);valid=YES;}
    if(error==kAXErrorNotImplemented){if(position)CFRelease(position);if(size)CFRelease(size);}
    if(values)CFRelease(values);return valid;
}
static BOOL decorationFrame(AXUIElementRef element,CGRect *out){return decorationFrameRead(element,out,NO);}
static BOOL decorationNear(CGRect a,CGRect b){return fabs(a.origin.x-b.origin.x)<=1&&fabs(a.origin.y-b.origin.y)<=1&&fabs(a.size.width-b.size.width)<=1&&fabs(a.size.height-b.size.height)<=1;}
static id decorationAttribute(AXUIElementRef element,CFStringRef name,AXError *error){
    CFTypeRef value=NULL;AXError result=AXUIElementCopyAttributeValue(element,name,&value);if(error)*error=result;
    if(result){if(value)CFRelease(value);return nil;}return CFBridgingRelease(value);
}
static CGRect decorationLocal(CGRect frame,CGRect own){frame.origin.x-=own.origin.x;frame.origin.y-=own.origin.y;return frame;}
static BOOL decorationFinderFrame(AXUIElementRef element,pid_t pid,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline,CGRect *frame){
    pid_t actualPID=0;uint32_t actualWindow=0;
    return CACurrentMediaTime()<deadline&&!AXUIElementSetMessagingTimeout(element,.02)
        &&!AXUIElementGetPid(element,&actualPID)&&actualPID==pid&&!getWindow(element,&actualWindow)&&actualWindow==wid
        &&decorationFrame(element,frame)&&CACurrentMediaTime()<deadline
        &&!getWindow(element,&actualWindow)&&actualWindow==wid;
}
static AXUIElementRef decorationFinderSplit(AXUIElementRef parent,CGRect own,pid_t pid,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline){
    if(CACurrentMediaTime()>=deadline)return NULL;
    __attribute__((objc_precise_lifetime)) id children=decorationAttribute(parent,kAXChildrenAttribute,NULL);
    if(![children isKindOfClass:NSArray.class]||![children count]||[children count]>64)return NULL;
    AXUIElementRef selected=NULL;
    for(id value in children){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return NULL;
        AXUIElementRef child=(__bridge AXUIElementRef)value;
        if(AXUIElementSetMessagingTimeout(child,.02))return NULL;
        id role=decorationAttribute(child,kAXRoleAttribute,NULL);if(![role isKindOfClass:NSString.class])return NULL;
        if(![role isEqual:(__bridge NSString *)kAXSplitGroupRole])continue;
        CGRect frame;if(!decorationFinderFrame(child,pid,wid,getWindow,deadline,&frame))return NULL;
        if(!CGRectEqualToRect(frame,own))continue;if(selected)return NULL;selected=child;
    }
    // The caller retains this reference while the temporary children array dies.
    return selected?(AXUIElementRef)CFRetain(selected):NULL;
}
// Finder's observed search-scope row is draggable outside its controls, although
// it sits below AXToolbar. Recognize only this exact named Finder hierarchy;
// a generic group, empty content or a guessed title-bar height is not chrome.
static NSDictionary *decorationFinderSearchHeader(AXUIElementRef window,CGRect own,CGRect toolbar,pid_t pid,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline){
    if(CACurrentMediaTime()>=deadline||![[NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier isEqual:@"com.apple.finder"]
        ||CACurrentMediaTime()>=deadline||![decorationAttribute(window,kAXIdentifierAttribute,NULL)isEqual:@"FinderWindow"])return nil;
    AXUIElementRef outer=decorationFinderSplit(window,own,pid,wid,getWindow,deadline);if(!outer)return nil;
    AXUIElementRef inner=decorationFinderSplit(outer,own,pid,wid,getWindow,deadline);CFRelease(outer);if(!inner)return nil;
    __attribute__((objc_precise_lifetime)) id children=CACurrentMediaTime()<deadline?decorationAttribute(inner,kAXChildrenAttribute,NULL):nil;CFRelease(inner);
    if(![children isKindOfClass:NSArray.class]||[children count]!=5)return nil;
    AXUIElementRef header=NULL;CGRect headerFrame=CGRectNull,results=CGRectNull;NSMutableArray *siblings=[NSMutableArray array];
    for(id value in children){
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return nil;
        AXUIElementRef child=(__bridge AXUIElementRef)value;CGRect frame;
        if(!decorationFinderFrame(child,pid,wid,getWindow,deadline,&frame))return nil;
        id role=decorationAttribute(child,kAXRoleAttribute,NULL),identifier=decorationAttribute(child,kAXIdentifierAttribute,NULL);
        if(![role isKindOfClass:NSString.class]||CACurrentMediaTime()>=deadline)return nil;
        if([role isEqual:(__bridge NSString *)kAXGroupRole]&&[identifier isEqual:@"_NS:129"]){if(header)return nil;header=child;headerFrame=frame;}
        else {
            [siblings addObject:DWRectJSON(frame)];
            if([role isEqual:(__bridge NSString *)kAXScrollAreaRole]&&[identifier isEqual:@"_NS:23"]){if(!CGRectIsNull(results))return nil;results=frame;}
        }
    }
    if(!header||CGRectIsNull(results)||!CGRectContainsRect(CGRectInset(own,-1,-1),headerFrame)
        ||!CGRectContainsRect(CGRectInset(own,-1,-1),results)||fabs(CGRectGetMinY(headerFrame)-CGRectGetMaxY(toolbar))>1
        ||fabs(headerFrame.origin.x-results.origin.x)>1||fabs(headerFrame.size.width-results.size.width)>1
        ||CGRectGetMinY(results)<CGRectGetMaxY(headerFrame)-1)return nil;
    id controls=decorationAttribute(header,kAXChildrenAttribute,NULL);
    if(![controls isKindOfClass:NSArray.class]||[controls count]!=4)return nil;
    NSDictionary *roles=@{@"_NS:12":(__bridge NSString *)kAXStaticTextRole,@"_NS:29":(__bridge NSString *)kAXRadioGroupRole,
        @"_NS:51":(__bridge NSString *)kAXButtonRole,@"plusMinusButton":(__bridge NSString *)kAXCheckBoxRole};
    NSMutableSet *seen=[NSMutableSet set];NSMutableArray *excluded=[NSMutableArray array];
    for(id value in controls){
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return nil;
        AXUIElementRef control=(__bridge AXUIElementRef)value;CGRect frame;
        if(!decorationFinderFrame(control,pid,wid,getWindow,deadline,&frame)||!CGRectContainsRect(CGRectInset(headerFrame,-1,-1),frame))return nil;
        id identifier=decorationAttribute(control,kAXIdentifierAttribute,NULL),role=decorationAttribute(control,kAXRoleAttribute,NULL);
        if(![identifier isKindOfClass:NSString.class]||!roles[identifier]||![roles[identifier]isEqual:role]||[seen containsObject:identifier])return nil;
        if([identifier isEqual:@"plusMinusButton"]&&![decorationAttribute(control,kAXSubroleAttribute,NULL)isEqual:@"AXToggle"])return nil;
        [seen addObject:identifier];[excluded addObject:DWRectJSON(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    for(NSDictionary *sibling in siblings){CGRect frame=CGRectIntersection(DWRectFromJSON(sibling),headerFrame);
        if(!CGRectIsNull(frame)&&!CGRectIsEmpty(frame))[excluded addObject:DWRectJSON(decorationLocal(CGRectInset(frame,-1,-1),own))];}
    CGRect after;if(seen.count!=4||!decorationFinderFrame(header,pid,wid,getWindow,deadline,&after)||!CGRectEqualToRect(after,headerFrame))return nil;
    return @{@"region":DWRectJSON(decorationLocal(headerFrame,own)),@"excluded":excluded};
}
// Retain the first rejection for the next debug press, without another AX read
// or a log line on every background refresh. No title or document text is kept.
static NSDictionary *decorationRejected(NSString **reason,NSString *value){if(reason)*reason=value;return nil;}
// A group item's own rectangle is the toolbar's height; what is native in it is what its children cover (DWToolbarGroupExtent says
// why). Best effort inside the title lookup's budget: no time left, an unreadable child, or a child outside the group keeps the
// whole group native, exactly as before.
static CGRect decorationGroupExtent(AXUIElementRef item,CGRect frame,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline){
    if(CACurrentMediaTime()+.03>=deadline||![decorationAttribute(item,kAXRoleAttribute,NULL)isEqual:(__bridge NSString *)kAXGroupRole])return frame;
    id children=decorationAttribute(item,kAXChildrenAttribute,NULL);
    if(![children isKindOfClass:NSArray.class]||![children count]||[children count]>64)return frame;
    CGRect frames[64];size_t count=0;
    for(id value in children){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return frame;
        AXUIElementRef child=(__bridge AXUIElementRef)value;uint32_t childWindow=0;
        if(AXUIElementSetMessagingTimeout(child,.02)||getWindow(child,&childWindow)||childWindow!=wid||!decorationFrame(child,&frames[count]))return frame;
        count++;
    }
    CGRect extent;return DWToolbarGroupExtent(frame,frames,count,&extent)?extent:frame;
}
// Chromium browsers (Chrome; Aside is the same toolkit) draw their own caption: the tab strip row is the title bar, and Chromium calls
// -[NSWindow performWindowDragWithEvent:] for a press on its empty part. AppKit exposes no title element and no AXToolbar among the
// window's own children (the toolbar sits several wrapper groups down), so the unified-toolbar audit finds nothing. What the views
// toolkit does expose is an AXTabGroup whose top is the window's top and whose bottom is the strip row's bottom, with every tab an
// AXRadioButton inside it, and the strip's other controls (tab search, new tab) as sibling AXButton/AXPopUpButton. The caption is that row
// (the window's top edge to the AXTabGroup's bottom, the full width) minus the traffic lights, the whole AXTabGroup (tabs, their close
// buttons, tab-group chips), and every control the walk meets in the row. AXUIElementCopyElementAtPosition cannot tell the two apart: a
// point on a tab and a point on the empty strip both return an unlabelled leaf AXGroup (measured on Chrome 156, 2026-10-30), so this reads frames.
// Only elements that start above the traffic lights' bottom are walked; the toolbar and the web content start below it and are only
// measured, and anything measured that reaches into the row rejects the audit. Web content, a toolbar or a scroll area inside the row,
// several tab groups, an unreadable or foreign element, or an exhausted budget keeps the window's rejection exactly as before.
typedef struct{CGRect own,lights;uint32_t wid;AXError(*getWindow)(AXUIElementRef,uint32_t *);CFTimeInterval deadline;int budget;NSMutableArray *controls,*below;NSUInteger tabGroups;CGRect tabGroup;}DecorationCaption;
static NSString *decorationCaptionWalk(AXUIElementRef element,int depth,DecorationCaption *c){
    if(--c->budget<0)return @"caption_node_budget";if(CACurrentMediaTime()>=c->deadline)return @"caption_deadline";if(depth>8)return @"caption_depth";
    uint32_t window=0;CGRect frame;
    if(AXUIElementSetMessagingTimeout(element,.02)||c->getWindow(element,&window)||window!=c->wid||!decorationFrameRead(element,&frame,YES))return @"caption_geometry_or_owner";
    if(frame.size.width<=0||frame.size.height<=0)return nil;
    if(CGRectGetMinY(frame)>=CGRectGetMaxY(c->lights)){[c->below addObject:DWRectJSON(frame)];return nil;}
    id role=decorationAttribute(element,kAXRoleAttribute,NULL);if(![role isKindOfClass:NSString.class])return @"caption_role";
    if([role isEqual:@"AXWebArea"]||[role isEqual:(__bridge NSString *)kAXScrollAreaRole]||[role isEqual:(__bridge NSString *)kAXToolbarRole]
        ||[role isEqual:(__bridge NSString *)kAXSplitGroupRole]||[role isEqual:(__bridge NSString *)kAXTextAreaRole])return @"caption_content_or_toolbar_in_row";
    if([role isEqual:(__bridge NSString *)kAXTabGroupRole]){if(c->tabGroups++)return @"caption_multiple_tab_groups";c->tabGroup=frame;[c->controls addObject:DWRectJSON(frame)];return nil;}
    if(![role isEqual:(__bridge NSString *)kAXGroupRole]){[c->controls addObject:DWRectJSON(frame)];return nil;}
    id children=decorationAttribute(element,kAXChildrenAttribute,NULL);
    if(children&&![children isKindOfClass:NSArray.class])return @"caption_children";
    if([children count]>64)return @"caption_children_unbounded";
    if(![children count]){
        // A leaf group is the empty strip unless it offers an action of its own (a chip or a button drawn as a group).
        CFArrayRef names=NULL;if(AXUIElementCopyActionNames(element,&names)||!names)return @"caption_actions";
        NSArray *actions=CFBridgingRelease(names);
        for(NSString *name in @[(__bridge NSString *)kAXPressAction,(__bridge NSString *)kAXPickAction,(__bridge NSString *)kAXConfirmAction,(__bridge NSString *)kAXIncrementAction,(__bridge NSString *)kAXDecrementAction])
            if([actions containsObject:name]){[c->controls addObject:DWRectJSON(frame)];break;}
        return nil;
    }
    for(id value in children){
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return @"caption_child_type";
        NSString *failure=decorationCaptionWalk((__bridge AXUIElementRef)value,depth+1,c);if(failure)return failure;
    }
    return nil;
}
static NSDictionary *decorationBrowserCaption(NSArray *children,CGRect own,CGRect lights,uint32_t wid,AXError(*getWindow)(AXUIElementRef,uint32_t *),CFTimeInterval deadline,NSArray *chrome,NSMutableArray *excluded,NSString **reason){
    DecorationCaption c={.own=own,.lights=lights,.wid=wid,.getWindow=getWindow,.deadline=deadline,.budget=96,.controls=[NSMutableArray array],.below=[NSMutableArray array],.tabGroup=CGRectNull};
    for(id value in children){
        if([chrome containsObject:value])continue;
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return decorationRejected(reason,@"caption_child_type");
        NSString *failure=decorationCaptionWalk((__bridge AXUIElementRef)value,0,&c);if(failure)return decorationRejected(reason,failure);
    }
    if(!c.tabGroups)return decorationRejected(reason,@"missing_top_toolbar");
    CGRect tabs=c.tabGroup;CGFloat bottom=CGRectGetMaxY(tabs);
    if(fabs(CGRectGetMinY(tabs)-CGRectGetMinY(own))>1||!CGRectContainsRect(CGRectInset(own,-1,-1),tabs)||bottom<CGRectGetMaxY(lights)-1||bottom>=CGRectGetMaxY(own)
        ||CGRectGetMinY(lights)<CGRectGetMinY(own)-1)return decorationRejected(reason,@"caption_tab_group_not_top_row");
    for(NSDictionary *value in c.below)if(CGRectGetMinY(DWRectFromJSON(value))<bottom-1.5)return decorationRejected(reason,@"caption_control_below_lights");
    for(NSDictionary *value in c.controls)[excluded addObject:DWRectJSON(decorationLocal(CGRectInset(DWRectFromJSON(value),-1,-1),own))];
    if(reason)*reason=@"accepted_browser_caption";
    return @{@"region":DWRectJSON(CGRectMake(0,0,own.size.width,bottom-CGRectGetMinY(own))),@"excluded":excluded};
}
// A modern AppKit unified toolbar can contain or omit AXTitleUIElement. Its measured
// toolbar rectangle supplies the chrome boundary; whole child rectangles
// remain native. A group item is native where its children are (its full width,
// and the vertical extent of its children), never by a guess about its content.
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
        if(!wrapper)[otherFrames addObject:DWRectJSON(frame)];
    }
    if(!toolbar)return decorationBrowserCaption(children,own,lights,wid,getWindow,deadline,chrome,excluded,reason);
    for(NSDictionary *value in otherFrames){
        CGRect frame=DWRectFromJSON(value);
        frame=CGRectIntersection(frame,toolbarFrame);if(!CGRectIsNull(frame)&&!CGRectIsEmpty(frame))[excluded addObject:DWRectJSON(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(CACurrentMediaTime()>=deadline)return decorationRejected(reason,@"toolbar_deadline");
    id items=decorationAttribute(toolbar,kAXChildrenAttribute,NULL);
    if(![items isKindOfClass:NSArray.class]||![items count]||[items count]>64)return decorationRejected(reason,@"toolbar_items_unavailable_or_unbounded");
    for(id value in items){
        if(CACurrentMediaTime()>=deadline||CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return decorationRejected(reason,@"toolbar_item_deadline_or_type");
        AXUIElementRef item=(__bridge AXUIElementRef)value;CGRect frame;uint32_t itemWindow=0;
        if(AXUIElementSetMessagingTimeout(item,.02)||getWindow(item,&itemWindow)||itemWindow!=wid||!decorationFrame(item,&frame)
            ||!CGRectContainsRect(CGRectInset(toolbarFrame,-1,-1),frame))return decorationRejected(reason,@"toolbar_item_geometry_or_owner");
        [excluded addObject:DWRectJSON(decorationLocal(CGRectInset(decorationGroupExtent(item,frame,wid,getWindow,deadline),-1,-1),own))];
    }
    if(reason)*reason=@"accepted_unified_toolbar";
    return @{@"region":DWRectJSON(decorationLocal(toolbarFrame,own)),@"excluded":excluded};
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
        if(index!=3)[excluded addObject:DWRectJSON(decorationLocal(CGRectInset(frame,-1,-1),own))];
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
            [excluded addObject:DWRectJSON(decorationLocal(CGRectInset(frame,-1,-1),own))];continue;
        }
        if(detail&&CGRectGetMinY(frame)<bottom)boundary=@{@"role":[role isKindOfClass:NSString.class]?role:@"unavailable",@"frame":DWRectJSON(decorationLocal(frame,own))};
        bottom=fmin(bottom,CGRectGetMinY(frame));content=YES;
        [excluded addObject:DWRectJSON(decorationLocal(CGRectInset(frame,-1,-1),own))];
    }
    if(!content||bottom<=fmax(CGRectGetMaxY(lights),CGRectGetMaxY(title))){
        if(detail)*detail=@{@"lights":DWRectJSON(decorationLocal(lights,own)),@"title":DWRectJSON(decorationLocal(title,own)),@"boundary":boundary?:@{}};
        // Finder exposes a real title inside its unified toolbar, alongside
        // a full-window content wrapper. Re-audit through the same toolbar
        // path, requiring that toolbar to contain the primary title too. Its
        // exclusion list must start before the rejected content rectangles.
        if(content)return decorationToolbar(window,own,lights,title,wid,getWindow,deadline,chrome,[chromeExcluded mutableCopy],reason);
        return decorationRejected(reason,@"no_content_boundary");
    }
    if(reason)*reason=@"accepted";
    return @{@"region":DWRectJSON(CGRectMake(0,0,own.size.width,bottom-own.origin.y)),@"excluded":excluded};
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
                frame.origin.x-=own.origin.x;frame.origin.y-=own.origin.y;NSDictionary *rect=DWRectJSON(frame);if(![buttons containsObject:rect])[buttons addObject:rect];
            }
        }
        if(enabled)CFRelease(enabled);if(role)CFRelease(role);if(value)CFRelease(value);
    }
    if(CACurrentMediaTime()>=deadline){CFRelease(window);return nil;}
    NSString *titleReason=nil;NSDictionary *titleDetail=nil;BOOL debug=getenv("INFINIFY_DEBUG")!=NULL;
    NSDictionary *title=decorationTitle(window,own,selected.window,getWindow,deadline,&titleReason,debug?&titleDetail:NULL);
    // Title support is optional. A timed-out title/child query must not withdraw
    // an already successful green-button lookup from this unchanged window.
    if(CACurrentMediaTime()>=deadline){title=nil;if(debug)titleReason=@"title_deadline";}
    if(title&&[titleReason isEqual:@"accepted_unified_toolbar"]){
        CGRect toolbar=DWRectFromJSON(title[@"region"]);toolbar.origin.x+=own.origin.x;toolbar.origin.y+=own.origin.y;
        NSDictionary *header=decorationFinderSearchHeader(window,own,toolbar,selected.pid,selected.window,getWindow,deadline);
        // This optional audit never withdraws the independently valid toolbar.
        if(header){NSMutableDictionary *extended=[title mutableCopy];extended[@"additional_regions"]=@[header];title=extended.copy;titleReason=@"accepted_unified_toolbar_finder_search_header";}
    }
    CFRelease(window);CGRect after;
    if(!dw_focus_owner(selected,&after)||!CGRectEqualToRect(own,after))return nil;
    NSMutableDictionary *report=[@{@"identity":[identity copy],@"native_bounds":DWRectJSON(own),@"buttons":buttons.copy,@"title":title?:@{},@"sampled_at":@(CACurrentMediaTime())}mutableCopy];
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
static BOOL decorationDragMiss(NSDictionary *identity,CGPoint point,const char *reason){
    if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss pid=%d wid=%u point=%g,%g reason=%s\n",[identity[@"pid"]intValue],[identity[@"wid"]unsignedIntValue],point.x,point.y,reason);
    return NO;
}
// The one rule that turns a title report into "canvas-owned" or not, for a point in window-local native points: nil when the point is
// inside the title region (or one of its additional regions) and in none of the native control rectangles, else why not. Shared by the
// live press path and the recorded-shape tests.
static NSString *decorationRegionVerdict(NSDictionary *title,CGPoint local){
    NSArray *regions=[@[title]arrayByAddingObjectsFromArray:[title[@"additional_regions"]isKindOfClass:NSArray.class]?title[@"additional_regions"]:@[]];
    BOOL inside=NO;
    for(NSDictionary *candidate in regions){
        if(CGRectContainsPoint(DWRectFromJSON(candidate[@"region"]),local))inside=YES;
        for(NSDictionary *excluded in candidate[@"excluded"])if(CGRectContainsPoint(DWRectFromJSON(excluded),local)){CGRect frame=DWRectFromJSON(excluded);
            return [NSString stringWithFormat:@"excluded=%g,%g,%g,%g",frame.origin.x,frame.origin.y,frame.size.width,frame.size.height];}
    }
    if(inside)return nil;CGRect region=DWRectFromJSON(title[@"region"]);
    return [NSString stringWithFormat:@"outside title=%g,%g,%g,%g",region.origin.x,region.origin.y,region.size.width,region.size.height];
}
BOOL DWNativeWindowDragHit(NSDictionary *identity,NSDictionary *report,CGPoint point){
    if(!NSThread.isMainThread||![report[@"identity"]isEqual:identity]||CACurrentMediaTime()-[report[@"sampled_at"]doubleValue]>.5)return decorationDragMiss(identity,point,"stale_report");
    NSDictionary *title=report[@"title"];CGRect region=DWRectFromJSON(title[@"region"]);if(CGRectIsEmpty(region))return decorationDragMiss(identity,point,"no_region");
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(!identity[key]||![identity[key]isEqual:recipient[key]])return decorationDragMiss(identity,point,"recipient_changed");
    DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
    CGRect own;if(!dw_focus_owner(selected,&own))return decorationDragMiss(identity,point,"native_unavailable");
    CGRect cached=DWRectFromJSON(report[@"native_bounds"]);
    if(!CGRectEqualToRect(own,cached)){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss native=%g,%g,%g,%g cached=%g,%g,%g,%g\n",own.origin.x,own.origin.y,own.size.width,own.size.height,cached.origin.x,cached.origin.y,cached.size.width,cached.size.height);
        return decorationDragMiss(identity,point,"native_changed");
    }
    NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,selected.window));
    if(rows.count!=1)return decorationDragMiss(identity,point,"window_list_changed");NSDictionary *row=rows[0];CGRect displayed;
    if([row[(id)kCGWindowOwnerPID]intValue]!=selected.pid||![row[(id)kCGWindowIsOnscreen]boolValue]||[row[(id)kCGWindowAlpha]doubleValue]<=0
        ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)||CGRectIsEmpty(displayed)||!CGRectContainsPoint(displayed,point))return decorationDragMiss(identity,point,"not_in_displayed_window");
    CGPoint local=CGPointMake((point.x-displayed.origin.x)*own.size.width/displayed.size.width,(point.y-displayed.origin.y)*own.size.height/displayed.size.height);
    NSString *verdict=decorationRegionVerdict(title,local);
    if(verdict){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss local=%g,%g %s\n",local.x,local.y,verdict.UTF8String);
        return decorationDragMiss(identity,point,[verdict hasPrefix:@"excluded"]?"native_control":"outside_title");
    }
    CGRect after;if(!dw_focus_owner(selected,&after)||!CGRectEqualToRect(own,after)
        ||![recipient isEqual:DWNativeEventRecipientAtPoint(point)])return decorationDragMiss(identity,point,"changed_during_hit");
    return YES;
}
