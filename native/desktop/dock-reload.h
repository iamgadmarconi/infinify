// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <sys/types.h>
// Keeps the Dock payload loaded for as long as compositor mode is wanted. The payload lives in the Dock's process,
// so every Dock restart (`killall Dock`, a crash, a setting that restarts it) unloads it, and only root can put it
// back. While `native-desktop` runs with the launch daemon on, the app watches the Dock; when a new one appears it
// runs the bundled launcher's `--reload` (the same recovery-aware launcher, journal handoff from the retired Dock
// included, with the daemon in place of sudo) and takes the endpoint of the helper it started, so the presenter's
// ordinary authenticated re-admission puts the windows back. Three Dock restarts in a row around loads stop that for
// the payload version, across launches, until the owner loads by hand.
//
// Translated from Sunlight's `AdditionReloader` and `DockCrashGuard`
// (third_party/sunlight/Sources/Canvas/RealWindows/AdditionReloader.swift, afeea74, MIT, Copyright (c) 2026 spacefarm);
// dock-reload.m names the line ranges.

// Seconds a Dock restart counts as near a load, and the strikes that stop automatic loading.
extern const NSTimeInterval DWDockCrashWindow;
extern const NSUInteger DWDockCrashLimit;

// DockCrashGuard: each Dock restart while a load runs, or within DWDockCrashWindow of one ending, is a strike; any
// other restart clears them. At DWDockCrashLimit strikes in a row the payload is taken to be what brings the Dock down.
typedef struct {
    NSUInteger strikes;
    BOOL loading,loaded; // a load is running; one has run (lastLoad is set)
    NSTimeInterval lastLoad;
} DWDockCrashGuard;
void DWDockCrashGuardLoadStarted(DWDockCrashGuard *guard,NSTimeInterval at);
void DWDockCrashGuardLoadEnded(DWDockCrashGuard *guard,NSTimeInterval at);
// Counts a Dock restart; YES when it makes DWDockCrashLimit strikes in a row.
BOOL DWDockCrashGuardDockRestarted(DWDockCrashGuard *guard,NSTimeInterval at);
void DWDockCrashGuardReset(DWDockCrashGuard *guard);

// The remembered pause: auto-reload-paused.plist in the native-desktop state directory, naming the payload SHA-256 it
// was made for. A payload with another digest is not paused; a pause file that cannot be read as one is, since that
// cannot be told from the real thing. The launcher reads the same file.
NSString *DWDockReloadStateDirectory(void);
BOOL DWDockReloadPaused(NSString *directory,NSString *payloadSHA256);
BOOL DWDockReloadPause(NSString *directory,NSString *payloadSHA256,NSString *reason);
// The owner loads by hand: the pause is lifted. Returns YES when there was one.
BOOL DWDockReloadResume(NSString *directory);

// The launcher's --reload ends its output with `INFINIFY-NATIVE-ENDPOINT RUNTIME NONCE_FILE`. YES with the two paths when
// the last such line has the form the launcher writes (a /tmp/if-native.XXXXXX runtime and its nonce file).
BOOL DWDockReloadParseEndpoint(NSString *output,NSString *__autoreleasing *runtime,NSString *__autoreleasing *nonceFile);

@interface DWDockReloader : NSObject
// `launcher` is the bundled launch.sh; `payloadSHA256` the payload the launcher verified; `loadedAt` when it ran a load
// (seconds since 1970), 0 when it reused a helper already in the Dock.
- (instancetype)initWithLauncher:(NSString *)launcher payloadSHA256:(NSString *)payloadSHA256 stateDirectory:(NSString *)stateDirectory loadedAt:(NSTimeInterval)loadedAt;
// The Dock restarted: whatever was loaded into the old one is gone. Main thread.
@property(copy) void (^onDockRestarted)(void);
// A new helper answers at this runtime (its nonce is in the file). Main thread.
@property(copy) void (^onEndpoint)(NSString *runtime,NSString *nonceFile);
// The Dock kept restarting around loads: quiet reloads have just stopped, and are remembered. Main thread.
@property(copy) void (^onPaused)(void);
@property(copy) void (^onNote)(NSString *note);
// YES from a Dock restart until a helper answers (or until a pause ends the run).
@property(readonly) BOOL awaitingEndpoint;
@property(readonly) BOOL paused;
@property(readonly) DWDockCrashGuard guard;
// How long a new Dock is given to finish starting before the payload is loaded into it; how often the clock checks it;
// how long after a failed reload the one retry waits.
@property NSTimeInterval dockSettle,pollInterval,retryDelay;
// Seams for the regression: the Dock process as (pid, birth) or NO between Docks; the launcher run (status and output);
// the monotonic clock; the queue the launcher runs on.
@property(copy) BOOL (^dockSource)(pid_t *pid,uint64_t *sec,uint64_t *usec);
@property(copy) int (^loadRunner)(NSString *__autoreleasing *output);
@property(copy) NSTimeInterval (^clock)(void);
@property dispatch_queue_t workQueue;
// Starts or stops watching the Dock. Idempotent.
- (void)watch:(BOOL)wanted;
// One look at the Dock; the timer and the workspace notifications call it.
- (void)checkDock;
- (void)stop;
@end
