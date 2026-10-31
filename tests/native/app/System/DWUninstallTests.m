// SPDX-License-Identifier: GPL-3.0-or-later
// The parts of uninstall (native/app/System/DWUninstall.h) that run without touching this Mac's registrations: finding the
// running processes of one executable and ending them in order, and removing another copy through that copy's own
// `uninstall`. The processes are copies of /bin/sleep in a scratch directory and the copies are stand-in bundles whose
// executable is a shell script; nothing is moved to the Trash and no login item, daemon or setting is touched.
#import <Foundation/Foundation.h>
#import "DWUninstall.h"
#include <signal.h>
#include <sys/stat.h>

static int checks,failures;
static void check(BOOL ok,NSString *what) { checks++;if(!ok)failures++;printf("%s %s\n",ok?"ok  ":"FAIL",what.UTF8String); }

static NSString *standIn(NSString *root,NSString *name,NSString *script) {
    NSString *bundle=[root stringByAppendingPathComponent:name],*executable=[bundle stringByAppendingPathComponent:@"Contents/MacOS/Infinify"];
    [NSFileManager.defaultManager createDirectoryAtPath:executable.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [script writeToFile:executable atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    chmod(executable.fileSystemRepresentation,0755);
    return bundle;
}

int main(void) { @autoreleasepool {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"uninstall-%d",getpid()]];
    [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *sleeper=[root stringByAppendingPathComponent:@"Infinify"];
    [files copyItemAtPath:@"/bin/sleep" toPath:sleeper error:NULL];
    check(DWUninstallInstances(sleeper).count==0,@"no instance before any runs");
    NSMutableArray<NSTask *> *tasks=[NSMutableArray array];
    for(int i=0;i<2;i++){NSTask *task=[NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:sleeper] arguments:@[@"30"] error:NULL terminationHandler:nil];if(task)[tasks addObject:task];}
    NSTask *other=[NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/bin/sleep"] arguments:@[@"30"] error:NULL terminationHandler:nil];
    usleep(200000);
    NSArray<NSNumber *> *found=DWUninstallInstances(sleeper);
    NSSet *expected=[NSSet setWithArray:@[@(tasks[0].processIdentifier),@(tasks[1].processIdentifier)]];
    check([[NSSet setWithArray:found] isEqual:expected],[NSString stringWithFormat:@"both instances of this executable are found, and only they (%@)",found]);
    check(DWUninstallStopInstances(found,5),@"SIGTERM ends them within the time given");
    check(DWUninstallInstances(sleeper).count==0,@"none is left");
    check(other.running,@"a process of another executable is left alone");
    [other terminate];

    NSString *trap=[root stringByAppendingPathComponent:@"stubborn"];
    [@"#!/bin/sh\ntrap '' TERM\nsleep 30\n" writeToFile:trap atomically:YES encoding:NSUTF8StringEncoding error:NULL];chmod(trap.fileSystemRepresentation,0755);
    NSTask *stubborn=[NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/bin/sh"] arguments:@[trap] error:NULL terminationHandler:nil];
    usleep(200000);
    check(!DWUninstallStopInstances(@[@(stubborn.processIdentifier)],1),@"a process that ignores SIGTERM is reported as still running");
    kill(stubborn.processIdentifier,SIGKILL);

    NSString *why=nil;
    NSString *leaves=standIn(root,@"Leaves.app",@"#!/bin/sh\n[ \"$1\" = uninstall ] || exit 70\nrm -rf \"$(cd \"$(dirname \"$0\")/../..\" && pwd)\"\n");
    check(DWUninstallRetireCopy(leaves,&why)&&![files fileExistsAtPath:leaves],@"a copy whose own uninstall removes it is retired");
    why=nil;
    NSString *stays=standIn(root,@"Stays.app",@"#!/bin/sh\necho 'uninstall: the login item could not be removed'\nexit 1\n");
    check(!DWUninstallRetireCopy(stays,&why)&&[files fileExistsAtPath:stays],@"a copy whose uninstall fails is left, and that is reported");
    check([why containsString:@"login item could not be removed"],[NSString stringWithFormat:@"with that copy's own words (%@)",why]);

    [files removeItemAtPath:root error:NULL];
    printf("%d checks, %d failed\n",checks,failures);
    return failures?1:0;
} }
