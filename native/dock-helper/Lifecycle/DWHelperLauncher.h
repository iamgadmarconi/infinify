// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWHelperLifecycle.h"
#include <time.h>

// Compiled helper launcher modes invoked by `Infinify native-desktop launcher MODE` after
// `launch.sh` completes its pre-execution bundle/manifest/signature preflight.
// `DWHelperLauncherModeLaunchSetup` represents an owner-triggered launch from the setup
// assistant (`INFINIFY_LAUNCH_FROM_SETUP=1`), which follows `launch` policy while routing
// post-verification refusals back to `Infinify setup --refused REASON`.
typedef NS_ENUM(NSInteger,DWHelperLauncherMode) {
    DWHelperLauncherModeLaunch,
    DWHelperLauncherModeLaunchSetup,
    DWHelperLauncherModeCheck,
    DWHelperLauncherModeLogin,
    DWHelperLauncherModeReload,
};

BOOL DWHelperLauncherParseMode(const char *argument,DWHelperLauncherMode *mode);

// Adapter seam for the compiled launcher. Production binds to the containing app bundle,
// the login user's launch-state directory, real subprocesses (`doctor`, `loader-arm64e`,
// `codesign`, `sudo`, `pgrep`, `native-desktop daemon`), POSIX descriptors and `execv`.
// Tests can supply a temporary-directory / fake-Dock / fake-identity implementation to
// exercise launch-record, pause, nonce/runtime, same-Dock update, Dock restart and
// retired-journal recovery decisions without touching a real Dock or `/var/tmp`.
@protocol DWHelperLauncherEnvironment <DWHelperLifecycleEnvironment>
- (NSString *)bundlePath;
- (NSString *)stateDirectory;
- (uid_t)effectiveUID;
- (pid_t)currentPID;
- (pid_t)parentPID;
- (BOOL)isAppleSiliconDarwin;
- (int)readMacOSProductVersion:(NSString *__autoreleasing *)version;
- (BOOL)stdinIsTerminal;
- (time_t)currentEpochSeconds;
- (void)sleepSeconds:(unsigned int)seconds;
- (BOOL)randomBytes:(void *)buffer length:(size_t)length;
- (NSArray<NSNumber *> *)runningInfinifyPIDsForUID:(uid_t)uid includeAncestors:(BOOL)includeAncestors failed:(BOOL *)failed;
- (BOOL)verifyCodeSignatureAtPath:(NSString *)logicalPath deep:(BOOL)deep;
- (int)runDoctorAtPath:(NSString *)logicalDoctorPath output:(NSString *__autoreleasing *)output;
- (int)runLoaderDockIdentityAtPath:(NSString *)logicalLoaderPath output:(NSString *__autoreleasing *)output;
- (int)runLoaderPayloadIdentity:(NSString *)logicalPayloadPath loaderPath:(NSString *)logicalLoaderPath output:(NSString *__autoreleasing *)output;
- (int)runLoaderRestartDockPID:(pid_t)pid birthSec:(uint64_t)sec birthUsec:(uint64_t)usec loaderPath:(NSString *)logicalLoaderPath;
- (BOOL)daemonEnabledWithStatusText:(NSString *__autoreleasing *)statusText appPath:(NSString *)logicalAppPath;
- (BOOL)pingDaemonWithAppPath:(NSString *)logicalAppPath;
- (BOOL)stagedPayloadForRuntime:(NSString *)runtime appPath:(NSString *)logicalAppPath directory:(NSString *__autoreleasing *)directory sha256:(NSString *__autoreleasing *)sha256;
- (int)runDaemonLoadWithArguments:(NSArray<NSString *> *)arguments appPath:(NSString *)logicalAppPath;
- (BOOL)authorizeSudo;
- (int)runSudoLoaderAtPath:(NSString *)logicalLoaderPath payloadPath:(NSString *)logicalPayloadPath arguments:(NSArray<NSString *> *)arguments;
- (void)writeStdout:(NSString *)text;
- (void)writeStderr:(NSString *)text;
- (BOOL)writeReloadEndpoint:(NSString *)line;
- (int)execSetupRefused:(NSString *)reason appPath:(NSString *)logicalAppPath fallbackStatus:(int)fallbackStatus;
- (int)execDesktopAppAtPath:(NSString *)logicalAppPath runtime:(NSString *)runtime nonceFile:(NSString *)nonceFile
              daemonEnabled:(BOOL)daemonEnabled payloadSHA256:(NSString *)payloadSHA256 loadedAt:(uint64_t)loadedAt;
@end

@interface DWHelperLauncher : NSObject
+ (instancetype)systemLauncher;
- (instancetype)initWithEnvironment:(id<DWHelperLauncherEnvironment>)environment;
- (int)runMode:(DWHelperLauncherMode)mode;
@end

// Production CLI entry point for `Infinify native-desktop launcher MODE` (`argc == 1`, `argv[0] == MODE`).
int DWHelperLauncherMain(int argc,const char *argv[]);
