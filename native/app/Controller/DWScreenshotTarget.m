// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWScreenshotTarget {
    NSString *_unitName;
}
- (instancetype)initWithUnit:(NSString *)unit { if((self=[super initWithDictionary:@{}]))_unitName=unit;return self; }
- (DWScreenshotWindowTarget *)window { return [self cachedProjection:@"window" make:^id{return DWProject(DWScreenshotWindowTarget.class,self.rawDictionary[@"Window"]);}]; }
- (DWScreenshotRegionTarget *)region { return [self cachedProjection:@"region" make:^id{return DWProject(DWScreenshotRegionTarget.class,self.rawDictionary[@"Region"]);}]; }
- (DWScreenshotTargetKind)kind {
    if([_unitName isEqual:@"Viewport"])return DWScreenshotTargetViewport;
    if([_unitName isEqual:@"All"])return DWScreenshotTargetAll;
    if(self.rawDictionary[@"Window"])return DWScreenshotTargetWindow;
    if(self.rawDictionary[@"Region"])return DWScreenshotTargetRegion;return DWScreenshotTargetUnknown;
}
- (BOOL)isEqual:(id)other {
    if(self==other)return YES;if(![other isKindOfClass:DWScreenshotTarget.class])return NO;
    NSString *unit=((DWScreenshotTarget *)other)->_unitName;
    return (_unitName==unit||[_unitName isEqual:unit])&&[super isEqual:other];
}
- (NSUInteger)hash { return self.rawDictionary.hash^_unitName.hash; }
@end
