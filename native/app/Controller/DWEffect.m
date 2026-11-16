// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWEffect
- (NSString *)operation { return DWString(self.rawDictionary[@"op"]); }
- (NSNumber *)effectID { return DWNumber(self.rawDictionary[@"effect_id"]); }
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (DWIdentity *)identity { return [self cachedProjection:@"identity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"identity"]);}]; }
- (NSNumber *)generation { return DWNumber(self.rawDictionary[@"generation"]); }
- (DWEffectKind)kind {
    NSString *op=self.operation;
    if([op isEqual:@"focus_native_window"])return DWEffectFocusNativeWindow;
    if([op isEqual:@"resize_native_window"])return DWEffectResizeNativeWindow;
    if([op isEqual:@"observe_resize_source"])return DWEffectObserveResizeSource;
    if([op isEqual:@"exec"])return DWEffectExec;if([op isEqual:@"launch"])return DWEffectLaunch;
    if([op isEqual:@"close_window"])return DWEffectCloseWindow;
    if([op isEqual:@"set_minimized"])return DWEffectSetMinimized;
    if([op isEqual:@"screenshot"])return DWEffectScreenshot;return DWEffectUnknown;
}
@end
