// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
// Translated from Sunlight, repository https://github.com/spacefarm-digital/sunlight, commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm; notice in SUNLIGHT-NOTICE.txt), upstream path Sources/Canvas/Setup/LiveWindowsService.swift,
// function by function (the line numbers are those of that file at that commit):
//   lines 5-7    `LiveWindowsXPC`           -> InfinifyLoaderXPC (DWLoaddRequest.h; it takes the command's arguments as well)
//   lines 18-25  `State`                    -> DWLoaderState
//   lines 27-28  `plistName`, `machService` -> DWLoadDaemonPlist, DWLoadMachService (DWLoaddRequest.h)
//   lines 30     `service`                  -> +service
//   lines 32-40  `state(of:)`               -> +stateOf:
//   lines 42-49  `state`                    -> +state
//   lines 51-66  `register()`               -> +registerDaemon
//   lines 68-75  `unregister()`             -> +unregister
//   lines 77-97  `run(_:timeout:)`          -> +run:arguments:timeout:output:
//   lines 115-126 `ResultBox`               -> DWLoaderResult
// Not translated: `runPrivileged` and `runWithAdministratorPrompt` (lines 99-113), Sunlight's administrator-prompt
// fallback: Infinify's fallback is the launcher's own sudo step, which asks for a password in the owner's terminal.
// Edits: `state` takes "not found" with the plist present as not registered (macOS 27 answers that for a never-registered daemon), Foundation C-style logging in place of NSLog, the daemon's Login Items pane is opened on the calling thread
// (this runs before AppKit, from a command), and the plist is looked for at Contents/Library/LaunchDaemons of the main bundle.
#import "DWLoaderService.h"
#import "DWLoaddRequest.h"
#import "DWLoginItem.h"
#import <ServiceManagement/ServiceManagement.h>

// The XPC reply arrives on another queue than the one waiting for it.
@interface DWLoaderResult : NSObject
- (void)setStatus:(int)status output:(NSString *)output;
@property(readonly) int status;
@property(readonly,copy) NSString *output;
@end
@implementation DWLoaderResult {
    NSLock *_lock;BOOL _set;int _status;NSString *_output;
}
- (instancetype)init { if((self=[super init])){_lock=[NSLock new];_status=-1;_output=@"no reply";}return self; }
- (void)setStatus:(int)status output:(NSString *)output { [_lock lock];if(!_set){_set=YES;_status=status;_output=[output copy];}[_lock unlock]; }
- (int)status { [_lock lock];int v=_status;[_lock unlock];return v; }
- (NSString *)output { [_lock lock];NSString *v=_output;[_lock unlock];return v; }
@end

@implementation DWLoaderService
+ (SMAppService *)service { return [SMAppService daemonServiceWithPlistName:DWLoadDaemonPlist]; }
+ (DWLoaderState)stateOf:(SMAppServiceStatus)status {
    switch(status){
        case SMAppServiceStatusEnabled:return DWLoaderEnabled;
        case SMAppServiceStatusRequiresApproval:return DWLoaderNeedsApproval;
        case SMAppServiceStatusNotRegistered:return DWLoaderNotRegistered;
        case SMAppServiceStatusNotFound:return DWLoaderUnavailable;
    }
    return DWLoaderUnavailable;
}
+ (DWLoaderState)state {
    NSBundle *bundle=NSBundle.mainBundle;
    if(![bundle.bundleURL.pathExtension isEqualToString:@"app"]||![NSFileManager.defaultManager fileExistsAtPath:[bundle.bundlePath stringByAppendingPathComponent:[@"Contents/Library/LaunchDaemons" stringByAppendingPathComponent:DWLoadDaemonPlist]]])return DWLoaderUnavailable;
    // Once the bundle carries the property list, "not found" is what macOS answers for a daemon this bundle never registered (the
    // same answer DWLoginItem.m meets for the agent), so it is "not registered" here and not "no daemon in this build".
    SMAppServiceStatus status=[self service].status;
    return status==SMAppServiceStatusNotFound?DWLoaderNotRegistered:[self stateOf:status];
}
+ (DWLoaderState)registerDaemon {
    DWLoaderState current=[self state];
    if(current!=DWLoaderNotRegistered&&current!=DWLoaderNeedsApproval)return current;
    NSError *error=nil;
    // Registering a daemon that awaits approval fails with "Operation not permitted" (as does registering one already registered
    // and waiting); the status says more, and is the answer.
    BOOL registered=[[self service] registerAndReturnError:&error];
    DWLoaderState after=[self state];
    if(!registered&&after!=DWLoaderNeedsApproval)fprintf(stderr,"launch daemon: register: %s\n",(error.localizedDescription?:@"macOS gave no reason").UTF8String);
    if(after==DWLoaderNeedsApproval)[SMAppService openSystemSettingsLoginItems];
    return after;
}
+ (void)unregister {
    DWLoaderState current=[self state];
    if(current!=DWLoaderEnabled&&current!=DWLoaderNeedsApproval)return;
    NSError *error=nil;
    if(![[self service] unregisterAndReturnError:&error])fprintf(stderr,"launch daemon: unregister failed: %s\n",(error.localizedDescription?:@"macOS gave no reason").UTF8String);
}
+ (int)run:(NSString *)command arguments:(NSArray<NSString *> *)arguments timeout:(NSTimeInterval)timeout output:(NSString *__autoreleasing *)output {
    NSXPCConnection *connection=[[NSXPCConnection alloc]initWithMachServiceName:DWLoadMachService options:NSXPCConnectionPrivileged];
    NSXPCInterface *interface=[NSXPCInterface interfaceWithProtocol:@protocol(InfinifyLoaderXPC)];
    [interface setClasses:[NSSet setWithObjects:NSArray.class,NSString.class,nil] forSelector:@selector(runCommand:arguments:reply:) argumentIndex:1 ofReply:NO];
    connection.remoteObjectInterface=interface;
    [connection resume];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    DWLoaderResult *box=[DWLoaderResult new];
    id<InfinifyLoaderXPC> proxy=[connection remoteObjectProxyWithErrorHandler:^(NSError *error){
        // The daemon refuses a caller silently when it is not this team's hardened-runtime Infinify, or was started with a DYLD_ variable.
        [box setStatus:-1 output:[NSString stringWithFormat:@"couldn't reach the launch daemon: %@ (it also refuses a copy of this app that is not signed with the hardened runtime or was started with a DYLD_ variable set; the reason is in `sudo log show --last 5m --predicate 'process == \"loadd\"'`)",error.localizedDescription]];
        dispatch_semaphore_signal(done);
    }];
    if(!proxy){[connection invalidate];if(output)*output=@"the launch daemon has no interface";return -1;}
    [proxy runCommand:command arguments:arguments reply:^(int status,NSString *text){[box setStatus:status output:text];dispatch_semaphore_signal(done);}];
    BOOL answered=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)))==0;
    [connection invalidate];
    if(!answered){if(output)*output=@"the launch daemon didn't answer";return -1;}
    if(output)*output=box.output;
    return box.status;
}
+ (int)pingWithin:(NSTimeInterval)seconds output:(NSString *__autoreleasing *)output {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    for(;;){
        int status=[self run:@"ping" arguments:@[] timeout:5 output:output];
        if(status!=-1||deadline.timeIntervalSinceNow<=0)return status;
        sleep(1);
    }
}
+ (NSString *)describe:(DWLoaderState)state {
    switch(state){
        case DWLoaderUnavailable:return @"unavailable (this build has no launch daemon: it is ad-hoc signed, or not run from an Infinify.app)";
        case DWLoaderNotRegistered:return @"not registered";
        case DWLoaderNeedsApproval:return [@"registered, waiting for approval under " stringByAppendingString:DWLoginItemsPane];
        case DWLoaderEnabled:return @"enabled";
    }
    return @"unknown";
}
@end
