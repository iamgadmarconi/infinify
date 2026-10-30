// SPDX-License-Identifier: GPL-3.0-or-later
// Session-watch admission cases: DWSessionWatch with a private notification center and substituted public session and display queries.
// Split from tests/native/app/Windows/DWWindowManagerTests.m (0b3f028; native/desktop/window-discovery-regression.m at 37b27b1), moved verbatim.
// #imported by DWWindowManagerTests.m after its fixtures (check, fixtureNow, fixtureTime); never compiled alone.
// Startup admission uses a private notification center and substituted public
// queries; no host session/display or NSWorkspace singleton is inspected.
static NSDictionary *sessionValues;
static NSUInteger sessionQueries;
static uint32_t sessionDisplayCount=1;
static CGError sessionDisplayError;
static BOOL sessionDisplayAwake,sessionDisplayActive=YES;
static CFDictionaryRef sessionCopy(void) { sessionQueries++;return sessionValues?CFBridgingRetain(sessionValues):NULL; }
static CGError sessionDisplays(uint32_t capacity,CGDirectDisplayID *ids,uint32_t *count) {
    check(capacity==32,@"session display query has a fixed bounded capacity");*count=sessionDisplayCount;if(capacity)ids[0]=1;return sessionDisplayError;
}
static CGDirectDisplayID sessionMain(void) { return 1; }
static boolean_t sessionOnline(CGDirectDisplayID display) { return display==1; }
static boolean_t sessionActive(CGDirectDisplayID display) { return display==1&&sessionDisplayActive; }
static boolean_t sessionAsleep(CGDirectDisplayID display) { return display!=1||!sessionDisplayAwake; }
@interface SessionWorkspace : NSObject
@property NSNotificationCenter *notificationCenter;
+ (instancetype)sharedWorkspace;
@end
@implementation SessionWorkspace
+ (instancetype)sharedWorkspace { static SessionWorkspace *workspace;if(!workspace){workspace=[self new];workspace.notificationCenter=[NSNotificationCenter new];}return workspace; }
@end
#define NSWorkspace SessionWorkspace
#define CGSessionCopyCurrentDictionary sessionCopy
#define CGGetOnlineDisplayList sessionDisplays
#define CGMainDisplayID sessionMain
#define CGDisplayIsOnline sessionOnline
#define CGDisplayIsActive sessionActive
#define CGDisplayIsAsleep sessionAsleep
#define CACurrentMediaTime fixtureTime
#import "DWSessionWatch.m"
#undef NSWorkspace
#undef CGSessionCopyCurrentDictionary
#undef CGGetOnlineDisplayList
#undef CGMainDisplayID
#undef CGDisplayIsOnline
#undef CGDisplayIsActive
#undef CGDisplayIsAsleep
#undef CACurrentMediaTime
static void sessionAdmission(void) {
    fixtureNow=1000;sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES,(__bridge NSString *)kCGSessionLoginDoneKey:@YES};
    __block NSUInteger returns=0,leaves=0;
    DWSessionWatch *watch=[[DWSessionWatch alloc]initWithReturned:^{returns++;} left:^{leaves++;}];
    check(!watch.ready&&!returns&&!leaves,@"already asleep startup is blocked synchronously without departure/save callbacks");
    NSUInteger queries=sessionQueries;for(int i=0;i<10;i++)[watch poll];
    check(sessionQueries==queries,@"inactive admission does not query at idle-poll frequency");
    sessionDisplayAwake=YES;fixtureNow+=.5;[watch poll];
    check(watch.ready&&returns==1&&!leaves,@"missed prelaunch sleep notification recovers once current display becomes awake");
    queries=sessionQueries;fixtureNow+=5;[watch poll];check(sessionQueries==queries,@"active session has no polling query loop");
    NSNotificationCenter *center=SessionWorkspace.sharedWorkspace.notificationCenter;
    [center postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    [center postNotificationName:NSWorkspaceScreensDidSleepNotification object:nil];
    [center postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    check(!watch.ready&&leaves==1&&returns==1,@"Space changes cannot release either notification-held departure");
    [center postNotificationName:NSWorkspaceDidWakeNotification object:nil];
    check(!watch.ready&&returns==1,@"system wake alone leaves display-sleep hold intact");
    sessionDisplayAwake=NO;[center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    check(!watch.ready&&returns==1,@"early final wake notification does not override an asleep current display");
    queries=sessionQueries;sessionDisplayAwake=YES;fixtureNow+=.49;[watch poll];check(sessionQueries==queries,@"early-wake retry keeps its half-second budget");
    fixtureNow+=.02;[watch poll];check(watch.ready&&returns==2,@"wake readiness is retried without requiring another notification");
    [center postNotificationName:NSWorkspaceSessionDidResignActiveNotification object:nil];
    sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES,(__bridge NSString *)kCGSessionLoginDoneKey:@YES,@"CGSSessionScreenIsLocked":@YES};
    [center postNotificationName:NSWorkspaceSessionDidBecomeActiveNotification object:nil];check(!watch.ready&&leaves==2,@"known locked state blocks a session-return hint");
    sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@1,(__bridge NSString *)kCGSessionLoginDoneKey:@YES};fixtureNow+=.5;[watch poll];
    check(!watch.ready,@"malformed documented session boolean is not coerced into admission");
    sessionValues=nil;fixtureNow+=.5;[watch poll];check(!watch.ready,@"unavailable current session remains blocked");
    sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES,(__bridge NSString *)kCGSessionLoginDoneKey:@YES};
    sessionDisplayCount=32;fixtureNow+=.5;[watch poll];check(!watch.ready,@"saturated display inventory cannot authorize admission");
    sessionDisplayCount=1;sessionDisplayActive=NO;fixtureNow+=.5;[watch poll];check(!watch.ready,@"awake but inactive main display remains blocked");
    sessionDisplayActive=YES;fixtureNow+=.5;[watch poll];check(watch.ready&&returns==3,@"public readiness with unknown optional lock metadata recovers without asserting unlocked");
    [watch stop];queries=sessionQueries;fixtureNow+=1;[watch poll];[center postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    check(!watch.ready&&sessionQueries==queries&&returns==3&&leaves==2,@"stop removes callbacks and pending retry authority");
}
