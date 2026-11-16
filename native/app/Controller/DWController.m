// SPDX-License-Identifier: GPL-3.0-or-later
// Transport moved from Desktop -call:raw:; command schema stays private here.
#import "DWController+Private.h"
#import "DWController+External.h"
#import "DWScene+Private.h"
#import "DWFocusEffect.h"
#import "DWSizeEffect.h"
#import "DWSourceBinding.h"
#import "DWSnapshotMirror.h"
#import "DWTypedValue.h"
#import "DWDebugTrace.h"
#import "DWSceneWriter.h"
#include <stdio.h>
#include <string.h>

static NSDictionary *P(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static NSDictionary *R(CGRect r) { return @{@"x":@(r.origin.x),@"y":@(r.origin.y),@"width":@(r.size.width),@"height":@(r.size.height)}; }
static NSDictionary *B(CGSize b) { return @{@"width":@(b.width),@"height":@(b.height)}; }
static NSDictionary *M(DWModifiers m) { return @{@"control":@(m.control),@"option":@(m.option),@"shift":@(m.shift),@"command":@(m.command)}; }
static NSDictionary *I(DWIdentity *identity) { return identity.rawDictionary; }
static NSArray *asArray(id value) { return DWTyped(value,NSArray.class); }

@implementation DWAttachRequest
- (instancetype)init { if((self=[super init])){_bundleID=@"";_title=@"Untitled";}return self; }
@end
@implementation DWPresentWindow
+ (instancetype)windowWithBundleID:(NSString *)bundleID title:(NSString *)title {
    DWPresentWindow *window=[self new];window.bundleID=bundleID;window.title=title;return window;
}
@end

@interface DWResizeValidityFacts ()
@property(nonatomic,strong) DWResizeTransaction *transaction;
@property(nonatomic,strong) DWSource *source;
@property(nonatomic,strong) DWOutput *output;
@end
@implementation DWResizeValidityFacts
@end

@implementation DWController
- (instancetype)init { if((self=[super init])){_handle=driftwm_desktop_create();_snapshotMirror=[DWSnapshotMirror new];}return self; }
- (void)dealloc { driftwm_desktop_destroy(_handle); }
- (void)fail:(NSString *)reason { if(self.failed)self.failed(reason); }
- (void)setSnapshotDictionary:(NSDictionary *)dictionary {
    if(dictionary==_snapshotDictionary)return;
    if(_visualDictionary==_snapshotDictionary)_visualValue=_snapshotValue;
    _snapshotDictionary=dictionary;_snapshotValue=nil;
}
- (void)setVisualDictionary:(NSDictionary *)dictionary {
    if(dictionary==_visualDictionary)return;
    _visualDictionary=dictionary;_visualValue=dictionary==_snapshotDictionary?_snapshotValue:nil;
}
- (DWScene *)cachedScene {
    if(!_snapshotValue&&_snapshotDictionary)_snapshotValue=[DWScene sceneWithDictionary:_snapshotDictionary];
    return _snapshotValue;
}
- (DWScene *)visualScene {
    if(!_visualValue&&_visualDictionary)_visualValue=_visualDictionary==_snapshotDictionary?self.cachedScene:[DWScene sceneWithDictionary:_visualDictionary];
    return _visualValue;
}
- (DWScene *)scene {
    if(![self executeDictionary:@{@"op":@"snapshot"} query:YES rawResponse:NULL])return nil;
    return self.cachedScene;
}
- (DWControllerReply *)query:(NSDictionary *)command {
    NSDictionary *value=[self executeDictionary:command query:YES rawResponse:NULL];
    return value?[DWControllerReply replyWithDictionary:value]:nil;
}
- (DWControllerReply *)mutate:(NSDictionary *)command {
    NSDictionary *value=[self executeDictionary:command query:NO rawResponse:NULL];
    return value?[DWControllerReply replyWithDictionary:value]:nil;
}
// This classification exists only for external compatibility and the temporary
// migration shim. Every semantic method below chooses query/mutation directly.
- (NSDictionary *)legacyCommand:(NSDictionary *)command raw:(NSData *__autoreleasing *)raw {
    NSString *op=DWTyped(command[@"op"],NSString.class);
    BOOL query=(command.count==1&&[op isEqual:@"snapshot"])||[op isEqual:@"hit"]||[op isEqual:@"input"]||[op isEqual:@"resize_border"]||[op isEqual:@"gesture_fingers"]||[op isEqual:@"focus_policy"];
    return [self executeDictionary:command query:query rawResponse:raw];
}
- (DWControllerReply *)executeExternalCommand:(NSDictionary *)command rawResponse:(NSData *__autoreleasing *)raw {
    NSDictionary *value=[self legacyCommand:command raw:raw];
    return value?[DWControllerReply replyWithDictionary:value]:nil;
}
- (DWControllerReply *)navigationCommandDictionary:(NSDictionary *)command {
    NSDictionary *value=[self legacyCommand:command raw:NULL];
    DWControllerReply *reply=value?[DWControllerReply replyWithDictionary:value]:nil;
    return self.navigationPostprocess?self.navigationPostprocess(reply):reply;
}
- (DWControllerReply *)policyFactDictionary:(NSDictionary *)fact timestamp:(uint64_t)timestamp filter:(BOOL)filter focusAllowed:(BOOL)focusAllowed {
    return [self navigationCommandDictionary:@{@"op":@"focus_policy",@"timestamp_ns":@(timestamp),@"filter":@(filter),@"focus_allowed":@(focusAllowed),@"fact":fact}];
}

- (NSDictionary *)executeDictionary:(NSDictionary *)command query:(BOOL)query rawResponse:(NSData *__autoreleasing *)raw {
    BOOL snapshot=command.count==1&&[command[@"op"]isEqual:@"snapshot"];
    if(snapshot&&!raw&&self.snapshotDictionary)return self.snapshotDictionary;
    NSString *operation=DWTyped(command[@"op"],NSString.class);
    BOOL tick=[operation isEqual:@"tick_navigation"];
    DWScene *visualValue=tick?(_visualValue?:(_visualDictionary==_snapshotDictionary?_snapshotValue:nil)):nil;
    NSDictionary *before=tick?self.snapshotDictionary:nil,*visual=tick?self.visualDictionary:nil;
    if(!query){self.snapshotDictionary=nil;self.visualDictionary=nil;}
    // A new scene replaces what the baseline described; the delta is correct without this, so it only saves a patch that cannot be small.
    if([operation isEqual:@"load"])[self.snapshotMirror reset];
    // An internal snapshot is rebuilt from the sections that changed since the last one (a camera frame changes few). One a caller
    // asked the raw bytes of (public/IPC) takes the request below, unchanged.
    if(snapshot&&!raw){
        NSString *failure=nil;NSDictionary *result=[self.snapshotMirror snapshotFrom:self.handle error:&failure];if(!result){[self fail:failure];return nil;}
        self.snapshotDictionary=result;if(!self.visualDictionary)self.visualDictionary=result;return result;
    }
    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *response=driftwm_desktop_request(self.handle,request.bytes,request.length);if(!response){[self fail:@"Controller unavailable"];return nil;}
    NSData *data=[NSData dataWithBytes:response length:strlen(response)];driftwm_desktop_response_free(response);if(raw)*raw=data;
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![reply[@"ok"]boolValue]){[self fail:reply[@"error"]?:@"Controller error"];return nil;}
    NSDictionary *result=DWTyped(reply[@"data"],NSDictionary.class); // every controller reply is an object; a null or other JSON value is no reply
    if(DWDebugTrace()){
        NSMutableArray *effects=[asArray(result[@"effects"])mutableCopy]?:[NSMutableArray array];
        if(DWTyped(result[@"effect"],NSDictionary.class))[effects addObject:result[@"effect"]];
        for(NSDictionary *effect in effects)if([effect[@"op"]isEqual:@"observe_resize_source"]||[effect[@"op"]isEqual:@"resize_native_window"]){
            id ipc=command[@"request"];NSString *variant=DWTyped(ipc,NSString.class)?:((NSDictionary *)DWTyped(ipc,NSDictionary.class)).allKeys.firstObject?:@"none";
            NSString *action=DWTyped(command[@"action"],NSString.class)?:DWTyped(DWTyped(ipc,NSDictionary.class)[@"Action"],NSString.class);
            if(![@[@"toggle-fullscreen",@"fullscreen",@"fill",@"restore",@"center",@"fit"]containsObject:action?:@""])action=@"other";
            fprintf(stderr,"debug: native resize origin operation=%s ipc=%s action=%s transaction=%llu effect=%llu window=%llu\n",operation.UTF8String,variant.UTF8String,action.UTF8String,[effect[@"transaction"]unsignedLongLongValue],[effect[@"effect_id"]unsignedLongLongValue],[effect[@"window"]unsignedLongLongValue]);
        }
    }
    // set-trackpad switches every gesture off or on: the finger counts the system's own gestures are held back for follow it. A key, a gesture, a corner or `msg action` may run it.
    if(self.refreshGestureFingers&&!query){NSString *ran=DWTyped(command[@"action"],NSString.class)?:DWTyped(DWTyped(command[@"request"],NSDictionary.class)[@"Action"],NSString.class)?:DWTyped(DWTyped(result[@"fired"],NSDictionary.class)[@"action"],NSString.class);if([ran hasPrefix:@"set-trackpad"])self.refreshGestureFingers();}
    if(snapshot){self.snapshotDictionary=result;if(!self.visualDictionary)self.visualDictionary=result;}
    else if(tick&&[result[@"clock_only"]isEqual:@YES]){
        // This successful tick changed only clock_ns. Never mutate a retained
        // dictionary: ordinary Snapshot readers see the current clock, while
        // rendering/capture keep the same proven-unchanged geometry projection.
        if(before){NSMutableDictionary *next=[before mutableCopy],*navigation=[DWTyped(before[@"navigation"],NSDictionary.class)mutableCopy];navigation[@"clock_ns"]=command[@"timestamp_ns"];next[@"navigation"]=navigation.copy;self.snapshotDictionary=next.copy;}
        self.visualDictionary=visual;_visualValue=visualValue;
    }
    return result;
}

- (DWControllerReply *)hitOnOutput:(NSNumber *)output screen:(CGPoint)screen {
    NSDictionary *command=@{@"op":@"hit" ,@"output":output,@"screen":P(screen)};
    return [self query:command];
}

- (DWControllerReply *)inputOnOutput:(NSNumber *)output screen:(CGPoint)screen identity:(DWIdentity *)identity {
    NSDictionary *command=@{@"op":@"input" ,@"output":output,@"screen":P(screen),@"identity":I(identity)};
    return [self query:command];
}

- (DWControllerReply *)resizeBorderOnOutput:(NSNumber *)output screen:(CGPoint)screen {
    NSDictionary *command=@{@"op":@"resize_border" ,@"output":output,@"screen":P(screen)};
    return [self query:command];
}

- (DWControllerReply *)gestureFingers {
    NSDictionary *command=@{@"op":@"gesture_fingers"};
    return [self query:command];
}

- (DWControllerReply *)bindings {
    NSDictionary *command=@{@"op":@"bindings"};
    return [self mutate:command];
}

- (DWControllerReply *)mouseBinding:(NSString *)trigger source:(NSString *)source modifiers:(DWModifiers)modifiers windowContext:(BOOL)windowContext window:(NSNumber *)window pick:(BOOL)pick {
    NSMutableDictionary *command=[@{@"op":@"mouse_binding" ,@"trigger":trigger,@"source":source?:NSNull.null,@"modifiers":M(modifiers),@"context":windowContext?@"window":@"canvas",@"pick":@(pick)}mutableCopy];
    if(window)command[@"window"]=window;
    return [self mutate:command];
}

- (DWControllerReply *)hoverOnOutput:(NSNumber *)output screen:(CGPoint)screen time:(NSNumber *)time {
    NSMutableDictionary *command=[@{@"op":@"hover" ,@"output":output,@"screen":P(screen)}mutableCopy];
    if(time)command[@"time_ms"]=time;
    return [self mutate:command];
}

- (DWControllerReply *)hoverWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation output:(NSNumber *)output screen:(CGPoint)screen time:(NSNumber *)time forwardMotion:(BOOL)forward {
    NSMutableDictionary *command=[@{@"op":@"hover_source" ,@"window":window,@"identity":I(identity),@"generation":generation,@"output":output,@"screen":P(screen),@"forward_motion":@(forward)}mutableCopy];
    if(time)command[@"time_ms"]=time;
    return [self mutate:command];
}

- (DWControllerReply *)pointerOnOutput:(NSNumber *)output screen:(CGPoint)screen {
    NSDictionary *command=@{@"op":@"pointer" ,@"output":output?:NSNull.null,@"screen":P(screen)};
    return [self mutate:command];
}

- (DWControllerReply *)pickWindow:(NSNumber *)window output:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"pick" ,@"window":window,@"output":output};
    return [self mutate:command];
}

- (DWControllerReply *)pointerNearestOnOutput:(NSNumber *)output screen:(CGPoint)screen start:(CGPoint)start held:(BOOL)held focus:(BOOL)focus {
    NSDictionary *command=@{@"op":@"pointer_nearest" ,@"output":output,@"screen":P(screen),@"start":P(start),@"held":@(held),@"focus":@(focus)};
    return [self mutate:command];
}

- (DWControllerReply *)beginDragWindow:(NSNumber *)window output:(NSNumber *)output group:(BOOL)group {
    NSDictionary *command=@{@"op":@"begin_drag" ,@"window":window,@"output":output,@"group":@(group)};
    return [self mutate:command];
}

- (DWControllerReply *)beginResizeWindow:(NSNumber *)window output:(NSNumber *)output edges:(DWControllerResizeEdges)edges group:(BOOL)group {
    NSDictionary *command=@{@"op":@"begin_resize" ,@"window":window,@"output":output,@"edges":edges,@"group":@(group)};
    return [self mutate:command];
}

- (DWControllerReply *)gestureTo:(CGPoint)delta pointer:(NSValue *)pointer {
    NSMutableDictionary *command=[@{@"op":@"gesture_to" ,@"screen_delta":P(delta)}mutableCopy];
    if(pointer?P(pointer.pointValue):nil)command[@"pointer"]=pointer?P(pointer.pointValue):nil;
    return [self mutate:command];
}

- (DWControllerReply *)endGesture {
    NSDictionary *command=@{@"op":@"end_gesture"};
    return [self mutate:command];
}

- (DWControllerReply *)beginGesture:(DWControllerGestureKind)kind fingers:(NSUInteger)fingers modifiers:(DWModifiers)modifiers windowContext:(BOOL)windowContext output:(NSNumber *)output pointer:(CGPoint)pointer doubleTap:(BOOL)doubleTap time:(double)time {
    NSDictionary *command=@{@"op":@"gesture_begin" ,@"kind":kind,@"fingers":@(fingers),@"modifiers":M(modifiers),@"context":windowContext?@"window":@"canvas",@"output":output,@"pointer":P(pointer),@"doubletap":@(doubleTap),@"time_ms":@(time)};
    return [self mutate:command];
}

- (DWControllerReply *)updateGestureWithDelta:(CGPoint)delta scale:(double)scale rotation:(double)rotation time:(double)time held:(BOOL)held {
    NSDictionary *command=@{@"op":@"gesture_update" ,@"dx":@(delta.x),@"dy":@(delta.y),@"scale":@(scale),@"rotation":@(rotation),@"time_ms":@(time),@"held":@(held)};
    return [self mutate:command];
}

- (DWControllerReply *)endGestureCancelled:(BOOL)cancelled time:(double)time held:(BOOL)held {
    NSDictionary *command=@{@"op":@"gesture_end" ,@"cancelled":@(cancelled),@"time_ms":@(time),@"held":@(held)};
    return [self mutate:command];
}

- (DWControllerReply *)focusWindow:(NSNumber *)window {
    NSDictionary *command=@{@"op":@"focus" ,@"window":window};
    return [self mutate:command];
}

- (DWControllerReply *)activateWindow:(NSNumber *)window output:(NSNumber *)output cause:(DWActivationCause)cause identity:(DWIdentity *)identity generation:(NSNumber *)generation {
    NSMutableDictionary *command=[@{@"op":@"activate" ,@"window":window,@"output":output?:NSNull.null,@"cause":cause}mutableCopy];
    if(identity?I(identity):nil)command[@"identity"]=identity?I(identity):nil;if(generation)command[@"generation"]=generation;
    return [self mutate:command];
}

- (DWControllerReply *)clearFocus {
    NSDictionary *command=@{@"op":@"clear_focus"};
    return [self mutate:command];
}

- (DWControllerReply *)focusLost {
    NSDictionary *command=@{@"op":@"focus_lost"};
    return [self mutate:command];
}

- (DWControllerReply *)focusResult:(DWFocusEffect *)effect success:(BOOL)success {
    NSDictionary *command=@{@"op":@"focus_result" ,@"effect_id":effect.effectID,@"window":effect.window,@"identity":I(effect.identity),@"generation":effect.generation,@"success":@(success)};
    return [self mutate:command];
}

- (DWControllerReply *)focusLogical:(DWFocusEffect *)effect {
    NSDictionary *command=@{@"op":@"focus_logical" ,@"effect_id":effect.effectID,@"window":effect.window,@"identity":I(effect.identity),@"generation":effect.generation};
    return [self mutate:command];
}

- (DWControllerReply *)observeFocusWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation {
    NSDictionary *command=@{@"op":@"observe_focus" ,@"window":window,@"identity":I(identity),@"generation":generation};
    return [self mutate:command];
}

- (DWControllerReply *)endFocusCycle {
    NSDictionary *command=@{@"op":@"end_focus_cycle"};
    return [self mutate:command];
}

- (DWControllerReply *)cancelFocusCycle {
    NSDictionary *command=@{@"op":@"cancel_focus_cycle"};
    return [self mutate:command];
}

- (DWControllerReply *)cycleFocusBackward:(BOOL)backward held:(BOOL)held {
    NSDictionary *command=@{@"op":@"cycle_focus" ,@"backward":@(backward),@"held":@(held)};
    return [self mutate:command];
}

- (DWControllerReply *)cancelNavigationOnOutput:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"cancel_navigation" ,@"output":output};
    return [self mutate:command];
}

- (DWControllerReply *)panOnOutput:(NSNumber *)output delta:(CGPoint)delta time:(NSNumber *)time source:(NSString *)source {
    NSMutableDictionary *command=[@{@"op":@"pan" ,@"output":output,@"screen_delta":P(delta)}mutableCopy];
    if(time)command[@"time_ms"]=time;if(source)command[@"source"]=source;
    return [self mutate:command];
}

- (DWControllerReply *)endPanOnOutput:(NSNumber *)output time:(NSNumber *)time {
    NSMutableDictionary *command=[@{@"op":@"pan_end" ,@"output":output}mutableCopy];
    if(time)command[@"time_ms"]=time;
    return [self mutate:command];
}

- (DWControllerReply *)zoomOnOutput:(NSNumber *)output anchor:(CGPoint)anchor delta:(double)delta source:(NSString *)source phase:(NSString *)phase {
    NSMutableDictionary *command=[@{@"op":@"zoom_by" ,@"output":output,@"anchor":P(anchor),@"delta":@(delta),@"source":source}mutableCopy];
    if(phase)command[@"phase"]=phase;
    return [self mutate:command];
}

- (DWControllerReply *)navigateWindow:(NSNumber *)window output:(NSNumber *)output zoomPolicy:(DWControllerZoomPolicy)policy {
    NSDictionary *command=@{@"op":@"navigate_window" ,@"window":window,@"output":output,@"zoom_policy":policy};
    return [self mutate:command];
}

- (DWControllerReply *)cycleNavigateOnOutput:(NSNumber *)output backward:(BOOL)backward held:(BOOL)held {
    NSDictionary *command=@{@"op":@"cycle_navigate" ,@"output":output,@"backward":@(backward),@"held":@(held)};
    return [self mutate:command];
}

- (DWControllerReply *)beginNativeResizeWindow:(NSNumber *)window output:(NSNumber *)output edges:(DWControllerResizeEdges)edges start:(CGPoint)start group:(BOOL)group {
    NSMutableDictionary *command=[@{@"op":@"begin_native_resize" ,@"window":window,@"output":output,@"start_screen":P(start),@"group":@(group)}mutableCopy];
    if(edges)command[@"edges"]=edges;
    return [self mutate:command];
}

- (DWControllerReply *)nativeResizeTo:(CGPoint)screen transaction:(NSNumber *)transaction {
    NSDictionary *command=@{@"op":@"native_resize_to" ,@"transaction":transaction,@"screen":P(screen)};
    return [self mutate:command];
}

- (DWControllerReply *)endNativeResize:(NSNumber *)transaction {
    NSDictionary *command=@{@"op":@"end_native_resize" ,@"transaction":transaction};
    return [self mutate:command];
}

- (DWControllerReply *)cancelNativeResize:(NSNumber *)transaction {
    NSDictionary *command=@{@"op":@"cancel_native_resize" ,@"transaction":transaction};
    return [self mutate:command];
}

- (DWControllerReply *)nativeResizeResult:(DWNativeResult *)result effect:(DWSizeEffect *)effect {
    NSDictionary *command=@{@"op":@"native_resize_result" ,@"transaction":effect.transaction,@"effect_id":effect.effectID,@"identity":I(effect.identity),@"generation":effect.generation,@"result":result.rawDictionary};
    return [self mutate:command];
}

- (DWControllerReply *)setNativeResizeCapability:(BOOL)enabled {
    NSDictionary *command=@{@"op":@"native_resize_capability" ,@"enabled":@(enabled)};
    return [self mutate:command];
}

- (DWControllerReply *)nativeDecoration:(NSString *)action window:(NSNumber *)window output:(NSNumber *)output identity:(DWIdentity *)identity generation:(NSNumber *)generation {
    NSDictionary *command=@{@"op":@"native_decoration" ,@"action":action,@"window":window,@"output":output,@"identity":I(identity),@"generation":generation};
    return [self mutate:command];
}

- (DWControllerReply *)retitleWindow:(NSNumber *)window identity:(DWIdentity *)identity title:(NSString *)title {
    NSDictionary *command=@{@"op":@"retitle" ,@"window":window,@"identity":I(identity),@"title":title};
    return [self mutate:command];
}

- (DWControllerReply *)windowClosed:(NSNumber *)window identity:(DWIdentity *)identity output:(NSNumber *)output {
    NSMutableDictionary *command=[@{@"op":@"window_closed" ,@"window":window,@"identity":I(identity)}mutableCopy];
    if(output)command[@"output"]=output;
    return [self mutate:command];
}

- (DWControllerReply *)removeSourceWindow:(NSNumber *)window identity:(DWIdentity *)identity keepPlaceholder:(BOOL)keep {
    NSDictionary *command=@{@"op":@"remove_source" ,@"window":window,@"identity":I(identity),@"keep_placeholder":@(keep)};
    return [self mutate:command];
}

- (DWControllerReply *)forgetWindow:(NSNumber *)window {
    NSDictionary *command=@{@"op":@"forget" ,@"window":window};
    return [self mutate:command];
}

- (DWControllerReply *)observeWindow:(NSNumber *)window identity:(DWIdentity *)identity rect:(CGRect)rect buffer:(CGSize)buffer {
    NSDictionary *command=@{@"op":@"observe" ,@"window":window,@"identity":I(identity),@"source_rect":R(rect),@"buffer":B(buffer)};
    return [self mutate:command];
}

- (DWControllerReply *)observePresentationWindow:(NSNumber *)window identity:(DWIdentity *)identity rect:(CGRect)rect buffer:(CGSize)buffer {
    NSDictionary *command=@{@"op":@"observe_presentation" ,@"window":window,@"identity":I(identity),@"source_rect":R(rect),@"buffer":B(buffer)};
    return [self mutate:command];
}

- (DWControllerReply *)sourceVisibilityPendingWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation {
    NSDictionary *command=@{@"op":@"source_visibility_pending" ,@"window":window,@"identity":I(identity),@"generation":generation};
    return [self mutate:command];
}

- (DWControllerReply *)observeVisibilityWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation minimized:(BOOL)minimized {
    NSDictionary *command=@{@"op":@"observe_visibility" ,@"window":window,@"identity":I(identity),@"generation":generation,@"minimized":@(minimized)};
    return [self mutate:command];
}

- (DWControllerReply *)sourceVisibleWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation revision:(NSNumber *)revision {
    NSDictionary *command=@{@"op":@"source_visible" ,@"window":window,@"identity":I(identity),@"generation":generation,@"visibility_revision":revision};
    return [self mutate:command];
}

- (DWControllerReply *)relocateSourceWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation observedRect:(CGRect)observed expectedWorldRect:(CGRect)expected delta:(CGPoint)delta {
    NSDictionary *command=@{@"op":@"relocate_source" ,@"window":window,@"identity":I(identity),@"generation":generation,@"observed_rect":R(observed),@"expected_world_rect":R(expected),@"delta":P(delta)};
    return [self mutate:command];
}

- (DWControllerReply *)registerOutput:(NSString *)stableID screenBounds:(CGRect)bounds usableRect:(NSValue *)usable {
    NSMutableDictionary *command=[@{@"op":@"register_output" ,@"stable_id":stableID,@"screen_bounds":R(bounds)}mutableCopy];
    if(usable?R(usable.rectValue):nil)command[@"usable_rect_local"]=usable?R(usable.rectValue):nil;
    return [self mutate:command];
}

- (DWControllerReply *)removeOutput:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"remove_output" ,@"output":output};
    return [self mutate:command];
}

- (DWControllerReply *)outputsSettled {
    NSDictionary *command=@{@"op":@"outputs_settled"};
    return [self mutate:command];
}

- (DWControllerReply *)setUsableRect:(CGRect)rect output:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"set_usable_area" ,@"output":output,@"usable_rect_local":R(rect)};
    return [self mutate:command];
}

- (DWControllerReply *)loadConfig:(NSString *)path {
    NSDictionary *command=@{@"op":@"load_config" ,@"path":path?:NSNull.null};
    return [self mutate:command];
}

- (DWControllerReply *)setSuperChord:(NSString *)chord {
    NSDictionary *command=@{@"op":@"set_platform" ,@"super":chord};
    return [self mutate:command];
}

- (DWControllerReply *)layoutChangedName:(NSString *)name shortName:(NSString *)shortName index:(NSUInteger)index count:(NSUInteger)count {
    NSDictionary *command=@{@"op":@"layout_changed" ,@"name":name,@"short":shortName,@"index":@(index),@"count":@(count)};
    return [self mutate:command];
}

- (DWControllerReply *)action:(NSString *)action output:(NSNumber *)output pointer:(NSValue *)pointer held:(BOOL)held {
    NSMutableDictionary *command=[@{@"op":@"action" ,@"action":action,@"output":output?:NSNull.null,@"held":@(held)}mutableCopy];
    if(pointer?P(pointer.pointValue):nil)command[@"pointer"]=pointer?P(pointer.pointValue):nil;
    return [self mutate:command];
}

- (DWControllerReply *)tapModifiers:(DWModifiers)modifiers output:(NSNumber *)output pointer:(NSValue *)pointer held:(BOOL)held {
    NSMutableDictionary *command=[@{@"op":@"tap" ,@"modifiers":M(modifiers),@"output":output?:NSNull.null,@"held":@(held)}mutableCopy];
    if(pointer?P(pointer.pointValue):nil)command[@"pointer"]=pointer?P(pointer.pointValue):nil;
    return [self mutate:command];
}

- (DWControllerReply *)hotCorner:(NSString *)corner output:(NSNumber *)output pointer:(NSValue *)pointer held:(BOOL)held {
    NSMutableDictionary *command=[@{@"op":@"hot_corner" ,@"corner":corner,@"output":output,@"held":@(held)}mutableCopy];
    if(pointer?P(pointer.pointValue):nil)command[@"pointer"]=pointer?P(pointer.pointValue):nil;
    return [self mutate:command];
}

- (DWControllerReply *)stateOnOutput:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"ipc" ,@"output":output?:NSNull.null,@"request":@"State"};
    return [self mutate:command];
}

- (DWControllerReply *)bookmark:(NSString *)name output:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"ipc" ,@"output":output,@"request":@{@"Bookmark":@{@"name":name}}};
    return [self mutate:command];
}

- (DWControllerReply *)closeWindow:(NSNumber *)window output:(NSNumber *)output {
    NSMutableDictionary *command=[@{@"op":@"ipc" ,@"request":@{@"Close":window}}mutableCopy];
    if(output)command[@"output"]=output;
    return [self mutate:command];
}

- (DWControllerReply *)relaunchWindow:(NSNumber *)window output:(NSNumber *)output {
    NSMutableDictionary *command=[@{@"op":@"ipc" ,@"request":@{@"Relaunch":window}}mutableCopy];
    if(output)command[@"output"]=output;
    return [self mutate:command];
}

- (DWControllerReply *)stateEventOnOutput:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"state_event" ,@"output":output?:NSNull.null};
    return [self mutate:command];
}

- (DWControllerReply *)screenshotResultPath:(NSString *)path width:(NSNumber *)width height:(NSNumber *)height error:(NSString *)error {
    NSMutableDictionary *command=[@{@"op":@"screenshot_result"}mutableCopy];
    if(path)command[@"path"]=path;if(width)command[@"width"]=width;if(height)command[@"height"]=height;if(error)command[@"error"]=error;
    return [self mutate:command];
}

- (DWControllerReply *)saveScene:(NSString *)path {
    NSDictionary *command=@{@"op":@"save" ,@"path":path};
    return [self mutate:command];
}

- (DWControllerReply *)loadScene:(NSString *)path {
    NSDictionary *command=@{@"op":@"load" ,@"path":path};
    return [self mutate:command];
}

- (DWControllerReply *)tickNavigationAt:(uint64_t)timestamp {
    return [self mutate:@{@"op":@"tick_navigation",@"timestamp_ns":@(timestamp)}];
}
- (NSDictionary *)attachCommandDictionary:(DWAttachRequest *)r {
    NSMutableDictionary *command=[@{@"op":@"attach",@"identity":I(r.identity),@"bundle_id":r.bundleID,@"title":r.title,@"buffer":B(r.buffer),@"source_rect":R(r.sourceRect),@"unsolicited":@(r.unsolicited)}mutableCopy];
    if(r.logicalID)command[@"logical_id"]=r.logicalID;
    if(r.worldRect)command[@"world_rect"]=R(r.worldRect.rectValue);
    if(r.output)command[@"output"]=r.output;
    if(r.pointer)command[@"pointer"]=P(r.pointer.pointValue);
    if(r.pinOutput)command[@"screen_pin"]=@{@"output":r.pinOutput,@"screen_pos":P(r.pinPosition)};
    return command.copy;
}
- (DWControllerReply *)attach:(DWAttachRequest *)request { return [self mutate:[self attachCommandDictionary:request]]; }
- (DWResizeTransaction *)resizeTransaction { return self.scene.nativeResize; }
- (DWControllerReply *)adoptionComplete:(NSArray<DWPresentWindow *> *)present {
    NSMutableArray *rows=[NSMutableArray arrayWithCapacity:present.count];
    for(DWPresentWindow *window in present)[rows addObject:@{@"bundle_id":window.bundleID,@"title":window.title}];
    return [self mutate:@{@"op":@"adoption_complete",@"present":rows}];
}
- (BOOL)resizeRemovalAllowedForWindow:(NSNumber *)window allowed:(BOOL *)answer {
    uint8_t allowed=0;
    if(!self.handle||!driftwm_desktop_resize_removal_allowed(self.handle,window==nil,window.unsignedLongLongValue,&allowed))return NO;
    if(answer)*answer=allowed!=0;return YES;
}
- (BOOL)observationCurrentForWindow:(NSNumber *)window identity:(DWIdentity *)identity bounds:(CGRect)bounds buffer:(CGSize)buffer {
    DriftDesktopObservation observation={.window=window.unsignedLongLongValue,.birth_sec=identity.birthSeconds.longLongValue,.x=bounds.origin.x,.y=bounds.origin.y,.width=bounds.size.width,.height=bounds.size.height,.pid=identity.pid.intValue,.birth_usec=identity.birthMicroseconds.intValue,.wid=identity.wid.unsignedIntValue,.owner=identity.owner.unsignedIntValue,.buffer_width=(uint32_t)buffer.width,.buffer_height=(uint32_t)buffer.height};
    return driftwm_desktop_observation_current(self.handle,&observation)!=0;
}
- (NSArray<NSNumber *> *)outputIDs {
    NSMutableArray *outputs=[NSMutableArray array];
    for(size_t i=0,n=driftwm_desktop_output_count(self.handle);i<n;i++){
        uint64_t output;
        if(driftwm_desktop_output_id_at(self.handle,i,&output))[outputs addObject:@(output)];
    }
    return outputs.copy;
}
- (BOOL)output:(NSNumber *)output screenBounds:(CGRect *)bounds {
    DriftDesktopRect rect;
    if(!driftwm_desktop_output_screen_bounds(self.handle,output.unsignedLongLongValue,&rect))return NO;
    if(bounds)*bounds=CGRectMake(rect.x,rect.y,rect.width,rect.height);
    return YES;
}
- (DWSourceBinding *)sourceBindingForWindow:(NSNumber *)window {
    DriftDesktopSourceBinding b;
    if(!self.handle||!window||!driftwm_desktop_source_binding(self.handle,window.unsignedLongLongValue,&b))return nil;
    return DWProject(DWSourceBinding.class,@{@"identity":@{@"pid":@(b.pid),@"birth_sec":@(b.birth_sec),@"birth_usec":@(b.birth_usec),@"wid":@(b.wid),@"owner":b.owner?@(b.owner):(id)NSNull.null},@"generation":@(b.generation),@"observation_known":@(b.observation_known!=0),@"observed_rect":R(CGRectMake(b.x,b.y,b.width,b.height))});
}
- (NSNumber *)outputAtPoint:(CGPoint)point restrictedToOutputs:(NSArray<NSNumber *> *)outputs {
    if(!self.handle)return nil;
    for(size_t i=0,n=driftwm_desktop_output_count(self.handle);i<n;i++){
        uint64_t identifier;DriftDesktopRect r;NSNumber *output;
        if(!driftwm_desktop_output_id_at(self.handle,i,&identifier)||![outputs containsObject:(output=@(identifier))]||!driftwm_desktop_output_screen_bounds(self.handle,identifier,&r))continue;
        if(CGRectContainsPoint(CGRectMake(r.x,r.y,r.width,r.height),point))return output;
    }
    return nil;
}
- (DWResizeValidityFacts *)resizeValidityForWindow:(NSNumber *)window output:(NSNumber *)output {
    DWScene *scene=self.scene;if(!scene)return nil;
    DWResizeValidityFacts *facts=[DWResizeValidityFacts new];
    facts.transaction=scene.nativeResize;facts.source=[scene windowWithID:window].source;facts.output=[scene outputWithID:output];
    return facts;
}
- (BOOL)submitSceneToWriter:(DWSceneWriter *)writer path:(NSString *)path { return [writer submit:self.handle path:path]; }
@end
