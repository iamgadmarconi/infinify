// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
#include <math.h>
@implementation DWOutput
- (NSNumber *)identifier { return DWNumber(self.rawDictionary[@"id"]); }
- (CGPoint)camera { return DWScenePoint(self.rawDictionary[@"camera"]); }
- (NSNumber *)zoom { return DWNumber(self.rawDictionary[@"zoom"]); }
- (CGRect)screenBounds { return DWSceneRect(self.rawDictionary[@"screen_bounds"]); }
- (DWFullscreen *)fullscreen { return [self cachedProjection:@"fullscreen" make:^id{return DWProject(DWFullscreen.class,self.rawDictionary[@"fullscreen"]);}]; }
- (DWOutput *)outputWithCamera:(CGPoint)camera zoom:(NSNumber *)zoom screenBounds:(CGRect)bounds {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];d[@"camera"]=DWScenePointDictionary(camera);d[@"zoom"]=zoom;d[@"screen_bounds"]=DWSceneRectDictionary(bounds);return DWProject(self.class,d);
}
- (BOOL)hasSamePoseAsOutput:(DWOutput *)other {
    if(!other)return NO;for(NSString *k in @[@"camera",@"zoom",@"screen_bounds"])if(![self.rawDictionary[k]isEqual:other.rawDictionary[k]])return NO;return YES;
}
- (DWValuePresence)cameraPresence { return DWPresence(self.rawDictionary[@"camera"],NSDictionary.class); }
- (BOOL)cameraHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"camera"],0); }
- (DWValuePresence)screenBoundsPresence { return DWPresence(self.rawDictionary[@"screen_bounds"],NSDictionary.class); }
- (BOOL)screenBoundsHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen_bounds"],2); }
- (NSNumber *)pick { return DWNumber(self.rawDictionary[@"pick"]); }
- (DWValuePresence)fullscreenPresence { return DWPresence(self.rawDictionary[@"fullscreen"],NSDictionary.class); }
- (CGRect)screenBoundsOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen_bounds"],2)?self.screenBounds:CGRectNull; }
- (BOOL)isDrawable {
    NSNumber *identifier=self.identifier,*zoom=self.zoom;double i=identifier.doubleValue,z=zoom.doubleValue;CGRect r=self.screenBoundsOrNull;CGPoint c=self.camera;
    return identifier&&isfinite(i)&&i>0&&floor(i)==i&&identifier.unsignedLongLongValue>0
        &&self.cameraHasNumericComponents&&isfinite(c.x)&&isfinite(c.y)
        &&isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        &&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r))
        &&zoom&&isfinite(z)&&z>0;
}
@end
