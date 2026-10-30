// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <mach/message.h>
// What the Infinify launch daemon (Daemon.m) will do for a caller, as plain functions, so that the
// decisions can be read and tested without a root process, an XPC connection or a Dock.
//
// The daemon runs one operation: the bundled loader's `--inject-dock` for the login user's whole
// desktop, exactly as `native-desktop-launcher.sh` runs it under sudo, with the same arguments the
// launcher builds. It never runs the loader with a payload, runtime, journal or Dock the launcher would
// not name, and never in a form the launcher does not use (no unpinned Dock).

// What the app may ask the daemon for, over XPC. Daemon.m implements it; native/app/System/DWLoaderService.m calls it.
@protocol InfinifyLoaderXPC
- (void)runCommand:(NSString *)command arguments:(NSArray<NSString *> *)arguments reply:(void (^)(int status, NSString *output))reply;
@end

// The Mach service the daemon answers on, its launchd label, and the bundle identifier of the one app
// it answers.
extern NSString *const DWLoadMachService;
extern NSString *const DWLoadAppIdentifier;
extern NSString *const DWLoadDaemonPlist;

// The code-signing requirement an XPC caller must meet: Apple's anchor with a developer certificate,
// the app's bundle identifier, and the daemon's own team. nil when `team` is not an Apple team
// identifier (ten capital letters and digits), so that a requirement is never built from a stray string.
NSString *DWLoadCallerRequirement(NSString *team);

// The commands the daemon answers: "ping" (no arguments) and "load" (the loader arguments after
// `--inject-dock`). nil when the request is acceptable, else why not.
NSString *DWLoadRefusal(NSString *command,NSArray<NSString *> *arguments);

// The shapes "load" accepts, which are the launcher's two:
//   RUNTIME --nonce-file NONCE --desktop --expected-dock PID SEC USEC
//   ... and then --recover-journal JOURNAL --expected-retired-dock PID SEC USEC
// RUNTIME is /tmp/if-native.XXXXXX; NONCE is the file the launcher puts in it; JOURNAL is the v2-journal.json of a
// different runtime of the same form. There is no payload argument: the Dock opens the daemon's own root-owned copy of the
// bundled payload (below), never a file the caller can name or write. nil when the arguments are one of them.
NSString *DWLoadArgumentsRefusal(NSArray<NSString *> *arguments);

// Code-signature rules for the XPC caller, on top of the requirement from DWLoadCallerRequirement: the app must run with
// the hardened runtime (the signature carries the flag and the process enforces it), without get-task-allow, and without the
// entitlements that give back what the hardened runtime takes away (DYLD environment variables, unsigned libraries). A
// same-user process cannot then inject code into the running app to borrow its XPC identity. The plain function takes the
// signature's static flags (kSecCodeInfoFlags), the process's dynamic status word (kSecCodeInfoStatus) and its entitlements;
// nil when acceptable.
NSString *DWLoadCallerFlagsRefusal(uint32_t signatureFlags,uint32_t processStatus,NSDictionary *entitlements);
// On a Mac whose SIP debugging restrictions are off, which the Dock injection needs, the hardened runtime does NOT make dyld
// ignore DYLD_* variables (measured on macOS 27.0.1 in the guest and on the development Mac: a hardened-runtime process still
// loaded a DYLD_INSERT_LIBRARIES dylib), so a same-user process could start a genuine, correctly signed Infinify with a dylib
// of its own injected and ask the daemon for a load with its identity. The environment the caller was started with is therefore
// refused too if any variable is DYLD_* (or launchd's __XPC_DYLD_* form). The plain function takes "NAME=value" strings.
NSString *DWLoadCallerEnvironmentRefusal(NSArray<NSString *> *environment);
// The environment a process was started with (the kernel's copy of its argument area), nil if it cannot be read.
NSArray<NSString *> *DWLoadProcessEnvironment(pid_t pid);
// The same, for the live process behind an audit token (an XPC connection's, or a process's own for tests): signature flags,
// status, entitlements and starting environment.
NSString *DWLoadCallerRefusal(audit_token_t token);

// The SHA-256 of a file as lowercase hexadecimal, read through a descriptor opened without following
// a symbolic link; nil for anything but a regular file no larger than `limit`. `bytes` receives what was read.
NSString *DWLoadFileSHA256(NSString *path,NSUInteger limit,NSData *__autoreleasing *bytes);

// Checks the two files the daemon acts on against the digests built into it, so that nothing it runs or
// loads is taken on trust from the app bundle's say-so: the loader and the payload found next to the daemon. On
// success `loader` and `payload` hold the bytes that were hashed, which are what the daemon runs and stages (from copies it makes,
// never from the bundle paths it read them from, which the login user can write).
//   nativeDirectory: the bundle's Contents/Resources/NativeDesktop.
BOOL DWLoadVerifyArtifacts(NSString *nativeDirectory,NSString *loaderSHA256,NSString *payloadSHA256,NSData *__autoreleasing *loader,NSData *__autoreleasing *payload,NSString *__autoreleasing *why);

// The payload the Dock opens. For a load into RUNTIME the daemon makes ROOT/infinify-payload.<RUNTIME's six characters>
// (ROOT is /private/var/run), owned by root and mode 0755, holding the payload as payload-arm64e.dylib, root-owned 0644,
// below directories only root writes; DWStagedPayload.h has the rule, which DWLoader.m enforces before it injects. ROOT, the
// trusted owner (root, the test's own uid in the regression) and the login user are parameters so that the regression can use a
// directory of its own.
extern NSString *const DWLoadStagedRoot;
NSString *DWLoadStagedDirectory(NSString *root,NSString *runtime);
NSString *DWLoadStagedPayloadPath(NSString *root,NSString *runtime);
// Writes `payload` into a new staged directory for `runtime` (never into an existing one), checks that the file reads back
// with `payloadSHA256`, then opens the directory to the Dock (0755) and applies the DWStagedPayload.h rule to the result.
// Nothing is left behind on failure. `path` receives the payload's path.
BOOL DWLoadStagePayload(NSString *root,NSString *runtime,NSData *payload,NSString *payloadSHA256,uid_t trusted,uid_t login,NSString *__autoreleasing *path,NSString *__autoreleasing *why);
// Read-only: the SHA-256 of the payload staged for `runtime`, nil unless it passes the DWStagedPayload.h rule; `directory`
// receives the staged directory, where the payload's sidecar is. The launcher asks for this (through the app) in place of
// looking at the runtime's own copy.
NSString *DWLoadStagedPayloadDigest(NSString *root,NSString *runtime,uid_t trusted,uid_t login,NSString *__autoreleasing *directory,NSString *__autoreleasing *why);
// Removes the staged payloads of other runtimes of the login user (only directories of the trusted owner in the exact form whose
// sidecar, if any, is the login user's; only the payload and its sidecar, then the directory if that leaves it empty). Returns how
// many directories went.
NSUInteger DWLoadPruneStaged(NSString *root,NSString *keepRuntime,uid_t trusted,uid_t login);
