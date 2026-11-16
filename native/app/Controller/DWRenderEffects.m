// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWRenderEffects
- (NSNumber *)blurRadius { return DWNumber(self.rawDictionary[@"blur_radius"]); }
- (NSNumber *)blurStrength { return DWNumber(self.rawDictionary[@"blur_strength"]); }
- (NSNumber *)animateBlurFPS { return DWNumber(self.rawDictionary[@"animate_blur_fps"]); }
- (NSNumber *)animationSpeed { return DWNumber(self.rawDictionary[@"animation_speed"]); }
- (NSNumber *)animationScale { return DWNumber(self.rawDictionary[@"animation_scale"]); }
@end
