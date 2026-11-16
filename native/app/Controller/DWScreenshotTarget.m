// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWScreenshotTarget
- (DWScreenshotWindowTarget *)window { return [self cachedProjection:@"window" make:^id{return DWProject(DWScreenshotWindowTarget.class,self.rawDictionary[@"Window"]);}]; }
- (DWScreenshotRegionTarget *)region { return [self cachedProjection:@"region" make:^id{return DWProject(DWScreenshotRegionTarget.class,self.rawDictionary[@"Region"]);}]; }
- (DWScreenshotTargetKind)kind {
    if([self.rawDictionary[@"unit"]isEqual:@"Viewport"])return DWScreenshotTargetViewport;
    if([self.rawDictionary[@"unit"]isEqual:@"All"])return DWScreenshotTargetAll;
    if(self.rawDictionary[@"Window"])return DWScreenshotTargetWindow;
    if(self.rawDictionary[@"Region"])return DWScreenshotTargetRegion;return DWScreenshotTargetUnknown;
}
@end
