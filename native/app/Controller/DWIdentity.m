// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWIdentity
- (NSNumber *)pid { return DWNumber(self.rawDictionary[@"pid"]); }
- (NSNumber *)birthSeconds { return DWNumber(self.rawDictionary[@"birth_sec"]); }
- (NSNumber *)birthMicroseconds { return DWNumber(self.rawDictionary[@"birth_usec"]); }
- (NSNumber *)wid { return DWNumber(self.rawDictionary[@"wid"]); }
- (NSNumber *)owner { return DWNumber(self.rawDictionary[@"owner"]); }
- (NSNumber *)generation { return DWNumber(self.rawDictionary[@"generation"]); }
+ (instancetype)identityWithPID:(NSNumber *)pid birthSeconds:(NSNumber *)seconds birthMicroseconds:(NSNumber *)microseconds windowID:(NSNumber *)wid owner:(NSNumber *)owner {
    NSMutableDictionary *d=[@{@"pid":pid,@"birth_sec":seconds,@"birth_usec":microseconds,@"wid":wid}mutableCopy];
    if(owner)d[@"owner"]=owner;return DWProject(self,d);
}
- (DWIdentity *)identityWithGeneration:(NSNumber *)generation {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];if(generation)d[@"generation"]=generation;else [d removeObjectForKey:@"generation"];return DWProject(self.class,d);
}
- (DWValuePresence)ownerPresence { return DWPresence(self.rawDictionary[@"owner"],NSNumber.class); }
@end
