// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWRender
- (NSNumber *)revision { return DWNumber(self.rawDictionary[@"revision"]); }
- (DWRenderBackground *)background { return [self cachedProjection:@"background" make:^id{return DWProject(DWRenderBackground.class,self.rawDictionary[@"background"]);}]; }
- (DWRenderChrome *)chrome { return [self cachedProjection:@"chrome" make:^id{return DWProject(DWRenderChrome.class,self.rawDictionary[@"chrome"]);}]; }
- (DWRenderOutline *)outline { return [self cachedProjection:@"outline" make:^id{return DWProject(DWRenderOutline.class,self.rawDictionary[@"outline"]);}]; }
- (DWRenderEffects *)effects { return [self cachedProjection:@"effects" make:^id{return DWProject(DWRenderEffects.class,self.rawDictionary[@"effects"]);}]; }
- (NSArray *)errors { return DWArray(self.rawDictionary[@"errors"]); }
@end
