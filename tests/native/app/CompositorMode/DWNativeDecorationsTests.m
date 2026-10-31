// SPDX-License-Identifier: GPL-3.0-or-later
// The actual title-region classifier (decorationTitle and the shared point rule) run over Accessibility trees recorded from a
// disposable guest (Chrome 156, TextEdit, Finder, Aside's sign-in window; macOS 27.0.1, 2026-10-30). The AX calls are substituted by a
// table; no window, process, event or native session is touched. A pass says the classifier maps these recorded shapes to these
// verdicts. It is not proof that a press on a third-party window is routed (the live guest runs recorded in
// docs/native/app/CompositorMode/NATIVE-DRAG-ROUTING.md are that evidence).
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdio.h>

static AXError fakeCopyAttribute(AXUIElementRef element,CFStringRef attribute,CFTypeRef *value);
static AXError fakeCopyMultiple(AXUIElementRef element,CFArrayRef attributes,AXCopyMultipleAttributeOptions options,CFArrayRef *values);
static AXError fakeTimeout(AXUIElementRef element,float seconds);
static AXError fakeSettable(AXUIElementRef element,CFStringRef attribute,Boolean *settable);
static AXError fakeActionNames(AXUIElementRef element,CFArrayRef *names);
#define AXUIElementCopyAttributeValue fakeCopyAttribute
#define AXUIElementCopyMultipleAttributeValues fakeCopyMultiple
#define AXUIElementSetMessagingTimeout fakeTimeout
#define AXUIElementIsAttributeSettable fakeSettable
#define AXUIElementCopyActionNames fakeActionNames
#import "DWNativeDecorations.m"
#undef AXUIElementCopyAttributeValue
#undef AXUIElementCopyMultipleAttributeValues
#undef AXUIElementSetMessagingTimeout
#undef AXUIElementIsAttributeSettable
#undef AXUIElementCopyActionNames
#import "DWNativeDecorationsShapes.h"

// Link stubs for the live entry points of the module under test; the classifier tested here never calls them.
bool dw_focus_owner(DWFocusIdentity identity,CGRect *bounds){(void)identity;(void)bounds;return false;}
NSDictionary *DWNativeEventRecipientAtPoint(CGPoint point){(void)point;return nil;}

// ---- the substituted tree: a node is a dictionary {role,subrole,frame,actions,children(indexes)}; element i is application element pid 100000+i.
static NSMutableArray<NSMutableDictionary *> *nodes;
static NSDictionary *windowAttributes;
static NSMutableSet<NSNumber *> *unreadable;
static NSInteger nodeIndex(AXUIElementRef element){pid_t pid=0;return AXUIElementGetPid(element,&pid)?-1:pid-100000;}
static AXUIElementRef nodeElement(NSInteger index){return AXUIElementCreateApplication((pid_t)(100000+index));}
static AXError fakeTimeout(AXUIElementRef element,float seconds){(void)element;(void)seconds;return kAXErrorSuccess;}
static AXError fakeSettable(AXUIElementRef element,CFStringRef attribute,Boolean *settable){(void)element;(void)attribute;*settable=[windowAttributes[@"settable"]boolValue];return kAXErrorSuccess;}
static AXError fakeCopyMultiple(AXUIElementRef element,CFArrayRef attributes,AXCopyMultipleAttributeOptions options,CFArrayRef *values){(void)element;(void)attributes;(void)options;(void)values;return kAXErrorNotImplemented;}
static AXError fakeActionNames(AXUIElementRef element,CFArrayRef *names){
    NSInteger i=nodeIndex(element);if(i<0||i>=(NSInteger)nodes.count)return kAXErrorInvalidUIElement;*names=(CFArrayRef)CFBridgingRetain(nodes[i][@"actions"]);return kAXErrorSuccess;
}
static AXError fakeCopyAttribute(AXUIElementRef element,CFStringRef attribute,CFTypeRef *value){
    NSInteger i=nodeIndex(element);*value=NULL;if(i<0||i>=(NSInteger)nodes.count)return kAXErrorInvalidUIElement;
    NSMutableDictionary *node=nodes[i];NSString *name=(__bridge NSString *)attribute;
    if([name isEqual:(__bridge NSString *)kAXRoleAttribute]){*value=CFBridgingRetain(node[@"role"]);return kAXErrorSuccess;}
    if([name isEqual:(__bridge NSString *)kAXSubroleAttribute]){if(!node[@"subrole"])return kAXErrorNoValue;*value=CFBridgingRetain(node[@"subrole"]);return kAXErrorSuccess;}
    if([name isEqual:(__bridge NSString *)kAXChildrenAttribute]){
        NSMutableArray *children=[NSMutableArray array];for(NSNumber *c in node[@"children"])[children addObject:CFBridgingRelease(nodeElement(c.integerValue))];
        *value=CFBridgingRetain(children);return kAXErrorSuccess;
    }
    if([name isEqual:(__bridge NSString *)kAXPositionAttribute]||[name isEqual:(__bridge NSString *)kAXSizeAttribute]){
        if([unreadable containsObject:@(i)])return kAXErrorCannotComplete;
        CGRect f=[node[@"frame"]rectValue];
        if([name isEqual:(__bridge NSString *)kAXPositionAttribute]){CGPoint p=f.origin;*value=AXValueCreate(kAXValueCGPointType,&p);}
        else{CGSize s=f.size;*value=AXValueCreate(kAXValueCGSizeType,&s);}
        return kAXErrorSuccess;
    }
    if(i==0){
        NSDictionary *map=@{@"AXCloseButton":@"AXCloseButton",@"AXMinimizeButton":@"AXMinimizeButton",@"AXZoomButton":@"AXZoomButton",@"AXTitleUIElement":@"AXTitleUIElement",@"AXProxy":@"AXProxy"};
        NSString *key=map[name];
        if(key){NSNumber *target=windowAttributes[key];
            if([key isEqual:@"AXZoomButton"]&&(!target||target.integerValue<0))target=windowAttributes[@"AXFullScreenButton"];
            if(!target||target.integerValue<0)return kAXErrorNoValue;*value=nodeElement(target.integerValue);return kAXErrorSuccess;}
    }
    return kAXErrorAttributeUnsupported;
}
static AXError fakeWindowOf(AXUIElementRef element,uint32_t *wid){(void)element;*wid=7;return kAXErrorSuccess;}

// ---- fixture parsing: "depth #id Role/Subrole [x,y wxh] acts=a,b" lines, then "ATTRS settable=1 AXCloseButton=4 ...".
static void loadShape(const char *text){
    nodes=[NSMutableArray array];unreadable=[NSMutableSet set];windowAttributes=@{};NSMutableArray<NSNumber *> *stack=[NSMutableArray array];
    for(NSString *line in [@(text)componentsSeparatedByString:@"\n"]){
        if([line hasPrefix:@"ATTRS "]){
            NSMutableDictionary *attrs=[NSMutableDictionary dictionary];
            for(NSString *pair in [[line substringFromIndex:6]componentsSeparatedByString:@" "]){NSArray *kv=[pair componentsSeparatedByString:@"="];if(kv.count==2)attrs[kv[0]]=@([kv[1]integerValue]);}
            windowAttributes=attrs;continue;
        }
        // The frame is split by hand: scanf would read the size "0x0" as a hexadecimal number.
        NSRange open=[line rangeOfString:@"["],close=[line rangeOfString:@"]"],acts=[line rangeOfString:@" acts="];
        if(open.location==NSNotFound||close.location==NSNotFound||acts.location==NSNotFound)continue;
        int depth=0,ident=0;char role[64],subrole[64];
        if(sscanf(line.UTF8String,"%d #%d %63[^/]/%63s",&depth,&ident,role,subrole)<4)continue;
        NSArray *position=[[line substringWithRange:NSMakeRange(open.location+1,close.location-open.location-1)]componentsSeparatedByString:@" "];
        NSArray *origin=[position[0]componentsSeparatedByString:@","],*size=[position[1]componentsSeparatedByString:@"x"];
        double x=[origin[0]doubleValue],y=[origin[1]doubleValue],w=[size[0]doubleValue],h=[size[1]doubleValue];
        NSString *acts_=[line substringFromIndex:NSMaxRange(acts)];
        NSMutableDictionary *node=[@{@"role":@(role),@"frame":[NSValue valueWithRect:NSMakeRect(x,y,w,h)],@"children":[NSMutableArray array],
            @"actions":acts_.length?[acts_ componentsSeparatedByString:@","]:@[]}mutableCopy];
        if(strcmp(subrole,"(null)"))node[@"subrole"]=@(subrole);
        [nodes addObject:node];NSInteger index=(NSInteger)nodes.count-1;
        while(stack.count>(NSUInteger)depth)[stack removeLastObject];
        if(depth>0&&stack.count)[nodes[stack.lastObject.integerValue][@"children"]addObject:@(index)];
        [stack addObject:@(index)];
    }
}
static int failures,checks;
static void check(BOOL ok,const char *what,NSString *detail){checks++;if(!ok){failures++;fprintf(stderr,"FAIL: %s %s\n",what,detail.UTF8String);}}
// Runs the classifier on the loaded shape. Returns the reason and sets *title.
static NSString *classify(NSDictionary **title){
    CGRect own=[nodes[0][@"frame"]rectValue];NSString *reason=nil;
    *title=decorationTitle(nodeElement(0),own,7,fakeWindowOf,CACurrentMediaTime()+30,&reason,NULL);
    return reason?:@"(no reason)";
}
// nil: canvas-owned caption at this window-local point; otherwise why not.
static NSString *verdict(NSDictionary *title,double x,double y){return title?decorationRegionVerdict(title,CGPointMake(x,y)):@"no title region";}
static void expectOwned(NSDictionary *title,const char *what,double x,double y){NSString *v=verdict(title,x,y);check(!v,what,[NSString stringWithFormat:@"at %g,%g expected canvas-owned, got %@",x,y,v]);}
static void expectApp(NSDictionary *title,const char *what,double x,double y){NSString *v=verdict(title,x,y);check(v!=nil,what,[NSString stringWithFormat:@"at %g,%g expected the app's, got canvas-owned",x,y]);}
static void expectReason(NSString *reason,NSString *wanted,NSString *what){check([reason isEqual:wanted],what.UTF8String,[NSString stringWithFormat:@"reason %@ expected %@",reason,wanted]);}

int main(void){@autoreleasepool{
    NSDictionary *title;NSString *reason;
    // Chrome 156, three tabs, window 1200x1036 at 22,52 (coordinates below are window-local = absolute - origin).
    loadShape(DWShapeChromeThreeTabs);reason=classify(&title);
    expectReason(reason,@"accepted_browser_caption",@"chrome three tabs");
    expectOwned(title,"chrome: empty strip right of New Tab",1000-22,70-52);
    expectOwned(title,"chrome: strip top edge, right end",1200-4,2);
    expectOwned(title,"chrome: left of the traffic lights",3,3);
    expectOwned(title,"chrome: between the zoom button and the strip",102-22,70-52);
    expectOwned(title,"chrome: below the traffic lights, inside the row",30-22,89-52);
    expectApp(title,"chrome: first tab",250-22,70-52);
    expectApp(title,"chrome: second tab",480-22,70-52);
    expectApp(title,"chrome: a tab's close button",364-22,72-52);
    expectApp(title,"chrome: the New Tab button",876-22,70-52);
    expectApp(title,"chrome: the tab search button",128-22,72-52);
    expectApp(title,"chrome: close light",42-22,72-52);
    expectApp(title,"chrome: minimize light",65-22,72-52);
    expectApp(title,"chrome: full-screen light",88-22,72-52);
    expectApp(title,"chrome: back button",60-22,115-52);
    expectApp(title,"chrome: omnibox",500-22,115-52);
    expectApp(title,"chrome: toolbar, right of the omnibox",1160-22,115-52);
    expectApp(title,"chrome: web content",500-22,300-52);
    expectApp(title,"chrome: outside the window",-5,10);
    // One tab: the empty strip starts right of New Tab; the gap between the tab group and the button is the button's.
    loadShape(DWShapeChromeSoloTab);reason=classify(&title);
    expectReason(reason,@"accepted_browser_caption",@"chrome solo tab");
    expectOwned(title,"solo: empty strip",600-40,325-300);
    expectOwned(title,"solo: just right of New Tab",438-40,310-300);
    expectApp(title,"solo: the tab",300-40,325-300);
    expectApp(title,"solo: New Tab",418-40,325-300);
    expectApp(title,"solo: omnibox",400-40,364-300);
    // The same window with an infobar between the toolbar and the content (Relaunch button): all below the row.
    loadShape(DWShapeChromeInfobar);reason=classify(&title);
    expectReason(reason,@"accepted_browser_caption",@"chrome infobar");
    expectOwned(title,"infobar: empty strip",800-40,120-100);
    expectApp(title,"infobar: Relaunch button",700-40,215-100);
    expectApp(title,"infobar: its container",100-40,200-100);
    // Mutations of the recorded Chrome tree: every ambiguous shape keeps today's rejection.
    loadShape(DWShapeChromeThreeTabs);NSInteger tabGroup=-1,strip=-1;
    for(NSUInteger i=0;i<nodes.count;i++){if([nodes[i][@"role"]isEqual:@"AXTabGroup"])tabGroup=(NSInteger)i;}
    // strip row group = the 1114x41 group whose parent chain holds the tab group
    for(NSUInteger i=0;i<nodes.count;i++)if([nodes[i][@"role"]isEqual:@"AXGroup"]&&[nodes[i][@"frame"]rectValue].size.width==1114&&[nodes[i][@"frame"]rectValue].size.height==41)strip=(NSInteger)i;
    check(tabGroup>0&&strip>0,"mutation setup",@"tab group or strip row not found in the recorded shape");
    nodes[tabGroup][@"role"]=@"AXGroup";reason=classify(&title);
    expectReason(reason,@"missing_top_toolbar",@"no tab group keeps the old rejection");check(!title,"no tab group: no region",@"title returned");
    loadShape(DWShapeChromeThreeTabs);for(NSUInteger i=0;i<nodes.count;i++)if([nodes[i][@"role"]isEqual:@"AXGroup"]&&[nodes[i][@"frame"]rectValue].size.width==732&&[nodes[i][@"frame"]rectValue].size.height==41&&i>(NSUInteger)tabGroup)nodes[i][@"role"]=@"AXTabGroup";
    reason=classify(&title);expectReason(reason,@"caption_multiple_tab_groups",@"two tab groups");check(!title,"two tab groups: no region",@"title returned");
    loadShape(DWShapeChromeThreeTabs);for(NSUInteger i=0;i<nodes.count;i++)if([nodes[i][@"role"]isEqual:@"AXGroup"]&&[nodes[i][@"frame"]rectValue].size.width==320&&[nodes[i][@"frame"]rectValue].size.height==41)nodes[i][@"role"]=@"AXWebArea";
    reason=classify(&title);expectReason(reason,@"caption_content_or_toolbar_in_row",@"web content reaching into the row");check(!title,"web area in row: no region",@"title returned");
    loadShape(DWShapeChromeThreeTabs);for(NSUInteger i=0;i<nodes.count;i++)if([nodes[i][@"role"]isEqual:@"AXGroup"]&&[nodes[i][@"frame"]rectValue].size.width==320&&[nodes[i][@"frame"]rectValue].size.height==41)nodes[i][@"actions"]=@[@"AXPress"];
    reason=classify(&title);expectReason(reason,@"accepted_browser_caption",@"a leaf group with a press action");
    expectApp(title,"leaf group with AXPress is a control",1000-22,70-52);
    loadShape(DWShapeChromeThreeTabs);[unreadable addObject:@(strip)];reason=classify(&title);
    expectReason(reason,@"caption_geometry_or_owner",@"an unreadable strip element");check(!title,"unreadable: no region",@"title returned");
    loadShape(DWShapeChromeThreeTabs);{CGRect f=[nodes[tabGroup][@"frame"]rectValue];f.origin.y+=20;nodes[tabGroup][@"frame"]=[NSValue valueWithRect:f];}
    reason=classify(&title);expectReason(reason,@"caption_tab_group_not_top_row",@"a tab group that is not the top row");check(!title,"tab group lower: no region",@"title returned");
    // Aside's sign-in window: no tab group, close button outside the window: rejected exactly as before.
    loadShape(DWShapeAsideSignIn);reason=classify(&title);check(!title,"aside sign-in: no region",reason);
    // TextEdit (standard title, document proxy, format bar and text below), window 586x488 at 242,115: unchanged.
    loadShape(DWShapeTextEdit);reason=classify(&title);
    expectReason(reason,@"accepted",@"textedit");
    expectOwned(title,"textedit: title text",116,16);
    expectOwned(title,"textedit: empty title bar",200,16);
    expectApp(title,"textedit: close light",16,16);
    expectApp(title,"textedit: document proxy menu button",155,14);
    expectApp(title,"textedit: format bar",100,50);
    expectApp(title,"textedit: text content",300,200);
    // Finder (unified toolbar with title, grouped items), window 700x500 at 1300,150: unchanged.
    loadShape(DWShapeFinder);reason=classify(&title);
    expectReason(reason,@"accepted_unified_toolbar",@"finder");
    expectOwned(title,"finder: toolbar title",334,26);
    expectOwned(title,"finder: strip above a toolbar group's controls",170,3);
    expectApp(title,"finder: inside that group's control",170,26);
    expectApp(title,"finder: close light",26,26);
    expectApp(title,"finder: search button",1975-1300,176-150);
    expectApp(title,"finder: file list",300,300);
    fprintf(stderr,"%d checks, %d failures\n",checks,failures);
    return failures?1:0;
}}
