// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-tablet.h"
#include <math.h>

static BOOL tabletMouse(CGEventType type) {
    return type==kCGEventMouseMoved||type==kCGEventLeftMouseDown||type==kCGEventLeftMouseUp||type==kCGEventLeftMouseDragged
        ||type==kCGEventRightMouseDown||type==kCGEventRightMouseUp||type==kCGEventRightMouseDragged
        ||type==kCGEventOtherMouseDown||type==kCGEventOtherMouseUp||type==kCGEventOtherMouseDragged;
}
BOOL DWNativeTabletProximityEvent(CGEventRef event) {
    if(!event)return NO;CGEventType type=CGEventGetType(event);
    return type==kCGEventTabletProximity||(tabletMouse(type)&&CGEventGetIntegerValueField(event,kCGMouseEventSubtype)==kCGEventMouseSubtypeTabletProximity);
}
BOOL DWNativeTabletEvent(CGEventRef event) {
    if(!event)return NO;CGEventType type=CGEventGetType(event);
    return type==kCGEventTabletPointer||DWNativeTabletProximityEvent(event)
        ||(tabletMouse(type)&&CGEventGetIntegerValueField(event,kCGMouseEventSubtype)==kCGEventMouseSubtypeTabletPoint);
}
static NSNumber *tabletDevice(CGEventRef event) {
    return @(CGEventGetIntegerValueField(event,DWNativeTabletProximityEvent(event)?kCGTabletProximityEventDeviceID:kCGTabletEventDeviceID));
}
static BOOL tabletDown(CGEventType type) { return type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown; }
static BOOL tabletUp(CGEventType type) { return type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp; }
static BOOL tabletTargetEqual(NSDictionary *a,NSDictionary *b) {
    if(!a||!b)return NO;
    // Geometry is refreshed within the same ownership key. It is deliberately
    // absent here: a resize or camera move must not terminate the same stroke.
    for(NSString *key in @[@"identity",@"generation",@"window",@"output"])
        if(![a[key]isEqual:b[key]])return NO;
    return [(a[@"root_identity"]?:a[@"identity"])isEqual:(b[@"root_identity"]?:b[@"identity"])]
        &&[a[@"native_member"]boolValue]==[b[@"native_member"]boolValue];
}
static BOOL tabletSameTool(CGEventRef a,CGEventRef b) {
    if(!a||!b)return NO;
    for(NSNumber *field in @[@(kCGTabletProximityEventVendorUniqueID),@(kCGTabletProximityEventPointerType),@(kCGTabletProximityEventVendorPointerSerialNumber),@(kCGTabletProximityEventSystemTabletID)])
        if(CGEventGetIntegerValueField(a,field.intValue)!=CGEventGetIntegerValueField(b,field.intValue))return NO;
    return YES;
}

@interface DWNativeTabletTool : NSObject {
@public
    CGEventRef entry,admittedEntry,point;
}
@property NSDictionary *target;
@property CGPoint local;
@property uint32_t mouseButtons;
@property BOOL inProximity,contact,replaced,suppressed;
@end
@implementation DWNativeTabletTool
- (void)dealloc { if(entry)CFRelease(entry);if(admittedEntry)CFRelease(admittedEntry);if(point)CFRelease(point); }
@end

@implementation DWNativeTabletRouter {
    NSMutableDictionary<NSNumber *,DWNativeTabletTool *> *_tools;
    uint64_t _revision;
}
- (instancetype)init { if((self=[super init]))_tools=[NSMutableDictionary dictionary];return self; }
- (void)observeEvent:(CGEventRef)event {
    if(!NSThread.isMainThread||!DWNativeTabletProximityEvent(event))return;
    ++_revision;
    NSNumber *device=tabletDevice(event);DWNativeTabletTool *tool=_tools[device];
    if(!tool){tool=[DWNativeTabletTool new];_tools[device]=tool;}
    BOOL enter=CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity)!=0;
    BOOL wasInProximity=tool.inProximity;
    tool.inProximity=enter;
    if(enter){
        if(!wasInProximity&&tool.target)tool.replaced=YES;
        if(tool->entry&&tool.target&&!tabletSameTool(tool->entry,event))tool.replaced=YES;
        if(tool->entry)CFRelease(tool->entry);tool->entry=CGEventCreateCopy(event);
    }
    // Keep an outgoing recipient until forwardEvent: returns this physical exit
    // to it. A tool with no outgoing recipient needs no pending state.
    else if(!tool.target&&!tool.suppressed)[_tools removeObjectForKey:device];
}
- (BOOL)ownsEvent:(CGEventRef)event {
    if(!NSThread.isMainThread||!DWNativeTabletEvent(event))return NO;
    DWNativeTabletTool *tool=_tools[tabletDevice(event)];if(!tool||tool.replaced)return NO;
    if(DWNativeTabletProximityEvent(event)){
        if(CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity))return tool.contact||tool.suppressed;
        return tool.suppressed||(tool.target&&tabletSameTool(tool->admittedEntry,event));
    }
    return tool.contact||tool.suppressed;
}
- (NSDictionary *)retireReplacedToolForEvent:(CGEventRef)event validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!NSThread.isMainThread||!DWNativeTabletProximityEvent(event)||!CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity))return nil;
    NSNumber *device=tabletDevice(event);DWNativeTabletTool *tool=_tools[device];if(!tool.replaced)return nil;
    uint64_t revision=++_revision;NSDictionary *retired=[tool.target copy];
    [self cancelTool:tool time:CGEventGetTimestamp(event) validate:validate post:post];
    if(revision==_revision&&_tools[device]==tool){
        // The observed enter starts a new physical tool stream. Its payload
        // stays in entry; neither the old contact nor its suppression can
        // authorize posting the new tool's packets to the previous recipient.
        tool.replaced=NO;tool.suppressed=NO;tool.contact=NO;tool.mouseButtons=0;
        if(tool->admittedEntry){CFRelease(tool->admittedEntry);tool->admittedEntry=NULL;}
        if(tool->point){CFRelease(tool->point);tool->point=NULL;}
        return retired;
    }
    // A callback may have admitted a new lifetime with the same source key.
    // Its view gesture must not be cleared by this stale retirement result.
    return nil;
}
- (NSDictionary *)capturedTargetForEvent:(CGEventRef)event {
    if(![self ownsEvent:event])return nil;
    DWNativeTabletTool *tool=_tools[tabletDevice(event)];return [tool.target copy];
}
- (BOOL)postCopy:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!event||!target||!validate||!post||!isfinite(local.x)||!isfinite(local.y))return NO;
    uint64_t revision=_revision;
    if(!validate(target)||revision!=_revision)return NO;
    CGEventRef copy=CGEventCreateCopy(event);if(!copy)return NO;
    BOOL sent=post(copy,target,local);CFRelease(copy);return sent;
}
- (BOOL)proximity:(BOOL)enter tool:(DWNativeTabletTool *)tool time:(CGEventTimestamp)time validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!tool->admittedEntry||!tool.target)return NO;
    // An enter replay is a proximity packet, never a second mouse press when a
    // driver supplied proximity as a subtype of a physical mouse event.
    CGEventRef event=CGEventCreateCopy(tool->admittedEntry);if(!event)return NO;
    CGEventSetType(event,kCGEventTabletProximity);CGEventSetTimestamp(event,time);
    CGEventSetIntegerValueField(event,kCGTabletProximityEventEnterProximity,enter);
    BOOL sent=[self postCopy:event target:tool.target local:tool.local validate:validate post:post];CFRelease(event);return sent;
}
- (BOOL)forwardEvent:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!NSThread.isMainThread||!DWNativeTabletEvent(event)||!validate||!post)return NO;
    uint64_t revision=++_revision;
    NSNumber *device=tabletDevice(event);DWNativeTabletTool *tool=_tools[device];CGEventType type=CGEventGetType(event);
    BOOL proximity=DWNativeTabletProximityEvent(event),enter=proximity&&CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity)!=0;
    if(tool.replaced){
        [self cancelTool:tool time:CGEventGetTimestamp(event) validate:validate post:post];if(revision!=_revision)return NO;
        // This is a new physical tool, so its own enter begins a fresh stream.
        tool.replaced=NO;tool.suppressed=NO;tool.contact=NO;tool.mouseButtons=0;
    }
    if(proximity&&!enter){
        DWNativeTabletTool *outgoing=[self detachTool:tool];[_tools removeObjectForKey:device];
        // An unexpected physical tool-out still closes every admitted mouse
        // button. The physical packet itself is copied intact afterwards.
        NSInteger release=tabletUp(type)?CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber):-1;
        [self releaseContact:outgoing time:CGEventGetTimestamp(event) exceptButton:release validate:validate post:post];
        if(revision!=_revision)return NO;
        return outgoing.target&&[self postCopy:event target:outgoing.target local:outgoing.local validate:validate post:post];
    }
    // A point alone cannot tell us whether this tool is a pen or eraser. Wait for
    // an observed physical enter instead of fabricating identity/capabilities.
    if(!tool||!tool.inProximity||!tool->entry)return NO;
    BOOL same=tabletTargetEqual(tool.target,target);
    uint32_t buttons=tool.mouseButtons;NSInteger button=CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
    if(button>=0&&button<32){if(tabletDown(type))buttons|=1u<<(uint32_t)button;else if(tabletUp(type))buttons&=~(1u<<(uint32_t)button);}
    double pressure=proximity?0:CGEventGetDoubleValueField(event,kCGTabletEventPointPressure);
    uint32_t tabletButtons=proximity?0:(uint32_t)CGEventGetIntegerValueField(event,kCGTabletEventPointButtons);
    BOOL contact=buttons||tabletButtons||(isfinite(pressure)&&pressure>0);
    if(tool.suppressed){tool.mouseButtons=buttons;tool.contact=contact;tool.suppressed=contact;return NO;}
    if(tool.target){
        BOOL valid=validate(tool.target);if(revision!=_revision)return NO;
        if(!valid){
            BOOL captured=tool.contact;tool.target=nil;tool.mouseButtons=buttons;tool.contact=contact;tool.suppressed=captured&&contact;
            // A dead generation's held stroke may finish, but cannot start a new
            // stroke in another source before the physical release arrives.
            if(captured)return NO;
        }
    }
    if(tool.contact&&!same){
        // A contact admitted in one replica cannot begin a stroke in another.
        // Its physical zero-pressure/release returns to the existing recipient
        // at the last admitted application point; new hover can retarget later.
        BOOL matchingUp=tabletUp(type)&&button>=0&&button<32&&(tool.mouseButtons&(1u<<(uint32_t)button));
        // Additional buttons belong to the already captured tool as well. They
        // need their complete down/up pair even after it crossed a member edge.
        BOOL additionalDown=tabletDown(type)&&button>=0&&button<32;
        if(contact&&!matchingUp&&!additionalDown)return NO;
        BOOL sent=[self postCopy:event target:tool.target local:tool.local validate:validate post:post];
        if(revision!=_revision)return sent;
        if(sent){
            tool.contact=contact;tool.mouseButtons=buttons;
            if(tool->point)CFRelease(tool->point);tool->point=CGEventCreateCopy(event);
            if(!contact){[self proximity:NO tool:tool time:CGEventGetTimestamp(event) validate:validate post:post];if(revision==_revision)tool.target=nil;}
        }
        return sent;
    }
    // A fresh target must never receive the up-half of another app's press.
    if(tabletUp(type)&&(button<0||button>=32||!(tool.mouseButtons&(1u<<(uint32_t)button))))return NO;
    if(![target[@"identity"]isKindOfClass:NSDictionary.class]||![target[@"generation"]isKindOfClass:NSNumber.class]
        ||![target[@"window"]isKindOfClass:NSNumber.class]||![target[@"output"]isKindOfClass:NSNumber.class]
        ||!isfinite(local.x)||!isfinite(local.y))return NO;
    if(!validate(target)||revision!=_revision)return NO;
    if(!same){
        if(tool.target){BOOL closed=[self proximity:NO tool:tool time:CGEventGetTimestamp(event) validate:validate post:post];if(revision!=_revision||!closed)return NO;}
        tool.target=[target copy];tool.local=local;
        if(tool->admittedEntry)CFRelease(tool->admittedEntry);tool->admittedEntry=CGEventCreateCopy(tool->entry);
        if(!proximity){BOOL opened=[self proximity:YES tool:tool time:CGEventGetTimestamp(event) validate:validate post:post];if(revision!=_revision)return NO;if(!opened){tool.target=nil;return NO;}}
    }else{
        tool.target=[target copy];tool.local=local;
        if(proximity){if(tool->admittedEntry)CFRelease(tool->admittedEntry);tool->admittedEntry=CGEventCreateCopy(tool->entry);}
    }
    BOOL sent=[self postCopy:event target:tool.target local:local validate:validate post:post];
    if(revision!=_revision)return sent;
    if(sent&&(!proximity||tabletDown(type)||tabletUp(type))){
        tool.mouseButtons=buttons;tool.contact=contact;
        if(tool->point)CFRelease(tool->point);tool->point=CGEventCreateCopy(event);
    }
    return sent;
}
- (DWNativeTabletTool *)detachTool:(DWNativeTabletTool *)tool {
    if(!tool)return nil;
    DWNativeTabletTool *outgoing=[DWNativeTabletTool new];outgoing.target=tool.target;outgoing.local=tool.local;
    outgoing.mouseButtons=tool.mouseButtons;outgoing.contact=tool.contact;
    if(tool->admittedEntry)outgoing->admittedEntry=CGEventCreateCopy(tool->admittedEntry);
    if(tool->point)outgoing->point=CGEventCreateCopy(tool->point);
    // Detach before calling user blocks: reentrant cancellation cannot release
    // this same recipient twice or resurrect it after a reset.
    tool.target=nil;tool.contact=NO;tool.mouseButtons=0;tool.suppressed=NO;
    return outgoing;
}
- (void)releaseContact:(DWNativeTabletTool *)tool time:(CGEventTimestamp)time exceptButton:(NSInteger)except validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!tool||!tool.target||!tool->point)return;
    uint64_t revision=_revision;
    for(uint32_t button=0;button<32;++button){
        if(!(tool.mouseButtons&(1u<<button))||(NSInteger)button==except)continue;
        CGEventRef event=CGEventCreateCopy(tool->point);if(!event)continue;
        CGEventSetType(event,button==kCGMouseButtonLeft?kCGEventLeftMouseUp:button==kCGMouseButtonRight?kCGEventRightMouseUp:kCGEventOtherMouseUp);
        CGEventSetTimestamp(event,time);CGEventSetIntegerValueField(event,kCGMouseEventButtonNumber,button);
        if(DWNativeTabletProximityEvent(event))CGEventSetIntegerValueField(event,kCGTabletProximityEventEnterProximity,0);
        else{
            // Point fields do not apply to a proximity subtype: writing them
            // there could overwrite the driver's tool identification payload.
            // The SDK also requires establishing a mouse's tablet subtype
            // before setting the associated tablet point parameters.
            CGEventSetIntegerValueField(event,kCGMouseEventSubtype,kCGEventMouseSubtypeTabletPoint);
            CGEventSetIntegerValueField(event,kCGTabletEventPointButtons,0);CGEventSetDoubleValueField(event,kCGTabletEventPointPressure,0);
            CGEventSetDoubleValueField(event,kCGTabletEventTangentialPressure,0);
        }
        CGEventSetDoubleValueField(event,kCGMouseEventPressure,0);
        [self postCopy:event target:tool.target local:tool.local validate:validate post:post];CFRelease(event);
        if(revision!=_revision)return;
    }
    if(tool.contact&&!DWNativeTabletProximityEvent(tool->point)){
        CGEventRef event=CGEventCreateCopy(tool->point);if(!event)return;
        CGEventSetType(event,kCGEventTabletPointer);CGEventSetTimestamp(event,time);
        CGEventSetIntegerValueField(event,kCGTabletEventPointButtons,0);CGEventSetDoubleValueField(event,kCGTabletEventPointPressure,0);
        CGEventSetDoubleValueField(event,kCGMouseEventPressure,0);CGEventSetDoubleValueField(event,kCGTabletEventTangentialPressure,0);
        [self postCopy:event target:tool.target local:tool.local validate:validate post:post];CFRelease(event);
    }
}
- (void)cancelTool:(DWNativeTabletTool *)tool time:(CGEventTimestamp)time validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    uint64_t revision=_revision;DWNativeTabletTool *outgoing=[self detachTool:tool];
    // A synthetic cancellation releases the app, not the physical pen. Its held
    // tail remains ours until a real release and cannot enter another source.
    if(outgoing.contact){tool.suppressed=YES;tool.contact=YES;tool.mouseButtons=outgoing.mouseButtons;}
    [self releaseContact:outgoing time:time exceptButton:-1 validate:validate post:post];
    if(revision==_revision&&outgoing.target)[self proximity:NO tool:outgoing time:time validate:validate post:post];
}
- (void)cancelWithValidate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!NSThread.isMainThread)return;
    [self cancelTargetsMatching:^BOOL(NSDictionary *target){(void)target;return YES;} validate:validate post:post];
    [self reset];
}
- (void)cancelTargetsMatching:(BOOL (^)(NSDictionary *))matching validate:(DWNativeTabletValidate)validate post:(DWNativeTabletPost)post {
    if(!NSThread.isMainThread||!matching)return;
    uint64_t revision=++_revision;
    CGEventTimestamp time=(CGEventTimestamp)(NSProcessInfo.processInfo.systemUptime*1.e9);
    for(NSNumber *device in _tools.allKeys){
        DWNativeTabletTool *tool=_tools[device];if(!tool.target)continue;
        BOOL matched=matching(tool.target);if(revision!=_revision)return;
        if(matched)[self cancelTool:tool time:time validate:validate post:post];
        if(revision!=_revision)return;
    }
}
- (void)reset { if(!NSThread.isMainThread)return;++_revision;[_tools removeAllObjects]; }
@end
