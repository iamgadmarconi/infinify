// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
// Translated from Sunlight, repository https://github.com/spacefarm-digital/sunlight, commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm; notice in SUNLIGHT-NOTICE.txt), upstream path Sources/Canvas/RealWindows/AdditionReloader.swift,
// function by function (the line numbers are those of that file at that commit):
//   lines 38-42   dockBundleID, dockSettle, answerTimeout   -> kDockBundleID, dockSettle, kAnswerTimeout
//   lines 44-48   onDockRestarted, onPaused, crashGuard     -> the blocks and `guard`
//   lines 50-56   pausedKey, pausedAfterDockCrashes         -> DWDockReloadPaused/-Pause (a file the launcher reads too,
//                                                              in place of UserDefaults, which a shell script cannot read)
//   lines 57-61   dockPID, tried, quietTriesPerDock         -> dock, tried, kQuietTriesPerDock
//   lines 66-67   lastOutcome, timer                        -> the timer
//   lines 68-71   currentDockPID()                          -> currentDock (pid and process start, the identity the loader pins)
//   lines 80-108  watch(_:)                                 -> -watch: (the workspace notifications and the clock)
//   lines 110-129 checkDock()                               -> -checkDock
//   lines 131-136 mayTryQuietly                             -> -mayTry
//   lines 146-158 reload(interactive:asked:)                -> -reloadNow (never interactive; `asked` is the owner's
//                                                              manual `native-desktop`, which lifts the pause before the app starts)
//   lines 165-203 load(interactive:)                        -> -runLauncher (the launcher's --reload replaces the helper's
//                                                              `load`; the answer to wait for is the helper's endpoint, which
//                                                              the presenter then authenticates)
//   lines 242-257 run(_:_:)                                 -> -runLauncher's NSTask
//   lines 262-290 DockCrashGuard                            -> DWDockCrashGuard*
// Not translated: the administrator prompt, the sudoers rule and the Login Items registration (lines 24-26, 54-65, 134-139,
// 205-240): the prompt-free path here is the launch daemon, registered once by `native-desktop enable`.
// Edits: the clock fallback is 1 s, not 10 s (the Dock is not an app NSWorkspace reliably reports); a failed reload is tried
// once more after 10 s, still at most kQuietTriesPerDock per Dock; the guard counts the launcher's own load before the
// app started, so that a Dock killed soon after login is a strike.
#import "dock-reload.h"
#import "owner-file.h"
#import <AppKit/AppKit.h>
#include <libproc.h>
#include <sys/stat.h>
#include <unistd.h>

const NSTimeInterval DWDockCrashWindow=60;
const NSUInteger DWDockCrashLimit=3;
static NSString *const kDockBundleID=@"com.apple.dock";
static const NSUInteger kQuietTriesPerDock=2;
static const NSTimeInterval kAnswerTimeout=150; // the launcher waits for the loader's own readiness audit (seconds)
static NSString *const kPauseFile=@"auto-reload-paused.plist";
static NSString *const kEndpointPrefix=@"INFINIFY-NATIVE-ENDPOINT ";

void DWDockCrashGuardLoadStarted(DWDockCrashGuard *guard,NSTimeInterval at) { guard->loading=YES;guard->loaded=YES;guard->lastLoad=at; }
void DWDockCrashGuardLoadEnded(DWDockCrashGuard *guard,NSTimeInterval at) { guard->loading=NO;guard->loaded=YES;guard->lastLoad=at; }
BOOL DWDockCrashGuardDockRestarted(DWDockCrashGuard *guard,NSTimeInterval at) {
    BOOL nearLoad=guard->loading||(guard->loaded&&at-guard->lastLoad<DWDockCrashWindow);
    guard->strikes=nearLoad?guard->strikes+1:0;
    return guard->strikes>=DWDockCrashLimit;
}
void DWDockCrashGuardReset(DWDockCrashGuard *guard) { guard->strikes=0; }

NSString *DWDockReloadStateDirectory(void) { return [DWSupportDirectory() stringByAppendingPathComponent:@"native-desktop"]; }
BOOL DWDockReloadPaused(NSString *directory,NSString *payloadSHA256) {
    NSString *path=[directory stringByAppendingPathComponent:kPauseFile];
    struct stat st;
    if(lstat(path.fileSystemRepresentation,&st))return NO;
    // Present but not a pause this user made: it cannot be told from one, so it holds loading back until the owner loads by hand.
    NSDictionary *record=DWOwnerFileReadPlist(path);
    if(!record||![record[@"version"] isEqual:@1]||![record[@"payload_sha256"] isKindOfClass:NSString.class])return YES;
    return [record[@"payload_sha256"] isEqualToString:payloadSHA256];
}
BOOL DWDockReloadPause(NSString *directory,NSString *payloadSHA256,NSString *reason) {
    if(payloadSHA256.length!=64)return NO;
    return DWOwnerFileWritePlist([directory stringByAppendingPathComponent:kPauseFile],
        @{@"version":@1,@"payload_sha256":payloadSHA256,@"paused_at":[NSDate date],@"reason":reason?:@""});
}
BOOL DWDockReloadResume(NSString *directory) { return DWOwnerFileRemove([directory stringByAppendingPathComponent:kPauseFile]); }

BOOL DWDockReloadParseEndpoint(NSString *output,NSString *__autoreleasing *runtime,NSString *__autoreleasing *nonceFile) {
    NSString *line=nil;
    for(NSString *candidate in [output componentsSeparatedByString:@"\n"])if([candidate hasPrefix:kEndpointPrefix])line=candidate;
    if(!line)return NO;
    NSArray<NSString *> *parts=[[line substringFromIndex:kEndpointPrefix.length] componentsSeparatedByString:@" "];
    if(parts.count!=2)return NO;
    NSString *path=parts[0],*nonce=parts[1];
    static NSString *const prefix=@"/tmp/if-native.";
    if(path.length!=prefix.length+6||![path hasPrefix:prefix])return NO;
    for(NSUInteger i=prefix.length;i<path.length;i++){unichar c=[path characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z')))return NO;}
    if(![nonce isEqualToString:[path stringByAppendingString:@"/nonce"]])return NO;
    if(runtime)*runtime=path;
    if(nonceFile)*nonceFile=nonce;
    return YES;
}

// The Dock as the loader sees it: exactly one com.apple.dock, finished launching, with its process start.
static BOOL currentDock(pid_t *pid,uint64_t *sec,uint64_t *usec) {
    NSArray<NSRunningApplication *> *list=[NSRunningApplication runningApplicationsWithBundleIdentifier:kDockBundleID];
    if(list.count!=1||!list.firstObject.finishedLaunching)return NO;
    pid_t candidate=list.firstObject.processIdentifier;
    struct proc_bsdinfo info={0};
    if(candidate<=1||proc_pidinfo(candidate,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid()||!info.pbi_start_tvsec)return NO;
    *pid=candidate;*sec=info.pbi_start_tvsec;*usec=info.pbi_start_tvusec;
    return YES;
}

@implementation DWDockReloader {
    NSString *_launcher,*_payload,*_directory;
    DWDockCrashGuard _guard;
    pid_t _dockPID;uint64_t _dockSec,_dockUsec; // the Dock last seen; pid 0 between Docks
    pid_t _triedPID;NSUInteger _tried;
    pid_t _loadPID;uint64_t _loadSec,_loadUsec; // the Dock a running load was started for
    NSTimer *_timer;
    NSMutableArray *_observers;
    BOOL _awaiting,_paused,_running,_stopped;
    uint64_t _generation; // a newer Dock invalidates a reload waiting for the older one to settle
}
- (instancetype)initWithLauncher:(NSString *)launcher payloadSHA256:(NSString *)payloadSHA256 stateDirectory:(NSString *)stateDirectory loadedAt:(NSTimeInterval)loadedAt {
    if((self=[super init])){
        _launcher=[launcher copy];_payload=[payloadSHA256 copy];_directory=[stateDirectory copy];
        _dockSettle=1.5;_pollInterval=1;_retryDelay=10;_observers=[NSMutableArray array];
        _clock=^NSTimeInterval{return NSProcessInfo.processInfo.systemUptime;};
        _dockSource=^BOOL(pid_t *pid,uint64_t *sec,uint64_t *usec){return currentDock(pid,sec,usec);};
        _workQueue=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
        __weak DWDockReloader *weak=self;
        _loadRunner=^int(NSString *__autoreleasing *output){return [weak runLauncher:output];};
        _paused=DWDockReloadPaused(_directory,_payload);
        // The launcher's own load, just before this run started, is the first one the guard counts.
        NSTimeInterval ago=[NSDate date].timeIntervalSince1970-loadedAt;
        if(loadedAt>0&&ago>=0&&ago<3600)DWDockCrashGuardLoadEnded(&_guard,_clock()-ago);
    }
    return self;
}
- (BOOL)awaitingEndpoint { return _awaiting; }
- (BOOL)paused { return _paused; }
- (DWDockCrashGuard)guard { return _guard; }

- (void)watch:(BOOL)wanted {
    if(wanted==(_timer!=nil))return;
    if(!wanted){[_timer invalidate];_timer=nil;return;}
    _stopped=NO;
    pid_t pid=0;uint64_t sec=0,usec=0;
    if(self.dockSource(&pid,&sec,&usec)){_dockPID=pid;_dockSec=sec;_dockUsec=usec;}
    // The Dock's exit and relaunch are announced; the clock is the fallback.
    if(!_observers.count){
        NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;
        __weak DWDockReloader *weak=self;
        for(NSNotificationName name in @[NSWorkspaceDidTerminateApplicationNotification,NSWorkspaceDidLaunchApplicationNotification]){
            [_observers addObject:[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];
                if([app.bundleIdentifier isEqualToString:kDockBundleID])[weak checkDock];
            }]];
        }
    }
    NSTimer *timer=[NSTimer timerWithTimeInterval:self.pollInterval target:self selector:@selector(checkDock) userInfo:nil repeats:YES];
    timer.tolerance=.5;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    _timer=timer;
}
- (void)stop {
    _stopped=YES;_generation++;[self watch:NO];
    for(id observer in _observers)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
    [_observers removeAllObjects];
}
- (void)note:(NSString *)text { if(self.onNote)self.onNote(text); }

- (void)checkDock {
    if(_stopped)return;
    pid_t pid=0;uint64_t sec=0,usec=0;
    BOOL present=self.dockSource(&pid,&sec,&usec);
    if(!present){_dockPID=0;return;} // between the old Dock exiting and launchd starting the new one there is no Dock at all
    if(pid==_dockPID&&sec==_dockSec&&usec==_dockUsec)return;
    pid_t old=_dockPID;
    BOOL first=old==0&&_dockSec==0;
    _dockPID=pid;_dockSec=sec;_dockUsec=usec;
    if(first)return; // the Dock this run started with
    [self note:[NSString stringWithFormat:@"The Dock restarted (%d -> %d)",old,pid]];
    if(DWDockCrashGuardDockRestarted(&_guard,self.clock())&&!_paused){
        _paused=YES;
        if(!DWDockReloadPause(_directory,_payload,@"three Dock restarts in a row around loads"))[self note:@"The pause could not be written; it holds for this run only"];
        [self note:[NSString stringWithFormat:@"The Dock restarted %lu times in a row within %d s of loading the payload; not loading it by itself again (Infinify native-desktop, run by hand, tries again)",(unsigned long)DWDockCrashLimit,(int)DWDockCrashWindow]];
        _awaiting=NO;
        if(self.onPaused)self.onPaused();
        return;
    }
    _awaiting=YES;
    if(self.onDockRestarted)self.onDockRestarted();
    [self scheduleReloadAfter:self.dockSettle];
}

// Whether a reload may be tried in this Dock: not while paused, and twice per Dock at most (a try can race the Dock's own
// startup), so a payload that won't load isn't retried every time something asks.
- (BOOL)mayTry {
    return _dockPID!=0&&!_paused&&(_triedPID!=_dockPID||_tried<kQuietTriesPerDock);
}
- (void)scheduleReloadAfter:(NSTimeInterval)delay {
    uint64_t generation=++_generation;
    __weak DWDockReloader *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        DWDockReloader *me=weak;
        if(me&&!me->_stopped&&generation==me->_generation)[me reloadNow];
    });
}
- (void)reloadNow {
    // The Dock may have gone again while this waited: that restart schedules its own.
    pid_t pid=0;uint64_t sec=0,usec=0;
    if(_running||!self.dockSource(&pid,&sec,&usec)||pid!=_dockPID||sec!=_dockSec||usec!=_dockUsec)return;
    if(![self mayTry]){
        if(_paused)[self note:@"Automatic loading is paused for this payload; native presentation waits until Infinify native-desktop is run by hand"];
        else [self note:@"The payload was not loaded into this Dock after two tries; native presentation waits until the Dock restarts or Infinify native-desktop is run by hand"];
        return;
    }
    _tried=_triedPID==_dockPID?_tried+1:1;_triedPID=_dockPID;
    _loadPID=_dockPID;_loadSec=_dockSec;_loadUsec=_dockUsec;
    _running=YES;
    DWDockCrashGuardLoadStarted(&_guard,self.clock());
    __weak DWDockReloader *weak=self;
    dispatch_async(self.workQueue,^{
        NSString *output=@"";
        int status=weak.loadRunner(&output);
        dispatch_async(dispatch_get_main_queue(),^{[weak loadFinished:status output:output];});
    });
}
- (void)loadFinished:(int)status output:(NSString *)output {
    _running=NO;
    DWDockCrashGuardLoadEnded(&_guard,self.clock());
    if(_stopped)return;
    // The Dock went again while this load ran: its helper is in a Dock that is gone, and the restart's own reload found this one running.
    if(_loadPID!=_dockPID||_loadSec!=_dockSec||_loadUsec!=_dockUsec){
        [self note:@"The Dock restarted again while the payload was loading; loading it into the newer one"];
        if(_dockPID!=0&&[self mayTry])[self scheduleReloadAfter:self.dockSettle];
        return;
    }
    NSString *runtime=nil,*nonceFile=nil;
    if(status==0&&DWDockReloadParseEndpoint(output,&runtime,&nonceFile)){
        _awaiting=NO;
        if(self.onEndpoint)self.onEndpoint(runtime,nonceFile);
        return;
    }
    NSString *text=[output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *lines=[text componentsSeparatedByString:@"\n"];
    [self note:[NSString stringWithFormat:@"Reloading the payload failed: %@",text.length?lines.lastObject:[NSString stringWithFormat:@"exit status %d",status]]];
    if([self mayTry])[self scheduleReloadAfter:self.retryDelay];
    else [self note:@"Not trying again in this Dock"];
}

// The launcher's --reload, in the bundle, off the main thread. Its stdout carries the endpoint line; its stderr is this
// app's. Output is read before waiting: a full pipe would otherwise hold the child up forever.
- (int)runLauncher:(NSString *__autoreleasing *)output {
    NSTask *task=[NSTask new];
    task.executableURL=[NSURL fileURLWithPath:_launcher];
    task.arguments=@[@"--reload"];
    NSPipe *pipe=[NSPipe pipe];
    task.standardOutput=pipe;
    NSError *error=nil;
    if(![task launchAndReturnError:&error]){*output=error.localizedDescription;return -1;}
    __block BOOL finished=NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kAnswerTimeout*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{if(!finished&&task.running)[task terminate];});
    NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    finished=YES;
    *output=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"";
    return task.terminationStatus;
}
@end
