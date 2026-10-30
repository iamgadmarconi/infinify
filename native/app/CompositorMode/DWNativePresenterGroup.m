// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWDockPayload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/app/CompositorMode/DWNativePresenter.m (37b27b1): several admitted helper sessions presented as one.
#import "DWNativePresenter+Private.h"

// Each helper keeps its existing authenticated scope and journal. Grouping
// routes a logical canvas frame to those already admitted sessions; it never
// enrolls a process, loads code, or grants a helper another process's windows.
@implementation DWNativePresenterGroup
- (BOOL)activate {
    if(self.ended)return NO;
    for(DWNativePresenter *session in self.sessions)if(![session activate])return NO;
    return !self.ended;
}
- (void)suspendWithCompletion:(void (^)(void))completed {
    self.groupEnded=YES;self.finished=YES;dispatch_group_t drain=dispatch_group_create();
    for(DWNativePresenter *session in self.sessions){dispatch_group_enter(drain);[session suspendWithCompletion:^{dispatch_group_leave(drain);}];}
    dispatch_group_notify(drain,dispatch_get_main_queue(),^{if(completed)completed();});
}
- (void)finish {
    self.groupEnded=YES;if(self.finished)return;self.finished=YES;
    for(DWNativePresenter *session in self.sessions)[session finish];
}
- (BOOL)ended {
    if(self.groupEnded)return YES;
    for(DWNativePresenter *session in self.sessions)if(session.ended){
        self.groupEnded=YES;
        // Restore the whole presentation on a partial loss. Frame/input checks
        // stop now; draining sibling sessions belongs to the next main turn.
        dispatch_async(dispatch_get_main_queue(),^{[self finish];});return YES;
    }
    return NO;
}
- (BOOL)familiesNeeded { for(DWNativePresenter *session in self.sessions)if(session.familiesNeeded)return YES;return NO; }
- (BOOL)allowsWindow:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]allowsWindow:identity]; }
- (NSNumber *)rootWindowFor:(CGWindowID)window {
    if(self.ended)return nil;for(DWNativePresenter *session in self.sessions){NSNumber *root=[session rootWindowFor:window];if(root)return root;}return nil;
}
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native { [self bound:identity bounds:native family:nil]; }
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family {
    if(!self.ended)[self.owners[identity[@"pid"]]bound:identity bounds:native family:family];
}
- (void)unbound:(NSDictionary *)identity { [self.owners[identity[@"pid"]]unbound:identity]; }
- (BOOL)withholdWindow:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]withholdWindow:identity]; }
- (BOOL)isWindowWithheld:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]isWindowWithheld:identity]; }
- (void)resumeWindow:(NSDictionary *)identity { [self.owners[identity[@"pid"]]resumeWindow:identity]; }
- (BOOL)canRebaseWindow:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]canRebaseWindow:identity]; }
- (BOOL)rebaseWindow:(NSDictionary *)identity bounds:(CGRect)native { return !self.ended&&[self.owners[identity[@"pid"]]rebaseWindow:identity bounds:native]; }
- (BOOL)isWindowRebased:(NSDictionary *)identity { return !self.ended&&[self.owners[identity[@"pid"]]isWindowRebased:identity]; }
- (void)cancelRebaseWindow:(NSDictionary *)identity { [self.owners[identity[@"pid"]]cancelRebaseWindow:identity]; }
- (DWNativeHiddenRoot *)beginTransitionForWindow:(NSDictionary *)identity { return self.ended?nil:[self.owners[identity[@"pid"]]beginTransitionForWindow:identity]; }
- (BOOL)hideTransition:(DWNativeHiddenRoot *)transition { return !self.ended&&[self.owners[transition.identity[@"pid"]]hideTransition:transition]; }
- (BOOL)isTransitionHidden:(DWNativeHiddenRoot *)transition { return !self.ended&&[self.owners[transition.identity[@"pid"]]isTransitionHidden:transition]; }
- (BOOL)revealTransition:(DWNativeHiddenRoot *)transition screen:(CGRect)screen alpha:(double)alpha { return !self.ended&&[self.owners[transition.identity[@"pid"]]revealTransition:transition screen:screen alpha:alpha]; }
- (BOOL)isTransitionRevealed:(DWNativeHiddenRoot *)transition { return !self.ended&&[self.owners[transition.identity[@"pid"]]isTransitionRevealed:transition]; }
- (void)setTransitionFrameAcknowledged:(void (^)(void))callback {
    [super setTransitionFrameAcknowledged:callback];
    for(DWNativePresenter *session in self.sessions)session.transitionFrameAcknowledged=callback;
}
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    if(self.ended)return;
    for(DWNativePresenter *session in self.sessions){NSMutableDictionary *owned=[NSMutableDictionary dictionary];
        for(NSNumber *logical in identities)if(self.owners[identities[logical][@"pid"]]==session)owned[logical]=identities[logical];
        [session describe:snapshot bound:owned];}
}
- (void)submit { if(self.ended)return;for(DWNativePresenter *session in self.sessions){[session submit];if(self.ended)break;} }
- (void)requireFreshPlacementAcknowledgement {
    if(!NSThread.isMainThread||self.ended)return;
    for(DWNativePresenter *session in self.sessions)[session requireFreshPlacementAcknowledgement];
}
- (DWNativeAppliedPlacement *)acknowledgedPlacementForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation output:(NSNumber *)output {
    if(!NSThread.isMainThread||self.ended)return nil;
    return [self.owners[identity[@"pid"]]acknowledgedPlacementForWindow:window identity:identity generation:generation output:output];
}
- (BOOL)isAcknowledgedPlacementCurrent:(DWNativeAppliedPlacement *)placement {
    return NSThread.isMainThread&&!self.ended&&[placement isKindOfClass:DWNativeAppliedPlacement.class]
        &&[self.owners[placement.identity[@"pid"]]isAcknowledgedPlacementCurrent:placement];
}
- (BOOL)isParkingAcknowledgedForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation {
    return NSThread.isMainThread&&!self.ended&&[self.owners[identity[@"pid"]]isParkingAcknowledgedForWindow:window identity:identity generation:generation];
}
- (NSData *)debug:(NSDictionary *)request {
    if([request[@"stall"]isKindOfClass:NSNumber.class])return [self.sessions.firstObject debug:request];
    NSMutableArray *sessions=[NSMutableArray array],*records=[NSMutableArray array],*table=[NSMutableArray array];NSMutableDictionary *stats=[NSMutableDictionary dictionary],*probe=[NSMutableDictionary dictionary];
    BOOL complete=YES;
    for(DWNativePresenter *session in self.sessions){NSDictionary *value=[NSJSONSerialization JSONObjectWithData:[session debug:request] options:0 error:nil][@"Ok"][@"DebugNative"];
        if(![value isKindOfClass:NSDictionary.class]){complete=NO;continue;}[sessions addObject:value];[records addObjectsFromArray:value[@"records"]?:@[]];
        for(NSString *key in value[@"stats"])if(![key isEqual:@"last_applied_seq"])stats[key]=@([stats[key]unsignedLongLongValue]+[value[@"stats"][key]unsignedLongLongValue]);
        NSDictionary *local=value[@"probe"];
        if(![local isKindOfClass:NSDictionary.class]){complete=NO;continue;}
        [table addObjectsFromArray:local[@"table"]?:@[]];
        for(NSString *key in @[@"held",@"restoring",@"frames_received",@"frames_applied",@"frames_superseded",@"journal_writes"])probe[key]=@([probe[key]unsignedLongLongValue]+[local[key]unsignedLongLongValue]);
    }
    probe[@"table"]=table;
    NSDictionary *reply=@{@"group":@YES,@"ended":@(self.ended),@"sessions":sessions,@"records":records,@"stats":stats,@"probe":complete?probe:(id)NSNull.null};
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugNative":reply}} options:0 error:nil];
}
@end
