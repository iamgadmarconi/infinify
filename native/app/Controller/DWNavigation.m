// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWNavigation
- (DWPointerDemand *)cursorPan { return [self cachedProjection:@"cursorPan" make:^id{return DWProject(DWPointerDemand.class,self.rawDictionary[@"cursor_pan"]);}]; }
- (DWPointerDemand *)hoverPull { return [self cachedProjection:@"hoverPull" make:^id{return DWProject(DWPointerDemand.class,self.rawDictionary[@"hover_pull"]);}]; }
- (NSNumber *)clockNanoseconds { return DWNumber(self.rawDictionary[@"clock_ns"]); }
- (DWNavigationContext *)contextForOutput:(NSNumber *)output {
    return [self cachedProjection:[@"context/" stringByAppendingString:output.stringValue] make:^id{return DWProject(DWNavigationContext.class,DWDictionary(self.rawDictionary[@"contexts"])[output.stringValue]);}];
}
- (NSUInteger)flightCount { return DWDictionary(self.rawDictionary[@"flights"]).count; }
- (DWFlight *)flightForOutput:(NSNumber *)output {
    return [self cachedProjection:[@"flight/" stringByAppendingString:output.stringValue] make:^id{return DWProject(DWFlight.class,DWDictionary(self.rawDictionary[@"flights"])[output.stringValue]);}];
}
@end
