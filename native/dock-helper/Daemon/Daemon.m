// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
// infinify-loadd: the launch daemon that lets the signed Infinify app load its Dock payload without a password.
//
//   loadd daemon   run as the launch daemon the app registers with SMAppService
//                  (Contents/Library/LaunchDaemons/com.marengox.infinify.loader.plist), answering `ping` and
//                  `load` over XPC for the app alone: same team, Infinify's bundle identifier, the console user
//   loadd status   read-only: the team this daemon is signed by and the digests built into it
//
// Copied from Sunlight, https://github.com/spacefarm-digital/sunlight, commit afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT,
// Copyright (c) 2026 spacefarm; notice in native/app/Resources/SUNLIGHT-NOTICE.txt), upstream path LiveWindows/helper.m, which is itself
// adapted from yabai's src/sa.m (https://github.com/asmvik/yabai, MIT, Copyright (c) 2019 Asmund Vikane; notice in
// native/app/Resources/YABAI-NOTICE.txt). Copied verbatim:
//   lines 93-112   runCapturing
//   lines 43, 114-148   kDockPath, consoleUID, consoleUser, dockPID
//   lines 386-408  ownTeam, ownPath
// Copied with edits:
//   lines 410-460  `Daemon` (the class, its listener check, runCommand, exitWhenIdle) and
//   lines 462-478  `daemonMain`
//     - the protocol is InfinifyLoaderXPC (DWLoaddRequest.h) and takes the command's arguments as well (Sunlight's two commands take none);
//     - the commands are `ping` and `load`, checked by DWLoadRefusal (DWLoaddRequest.m) before anything runs;
//     - the child is not the daemon's own executable but the bundled loader-arm64e, run from a root-owned copy whose
//       bytes were checked against the digest built into this daemon;
//     - the Dock opens a root-owned copy of the bundled payload that the daemon stages below /private/var/run, checked against the
//       digest built into the daemon, never a file in the caller's runtime (added; DWLoaddRequest.m DWLoadStagePayload, DWStagedPayload.h);
//     - the requirement comes from DWLoadCallerRequirement and the caller must also be the console user (added), run with the
//       hardened runtime, without get-task-allow and without a DYLD_* environment (added; DWLoadCallerRefusal, checked on every message);
//     - the queue label, the Mach service and the messages carry Infinify's names (DWLoaddRequest.m).
// Not taken: the add-on installation, `unload`, `bootarg`, `status`'s SIP and boot-argument report, the socket probe
// (lines 46-91, 150-378, 480-492): Infinify's launcher reports SIP and the boot policy through the doctor and loads
// through the loader it already has.
//
// Everything the daemon does for a caller, it does with the checks native-desktop-launcher.sh and loader-arm64e already
// make (Dock identity pinning, private runtime, nonce, journal handoff); it adds none that loosen them.
#include <Foundation/Foundation.h>
#include <Security/Security.h>
#include <libproc.h>
#include <os/log.h>
#include <sys/stat.h>
#include <pwd.h>
#include <signal.h>
#include <unistd.h>
#include "DWLoaddRequest.h"

// Built in by scripts/build-privileged.sh from the loader and payload it has just signed. A daemon built without them
// refuses to load anything.
#ifndef INFINIFY_LOADER_SHA256
#define INFINIFY_LOADER_SHA256 ""
#endif
#ifndef INFINIFY_PAYLOAD_SHA256
#define INFINIFY_PAYLOAD_SHA256 ""
#endif

static const char kDockPath[] = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";

/// Runs a command and hands back its exit status, with stdout and stderr in `output`.
static int runCapturing(NSString *path, NSArray<NSString *> *arguments, NSString **output)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (output) *output = error.localizedDescription;
        return -1;
    }
    // Read before waiting: a full pipe would otherwise hold the child up forever.
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return task.terminationStatus;
}

/// The console user's uid: whose Dock this is, and who the socket is named after. As root (sudo, the
/// app's administrator prompt, or the launch daemon) that isn't the helper's own user.
static uid_t consoleUID(void)
{
    struct stat console;
    return stat("/dev/console", &console) == 0 ? console.st_uid : getuid();
}

static const char *consoleUser(void)
{
    struct passwd *pw = getpwuid(consoleUID());
    return pw ? pw->pw_name : NULL;
}

/// The console user's Dock, by executable path and owner; 0 when there's none (between a Dock exiting
/// and launchd starting the next one).
static pid_t dockPID(void)
{
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 0;
    pid_t *pids = calloc((size_t)count + 64, sizeof(pid_t));
    count = proc_listallpids(pids, (int)(((size_t)count + 64) * sizeof(pid_t)));
    uid_t owner = consoleUID();
    pid_t found = 0;
    for (int i = 0; i < count && !found; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        struct proc_bsdshortinfo info;
        if (pids[i] <= 0 || proc_pidpath(pids[i], path, sizeof(path)) <= 0 || strcmp(path, kDockPath) != 0) continue;
        if (proc_pidinfo(pids[i], PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) && info.pbsi_uid == owner) {
            found = pids[i];
        }
    }
    free(pids);
    return found;
}

/// The team this helper is signed by; nil when ad-hoc. Callers must share it.
static NSString *ownTeam(void)
{
    SecCodeRef code = NULL;
    SecStaticCodeRef staticCode = NULL;
    CFDictionaryRef info = NULL;
    NSString *team = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess
        && SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &staticCode) == errSecSuccess
        && SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info) == errSecSuccess) {
        team = [((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoTeamIdentifier] copy];
    }
    if (info) CFRelease(info);
    if (staticCode) CFRelease(staticCode);
    if (code) CFRelease(code);
    return team;
}

static NSString *ownPath(void)
{
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(getpid(), path, sizeof(path)) > 0 ? @(path) : nil;
}

// MARK: Launch daemon

/// The directory of the loader and payload next to this executable: Contents/Resources/NativeDesktop of the bundle
/// the daemon was registered from. Nil when the executable is not at that place of an Infinify.app.
static NSString *nativeDirectory(void)
{
    NSString *path = ownPath();
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![path.lastPathComponent isEqualToString:@"loadd"] || ![directory hasSuffix:@"/Infinify.app/Contents/Resources/NativeDesktop"]) return nil;
    return directory;
}

static NSDictionary *ownDigests(void)
{
    return @{@"loader": @INFINIFY_LOADER_SHA256, @"payload": @INFINIFY_PAYLOAD_SHA256};
}

/// Reads a `[pid, birth_sec, birth_usec]` triple from three decimal arguments.
static BOOL parseIdentity(NSArray<NSString *> *arguments, NSUInteger at, pid_t *pid, unsigned long long *sec, unsigned long long *usec)
{
    *pid = (pid_t)strtoul(arguments[at].UTF8String, NULL, 10);
    *sec = strtoull(arguments[at + 1].UTF8String, NULL, 10);
    *usec = strtoull(arguments[at + 2].UTF8String, NULL, 10);
    return *pid > 1;
}

/// The Dock's process start, as the loader reads it, for the pinned comparison below.
static BOOL processBirth(pid_t pid, unsigned long long *sec, unsigned long long *usec)
{
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_pid != (uint32_t)pid) return false;
    *sec = info.pbi_start_tvsec;
    *usec = info.pbi_start_tvusec;
    return true;
}

/// Removes the staged payload just made (and a sidecar, if one is there) and its directory: only for a load that never reached the Dock.
static void dropStaged(NSString *staged)
{
    unlink(staged.fileSystemRepresentation);
    unlink([staged stringByAppendingString:@".json"].fileSystemRepresentation);
    rmdir(staged.stringByDeletingLastPathComponent.fileSystemRepresentation);
}

/// `load`: the bundled loader's --inject-dock, with the arguments the launcher built (less the payload, which is this
/// daemon's to name). Nothing the login user can write is executed as root or opened by the Dock:
///  - the loader runs from a copy this daemon makes in a directory only root can enter, after checking its bytes against the
///    digest built into the daemon;
///  - the Dock opens a copy of the bundled payload that this daemon makes below /private/var/run, in a root-owned 0755
///    directory holding one root-owned 0644 file (DWLoaddRequest.m DWLoadStagePayload; the rule is DWStagedPayload.h's), after
///    checking its bytes against the digest built into the daemon and reading the copy back. The runtime's own payload, the
///    user's, is never read, and the bundle's file is read once: the bytes hashed are the bytes written.
/// DWLoader.m refuses an injection whose payload does not meet the same rule, so a daemon that staged wrongly loads nothing.
static int loadDesktop(NSArray<NSString *> *arguments, NSString **output)
{
    NSString *why = nil;
    NSString *native = nativeDirectory();
    if (!native) {
        *output = @"infinify-loadd: this daemon is not running from Contents/Resources/NativeDesktop of an Infinify.app\n";
        return 70;
    }
    NSData *loader = nil, *payload = nil;
    if (!DWLoadVerifyArtifacts(native, @INFINIFY_LOADER_SHA256, @INFINIFY_PAYLOAD_SHA256, &loader, &payload, &why)) {
        *output = [NSString stringWithFormat:@"infinify-loadd: %@\n", why];
        return 70;
    }
    pid_t pid = 0;
    unsigned long long sec = 0, usec = 0, nowSec = 0, nowUsec = 0;
    parseIdentity(arguments, 5, &pid, &sec, &usec);
    if (dockPID() != pid || !processBirth(pid, &nowSec, &nowUsec) || nowSec != sec || nowUsec != usec) {
        *output = @"infinify-loadd: the Dock is not the process the launcher pinned\n";
        return 71;
    }
    NSString *runtime = arguments[0], *staged = nil;
    if (!DWLoadStagePayload(DWLoadStagedRoot, runtime, payload, @INFINIFY_PAYLOAD_SHA256, 0, consoleUID(), &staged, &why)) {
        *output = [NSString stringWithFormat:@"infinify-loadd: %@\n", why];
        return 72;
    }
    char directory[] = "/var/run/infinify-loadd.XXXXXX";
    if (!mkdtemp(directory)) {
        *output = @"infinify-loadd: couldn't make a private directory for the loader\n";
        dropStaged(staged);
        return 72;
    }
    NSString *copy = [@(directory) stringByAppendingPathComponent:@"loader-arm64e"];
    int status = 72;
    if ([loader writeToFile:copy atomically:NO] && chmod(copy.fileSystemRepresentation, 0700) == 0) {
        // The copy, not the bundle, is what runs: it must read back as the bytes that were checked.
        NSString *copied = DWLoadFileSHA256(copy, 16u << 20, NULL);
        if ([copied isEqualToString:@INFINIFY_LOADER_SHA256]) {
            NSMutableArray<NSString *> *loaderArguments = [NSMutableArray arrayWithObjects:@"--inject-dock", staged, nil];
            [loaderArguments addObjectsFromArray:arguments];
            status = runCapturing(copy, loaderArguments, output);
        } else {
            *output = @"infinify-loadd: the loader copy does not read back as the checked bytes\n";
        }
    } else {
        *output = @"infinify-loadd: couldn't write the loader copy\n";
    }
    unlink(copy.fileSystemRepresentation);
    rmdir(directory);
    struct stat sidecar;
    NSString *sidecarPath = [staged stringByAppendingString:@".json"];
    if (status == 0) {
        // Ready: the Dock has the payload mapped. The copy stays (the launcher checks it on a reuse, and its sidecar is the
        // provenance of a later recovery) until the next successful load, which drops the staged copies of earlier runtimes.
        DWLoadPruneStaged(DWLoadStagedRoot, runtime, 0, consoleUID());
    } else if (lstat(sidecarPath.fileSystemRepresentation, &sidecar) != 0) {
        // The loader removes its sidecar only when it never began executing in the Dock (and never made one when it refused
        // early), so the Dock cannot open the copy: nothing refers to it.
        dropStaged(staged);
    }
    // Otherwise execution began and the outcome is unknown: the remote thread may still dlopen the copy, so it stays, as the
    // loader leaves its sidecar and allocations, until the owner has inspected the pending launch record.
    return status;
}

/// NSXPCConnection's audit token: the kernel's identity of the peer (pid and pid version, so an exec or a reused pid is another
/// token), which Security turns into the live process's code. It is not in the public header; Apple's own sample code and the
/// helpers of every signed installer read it. A system without it refuses every caller.
@interface NSXPCConnection (InfinifyAudit)
@property (readonly) audit_token_t auditToken;
@end

@interface Daemon : NSObject <NSXPCListenerDelegate, InfinifyLoaderXPC>
@property (copy) NSString *requirement;
@end

@implementation Daemon {
    dispatch_queue_t _queue;
    NSUInteger _generation;
}

- (instancetype)init
{
    if ((self = [super init])) _queue = dispatch_queue_create("com.marengox.infinify.loader", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    // The caller must be the console user's: another user's copy of the app is not asked to load into this Dock.
    if (connection.effectiveUserIdentifier != consoleUID()) return NO;
    // The system checks the caller's signature on every message, not once at connect.
    [connection setCodeSigningRequirement:self.requirement];
    // And the app must run with the hardened runtime and without get-task-allow, so that a process of the same user cannot
    // inject into it and speak with its identity (checked again for every request, below).
    NSString *signature = [connection respondsToSelector:@selector(auditToken)] ? DWLoadCallerRefusal(connection.auditToken) : @"the caller's identity is not available";
    if (signature) {
        // The caller is told nothing but that the connection failed; the reason is for the owner, in the unified log.
        os_log_error(OS_LOG_DEFAULT, "infinify-loadd: refused a connection from pid %d: %{public}@", connection.processIdentifier, signature);
        return NO;
    }
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(InfinifyLoaderXPC)];
    [interface setClasses:[NSSet setWithObjects:NSArray.class, NSString.class, nil]
              forSelector:@selector(runCommand:arguments:reply:) argumentIndex:1 ofReply:NO];
    connection.exportedInterface = interface;
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

/// One command at a time, each in a child process of this helper, so its output can go back to the app
/// and a crash in one doesn't take the daemon with it.
- (void)runCommand:(NSString *)command arguments:(NSArray<NSString *> *)arguments reply:(void (^)(int, NSString *))reply
{
    NSXPCConnection *caller = NSXPCConnection.currentConnection;
    NSString *signature = [caller respondsToSelector:@selector(auditToken)] ? DWLoadCallerRefusal(caller.auditToken) : @"the caller's identity is not available";
    if (signature) {
        os_log_error(OS_LOG_DEFAULT, "infinify-loadd: refused a request from pid %d: %{public}@", caller.processIdentifier, signature);
        reply(65, [NSString stringWithFormat:@"infinify-loadd: %@\n", signature]);
        return;
    }
    NSString *refusal = DWLoadRefusal(command, arguments);
    if (refusal) {
        reply(64, [NSString stringWithFormat:@"infinify-loadd: %@\n", refusal]);
        return;
    }
    dispatch_async(_queue, ^{
        NSString *output = nil;
        int status;
        if ([command isEqualToString:@"ping"]) {
            output = [NSString stringWithFormat:@"infinify-loadd: answering for a hardened-runtime %@ (loader %@, payload %@)\n", self.requirement, ownDigests()[@"loader"], ownDigests()[@"payload"]];
            status = 0;
        } else {
            status = loadDesktop(arguments, &output);
        }
        reply(status, output ?: @"infinify-loadd: no output\n");
        [self exitWhenIdle];
    });
}

/// launchd starts the daemon again on the next request, so it doesn't stay around between Dock restarts.
- (void)exitWhenIdle
{
    NSUInteger generation = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), _queue, ^{
        if (self->_generation == generation) exit(0);
    });
}
@end

static int daemonMain(void)
{
    NSString *team = ownTeam();
    NSString *requirement = DWLoadCallerRequirement(team);
    if (!requirement) {
        fprintf(stderr, "infinify-loadd: the daemon needs a team signature to know which app to answer\n");
        return 1;
    }
    Daemon *daemon = [[Daemon alloc] init];
    daemon.requirement = requirement;
    NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:DWLoadMachService];
    listener.delegate = daemon;
    [listener resume];
    [daemon exitWhenIdle];
    [NSRunLoop.currentRunLoop run];
    return 0;
}

/// Read-only: what this daemon is signed by and built with.
static int status(void)
{
    NSString *team = ownTeam();
    printf("Team: %s\n", team.length ? team.UTF8String : "none (ad-hoc)");
    printf("Caller requirement: %s\n", DWLoadCallerRequirement(team).UTF8String ?: "none");
    printf("Loader SHA-256: %s\n", INFINIFY_LOADER_SHA256);
    printf("Payload SHA-256: %s\n", INFINIFY_PAYLOAD_SHA256);
    NSString *native = nativeDirectory();
    printf("NativeDesktop: %s\n", native.UTF8String ?: "not in an Infinify.app bundle");
    printf("Console user: %s\n", consoleUser() ?: "none");
    printf("Console user's Dock: %d\n", dockPID());
    return 0;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const char *command = argc > 1 ? argv[1] : "";
        if (!strcmp(command, "daemon")) return daemonMain();
        if (!strcmp(command, "status")) return status();
        fprintf(stderr, "usage: loadd daemon | status\n");
        return 64;
    }
}
