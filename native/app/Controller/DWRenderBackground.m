// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWRenderBackground
- (NSString *)type { return DWString(self.rawDictionary[@"type"]); }
- (NSString *)path { return DWString(self.rawDictionary[@"path"]); }
- (NSString *)texture { return DWString(self.rawDictionary[@"texture"]); }
- (NSNumber *)mirrorTile { return DWNumber(self.rawDictionary[@"mirror_tile"]); }
- (NSNumber *)transparentShader { return DWNumber(self.rawDictionary[@"transparent_shader"]); }
- (NSNumber *)animateFPS { return DWNumber(self.rawDictionary[@"animate_fps"]); }
- (NSNumber *)cacheShader { return DWNumber(self.rawDictionary[@"cache_shader"]); }
- (NSNumber *)cacheBudgetMB { return DWNumber(self.rawDictionary[@"cache_budget_mb"]); }
- (NSNumber *)inheritMacOS { return DWNumber(self.rawDictionary[@"inherit_macos"]); }
- (NSNumber *)parallax { return DWNumber(self.rawDictionary[@"parallax"]); }
@end
