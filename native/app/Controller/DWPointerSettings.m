// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWPointerSettings
- (NSNumber *)trackpadSpeed { return DWNumber(self.rawDictionary[@"trackpad_speed"]); }
- (NSNumber *)mouseSpeed { return DWNumber(self.rawDictionary[@"mouse_speed"]); }
- (NSNumber *)zoomStep { return DWNumber(self.rawDictionary[@"zoom_step"]); }
- (NSNumber *)zoomMouseSpeed { return DWNumber(self.rawDictionary[@"zoom_mouse_speed"]); }
- (NSNumber *)zoomTrackpadSpeed { return DWNumber(self.rawDictionary[@"zoom_trackpad_speed"]); }
@end
