// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWRenderChrome
- (DWRGBA *)background { return [self cachedProjection:@"background" make:^id{return DWProjectColor(self.rawDictionary[@"background"]);}]; }
- (DWRGBA *)foreground { return [self cachedProjection:@"foreground" make:^id{return DWProjectColor(self.rawDictionary[@"foreground"]);}]; }
- (NSNumber *)cornerRadius { return DWNumber(self.rawDictionary[@"corner_radius"]); }
- (NSNumber *)titleBarHeight { return DWNumber(self.rawDictionary[@"title_bar_height"]); }
- (NSString *)font { return DWString(self.rawDictionary[@"font"]); }
- (NSNumber *)fontSize { return DWNumber(self.rawDictionary[@"font_size"]); }
- (NSString *)fontWeight { return DWString(self.rawDictionary[@"font_weight"]); }
- (NSString *)titleAlign { return DWString(self.rawDictionary[@"title_align"]); }
@end
