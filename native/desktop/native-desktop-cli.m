// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation over SMAppService, the bundled launcher and the launch daemon's XPC (loader-service.m).
#import "native-desktop-cli.h"
#import "loader-service.h"
#import "login-item.h"
#import "dock-reload.h"
#import "owner-file.h"
#import "loadd-request.h"
#import <ServiceManagement/ServiceManagement.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const kLoginFile=@"login.plist";

static NSString *launcherPath(void) {
    NSString *launcher=[NSBundle.mainBundle pathForResource:@"launch" ofType:@"sh" inDirectory:@"NativeDesktop"];
    return launcher&&[NSFileManager.defaultManager isExecutableFileAtPath:launcher]?launcher:nil;
}
static NSString *manifestPayloadSHA(void) {
    NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Resources/NativeDesktop/manifest.plist"];
    NSDictionary *manifest=[NSDictionary dictionaryWithContentsOfFile:path];
    NSString *sha=manifest[@"artifacts"][@"payload"][@"sha256"];
    return [sha isKindOfClass:NSString.class]?sha:nil;
}
static BOOL stateDirectory(NSString *directory) {
    struct stat st;
    if(lstat(directory.fileSystemRepresentation,&st)==0)return S_ISDIR(st.st_mode)&&st.st_uid==getuid()&&(st.st_mode&07777)==0700;
    NSError *error=nil;
    return [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
}

// The login-mode record: login.plist in the state directory, written by `enable` and read by `login-start`.
BOOL DWNativeWriteLoginRecord(NSString *directory,BOOL agentAdded) {
    if(!stateDirectory(directory))return NO;
    return DWOwnerFileWritePlist([directory stringByAppendingPathComponent:kLoginFile],@{@"version":@1,@"mode":@"compositor",@"agent_added":@(agentAdded)});
}
NSDictionary *DWNativeReadLoginRecord(NSString *directory) {
    NSDictionary *record=DWOwnerFileReadPlist([directory stringByAppendingPathComponent:kLoginFile]);
    return [record[@"version"] isEqual:@1]&&[record[@"mode"] isEqual:@"compositor"]?record:nil;
}
BOOL DWNativeRemoveLoginRecord(NSString *directory) { return DWOwnerFileRemove([directory stringByAppendingPathComponent:kLoginFile]); }
BOOL DWNativeLoginIsCompositor(void) { return DWNativeReadLoginRecord(DWDockReloadStateDirectory())!=nil; }

static int execLauncher(NSString *launcher,const char *argument) {
    char *arguments[]={(char *)launcher.fileSystemRepresentation,(char *)argument,NULL};
    execv(arguments[0],arguments);perror("Infinify: native desktop launcher");return 69;
}
static int runLauncher(NSString *launcher,const char *argument) {
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:launcher];task.arguments=@[@(argument)];
    NSError *error=nil;
    if(![task launchAndReturnError:&error]){fprintf(stderr,"Infinify: %s\n",error.localizedDescription.UTF8String);return 69;}
    [task waitUntilExit];return task.terminationStatus;
}
static const char *agentWord(SMAppServiceStatus status) {
    switch(status){
        case SMAppServiceStatusEnabled:return "on";
        case SMAppServiceStatusRequiresApproval:return "registered, waiting for approval";
        case SMAppServiceStatusNotRegistered:case SMAppServiceStatusNotFound:return "off";
    }
    return "unknown";
}
static NSString *plistValue(NSString *path,NSString *key) {
    NSDictionary *record=[NSDictionary dictionaryWithContentsOfFile:path];
    id value=record[key];return [value isKindOfClass:NSString.class]?value:value?[value description]:nil;
}

static int status(void) {
    NSString *directory=DWDockReloadStateDirectory(),*payload=manifestPayloadSHA();
    NSDictionary *login=DWNativeReadLoginRecord(directory);
    printf("compositor mode at login: %s\n",login?"enabled":"disabled");
    printf("login item: %s\n",agentWord([SMAppService agentServiceWithPlistName:DWLoginItemAgentPlist].status));
    printf("launch daemon: %s\n",[DWLoaderService describe:[DWLoaderService state]].UTF8String);
    BOOL paused=payload&&DWDockReloadPaused(directory,payload);
    printf("automatic Dock reload: %s\n",paused?"paused after Dock restarts around loads; run Infinify native-desktop by hand to lift it":"ready");
    NSString *record=[directory stringByAppendingPathComponent:@"launch.plist"],*pending=[directory stringByAppendingPathComponent:@"launch.pending.plist"];
    BOOL hasPending=access(pending.fileSystemRepresentation,F_OK)==0;
    if(hasPending)printf("launch record: a launch or recovery is pending (%s); the launcher refuses to load until it is inspected\n",pending.fileSystemRepresentation);
    else if(access(record.fileSystemRepresentation,F_OK)==0)printf("launch record: %s, Dock %s\n",(plistValue(record,@"outcome")?:@"unreadable").UTF8String,(plistValue(record,@"dock_pid")?:@"?").UTF8String);
    else printf("launch record: none\n");
    NSString *log=[directory stringByAppendingPathComponent:@"login.log"];
    if(access(log.fileSystemRepresentation,F_OK)==0)printf("login start log: %s\n",log.fileSystemRepresentation);
    return 0;
}

static int enable(void) {
    NSString *launcher=launcherPath(),*directory=DWDockReloadStateDirectory();
    if(!launcher){fputs("Infinify: the bundled native launcher is missing; rebuild or reinstall the complete app.\n",stderr);return 69;}
    DWLoginItemWarnIfOutsideApplications("native-desktop enable");
    fputs("Checking the bundle and the boot policy (read-only)...\n",stdout);fflush(stdout);
    if(runLauncher(launcher,"--check")!=0){fputs("native-desktop enable: the check failed; nothing was registered.\n",stderr);return 1;}
    DWLoaderState state=[DWLoaderService state];
    if(state==DWLoaderUnavailable){fprintf(stderr,"native-desktop enable: launch daemon: %s\nCompositor mode can still be started by hand with Infinify native-desktop.\n",[DWLoaderService describe:state].UTF8String);return 1;}
    if(state==DWLoaderNotRegistered||state==DWLoaderNeedsApproval)state=[DWLoaderService registerDaemon];
    if(state==DWLoaderNeedsApproval){
        printf("Approve Infinify once under %s (the pane is open); waiting up to three minutes...\n",DWLoginItemsPane.UTF8String);fflush(stdout);
        for(int waited=0;waited<180&&state==DWLoaderNeedsApproval;waited+=2){sleep(2);state=[DWLoaderService state];}
    }
    if(state!=DWLoaderEnabled){fprintf(stderr,"native-desktop enable: launch daemon: %s\nRun this again once it is approved.\n",[DWLoaderService describe:state].UTF8String);return 1;}
    NSString *reply=nil;
    int pinged=[DWLoaderService run:@"ping" arguments:@[] timeout:30 output:&reply];
    if(pinged!=0){fprintf(stderr,"native-desktop enable: the launch daemon does not answer this app: %s\n",reply.UTF8String);return 1;}
    fputs("The launch daemon answers.\n",stdout);
    // The marker first: registering the login item below starts it at once.
    SMAppService *agent=[SMAppService agentServiceWithPlistName:DWLoginItemAgentPlist];
    BOOL agentWasOn=agent.status==SMAppServiceStatusEnabled;
    NSDictionary *previous=DWNativeReadLoginRecord(directory);
    BOOL added=agentWasOn?[previous[@"agent_added"] boolValue]:YES;
    if(!DWNativeWriteLoginRecord(directory,added)){fputs("native-desktop enable: could not write the login-mode record.\n",stderr);return 1;}
    DWDockReloadResume(directory);
    if(!agentWasOn){
        const char *on[]={"on"};
        if(DWLoginItemCommand(1,on)!=0){DWNativeRemoveLoginRecord(directory);fputs("native-desktop enable: the login item was not registered; the login-mode record was removed again.\n",stderr);return 1;}
    }else fputs("login item: already on; the running instance keeps its mode until it restarts (launchctl kickstart -k gui/$(id -u)/com.marengox.infinify.agent).\n",stdout);
    puts("compositor mode at login: enabled. It starts at the next login, loads the Dock payload through the launch daemon, and reloads it after a Dock restart.");
    return 0;
}

static int disable(void) {
    NSString *directory=DWDockReloadStateDirectory();
    NSDictionary *login=DWNativeReadLoginRecord(directory);
    BOOL added=[login[@"agent_added"] boolValue];
    DWNativeRemoveLoginRecord(directory);
    DWDockReloadResume(directory);
    int result=0;
    if(added){const char *off[]={"off"};result=DWLoginItemCommand(1,off);}
    else if(login)puts("login item: left as it was before enable (it was already on).");
    [DWLoaderService unregister];
    printf("launch daemon: %s\n",[DWLoaderService describe:[DWLoaderService state]].UTF8String);
    puts("compositor mode at login: disabled. An instance running now is not stopped (Infinify msg action quit); launch records and journals are left as the launcher keeps them.");
    return result;
}

// The launcher's way to the launch daemon. `status` prints the daemon's state and succeeds only when it is enabled. `staged RUNTIME`
// is read-only and talks to nobody: it prints "DIRECTORY SHA256" of the payload the daemon staged for that runtime (loadd-request.m's
// rule: root's copy, in root's directory, below directories only root writes), and fails when there is none or it fails the rule.
static int daemonCommand(int argc,const char **argv) {
    if(argc==2&&!strcmp(argv[0],"staged")){
        NSString *directory=nil,*why=nil;
        NSString *digest=DWLoadStagedPayloadDigest(DWLoadStagedRoot,@(argv[1]),0,getuid(),&directory,&why);
        if(!digest){fprintf(stderr,"no staged payload for %s: %s\n",argv[1],(why?:@"unknown").UTF8String);return 1;}
        printf("%s %s\n",directory.UTF8String,digest.UTF8String);
        return 0;
    }
    if(argc>=1&&!strcmp(argv[0],"status")&&argc==1){
        DWLoaderState state=[DWLoaderService state];
        puts(state==DWLoaderEnabled?"enabled":state==DWLoaderNeedsApproval?"needs-approval":state==DWLoaderNotRegistered?"not-registered":"unavailable");
        return state==DWLoaderEnabled?0:1;
    }
    BOOL ping=argc==1&&!strcmp(argv[0],"ping"),load=argc>=2&&!strcmp(argv[0],"load");
    if(!ping&&!load){fputs("usage: Infinify native-desktop daemon status | ping | staged RUNTIME | load RUNTIME LOADER-ARGUMENTS...\n",stderr);return 64;}
    NSMutableArray<NSString *> *arguments=[NSMutableArray array];
    for(int i=1;i<argc;i++)[arguments addObject:@(argv[i])];
    NSString *output=nil;
    int result=[DWLoaderService run:ping?@"ping":@"load" arguments:arguments timeout:90 output:&output];
    fputs(output.UTF8String?:"",result==0?stdout:stderr);
    return result==0?0:result<0||result>125?1:result;
}

int DWNativeDesktopCommand(int argc,const char **argv) { @autoreleasepool {
    if(argc>=1&&!strcmp(argv[0],"daemon"))return daemonCommand(argc-1,argv+1);
    if(argc==1&&!strcmp(argv[0],"enable"))return enable();
    if(argc==1&&!strcmp(argv[0],"disable"))return disable();
    if(argc==1&&!strcmp(argv[0],"status"))return status();
    if(argc>1||(argc==1&&strcmp(argv[0],"--check")&&strcmp(argv[0],"--help")&&strcmp(argv[0],"--login"))){
        fputs("usage: Infinify native-desktop [--check | --help | enable | disable | status]\n",stderr);return 64;
    }
    NSString *launcher=launcherPath();
    if(!launcher){fputs("Infinify: the bundled native launcher is missing; rebuild or reinstall the complete app.\n",stderr);return 69;}
    return execLauncher(launcher,argc?argv[0]:NULL);
} }
