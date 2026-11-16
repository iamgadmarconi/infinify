// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWController+External.h"
#import "DWScene+Private.h"
@implementation DWControllerReply (External)
- (NSDictionary *)externalReplyObject { return DWDictionary(self.rawDictionary[@"reply"]); }
@end
@implementation DWPlacement (External)
- (id)externalScreenRect { return self.rawDictionary[@"screen_rect"]; }
- (id)externalClipRect { return self.rawDictionary[@"clip_rect"]; }
@end
