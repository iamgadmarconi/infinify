// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWFlight
- (NSNumber *)generation { return DWNumber(self.rawDictionary[@"generation"]); }
- (CGPoint)cameraTarget { return DWScenePoint(self.rawDictionary[@"camera_target"]); }
- (NSNumber *)zoomTarget { return DWNumber(self.rawDictionary[@"zoom_target"]); }
- (DWValuePresence)cameraTargetPresence { return DWPresence(self.rawDictionary[@"camera_target"],NSDictionary.class); }
- (BOOL)cameraTargetHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"camera_target"],0); }
@end
