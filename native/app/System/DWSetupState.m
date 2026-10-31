// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation; the policy read is the doctor's own (native/dock-helper/Loader/DWPreflight.h).
#import "DWSetupState.h"
#import "DWOwnerFile.h"
#import "DWPreflight.h"
#import "DWLoginItem.h"
#import <ServiceManagement/ServiceManagement.h>

const NSInteger DWSetupPaneCount=5;
static NSString *const kSetupFile=@"setup.plist";
static NSString *const kBundleIdentifier=@"com.marengox.infinify";
static NSString *const kAgentLabel=@"com.marengox.infinify.agent";
static NSArray<NSString *> *paneNames(void) { return @[@"welcome",@"permissions",@"login",@"compositor",@"ready"]; }

static NSDictionary *readRecord(NSString *directory) {
    NSDictionary *record=DWOwnerFileReadPlist([directory stringByAppendingPathComponent:kSetupFile]);
    return [record[@"version"] isEqual:@1]?record:nil;
}
static BOOL writeRecord(NSString *directory,NSDictionary *record) {
    struct stat st;
    if(lstat(directory.fileSystemRepresentation,&st)!=0){
        if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL])return NO;
    }else if(!S_ISDIR(st.st_mode)||st.st_uid!=getuid())return NO;
    return DWOwnerFileWritePlist([directory stringByAppendingPathComponent:kSetupFile],record);
}

DWSetupMode DWSetupModeAt(NSString *supportDirectory,BOOL compositorAtLogin) {
    if(compositorAtLogin)return DWSetupCompositor;
    return [readRecord(supportDirectory)[@"mode"] isEqual:@"demo"]?DWSetupDemo:DWSetupIncomplete;
}
DWSetupPane DWSetupResumePaneAt(NSString *supportDirectory) {
    NSDictionary *record=readRecord(supportDirectory);
    if([record[@"mode"] isEqual:@"demo"])return DWSetupPaneCompositor;
    NSUInteger index=[paneNames() indexOfObject:record[@"pane"]?:@""];
    return index==NSNotFound?DWSetupPaneWelcome:(DWSetupPane)index;
}
BOOL DWSetupRecordPane(NSString *supportDirectory,DWSetupPane pane) {
    if(pane<0||pane>=DWSetupPaneCount)return NO;
    NSMutableDictionary *record=[readRecord(supportDirectory)?:@{} mutableCopy];
    record[@"version"]=@1;record[@"pane"]=paneNames()[(NSUInteger)pane];
    return writeRecord(supportDirectory,record);
}
BOOL DWSetupRecordDemo(NSString *supportDirectory) {
    return writeRecord(supportDirectory,@{@"version":@1,@"mode":@"demo",@"pane":paneNames()[DWSetupPaneCompositor]});
}
BOOL DWSetupForget(NSString *supportDirectory) {
    return DWOwnerFileRemove([supportDirectory stringByAppendingPathComponent:kSetupFile]);
}

DWSetupPolicy DWSetupReadPolicy(void) {
    uint32_t config=0;int preview=0;
    int result=dw_preflight(&config,&preview);
    return (DWSetupPolicy){.known=result>=0,.sipRelaxed=(config&0x06)==0x06,.bootArgument=preview!=0};
}

NSArray<NSString *> *DWSetupCopyCandidates(void) {
    return @[@"/Applications/Infinify.app",[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Infinify.app"]];
}
NSArray<NSString *> *DWSetupOtherCopies(NSString *runningBundle,NSArray<NSString *> *candidates) {
    struct stat running;BOOL known=stat(runningBundle.fileSystemRepresentation,&running)==0;
    NSMutableArray<NSString *> *others=[NSMutableArray array];
    for(NSString *candidate in candidates){
        struct stat st;
        if(lstat(candidate.fileSystemRepresentation,&st)!=0||!S_ISDIR(st.st_mode))continue;
        if(known&&st.st_dev==running.st_dev&&st.st_ino==running.st_ino)continue;
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[candidate stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if([info[@"CFBundleIdentifier"] isEqual:kBundleIdentifier])[others addObject:candidate];
    }
    return others;
}

BOOL DWSetupRunningAsLoginItem(void) {
    const char *job=getenv("XPC_SERVICE_NAME");
    return job&&!strcmp(job,kAgentLabel.UTF8String);
}

int DWSetupHandOverToCompositor(BOOL byHand) {
    BOOL agentOn=[SMAppService agentServiceWithPlistName:DWLoginItemAgentPlist].status==SMAppServiceStatusEnabled;
    if(!byHand&&agentOn&&!DWSetupRunningAsLoginItem()){
        // A process of this name would make the login item's launcher stop at "already running": this one becomes launchctl first.
        NSString *target=[NSString stringWithFormat:@"gui/%u/%@",getuid(),kAgentLabel];
        char *arguments[]={"launchctl","kickstart",(char *)target.UTF8String,NULL};
        execv("/bin/launchctl",arguments);perror("Infinify: launchctl kickstart");return 69;
    }
    NSString *launcher=[NSBundle.mainBundle pathForResource:@"launch" ofType:@"sh" inDirectory:@"NativeDesktop"];
    if(!launcher||![NSFileManager.defaultManager isExecutableFileAtPath:launcher]){fputs("Infinify: the bundled native launcher is missing; reinstall the complete app.\n",stderr);return 69;}
    // Run by hand there is no terminal either: the launcher hands a refusal back to the assistant, as it does at login.
    if(byHand)setenv("INFINIFY_LAUNCH_FROM_SETUP","1",1);
    char *arguments[]={(char *)launcher.fileSystemRepresentation,byHand?NULL:"--login",NULL};
    execv(arguments[0],arguments);perror("Infinify: native desktop launcher");return 69;
}
