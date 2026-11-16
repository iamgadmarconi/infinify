// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWController+Focus.h"
#import "DWController+Private.h"
#import "DWScene+Private.h"

@interface DWFocusPolicyContext ()
@property(nonatomic,copy) uint64_t (^clockProvider)(void);
@property(nonatomic,copy) BOOL (^filterProvider)(void);
@property(nonatomic,copy) BOOL (^focusAllowedProvider)(void);
@end
@implementation DWFocusPolicyContext
- (instancetype)initWithClock:(uint64_t (^)(void))clock filter:(BOOL (^)(void))filter focusAllowed:(BOOL (^)(void))focusAllowed {
    if((self=[super init])){_clockProvider=[clock copy];_filterProvider=[filter copy];_focusAllowedProvider=[focusAllowed copy];}return self;
}
- (uint64_t)timestamp { return self.clockProvider(); }
- (BOOL)filter { return self.filterProvider(); }
- (BOOL)focusAllowed { return self.focusAllowedProvider(); }
@end

@implementation DWController (Focus)
- (NSDictionary *)navigationPolicyFact:(NSDictionary *)fact context:(DWFocusPolicyContext *)context {
    return [self policyFactDictionary:fact timestamp:context.timestamp filter:context.filter focusAllowed:context.focusAllowed].rawDictionary;
}
- (DWScene *)navigationScene {
    return [DWScene sceneWithDictionary:[self navigationCommandDictionary:@{@"op":@"snapshot"}].rawDictionary];
}
- (DWEffect *)navigationEffectForReply:(DWControllerReply *)reply {
    return reply.navigationEffect;
}
- (DWControllerReply *)navigationExecute:(DWControllerReply * (^)(void))execute {
    DWControllerReply *reply=execute();
    return self.navigationPostprocess?self.navigationPostprocess(reply):reply;
}
// The closed six-step protocol lives here, including its synchronous receipt.
// No extra receipt is generated: only Rust's explicit receipt context recurses.
- (void)navigationSteps:(NSArray *)steps capturedEpoch:(uint64_t)epoch receivedReply:(DWControllerReply *)received context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    for(NSDictionary *step in steps){
        NSString *kind=step[@"step"];
        if([kind isEqual:@"cancel_click"])[execution navigationCancelNativeClick];
        else if([kind isEqual:@"advance"])[execution navigationAdvanceReleasingHold:[step[@"release_hold"]boolValue]];
        else if([kind isEqual:@"send"]){
            DWControllerReply *reply=[self navigationCommandDictionary:step[@"command"]];
            if([step[@"receipt"]isKindOfClass:NSDictionary.class]){
                NSDictionary *decision=[self navigationPolicyFact:@{@"kind":@"observation_receipt",@"context":step[@"receipt"],@"reply":reply.rawDictionary?:NSNull.null} context:context];
                [self navigationSteps:decision[@"steps"] capturedEpoch:epoch receivedReply:reply context:context execution:execution];
            }
        }else if([kind isEqual:@"answer"]){
            uint64_t answerEpoch=[step[@"captured_epoch"]boolValue]?epoch:execution.currentEpoch;
            [execution navigationAnswerEffect:DWProject(DWEffect.class,step[@"effect"]) logical:[step[@"logical"]boolValue] epoch:answerEpoch];
        }else if([kind isEqual:@"perform_reply"]){
            [execution navigationPerformReply:received correction:DWProject(DWFocusCorrection.class,step[@"correction"]) prepared:YES];
        }else if([kind isEqual:@"changed"])[execution navigationChanged];
    }
}
- (void)navigationConsumePolicy:(NSDictionary *)decision context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    if([decision[@"cancel_work"]boolValue]){
        [execution navigationCancelNativeClick];[execution navigationAdvanceReleasingHold:YES];
        [self navigationCommandDictionary:@{@"op":@"cancel_focus_cycle"}];
    }
    if([decision[@"advance"]boolValue]){[execution navigationCancelNativeClick];[execution navigationAdvanceReleasingHold:NO];}
    if([decision[@"reply"]isKindOfClass:NSDictionary.class])
        [execution navigationPerformReply:[DWControllerReply replyWithDictionary:decision[@"reply"]] correction:nil prepared:NO];
    if([decision[@"changed"]boolValue])[execution navigationChanged];
    // Capture only after the preceding synchronous hooks, as consumePolicy did.
    [self navigationSteps:decision[@"steps"] capturedEpoch:execution.currentEpoch receivedReply:nil context:context execution:execution];
}
- (DWControllerReply *)attach:(DWAttachRequest *)request arrived:(BOOL)arrived adopted:(BOOL)adopted utility:(BOOL)utility context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    NSDictionary *command=[self attachCommandDictionary:request];
    if(arrived&&adopted&&context.filter&&!utility){
        NSDictionary *decision=[self navigationPolicyFact:@{@"kind":@"window_arrived",@"identity":command[@"identity"],@"bundle":command[@"bundle_id"]} context:context];
        [self navigationConsumePolicy:decision context:context execution:execution];
        NSMutableDictionary *attach=[command mutableCopy];
        attach[@"unsolicited"]=decision?decision[@"unsolicited"]:@YES;
        return [self navigationCommandDictionary:attach];
    }
    return [self navigationCommandDictionary:command];
}
- (void)observeIdentity:(DWIdentity *)actual familyBinding:(DWSourceBinding *)family eventAt:(uint64_t)observedAt output:(NSNumber *)output capturedEpoch:(uint64_t)epoch context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    NSDictionary *decision=[self navigationPolicyFact:@{@"kind":@"observation",@"actual":actual.rawDictionary,@"family":family.rawDictionary?:NSNull.null,@"event_at":@(observedAt),@"output":output?:NSNull.null} context:context];
    if(!decision)decision=@{@"steps":@[@{@"step":@"cancel_click"},@{@"step":@"advance",@"release_hold":@NO},@{@"step":@"send",@"command":@{@"op":@"focus_lost"},@"receipt":NSNull.null},@{@"step":@"changed"}]};
    [self navigationSteps:decision[@"steps"] capturedEpoch:epoch receivedReply:nil context:context execution:execution];
}
- (BOOL)applicationPID:(pid_t)pid birthSeconds:(NSNumber *)seconds microseconds:(NSNumber *)microseconds bundle:(NSString *)bundle activated:(BOOL)activated eventAt:(uint64_t)eventAt context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    NSDictionary *decision=[self navigationPolicyFact:@{@"kind":@"application",@"process":@{@"pid":@(pid),@"birth_sec":seconds,@"birth_usec":microseconds},@"bundle":bundle?:NSNull.null,@"event_at":@(eventAt),@"activated":@(activated)} context:context];
    [self navigationConsumePolicy:decision context:context execution:execution];
    return [decision[@"observe"]boolValue];
}
- (void)systemSwitchHeld:(BOOL)held context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    [self navigationConsumePolicy:[self navigationPolicyFact:@{@"kind":@"switch",@"held":@(held)} context:context] context:context execution:execution];
}
- (void)systemUIIntentWithContext:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    [self navigationConsumePolicy:[self navigationPolicyFact:@{@"kind":@"system_ui"} context:context] context:context execution:execution];
}
- (void)launchIntentForBundle:(NSString *)bundle context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    [self navigationConsumePolicy:[self navigationPolicyFact:@{@"kind":@"launch_intent",@"bundle":bundle} context:context] context:context execution:execution];
}
- (void)windowClicked:(NSNumber *)window context:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    [self navigationConsumePolicy:[self navigationPolicyFact:@{@"kind":@"window_click",@"window":window?:NSNull.null} context:context] context:context execution:execution];
}
- (void)cancelBackgroundArrivalWithContext:(DWFocusPolicyContext *)context execution:(id<DWNavigationExecution>)execution {
    [self navigationConsumePolicy:[self navigationPolicyFact:@{@"kind":@"cancel_background"} context:context] context:context execution:execution];
}
- (void)clearBackgroundArrivalWithContext:(DWFocusPolicyContext *)context { [self navigationPolicyFact:@{@"kind":@"clear_background"} context:context]; }
- (void)resetFocusPolicyWithContext:(DWFocusPolicyContext *)context { [self navigationPolicyFact:@{@"kind":@"reset_policy"} context:context]; }
- (void)resetFocusRestoresWithContext:(DWFocusPolicyContext *)context { [self navigationPolicyFact:@{@"kind":@"reset_restores"} context:context]; }
- (DWFocusCorrection *)prepareFocusReply:(DWControllerReply *)reply protect:(BOOL)protect context:(DWFocusPolicyContext *)context {
    NSDictionary *decision=[self navigationPolicyFact:@{@"kind":@"reply",@"reply":reply.rawDictionary,@"protect":@(protect)} context:context];
    return DWProject(DWFocusCorrection.class,decision);
}
- (void)focusAnswerBegan:(DWEffect *)effect success:(BOOL)success context:(DWFocusPolicyContext *)context {
    [self navigationPolicyFact:@{@"kind":@"answer",@"effect_id":effect.effectID,@"success":@(success)} context:context];
}
- (void)focusConfirmed:(DWIdentity *)identity context:(DWFocusPolicyContext *)context {
    [self navigationPolicyFact:@{@"kind":@"confirmed",@"identity":identity.rawDictionary} context:context];
}
- (DWControllerReply *)navigationAnswerFocus:(DWEffect *)effect logical:(BOOL)logical success:(BOOL)success {
    NSMutableDictionary *command=[effect.rawDictionary mutableCopy];
    command[@"op"]=logical?@"focus_logical":@"focus_result";
    if(!logical)command[@"success"]=@(success);
    return [self navigationCommandDictionary:command];
}
- (DWControllerReply *)navigationCancelFocusCycle { return [self navigationCommandDictionary:@{@"op":@"cancel_focus_cycle"}]; }
- (DWControllerReply *)navigationEndFocusCycle { return [self navigationCommandDictionary:@{@"op":@"end_focus_cycle"}]; }
- (DWControllerReply *)navigationCancelOnOutput:(NSNumber *)output { return [self navigationCommandDictionary:@{@"op":@"cancel_navigation",@"output":output}]; }
- (DWControllerReply *)navigationTickAt:(uint64_t)timestamp { return [self navigationCommandDictionary:@{@"op":@"tick_navigation",@"timestamp_ns":@(timestamp)}]; }
- (DWControllerReply *)navigationActivateBinding:(DWSourceBinding *)binding cause:(NSString *)cause output:(NSNumber *)output includeOutput:(BOOL)includeOutput {
    NSMutableDictionary *command=[binding.rawDictionary mutableCopy];command[@"op"]=@"activate";command[@"cause"]=cause;
    if(includeOutput)command[@"output"]=output?:NSNull.null;
    return [self navigationCommandDictionary:command];
}
- (DWControllerReply *)navigationObserveBinding:(DWSourceBinding *)binding {
    NSMutableDictionary *command=[binding.rawDictionary mutableCopy];command[@"op"]=@"observe_focus";
    return [self navigationCommandDictionary:command];
}
@end
