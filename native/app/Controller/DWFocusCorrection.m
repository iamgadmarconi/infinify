// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWFocusCorrection
- (NSNumber *)correction { return DWNumber(self.rawDictionary[@"correction"]); }
- (DWIdentity *)observed { return [self cachedProjection:@"observed" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"observed"]);}]; }
- (NSNumber *)intruderPID { return DWNumber(self.rawDictionary[@"intruder_pid"]); }
- (NSNumber *)startedAt { return DWNumber(self.rawDictionary[@"started_at"]); }
@end
