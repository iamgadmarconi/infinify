// SPDX-License-Identifier: GPL-3.0-or-later
// Run the real host executable, then post one untagged mouse-up only to its
// enrolled disposable source. This models untagged-input observation, not human
// keyboard delivery or native-control success. It never requests activation.
#define main capturedFixtureMain
#include "captured.m"
#undef main

static void regressionRequire(BOOL condition, NSString *message) {
    if(!condition)[NSException raise:@"RegressionFailure" format:@"%@",message];
}
static void regressionWait(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!stopped&&end.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static NSDictionary *regressionCase(NSString *binary, NSString *directory, BOOL demo) {
    NSTask *hostTask=[NSTask new]; hostTask.executableURL=[NSURL fileURLWithPath:binary];
    hostTask.arguments=@[demo?@"--demo":@"--probe",directory,demo?@"4":@"10"];
    NSError *error=nil; regressionRequire([hostTask launchAndReturnError:&error],error.description?:@"Host launch failed");
    NSDate *start=NSDate.date; Router *router=[Router new];
    @try {
        NSDictionary *ready=nil;
        while(hostTask.running&&!stopped&&-start.timeIntervalSinceNow<3) {
            ready=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
            if([ready[@"bounds"]count]&&[ready[@"tick"]doubleValue]>=.3)break;
            regressionWait(.02);
        }
        router.pid=[ready[@"pid"]intValue];router.wid=[ready[@"window"]unsignedIntValue];
        router.processBirth=ready[@"birth"];router.bounds=ready[@"bounds"];router.tag=0;
        router.sent=[NSMutableArray array];router.deadline=[NSDate dateWithTimeIntervalSinceNow:2];
        router.eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);
        struct proc_bsdinfo identity={0};
        regressionRequire(proc_pidinfo(router.pid,PROC_PIDTBSDINFO,0,&identity,sizeof(identity))==sizeof(identity)
            &&identity.pbi_ppid==(uint32_t)hostTask.processIdentifier&&[router valid],@"Source is not the exact host-owned child");
        CGEventRef event=CGEventCreateMouseEvent(router.eventSource,kCGEventLeftMouseUp,CGPointZero,kCGMouseButtonLeft);
        BOOL posted=[router post:event at:CGPointMake(10,10)];CFRelease(event);
        regressionRequire(posted,@"Guarded process-directed untagged event was not posted");
        CFRelease(router.eventSource);router.eventSource=NULL;
        BOOL observed=NO,aliveAfterSuppression=NO;
        while(hostTask.running&&!stopped&&-start.timeIntervalSinceNow<8) {
            NSDictionary *current=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
            observed|=[current[@"untagged_events"]unsignedIntegerValue]>[ready[@"untagged_events"]unsignedIntegerValue];
            if(demo&&observed&&-start.timeIntervalSinceNow>=2.5&&[current[@"tick"]doubleValue]>=2.4)
                aliveAfterSuppression=YES;
            regressionWait(.02);
        }
        regressionRequire(!stopped&&!hostTask.running,@"Host interrupted or exceeded bounded test deadline");
        [hostTask waitUntilExit]; NSDictionary *receipt=readJSON([directory stringByAppendingPathComponent:@"receipt.json"]);
        regressionRequire(observed,@"Source never observed the untagged event");
        regressionRequire([receipt[@"screenshots_suppressed_after_input"]boolValue],@"Host did not suppress capture after input");
        regressionRequire([receipt[@"frames"]count]==0,@"Fixture capture happened after early untagged input");
        regressionRequire([receipt[@"source_reaped"]boolValue]&&[receipt[@"source_exit_status"]intValue]==0,@"Source cleanup failed");
        regressionRequire([receipt[@"attempts"]count]==0&&!receipt[@"source_activation_requested"],@"Regression unexpectedly ran control/focus proof");
        regressionRequire([receipt[@"source_initial"][@"bounds"]isEqual:receipt[@"source_final"][@"bounds"]],@"Source bounds changed");
        if(demo) {
            regressionRequire(hostTask.terminationStatus==0&&[receipt[@"signal"]intValue]==0&&aliveAfterSuppression,@"Demo stopped early after normal untagged input");
            regressionRequire(-start.timeIntervalSinceNow>=3.8,@"Demo did not reach its requested lifetime");
        } else {
            regressionRequire([receipt[@"signal"]intValue]==1&&-start.timeIntervalSinceNow<5,@"Scripted proof failed to abort promptly on contamination");
        }
        return @{@"mode":demo?@"demo":@"probe",@"passed":@YES,@"untagged_observed":@(observed),
                 @"alive_after_suppression":@(aliveAfterSuppression),@"elapsed_seconds":@(-start.timeIntervalSinceNow),
                 @"source_pid":@(router.pid),@"host_pid":@(hostTask.processIdentifier),@"source_birth":router.processBirth,
                 @"sent":router.sent,@"scope":@"own child PID-directed untagged mouse-up; no keyboard/focus/global input proof"};
    } @finally {
        if(router.eventSource)CFRelease(router.eventSource);
        if(hostTask.running)[hostTask terminate];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while(hostTask.running&&deadline.timeIntervalSinceNow>0)regressionWait(.02);
        if(hostTask.running)kill(hostTask.processIdentifier,SIGKILL);
        [hostTask waitUntilExit];
    }
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=3)return 64;
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    NSString *root=@(argv[2]);NSMutableDictionary *result=[@{@"passed":@NO,@"checks":[NSMutableArray array]}mutableCopy];
    int status=1;
    @try {
        for(NSString *name in @[@"demo",@"probe"]) {
            NSString *directory=[root stringByAppendingPathComponent:name];
            regressionRequire([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil],@"Fresh case directory required");
            [result[@"checks"]addObject:regressionCase(@(argv[1]),directory,[name isEqual:@"demo"])];
        }
        result[@"passed"]=@YES;status=0;
    } @catch(NSException *error) {result[@"failure"]=error.reason?:error.name;}
    save(result,[root stringByAppendingPathComponent:@"verification.json"]);
    printf("%s\n",[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]encoding:NSUTF8StringEncoding].UTF8String);
    return status;
}}
