// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWDecoration
- (NSString *)mode { return DWString(self.rawDictionary[@"mode"]); }
- (NSNumber *)borderWidth { return DWNumber(self.rawDictionary[@"border_width"]); }
- (DWRGBA *)borderColor { return [self cachedProjection:@"borderColor" make:^id{return DWProjectColor(self.rawDictionary[@"border_color"]);}]; }
- (DWRGBA *)borderColorFocused { return [self cachedProjection:@"borderColorFocused" make:^id{return DWProjectColor(self.rawDictionary[@"border_color_focused"]);}]; }
- (NSNumber *)cornerRadius { return DWNumber(self.rawDictionary[@"corner_radius"]); }
- (NSNumber *)shadow { return DWNumber(self.rawDictionary[@"shadow"]); }
- (NSNumber *)shadowRadius { return DWNumber(self.rawDictionary[@"shadow_radius"]); }
- (DWRGBA *)shadowColor { return [self cachedProjection:@"shadowColor" make:^id{return DWProjectColor(self.rawDictionary[@"shadow_color"]);}]; }
- (NSNumber *)opacity { return DWNumber(self.rawDictionary[@"opacity"]); }
- (NSNumber *)blur { return DWNumber(self.rawDictionary[@"blur"]); }
@end
