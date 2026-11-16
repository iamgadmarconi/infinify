// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWHotCornerSettings
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (NSString *)stableID { return DWString(self.rawDictionary[@"stable_id"]); }
- (NSNumber *)threshold { return DWNumber(self.rawDictionary[@"threshold"]); }
- (NSNumber *)disableWhileDragging { return DWNumber(self.rawDictionary[@"disable_while_dragging"]); }
- (NSNumber *)disableWhenFullscreen { return DWNumber(self.rawDictionary[@"disable_when_fullscreen"]); }
- (DWCornerActions *)corners { return [self cachedProjection:@"corners" make:^id{return DWProject(DWCornerActions.class,self.rawDictionary[@"corners"]);}]; }
@end
