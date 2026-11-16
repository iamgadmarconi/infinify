// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWBinding
- (NSString *)kind { return DWString(self.rawDictionary[@"kind"]); }
- (NSString *)action { return DWString(self.rawDictionary[@"action"]); }
- (NSString *)combo { return DWString(self.rawDictionary[@"combo"]); }
- (NSNumber *)implemented { return DWNumber(self.rawDictionary[@"implemented"]); }
- (NSNumber *)focus { return DWNumber(self.rawDictionary[@"focus"]); }
- (NSNumber *)speed { return DWNumber(self.rawDictionary[@"speed"]); }
- (NSNumber *)panSpeed { return DWNumber(self.rawDictionary[@"pan_speed"]); }
- (NSNumber *)zoomSpeed { return DWNumber(self.rawDictionary[@"zoom_speed"]); }
- (NSNumber *)invert { return DWNumber(self.rawDictionary[@"invert"]); }
- (NSNumber *)passable { return DWNumber(self.rawDictionary[@"passable"]); }
- (NSNumber *)keyCode { return DWNumber(self.rawDictionary[@"key_code"]); }
- (NSNumber *)nxKeyType { return DWNumber(self.rawDictionary[@"nx_key_type"]); }
- (DWModifiers *)modifiers { return [self cachedProjection:@"modifiers" make:^id{return DWProject(DWModifiers.class,self.rawDictionary[@"modifiers"]);}]; }
- (NSString *)key { return DWString(self.rawDictionary[@"key"]); }
- (NSNumber *)trackpadSpeed { return DWNumber(self.rawDictionary[@"trackpad_speed"]); }
- (NSNumber *)mouseSpeed { return DWNumber(self.rawDictionary[@"mouse_speed"]); }
- (NSNumber *)zoomStep { return DWNumber(self.rawDictionary[@"zoom_step"]); }
- (NSNumber *)zoomMouseSpeed { return DWNumber(self.rawDictionary[@"zoom_mouse_speed"]); }
- (NSNumber *)zoomTrackpadSpeed { return DWNumber(self.rawDictionary[@"zoom_trackpad_speed"]); }
- (NSString *)chord { return DWString(self.rawDictionary[@"chord"]); }
- (NSNumber *)repeat { return DWNumber(self.rawDictionary[@"repeat"]); }
- (NSString *)character { return DWString(self.rawDictionary[@"character"]); }
- (NSString *)reason { return DWString(self.rawDictionary[@"reason"]); }
- (NSString *)purpose { return DWString(self.rawDictionary[@"purpose"]); }
@end
