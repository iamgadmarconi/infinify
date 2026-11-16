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
static NSDictionary *R(CGRect r) { return DWSceneRectDictionary(r); }
static NSDictionary *B(CGSize b) { return @{@"width":@(b.width),@"height":@(b.height)}; }
static NSDictionary *M(DWModifierFlags m) { return @{@"control":@(m.control),@"option":@(m.option),@"shift":@(m.shift),@"command":@(m.command)}; }
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
    if(_snapshotValue)_seedScene=_snapshotValue;
    else if(!_seedScene)_seedScene=_visualValue;
    if(_visualDictionary==_snapshotDictionary)_visualValue=_snapshotValue;
    _snapshotDictionary=dictionary;_snapshotValue=nil;
}
- (void)setVisualDictionary:(NSDictionary *)dictionary {
    if(dictionary==_visualDictionary)return;
    _visualDictionary=dictionary;_visualValue=dictionary==_snapshotDictionary?_snapshotValue:nil;
}
- (DWScene *)cachedScene {
    if(!_snapshotValue&&_snapshotDictionary){
        _snapshotValue=_seedScene.rawDictionary==_snapshotDictionary?_seedScene:
            [[DWScene sceneWithDictionary:_snapshotDictionary]sceneBySeedingProjectionsFrom:_seedScene];
        _seedScene=nil;
    }
    return _snapshotValue;
}
- (DWScene *)visualScene {
    if(!_visualValue&&_visualDictionary){
        if(_visualDictionary==_snapshotDictionary)_visualValue=self.cachedScene;
        else _visualValue=_seedScene.rawDictionary==_visualDictionary?_seedScene:
            [[DWScene sceneWithDictionary:_visualDictionary]sceneBySeedingProjectionsFrom:_seedScene];
    }
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
// The external bridge's only callers send IPC and screenshot completion
// commands. Forward even malformed commands unchanged to Rust's validator;
// as before, these transactions invalidate caches before any possible mutation.
- (DWControllerReply *)executeExternalCommand:(NSDictionary *)command rawResponse:(NSData *__autoreleasing *)raw {
    NSDictionary *value=[self executeDictionary:command query:NO rawResponse:raw];
    return value?[DWControllerReply replyWithDictionary:value]:nil;
}
- (DWControllerReply *)navigationQueryDictionary:(NSDictionary *)command {
    DWControllerReply *reply=[self query:command];
    return self.navigationPostprocess?self.navigationPostprocess(reply):reply;
}
- (DWControllerReply *)navigationMutationDictionary:(NSDictionary *)command {
    DWControllerReply *reply=[self mutate:command];
    return self.navigationPostprocess?self.navigationPostprocess(reply):reply;
}
- (DWControllerReply *)policyFactDictionary:(NSDictionary *)fact timestamp:(uint64_t)timestamp filter:(BOOL)filter focusAllowed:(BOOL)focusAllowed {
    return [self navigationQueryDictionary:@{@"op":@"focus_policy",@"timestamp_ns":@(timestamp),@"filter":@(filter),@"focus_allowed":@(focusAllowed),@"fact":fact}];
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

- (DWControllerReply *)mouseBinding:(NSString *)trigger source:(NSString *)source modifiers:(DWModifierFlags)modifiers windowContext:(BOOL)windowContext window:(NSNumber *)window pick:(BOOL)pick {
    id<NSCopying> keys[7]={@"op",@"trigger",@"source",@"modifiers",@"context",@"pick"};
    id values[7]={@"mouse_binding",trigger,source?:NSNull.null,M(modifiers),windowContext?@"window":@"canvas",@(pick)};
    NSUInteger count=6;id optional;
    if((optional=window)){keys[count]=@"window";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)hoverOnOutput:(NSNumber *)output screen:(CGPoint)screen time:(NSNumber *)time {
    id<NSCopying> keys[4]={@"op",@"output",@"screen"};
    id values[4]={@"hover",output,P(screen)};
    NSUInteger count=3;id optional;
    if((optional=time)){keys[count]=@"time_ms";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)hoverWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation output:(NSNumber *)output screen:(CGPoint)screen time:(NSNumber *)time forwardMotion:(NSNumber *)forward {
    id<NSCopying> keys[8]={@"op",@"window",@"identity",@"generation",@"output",@"screen"};
    id values[8]={@"hover_source",window,I(identity),generation,output,P(screen)};
    NSUInteger count=6;id optional;
    if(forward){keys[count]=@"forward_motion";values[count++]=forward;}
    if((optional=time)){keys[count]=@"time_ms";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
    NSDictionary *command=@{@"op":@"pointer_nearest" ,@"output":output?:NSNull.null,@"screen":P(screen),@"start":P(start),@"held":@(held),@"focus":@(focus)};
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
    id<NSCopying> keys[3]={@"op",@"screen_delta"};
    id values[3]={@"gesture_to",P(delta)};
    NSUInteger count=2;id optional;
    if((optional=pointer?P(pointer.pointValue):nil)){keys[count]=@"pointer";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)endGesture {
    NSDictionary *command=@{@"op":@"end_gesture"};
    return [self mutate:command];
}

- (DWControllerReply *)beginGesture:(DWControllerGestureKind)kind fingers:(NSUInteger)fingers modifiers:(DWModifierFlags)modifiers windowContext:(BOOL)windowContext output:(NSNumber *)output pointer:(CGPoint)pointer doubleTap:(NSNumber *)doubleTap time:(double)time {
    NSMutableDictionary *command=[@{@"op":@"gesture_begin",@"kind":kind,@"fingers":@(fingers),@"modifiers":M(modifiers),@"context":windowContext?@"window":@"canvas",@"output":output,@"pointer":P(pointer),@"time_ms":@(time)}mutableCopy];
    if(doubleTap)command[@"doubletap"]=doubleTap;
    return [self mutate:command];
}

- (DWControllerReply *)updateGestureWithDelta:(CGPoint)delta scale:(NSNumber *)scale rotation:(NSNumber *)rotation time:(double)time held:(BOOL)held {
    NSMutableDictionary *command=[@{@"op":@"gesture_update",@"dx":@(delta.x),@"dy":@(delta.y),@"time_ms":@(time),@"held":@(held)}mutableCopy];
    if(scale)command[@"scale"]=scale;if(rotation)command[@"rotation"]=rotation;
    return [self mutate:command];
}

- (DWControllerReply *)endGestureCancelled:(BOOL)cancelled time:(double)time held:(NSNumber *)held {
    NSMutableDictionary *command=[@{@"op":@"gesture_end",@"cancelled":@(cancelled),@"time_ms":@(time)}mutableCopy];
    if(held)command[@"held"]=held;
    return [self mutate:command];
}

- (DWControllerReply *)focusWindow:(NSNumber *)window {
    NSDictionary *command=@{@"op":@"focus" ,@"window":window};
    return [self mutate:command];
}

- (DWControllerReply *)activateWindow:(NSNumber *)window output:(NSNumber *)output cause:(DWActivationCause)cause identity:(DWIdentity *)identity generation:(NSNumber *)generation {
    id<NSCopying> keys[6]={@"op",@"window",@"output",@"cause"};
    id values[6]={@"activate",window,output?:NSNull.null,cause};
    NSUInteger count=4;id optional;
    if((optional=identity?I(identity):nil)){keys[count]=@"identity";values[count++]=optional;}
    if((optional=generation)){keys[count]=@"generation";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
    id<NSCopying> keys[5]={@"op",@"output",@"screen_delta"};
    id values[5]={@"pan",output,P(delta)};
    NSUInteger count=3;id optional;
    if((optional=time)){keys[count]=@"time_ms";values[count++]=optional;}
    if((optional=source)){keys[count]=@"source";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)endPanOnOutput:(NSNumber *)output time:(NSNumber *)time {
    id<NSCopying> keys[3]={@"op",@"output"};
    id values[3]={@"pan_end",output};
    NSUInteger count=2;id optional;
    if((optional=time)){keys[count]=@"time_ms";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)zoomOnOutput:(NSNumber *)output anchor:(CGPoint)anchor delta:(double)delta source:(NSString *)source phase:(NSString *)phase {
    id<NSCopying> keys[6]={@"op",@"output",@"anchor",@"delta",@"source"};
    id values[6]={@"zoom_by",output,P(anchor),@(delta),source};
    NSUInteger count=5;id optional;
    if((optional=phase)){keys[count]=@"phase";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
    id<NSCopying> keys[6]={@"op",@"window",@"output",@"start_screen",@"group"};
    id values[6]={@"begin_native_resize",window,output,P(start),@(group)};
    NSUInteger count=5;id optional;
    if((optional=edges)){keys[count]=@"edges";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
    id<NSCopying> keys[4]={@"op",@"window",@"identity"};
    id values[4]={@"window_closed",window,I(identity)};
    NSUInteger count=3;id optional;
    if((optional=output)){keys[count]=@"output";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
    id<NSCopying> keys[4]={@"op",@"stable_id",@"screen_bounds"};
    id values[4]={@"register_output",stableID,R(bounds)};
    NSUInteger count=3;id optional;
    if((optional=usable?R(usable.rectValue):nil)){keys[count]=@"usable_rect_local";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
    id<NSCopying> keys[5]={@"op",@"action",@"output",@"held"};
    id values[5]={@"action",action,output?:NSNull.null,@(held)};
    NSUInteger count=4;id optional;
    if((optional=pointer?P(pointer.pointValue):nil)){keys[count]=@"pointer";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)tapModifiers:(DWModifierFlags)modifiers output:(NSNumber *)output pointer:(NSValue *)pointer held:(BOOL)held {
    id<NSCopying> keys[5]={@"op",@"modifiers",@"output",@"held"};
    id values[5]={@"tap",M(modifiers),output?:NSNull.null,@(held)};
    NSUInteger count=4;id optional;
    if((optional=pointer?P(pointer.pointValue):nil)){keys[count]=@"pointer";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)hotCorner:(NSString *)corner output:(NSNumber *)output pointer:(NSValue *)pointer held:(BOOL)held {
    id<NSCopying> keys[5]={@"op",@"corner",@"output",@"held"};
    id values[5]={@"hot_corner",corner,output,@(held)};
    NSUInteger count=4;id optional;
    if((optional=pointer?P(pointer.pointValue):nil)){keys[count]=@"pointer";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)toggleFullscreenOnOutput:(NSNumber *)output {
    return [self mutate:@{@"op":@"action",@"action":@"toggle-fullscreen",@"output":output}];
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
    id<NSCopying> keys[3]={@"op",@"request"};
    id values[3]={@"ipc",@{@"Close":window}};
    NSUInteger count=2;id optional;
    if((optional=output)){keys[count]=@"output";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)relaunchWindow:(NSNumber *)window output:(NSNumber *)output {
    id<NSCopying> keys[3]={@"op",@"request"};
    id values[3]={@"ipc",@{@"Relaunch":window}};
    NSUInteger count=2;id optional;
    if((optional=output)){keys[count]=@"output";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
    return [self mutate:command];
}

- (DWControllerReply *)stateEventOnOutput:(NSNumber *)output {
    NSDictionary *command=@{@"op":@"state_event" ,@"output":output?:NSNull.null};
    return [self mutate:command];
}

- (DWControllerReply *)screenshotResultPath:(NSString *)path width:(NSNumber *)width height:(NSNumber *)height error:(NSString *)error {
    id<NSCopying> keys[5]={@"op"};
    id values[5]={@"screenshot_result"};
    NSUInteger count=1;id optional;
    if((optional=path)){keys[count]=@"path";values[count++]=optional;}
    if((optional=width)){keys[count]=@"width";values[count++]=optional;}
    if((optional=height)){keys[count]=@"height";values[count++]=optional;}
    if((optional=error)){keys[count]=@"error";values[count++]=optional;}
    NSDictionary *command=[NSDictionary dictionaryWithObjects:values forKeys:keys count:count];
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
- (DWSource *)sourceBindingForWindow:(NSNumber *)window {
    DriftDesktopSourceBinding b;
    if(!self.handle||!window||!driftwm_desktop_source_binding(self.handle,window.unsignedLongLongValue,&b))return nil;
    return DWProject(DWSource.class,@{@"identity":@{@"pid":@(b.pid),@"birth_sec":@(b.birth_sec),@"birth_usec":@(b.birth_usec),@"wid":@(b.wid),@"owner":b.owner?@(b.owner):(id)NSNull.null},@"generation":@(b.generation),@"observation_known":@(b.observation_known!=0),@"observed_rect":R(CGRectMake(b.x,b.y,b.width,b.height))});
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
