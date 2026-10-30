// SPDX-License-Identifier: GPL-3.0-or-later
// The Dock-reload decisions: Sunlight's crash guard (its AdditionReloaderTests, translated), the remembered pause, the launcher's
// endpoint line, the reloader's state transitions against a fake Dock, clock and launcher, and the login-mode record.
// No launch daemon, Dock, window, sudo or loader is involved. This does not show that a payload loads into a real Dock (the guest
// run recorded in docs/native/dock-helper/Daemon/README.md does).
#import "DWDockReloader.h"
#import "DWNativeDesktopCLI.h"
#include <sys/stat.h>
#include <unistd.h>

static int failures=0,checks=0;
#define CHECK(condition,...) do{checks++;if(!(condition)){failures++;fprintf(stderr,"FAIL line %d: %s -- ",__LINE__,#condition);fprintf(stderr,__VA_ARGS__);fputc('\n',stderr);}}while(0)
static NSString *const kShaA=@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static NSString *const kShaB=@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

static void pump(BOOL (^done)(void),NSTimeInterval seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!done()&&deadline.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
}
static void settle(NSTimeInterval seconds) { pump(^BOOL{return NO;},seconds); }

// Translated from lines 20-64 of Tests/CanvasTests/AdditionReloaderTests.swift in https://github.com/spacefarm-digital/sunlight, commit
// afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm; notice in SUNLIGHT-NOTICE.txt).
static void crashGuard(void) {
    // testTripsOnThreeRestartsAroundLoads (22-36): a load, the Dock going down, the next load, down again: the third trips it.
    DWDockCrashGuard guard={0};NSTimeInterval now=0;
    for(NSUInteger strike=1;strike<=DWDockCrashLimit;strike++){
        DWDockCrashGuardLoadStarted(&guard,now);DWDockCrashGuardLoadEnded(&guard,now+2);now+=5;
        CHECK(DWDockCrashGuardDockRestarted(&guard,now)==(strike==DWDockCrashLimit),"strike %lu",(unsigned long)strike);
        now+=2;
    }
    // testRestartDuringALoadIsOneStrike (38-44)
    DWDockCrashGuard during={0};
    DWDockCrashGuardLoadStarted(&during,0);
    CHECK(!DWDockCrashGuardDockRestarted(&during,1)&&during.strikes==1,"a restart during a load: %lu strikes",(unsigned long)during.strikes);
    // testRestartAwayFromLoadsClearsStrikes (46-54)
    DWDockCrashGuard away={0};
    DWDockCrashGuardLoadStarted(&away,0);DWDockCrashGuardLoadEnded(&away,1);
    DWDockCrashGuardDockRestarted(&away,3);DWDockCrashGuardDockRestarted(&away,4);
    CHECK(away.strikes==2,"two restarts near the load: %lu",(unsigned long)away.strikes);
    CHECK(!DWDockCrashGuardDockRestarted(&away,1+DWDockCrashWindow+1)&&away.strikes==0,"a restart away from loads: %lu",(unsigned long)away.strikes);
    // testResetStartsCountingAfresh (55-63)
    DWDockCrashGuard reset={0};
    DWDockCrashGuardLoadStarted(&reset,0);DWDockCrashGuardDockRestarted(&reset,1);DWDockCrashGuardDockRestarted(&reset,2);
    DWDockCrashGuardReset(&reset);
    CHECK(!DWDockCrashGuardDockRestarted(&reset,3)&&reset.strikes==1,"after reset: %lu",(unsigned long)reset.strikes);
    // Not in Sunlight's tests: a restart with no load ever seen is no strike, and exactly the window's edge is not near.
    DWDockCrashGuard never={0};
    CHECK(!DWDockCrashGuardDockRestarted(&never,5)&&never.strikes==0,"a restart with no load");
    DWDockCrashGuard edge={0};DWDockCrashGuardLoadEnded(&edge,0);
    DWDockCrashGuardDockRestarted(&edge,DWDockCrashWindow);
    CHECK(edge.strikes==0,"a restart exactly one window after a load");
}

static NSString *makeDirectory(void) {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dock-reload-regression-%d-%u",getpid(),arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return path;
}

static void pauseStore(void) {
    NSString *directory=makeDirectory(),*file=[directory stringByAppendingPathComponent:@"auto-reload-paused.plist"];
    CHECK(!DWDockReloadPaused(directory,kShaA),"paused with no file");
    CHECK(!DWDockReloadResume(directory),"resumed with no file");
    CHECK(DWDockReloadPause(directory,kShaA,@"test"),"pause not written");
    struct stat st;CHECK(lstat(file.fileSystemRepresentation,&st)==0&&(st.st_mode&07777)==0600&&st.st_uid==getuid(),"pause file is not private");
    CHECK(DWDockReloadPaused(directory,kShaA),"not paused for the payload it was made for");
    CHECK(!DWDockReloadPaused(directory,kShaB),"paused for another payload: a new build must try again by itself");
    CHECK(DWDockReloadResume(directory)&&!DWDockReloadPaused(directory,kShaA),"resume did not lift the pause");
    // A file that is not a pause this user made cannot be told from one: it holds loading back.
    [@"not a plist" writeToFile:file atomically:NO encoding:NSUTF8StringEncoding error:nil];chmod(file.fileSystemRepresentation,0600);
    CHECK(DWDockReloadPaused(directory,kShaB),"an unreadable pause file did not pause");
    DWDockReloadResume(directory);
    CHECK(DWDockReloadPause(directory,kShaA,@"test"),"pause not written again");
    chmod(file.fileSystemRepresentation,0644);
    CHECK(DWDockReloadPaused(directory,kShaB),"a world-readable pause file did not pause");
    DWDockReloadResume(directory);
    NSString *link=[directory stringByAppendingPathComponent:@"elsewhere"];[@"x" writeToFile:link atomically:NO encoding:NSUTF8StringEncoding error:nil];
    symlink(link.fileSystemRepresentation,file.fileSystemRepresentation);
    CHECK(DWDockReloadPaused(directory,kShaB),"a symlinked pause file did not pause");
    DWDockReloadResume(directory);
    CHECK(!DWDockReloadPause(directory,@"short",@"test"),"a pause for a malformed digest was written");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void endpointLine(void) {
    NSString *runtime=nil,*nonce=nil;
    NSString *good=@"doctor said things\nINFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123 /tmp/if-native.AbC123/nonce\n";
    CHECK(DWDockReloadParseEndpoint(good,&runtime,&nonce)&&[runtime isEqualToString:@"/tmp/if-native.AbC123"]&&[nonce isEqualToString:@"/tmp/if-native.AbC123/nonce"],"the launcher's line was refused");
    CHECK(DWDockReloadParseEndpoint([good stringByAppendingString:@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.Zz9y8x /tmp/if-native.Zz9y8x/nonce\n"],&runtime,&nonce)&&[runtime isEqualToString:@"/tmp/if-native.Zz9y8x"],"the last line does not win");
    for(NSString *bad in @[@"",@"INFINIFY-NATIVE-ENDPOINT",@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123",@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123 /tmp/if-native.AbC123/other",
        @"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123 /tmp/if-native.Zz9y8x/nonce",@"INFINIFY-NATIVE-ENDPOINT /tmp/other.AbC123 /tmp/other.AbC123/nonce",@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC1234 /tmp/if-native.AbC1234/nonce",
        @"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123 /tmp/if-native.AbC123/nonce extra",@"  INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123 /tmp/if-native.AbC123/nonce",@"INFINIFY-NATIVE-ENDPOINT  /tmp/if-native.AbC123 /tmp/if-native.AbC123/nonce"])
        CHECK(!DWDockReloadParseEndpoint(bad,&runtime,&nonce),"accepted: %s",bad.UTF8String);
}

@interface Fake : NSObject
@property BOOL present;@property pid_t pid;@property uint64_t sec,usec;@property NSTimeInterval now;
@property NSMutableArray<NSNumber *> *statuses;@property NSInteger loads;@property NSString *output;
@property NSMutableArray<NSString *> *notes;@property NSMutableArray<NSString *> *endpoints;@property NSInteger restarts,pauses;
@end
@implementation Fake
- (void)newDock:(pid_t)pid { self.present=YES;self.pid=pid;self.sec=1000+(uint64_t)pid;self.usec=7; }
@end
static DWDockReloader *reloader(Fake *fake,NSString *directory,NSString *sha,NSTimeInterval loadedAt) {
    DWDockReloader *r=[[DWDockReloader alloc]initWithLauncher:@"/nonexistent/launch.sh" payloadSHA256:sha stateDirectory:directory loadedAt:loadedAt];
    r.dockSettle=.02;r.pollInterval=3600;
    dispatch_queue_t queue=dispatch_queue_create("regression.launcher",DISPATCH_QUEUE_SERIAL);
    r.workQueue=queue;
    r.dockSource=^BOOL(pid_t *pid,uint64_t *sec,uint64_t *usec){if(!fake.present)return NO;*pid=fake.pid;*sec=fake.sec;*usec=fake.usec;return YES;};
    r.clock=^NSTimeInterval{return fake.now;};
    r.loadRunner=^int(NSString *__autoreleasing *output){
        @synchronized(fake){fake.loads++;int status=[fake.statuses.firstObject intValue];if(fake.statuses.count>1)[fake.statuses removeObjectAtIndex:0];*output=fake.output;return status;}
    };
    r.onNote=^(NSString *note){[fake.notes addObject:note];};
    r.onEndpoint=^(NSString *runtime,NSString *nonce){[fake.endpoints addObject:[runtime stringByAppendingFormat:@" %@",nonce]];};
    r.onDockRestarted=^{fake.restarts++;};
    r.onPaused=^{fake.pauses++;};
    return r;
}
static Fake *fakeDock(void) {
    Fake *fake=[Fake new];[fake newDock:500];fake.now=1000;fake.statuses=[NSMutableArray arrayWithObject:@0];fake.notes=[NSMutableArray array];fake.endpoints=[NSMutableArray array];
    fake.output=@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.AbC123 /tmp/if-native.AbC123/nonce\n";
    return fake;
}
static void stepDock(Fake *fake,DWDockReloader *r,pid_t pid,NSTimeInterval at) {
    // The old Dock exits (no Dock for a poll), then the new one appears.
    fake.present=NO;[r checkDock];
    fake.now=at;[fake newDock:pid];[r checkDock];
}

static void reloadTransitions(void) {
    NSString *directory=makeDirectory();
    // A Dock that does not change is not a restart; the one a run starts with is not either.
    Fake *fake=fakeDock();
    DWDockReloader *r=reloader(fake,directory,kShaA,0);
    [r watch:YES];[r checkDock];[r checkDock];
    CHECK(fake.restarts==0&&!r.awaitingEndpoint&&fake.loads==0,"a steady Dock was taken for a restart");
    // No Dock between two Docks counts for nothing.
    fake.present=NO;[r checkDock];[r checkDock];
    CHECK(fake.restarts==0&&fake.loads==0,"no Dock was taken for a restart");
    // A new Dock: noted, awaited, the launcher run once after the settle, its endpoint handed over, the wait ended.
    [fake newDock:501];fake.now=2000;[r checkDock];
    CHECK(fake.restarts==1&&r.awaitingEndpoint,"a new Dock was not noticed");
    pump(^BOOL{return fake.endpoints.count>0;},2);
    CHECK(fake.loads==1&&fake.endpoints.count==1&&[fake.endpoints.firstObject isEqualToString:@"/tmp/if-native.AbC123 /tmp/if-native.AbC123/nonce"]&&!r.awaitingEndpoint,"the reload: %ld loads, %lu endpoints",(long)fake.loads,(unsigned long)fake.endpoints.count);
    CHECK(r.guard.strikes==0&&!r.paused,"a healthy reload struck: %lu",(unsigned long)r.guard.strikes);
    // A launcher that fails is tried twice for the Dock and then left (the second try is 10 s later; the test lets it through).
    fake=fakeDock();fake.statuses=[NSMutableArray arrayWithObject:@1];fake.output=@"Infinify native desktop: launch daemon does not answer\n";
    r=reloader(fake,directory,kShaA,0);r.retryDelay=.05;[r watch:YES];
    [fake newDock:601];[r checkDock];
    pump(^BOOL{return fake.loads>=2;},2);settle(.3);
    CHECK(fake.loads==2&&fake.endpoints.count==0&&r.awaitingEndpoint,"a failed reload: %ld loads (two tries per Dock)",(long)fake.loads);
    CHECK([fake.notes.lastObject containsString:@"Not trying again"],"the end of the tries is not said: %s",[fake.notes.lastObject UTF8String]);
    CHECK([[fake.notes componentsJoinedByString:@"\n"] containsString:@"launch daemon does not answer"],"the launcher's reason is not reported: %s",[[fake.notes componentsJoinedByString:@"|"] UTF8String]);
    // A different Dock gets its own tries.
    [r stop];
    fake=fakeDock();fake.statuses=[NSMutableArray arrayWithObject:@1];
    r=reloader(fake,directory,kShaA,0);r.retryDelay=.05;[r watch:YES];
    [fake newDock:701];[r checkDock];pump(^BOOL{return fake.loads>=2;},2);settle(.2);
    [fake newDock:702];fake.now+=120;[r checkDock];pump(^BOOL{return fake.loads>=4;},2);settle(.2);
    CHECK(fake.loads==4,"a second Dock did not get its own two tries: %ld",(long)fake.loads);
    [r stop];
    // A Dock that goes again while a reload waits for it to settle: only the latest is loaded into.
    fake=fakeDock();r=reloader(fake,directory,kShaA,0);r.dockSettle=.3;[r watch:YES];
    [fake newDock:801];[r checkDock];settle(.05);[fake newDock:802];fake.now+=100;[r checkDock];
    pump(^BOOL{return fake.endpoints.count>0;},3);settle(.4);
    CHECK(fake.loads==1&&fake.restarts==2,"two quick restarts: %ld loads, %ld restarts",(long)fake.loads,(long)fake.restarts);
    [r stop];
    // A Dock that goes again while a load runs: that load's helper is in a dead Dock and is not reported; the newer Dock gets its own.
    fake=fakeDock();r=reloader(fake,directory,kShaA,0);
    __block BOOL release=NO;
    __weak Fake *weakFake=fake;
    r.loadRunner=^int(NSString *__autoreleasing *output){
        Fake *f=weakFake;NSInteger n;@synchronized(f){n=++f.loads;}
        if(n==1)while(!release)usleep(2000);
        *output=n==1?@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.Old000 /tmp/if-native.Old000/nonce\n":@"INFINIFY-NATIVE-ENDPOINT /tmp/if-native.New000 /tmp/if-native.New000/nonce\n";
        return 0;
    };
    [r watch:YES];
    [fake newDock:951];[r checkDock];pump(^BOOL{return weakFake.loads>=1;},2);
    [fake newDock:952];fake.now+=100;[r checkDock];settle(.1);release=YES;
    pump(^BOOL{return weakFake.endpoints.count>=1;},3);settle(.1);
    CHECK(fake.loads==2&&fake.endpoints.count==1&&[fake.endpoints.firstObject hasPrefix:@"/tmp/if-native.New000"],"a Dock that went during a load: %ld loads, endpoints %s",(long)fake.loads,[[fake.endpoints componentsJoinedByString:@","] UTF8String]);
    [r stop];
    // A reload that finishes after a stop is not reported.
    fake=fakeDock();r=reloader(fake,directory,kShaA,0);[r watch:YES];
    [fake newDock:901];[r checkDock];[r stop];settle(.2);
    CHECK(fake.loads==0&&fake.endpoints.count==0,"a stopped reloader loaded");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void crashGuardInTheReloader(void) {
    NSString *directory=makeDirectory();
    Fake *fake=fakeDock();
    // The launcher loaded the payload just before this run started (it says so); that load is the first the guard counts.
    DWDockReloader *r=reloader(fake,directory,kShaA,[NSDate date].timeIntervalSince1970);
    [r watch:YES];
    // Three Dock restarts within a minute of loads: the first two are reloaded, the third stops loading, is remembered and ends the wait.
    NSTimeInterval at=1000;
    for(int restart=1;restart<=3;restart++){
        at+=10;
        stepDock(fake,r,500+restart,at);
        if(restart<3){pump(^BOOL{return fake.endpoints.count>=(NSUInteger)restart;},2);fake.now+=5;}
    }
    CHECK(fake.loads==2,"loads before the pause: %ld",(long)fake.loads);
    CHECK(r.paused&&fake.pauses==1&&!r.awaitingEndpoint,"the third restart did not pause (paused=%d, pauses=%ld)",r.paused,(long)fake.pauses);
    settle(.2);
    CHECK(fake.loads==2,"a load ran after the pause: %ld",(long)fake.loads);
    CHECK(DWDockReloadPaused(directory,kShaA),"the pause was not remembered");
    // Another restart while paused does not load (and does not count).
    stepDock(fake,r,520,at+500);settle(.2);
    CHECK(fake.loads==2,"a restart while paused loaded");
    [r stop];
    // The next launch of the same payload starts paused; a restart does not load. A build with another payload tries again by itself.
    fake=fakeDock();r=reloader(fake,directory,kShaA,0);[r watch:YES];
    CHECK(r.paused,"a new run of the same payload did not start paused");
    stepDock(fake,r,530,5000);settle(.2);
    CHECK(fake.loads==0,"a paused run loaded after a restart");
    [r stop];
    fake=fakeDock();r=reloader(fake,directory,kShaB,0);[r watch:YES];
    CHECK(!r.paused,"a new payload started paused");
    stepDock(fake,r,540,5000);pump(^BOOL{return fake.loads>=1;},2);
    CHECK(fake.loads==1,"a new payload did not reload");
    [r stop];
    // The owner loads by hand (the launcher lifts the file): the next run is no longer paused.
    DWDockReloadResume(directory);
    fake=fakeDock();r=reloader(fake,directory,kShaA,0);
    CHECK(!r.paused,"still paused after the owner loaded by hand");
    [r stop];
    // Restarts far apart (more than a minute after the last load) never strike, however many.
    fake=fakeDock();r=reloader(fake,directory,kShaA,0);[r watch:YES];
    for(int restart=1;restart<=5;restart++){stepDock(fake,r,550+restart,2000.0*restart);pump(^BOOL{return fake.endpoints.count>=(NSUInteger)restart;},2);}
    CHECK(fake.loads==5&&!r.paused&&r.guard.strikes<=1,"spaced restarts: %ld loads, paused=%d, strikes=%lu",(long)fake.loads,r.paused,(unsigned long)r.guard.strikes);
    [r stop];
    // The launcher's own load before the run counts: a Dock killed soon after login is a strike.
    fake=fakeDock();
    r=reloader(fake,directory,kShaA,[NSDate date].timeIntervalSince1970-3);
    CHECK(r.guard.strikes==0,"strikes before any restart");
    [r watch:YES];stepDock(fake,r,560,fake.now+10);
    CHECK(r.guard.strikes==1,"a restart 13 s after the launcher's load: %lu strikes",(unsigned long)r.guard.strikes);
    [r stop];
    fake=fakeDock();
    r=reloader(fake,directory,kShaA,0);[r watch:YES];stepDock(fake,r,570,fake.now+10);
    CHECK(r.guard.strikes==0,"a reused helper (no load) struck: %lu",(unsigned long)r.guard.strikes);
    [r stop];
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void loginRecord(void) {
    NSString *directory=makeDirectory();
    CHECK(DWNativeReadLoginRecord(directory)==nil,"a record with no file");
    CHECK(DWNativeWriteLoginRecord(directory,YES),"record not written");
    NSDictionary *record=DWNativeReadLoginRecord(directory);
    CHECK([record[@"mode"] isEqual:@"compositor"]&&[record[@"agent_added"] isEqual:@YES],"record content");
    NSString *file=[directory stringByAppendingPathComponent:@"login.plist"];
    struct stat st;CHECK(lstat(file.fileSystemRepresentation,&st)==0&&(st.st_mode&07777)==0600,"record is not private");
    CHECK(DWNativeWriteLoginRecord(directory,NO)&&[DWNativeReadLoginRecord(directory)[@"agent_added"] isEqual:@NO],"record not rewritten");
    chmod(file.fileSystemRepresentation,0644);
    CHECK(DWNativeReadLoginRecord(directory)==nil,"a world-readable record counted");
    chmod(file.fileSystemRepresentation,0600);
    CHECK(DWNativeRemoveLoginRecord(directory)&&DWNativeReadLoginRecord(directory)==nil&&!DWNativeRemoveLoginRecord(directory),"record removal");
    [@{@"version":@1,@"mode":@"capture"} writeToFile:file atomically:NO];chmod(file.fileSystemRepresentation,0600);
    CHECK(DWNativeReadLoginRecord(directory)==nil,"another mode counted as compositor mode");
    DWNativeRemoveLoginRecord(directory);
    NSString *loose=[directory stringByAppendingPathComponent:@"loose"];
    [NSFileManager.defaultManager createDirectoryAtPath:loose withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    CHECK(!DWNativeWriteLoginRecord(loose,NO),"a record was written into a directory others can enter");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

int main(void) { @autoreleasepool {
    crashGuard();pauseStore();endpointLine();reloadTransitions();crashGuardInTheReloader();loginRecord();
    if(failures){fprintf(stderr,"dock-reload-regression: %d of %d checks FAILED\n",failures,checks);return 1;}
    printf("dock-reload-regression: %d checks passed\n",checks);
    return 0;
} }
