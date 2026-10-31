// SPDX-License-Identifier: GPL-3.0-or-later
// What setup decided (native/app/System/DWSetupState.h), against scratch directories: the mode a plain launch and the login
// item act on, the pane setup resumes at, the owner-only record, the other copies setup would remove, and the login item's
// job name. Reads SIP once, read-only; writes only its scratch directory.
#import <Foundation/Foundation.h>
#import "DWSetupState.h"
#include <sys/stat.h>

static int checks,failures;
static void check(BOOL ok,NSString *what) { checks++;if(!ok)failures++;printf("%s %s\n",ok?"ok  ":"FAIL",what.UTF8String); }

int main(void) { @autoreleasepool {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"setup-state-%d",getpid()]];
    NSString *support=[root stringByAppendingPathComponent:@"Infinify"];
    [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];

    check(DWSetupModeAt(support,NO)==DWSetupIncomplete,@"nothing recorded: setup is not done");
    check(DWSetupModeAt(support,YES)==DWSetupCompositor,@"the login-mode record alone makes compositor mode the default (native-desktop enable)");
    check(DWSetupResumePaneAt(support)==DWSetupPaneWelcome,@"nothing recorded: setup starts at the welcome");
    check(DWSetupRecordPane(support,DWSetupPaneLogin),@"a pane is recorded, the support directory made on the way");
    struct stat st;
    check(lstat([support stringByAppendingPathComponent:@"setup.plist"].fileSystemRepresentation,&st)==0&&(st.st_mode&07777)==0600,@"the record is the owner's alone (0600)");
    check(lstat(support.fileSystemRepresentation,&st)==0&&(st.st_mode&07777)==0700,@"in an owner-only directory (0700)");
    check(DWSetupResumePaneAt(support)==DWSetupPaneLogin,@"setup resumes at the pane recorded (after the Screen Recording relaunch)");
    check(DWSetupModeAt(support,NO)==DWSetupIncomplete,@"a pane reached is not setup done");
    check(!DWSetupRecordPane(support,(DWSetupPane)DWSetupPaneCount),@"a pane out of range is refused");

    check(DWSetupRecordDemo(support),@"the demo is recorded");
    check(DWSetupModeAt(support,NO)==DWSetupDemo,@"the demo is what a plain launch runs then");
    check(DWSetupModeAt(support,YES)==DWSetupCompositor,@"compositor mode, once set up, wins over an earlier demo");
    check(DWSetupResumePaneAt(support)==DWSetupPaneCompositor,@"after the demo, setup reopens at the one step left");
    DWSetupRecordPane(support,DWSetupPaneReady);
    check(DWSetupModeAt(support,NO)==DWSetupDemo,@"recording a later pane keeps the demo choice");

    chmod([support stringByAppendingPathComponent:@"setup.plist"].fileSystemRepresentation,0644);
    check(DWSetupModeAt(support,NO)==DWSetupIncomplete,@"a record others could have written is not trusted");
    chmod([support stringByAppendingPathComponent:@"setup.plist"].fileSystemRepresentation,0600);
    [@"not a property list" writeToFile:[support stringByAppendingPathComponent:@"setup.plist"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    chmod([support stringByAppendingPathComponent:@"setup.plist"].fileSystemRepresentation,0600);
    check(DWSetupModeAt(support,NO)==DWSetupIncomplete&&DWSetupResumePaneAt(support)==DWSetupPaneWelcome,@"an unreadable record is setup not done, from the welcome");
    check(DWSetupForget(support)&&DWSetupModeAt(support,NO)==DWSetupIncomplete,@"forgetting setup removes the record");
    check(!DWSetupForget(support),@"forgetting twice finds nothing");

    // Other copies: bundles with Infinify's identifier, never the running one, never anything else.
    NSString *mine=[root stringByAppendingPathComponent:@"Applications/Infinify.app"],*other=[root stringByAppendingPathComponent:@"Home/Applications/Infinify.app"],*foreign=[root stringByAppendingPathComponent:@"Other/Infinify.app"];
    for(NSString *bundle in @[mine,other,foreign]){
        [files createDirectoryAtPath:[bundle stringByAppendingPathComponent:@"Contents"] withIntermediateDirectories:YES attributes:nil error:NULL];
        [@{@"CFBundleIdentifier":bundle==foreign?@"com.example.other":@"com.marengox.infinify"} writeToFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES];
    }
    NSString *missing=[root stringByAppendingPathComponent:@"Nowhere/Infinify.app"];
    NSArray *found=DWSetupOtherCopies(mine,@[mine,other,foreign,missing]);
    check([found isEqual:@[other]],[NSString stringWithFormat:@"another Infinify is found, the running one and a foreign bundle are not (%@)",found]);
    NSString *link=[root stringByAppendingPathComponent:@"Link.app"];[files createSymbolicLinkAtPath:link withDestinationPath:other error:NULL];
    check(DWSetupOtherCopies(mine,@[link]).count==0,@"a symlink is not taken for a copy");
    check([DWSetupCopyCandidates() containsObject:@"/Applications/Infinify.app"]&&DWSetupCopyCandidates().count==2,@"the candidates are the two Applications folders");

    // The login item's job is told by the name launchd gives it.
    unsetenv("XPC_SERVICE_NAME");check(!DWSetupRunningAsLoginItem(),@"no job name: not the login item");
    setenv("XPC_SERVICE_NAME","com.marengox.infinify.agent",1);check(DWSetupRunningAsLoginItem(),@"the agent's label: the login item's job");
    setenv("XPC_SERVICE_NAME","com.example.other",1);check(!DWSetupRunningAsLoginItem(),@"another job: not the login item");

    DWSetupPolicy policy=DWSetupReadPolicy();
    check(policy.known,[NSString stringWithFormat:@"SIP is read (here: SIP %s, boot argument %s, so compositor mode %s)",policy.sipRelaxed?"relaxed":"on",policy.bootArgument?"set":"not set",DWSetupPolicyAllows(policy)?"is possible":"needs Recovery"]);
    DWSetupPolicy shut={.known=YES,.sipRelaxed=YES,.bootArgument=NO};
    check(!DWSetupPolicyAllows(shut),@"SIP relaxed without the boot argument is not enough");

    [files removeItemAtPath:root error:NULL];
    printf("%d checks, %d failed\n",checks,failures);
    return failures?1:0;
} }
