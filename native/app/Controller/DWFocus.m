// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWFocus
- (NSNumber *)intent { return DWNumber(self.rawDictionary[@"intent"]); }
- (DWFocusEffect *)observedNative { return [self cachedProjection:@"observedNative" make:^id{return (DWFocusEffect *)DWProjectEffect(self.rawDictionary[@"observed_native"]);}]; }
- (DWFocusEffect *)pendingEffect { return [self cachedProjection:@"pendingEffect" make:^id{return (DWFocusEffect *)DWProjectEffect(self.rawDictionary[@"pending_effect"]);}]; }
- (NSArray *)history { return DWArray(self.rawDictionary[@"history"]); }
- (NSNumber *)cycle { return DWNumber(self.rawDictionary[@"cycle"]); }
- (NSNumber *)releasePending { return DWNumber(self.rawDictionary[@"release_pending"]); }
- (DWNativeResult *)lastResult { return [self cachedProjection:@"lastResult" make:^id{return DWProject(DWNativeResult.class,self.rawDictionary[@"last_result"]);}]; }
- (DWValuePresence)pendingEffectPresence { return DWPresence(self.rawDictionary[@"pending_effect"],NSDictionary.class); }
@end
