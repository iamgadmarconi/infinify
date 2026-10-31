// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation over the commands it undoes: `login-item` (DWLoginItem.m), `native-desktop disable` (DWNativeDesktopCLI.m)
// and the settings takeover's restore (DWSystemTakeover.m).
#import "DWUninstall.h"
#import "DWLoginItem.h"
#import "DWNativeDesktopCLI.h"
#import "DWOwnerFile.h"
#import "DWSetupState.h"
#import "DWSystemTakeover.h"
#import <libproc.h>
#include <signal.h>

NSArray<NSNumber *> *DWUninstallInstances(NSString *executable) {
    char wanted[PATH_MAX];
    if(!realpath(executable.fileSystemRepresentation,wanted))return @[];
    int capacity=proc_listallpids(NULL,0);if(capacity<=0)return @[];
    pid_t pids[capacity+64];int count=proc_listallpids(pids,(int)sizeof(pids));
    NSMutableArray<NSNumber *> *found=[NSMutableArray array];
    for(int i=0;i<count;i++){
        if(pids[i]<=0||pids[i]==getpid())continue;
        struct proc_bsdinfo info={0};
        if(proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid())continue;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if(proc_pidpath(pids[i],path,sizeof(path))<=0)continue;
        char resolved[PATH_MAX];
        if(realpath(path,resolved)&&!strcmp(resolved,wanted))[found addObject:@(pids[i])];
    }
    return found;
}

BOOL DWUninstallStopInstances(NSArray<NSNumber *> *pids,NSTimeInterval seconds) {
    for(NSNumber *pid in pids)kill(pid.intValue,SIGTERM);
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    for(;;){
        BOOL left=NO;
        for(NSNumber *pid in pids)if(kill(pid.intValue,0)==0||errno==EPERM)left=YES;
        if(!left)return YES;
        if(deadline.timeIntervalSinceNow<=0)return NO;
        usleep(100000);
    }
}

static BOOL inApplicationsFolder(NSString *bundle) { return [bundle.stringByDeletingLastPathComponent.lastPathComponent isEqual:@"Applications"]; }

static BOOL trash(NSString *bundle,NSString *__autoreleasing *why) {
    NSError *error=nil;
    if([NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:bundle] resultingItemURL:nil error:&error])return YES;
    if(why)*why=[NSString stringWithFormat:@"%@ could not be moved to the Trash: %@",bundle,error.localizedDescription?:@"macOS gave no reason"];
    return NO;
}

int DWUninstallCommand(int argc,const char **argv) { @autoreleasepool {
    BOOL leaveApp=argc==1&&!strcmp(argv[0],"--leave-app");
    if(argc>1||(argc==1&&!leaveApp)){fputs("usage: Infinify uninstall [--leave-app]\n",stderr);return 64;}
    int result=0;
    // The login item first: unregistering it ends the instance launchd started, and nothing starts Infinify again.
    const char *off[]={"off"};
    if(DWLoginItemCommand(1,off)!=0)result=1;
    NSArray<NSNumber *> *running=DWUninstallInstances(NSBundle.mainBundle.executablePath);
    if(running.count){
        printf("stopping %lu running Infinify process%s (SIGTERM; windows and settings are put back as at any quit)\n",(unsigned long)running.count,running.count==1?"":"es");
        if(!DWUninstallStopInstances(running,10)){fputs("uninstall: an Infinify process did not end within ten seconds; quit it (Infinify msg action quit) and run this again.\n",stderr);result=1;}
    }
    if(DWNativeDesktopTurnOff()!=0)result=1;
    NSString *note=nil;
    if(![[DWSystemTakeover system] restore:&note])result=1;
    if(note.length)printf("%s\n",note.UTF8String);
    DWSetupForget(DWSupportDirectory());
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    if(leaveApp)printf("left %s for the package manager to remove\n",bundle.fileSystemRepresentation);
    else if(!inApplicationsFolder(bundle))printf("left %s in place: it is not in an Applications folder\n",bundle.fileSystemRepresentation);
    else{NSString *why=nil;if(trash(bundle,&why))printf("moved %s to the Trash\n",bundle.fileSystemRepresentation);else{fprintf(stderr,"uninstall: %s\n",why.UTF8String);result=1;}}
    puts(result?"Infinify is not fully uninstalled; see above.":"Infinify is uninstalled. The scene stays in ~/Library/Application Support/Infinify and the config in ~/.config/infinify.");
    return result;
} }

static int runCopy(NSString *executable,NSArray<NSString *> *arguments,NSString *__autoreleasing *output) {
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:executable];task.arguments=arguments;
    NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=pipe;task.standardInput=[NSFileHandle fileHandleWithNullDevice];
    NSError *error=nil;
    if(![task launchAndReturnError:&error]){if(output)*output=error.localizedDescription;return -1;}
    NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];
    if(output)*output=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    return task.terminationStatus;
}

BOOL DWUninstallRetireCopy(NSString *bundle,NSString *__autoreleasing *why) {
    NSString *executable=[bundle stringByAppendingPathComponent:@"Contents/MacOS/Infinify"],*output=nil;
    int status=runCopy(executable,@[@"uninstall"],&output);
    if(status==64){
        // A build from before `uninstall`: what it does, step by step, with that copy's own commands.
        runCopy(executable,@[@"login-item",@"off"],NULL);
        DWUninstallStopInstances(DWUninstallInstances(executable),10);
        runCopy(executable,@[@"native-desktop",@"disable"],NULL);
        status=trash(bundle,why)?0:1;
        if(status)return NO;
    }
    struct stat st;
    if(status==0&&lstat(bundle.fileSystemRepresentation,&st)!=0)return YES;
    if(why&&!*why)*why=[NSString stringWithFormat:@"The copy at %@ was not removed%@",bundle,output.length?[@": " stringByAppendingString:[output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]:@"."];
    return NO;
}
