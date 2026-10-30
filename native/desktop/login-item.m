// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation over SMAppService (macOS 13+). The agent's program is the bundle's
// own executable (BundleProgram), so the registration follows the bundle it was made from.
#import "login-item.h"
#import <ServiceManagement/ServiceManagement.h>

NSString *const DWLoginItemAgentPlist=@"com.marengox.infinify.agent.plist";
NSString *const DWLoginItemsPane=@"System Settings > General > Login Items & Extensions";
void DWLoginItemWarnIfOutsideApplications(const char *who) {
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    if(![bundle.pathComponents containsObject:@"Applications"])fprintf(stderr,"%s: registering the bundle at %s, which is not in an Applications folder; scripts/install-app.sh installs one.\n",who,bundle.fileSystemRepresentation);
}
static int report(SMAppServiceStatus status) {
    switch(status){
        case SMAppServiceStatusEnabled:puts("login item: on");return 0;
        case SMAppServiceStatusNotRegistered:puts("login item: off");return 0;
        case SMAppServiceStatusRequiresApproval:printf("login item: registered, waiting for approval: allow Infinify under %s\n",DWLoginItemsPane.UTF8String);return 0;
        // What macOS answers for an agent it has never been told of, the bundle carrying its property list or not.
        case SMAppServiceStatusNotFound:puts("login item: off (never registered from this bundle)");return 0;
    }
    printf("login item: unknown status %ld\n",(long)status);return 0;
}
int DWLoginItemCommand(int argc,const char **argv) { @autoreleasepool {
    BOOL on=argc==1&&!strcmp(argv[0],"on"),off=argc==1&&!strcmp(argv[0],"off");
    if(!on&&!off&&!(argc==1&&!strcmp(argv[0],"status"))){fputs("usage: Infinify login-item on | off | status\n",stderr);return 64;}
    SMAppService *service=[SMAppService agentServiceWithPlistName:DWLoginItemAgentPlist];
    if(!on&&!off)return report(service.status);
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    if(![NSFileManager.defaultManager fileExistsAtPath:[[bundle stringByAppendingPathComponent:@"Contents/Library/LaunchAgents"]stringByAppendingPathComponent:DWLoginItemAgentPlist]]){
        fprintf(stderr,"login item: %s carries no LaunchAgent. Run the installed bundle's own executable, ~/Applications/Infinify.app/Contents/MacOS/Infinify (scripts/install-app.sh puts it there).\n",bundle.fileSystemRepresentation);return 1;}
    // Already as asked: macOS answers a second registration, and the removal of none, with an error. None is also what it
    // answers "not found" for: an agent this bundle never registered.
    SMAppServiceStatus status=service.status;
    if(on&&status==SMAppServiceStatusEnabled)return report(status);
    if(off&&(status==SMAppServiceStatusNotRegistered||status==SMAppServiceStatusNotFound))return report(status);
    // The registration names this bundle where it is. One left in a build directory is replaced by every build, and an ad hoc signature loses the privacy grants with it.
    if(on)DWLoginItemWarnIfOutsideApplications("login item");
    NSError *error=nil;
    if(!(on?[service registerAndReturnError:&error]:[service unregisterAndReturnError:&error])){
        fprintf(stderr,"login item: %s: %s\n",on?"not registered":"not unregistered",(error.localizedDescription?:@"macOS gave no reason").UTF8String);
        if(on&&service.status==SMAppServiceStatusRequiresApproval)fprintf(stderr,"login item: allow Infinify under %s, then run this again.\n",DWLoginItemsPane.UTF8String);
        return 1;}
    return report(service.status);
} }
