// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWShellEffect
- (NSString *)app { return DWString(self.rawDictionary[@"app"]); }
- (NSString *)bundleID { return DWString(self.rawDictionary[@"bundle_id"]); }
- (NSString *)command { return DWString(self.rawDictionary[@"command"]); }
- (NSString *)source { return DWString(self.rawDictionary[@"source"]); }
- (NSString *)action { return DWString(self.rawDictionary[@"action"]); }
- (NSString *)path { return DWString(self.rawDictionary[@"path"]); }
- (NSNumber *)scale { return DWNumber(self.rawDictionary[@"scale"]); }
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (NSNumber *)width { return DWNumber(self.rawDictionary[@"width"]); }
- (NSNumber *)height { return DWNumber(self.rawDictionary[@"height"]); }
- (CGRect)region { return DWSceneRect(self.rawDictionary[@"region"]); }
- (DWScreenshotTarget *)target { return [self cachedProjection:@"target" make:^id{return DWProject(DWScreenshotTarget.class,self.rawDictionary[@"target"]);}]; }
- (NSNumber *)minimized { return DWNumber(self.rawDictionary[@"minimized"]); }
- (CGRect)regionOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"region"],2)?self.region:CGRectNull; }
- (NSNumber *)fitPadding { return DWNumber(self.rawDictionary[@"fit_padding"]); }
- (NSDictionary<NSString *,NSString *> *)environment { return DWDictionary(self.rawDictionary[@"env"]); }
- (NSString *)line { return DWString(self.rawDictionary[@"line"]); }
- (CGPoint)screen { return DWScenePoint(self.rawDictionary[@"screen"]); }
- (BOOL)screenHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen"],0); }
- (DWValuePresence)screenPresence { return DWPresence(self.rawDictionary[@"screen"],NSDictionary.class); }
- (NSString *)layoutTarget { return DWString(self.rawDictionary[@"target"]); }
- (NSNumber *)layoutIndex { return DWNumber(self.rawDictionary[@"index"]); }
@end
