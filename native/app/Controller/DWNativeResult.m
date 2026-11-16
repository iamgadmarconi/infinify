// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWNativeResult
- (NSString *)outcome { return DWString(self.rawDictionary[@"outcome"]); }
- (NSNumber *)axError { return DWNumber(self.rawDictionary[@"ax_error"]); }
- (NSNumber *)mutationAttempted { return DWNumber(self.rawDictionary[@"mutation_attempted"]); }
- (NSNumber *)observed { return DWNumber(self.rawDictionary[@"observed"]); }
- (CGSize)requested { return DWSceneSize(self.rawDictionary[@"requested"]); }
- (CGRect)actualAX { return DWSceneRect(self.rawDictionary[@"actual_ax"]); }
- (CGRect)actualCG { return DWSceneRect(self.rawDictionary[@"actual_cg"]); }
- (DWValuePresence)requestedPresence { return DWPresence(self.rawDictionary[@"requested"],NSDictionary.class); }
- (BOOL)requestedHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"requested"],1); }
- (DWValuePresence)actualAXPresence { return DWPresence(self.rawDictionary[@"actual_ax"],NSDictionary.class); }
- (BOOL)actualAXHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"actual_ax"],2); }
- (DWValuePresence)actualCGPresence { return DWPresence(self.rawDictionary[@"actual_cg"],NSDictionary.class); }
- (BOOL)actualCGHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"actual_cg"],2); }
- (NSNumber *)success { return DWNumber(self.rawDictionary[@"success"]); }
- (DWFocusEffect *)effect { return [self cachedProjection:@"effect" make:^id{return DWProject(DWFocusEffect.class,self.rawDictionary[@"effect"]);}]; }
- (CGRect)actualAXOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"actual_ax"],2)?self.actualAX:CGRectNull; }
- (CGRect)actualCGOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"actual_cg"],2)?self.actualCG:CGRectNull; }
+ (instancetype)resultWithNativeResize:(DWResizeResult)r {
    return DWProject(self,@{@"outcome":@(dw_resize_outcome_name(r.outcome)),@"ax_error":@(r.ax_error),
        @"mutation_attempted":@(r.mutation_attempted),@"observed":@(r.observed),
        @"requested":DWSceneSizeDictionary(r.requested),@"actual_ax":DWSceneRectDictionary(r.actual_ax),@"actual_cg":DWSceneRectDictionary(r.actual_cg)});
}
+ (instancetype)unansweredForSizeEffect:(DWSizeEffect *)effect {
    BOOL setter=effect.requestedPresence==DWValuePresent;
    DWResizeResult r={.outcome=DWResizeTimedOut,.ax_error=-25204,.mutation_attempted=setter,
        .observed=false,.requested=setter?effect.nativeRequestedSize:CGSizeZero,.actual_ax=CGRectZero,.actual_cg=CGRectZero};
    return [self resultWithNativeResize:r];
}
- (DWNativeResult *)withMutationAttempted:(BOOL)attempted {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];d[@"mutation_attempted"]=@(attempted);return DWProject(self.class,[d copy]);
}
- (CGRect)nativeActualAX { return DWNativeCoercingRect(self.rawDictionary[@"actual_ax"]); }
- (CGRect)nativeActualCG { return DWNativeCoercingRect(self.rawDictionary[@"actual_cg"]); }
@end
