// SPDX-License-Identifier: GPL-3.0-or-later
// External, owned-fixture AX exercise. No AX/WindowServer calls are substituted.
#import <AppKit/AppKit.h>
#import "resize.h"
#include <dlfcn.h>
#include <libproc.h>
#include <math.h>
#include <unistd.h>

static NSArray *rect(CGRect r) {
    return @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)];
}
static NSDictionary *report(DWResizeResult r) {
    return @{ @"outcome": @(dw_resize_outcome_name(r.outcome)), @"ax_error": @(r.ax_error),
              @"mutation_attempted": @(r.mutation_attempted), @"observed": @(r.observed),
              @"moved": @(r.moved), @"ax": rect(r.actual_ax), @"cg": rect(r.actual_cg) };
}
static void require(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"FixtureCheck" reason:message userInfo:nil];
}
static BOOL current(DWResizeIdentity identity) {
    struct proc_bsdinfo info = {0};
    return proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)
        && info.pbi_start_tvsec == identity.birth_seconds
        && info.pbi_start_tvusec == identity.birth_microseconds;
}
static NSDictionary *independent(DWResizeIdentity identity) {
    // Query ABI precedent: native/families/owned-window-geometry.h, checked against
    // yabai dd845723416f5fe92af49fad5ebab00369e07edd. No mutators are resolved.
    require(current(identity), @"independent process identity is current");
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, identity.window));
    require(list.count == 1, @"one independently selected CG window");
    NSDictionary *window = list.firstObject;
    require([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] == identity.pid
            && [window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == identity.window,
            @"independent CG window still belongs to the spawned fixture");
    CGRect bounds = CGRectZero;
    require(CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds),
            @"independent CG frame is readable");
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    require(sky != NULL, @"read-only SkyLight queries available");
    int (*connection)(void) = dlsym(sky, "SLSMainConnectionID");
    CGError (*transform)(int, uint32_t, CGAffineTransform *) = dlsym(sky, "SLSGetWindowTransform");
    CGError (*nativeBounds)(int, uint32_t, CGRect *) = dlsym(sky, "SLSGetWindowBounds");
    CGAffineTransform t = CGAffineTransformIdentity;
    CGRect native = CGRectZero;
    BOOL valid = connection && transform && nativeBounds && current(identity);
    if (valid) valid = transform(connection(), identity.window, &t) == kCGErrorSuccess
        && current(identity) && nativeBounds(connection(), identity.window, &native) == kCGErrorSuccess
        && current(identity);
    dlclose(sky);
    require(valid, @"independent native bounds and transform read with exact live identity");
    NSArray *affine = @[@(t.a), @(t.b), @(t.c), @(t.d), @(t.tx), @(t.ty)];
    for (NSNumber *value in affine) require(isfinite(value.doubleValue), @"finite independent transform");
    return @{ @"pid": @(identity.pid), @"window": @(identity.window),
              @"birth_seconds": @(identity.birth_seconds), @"birth_microseconds": @(identity.birth_microseconds),
              @"bounds": rect(bounds), @"native_bounds": rect(native), @"transform": affine };
}
static DWResizeResult observe(DWResizeIdentity identity) {
    DWResizeResult result = {0};
    for (int n = 0; n < 30; n++) {
        result = dw_resize_observe(identity);
        if (result.observed || result.outcome == DWResizeUnavailable || result.outcome == DWResizeStaleIdentity) break;
        usleep(20000);
    }
    return result;
}
static void writeJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
}
static BOOL booleanValue(id value, BOOL expected) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        && [value boolValue] == expected;
}
static NSDictionary *displayState(CGDirectDisplayID display, boolean_t online, boolean_t active, boolean_t asleep) {
    // Explicit BOOL boxing keeps the producer and the JSON supervisor contract
    // boolean-valued; C comparison expressions otherwise box as integer 0/1.
    return @{ @"id": @(display), @"online": @((BOOL)(online != 0)),
              @"active": @((BOOL)(active != 0)), @"asleep": @((BOOL)(asleep != 0)) };
}
static NSDictionary *sessionGate(NSDictionary *session, NSArray *displays, CGError displayError, CGDirectDisplayID mainDisplay) {
    // CGSession.h documents the console/login keys as CFBoolean. The lock key
    // is an observed private dictionary entry, not a documented unlocked-state
    // contract: missing/malformed lock metadata remains explicitly unknown.
    id console = session[(__bridge NSString *)kCGSessionOnConsoleKey];
    id login = session[(__bridge NSString *)kCGSessionLoginDoneKey];
    id locked = session[@"CGSSessionScreenIsLocked"];
    NSMutableArray *blockers = [NSMutableArray new];
    if (!session) [blockers addObject:@"quartz_session_unavailable"];
    if (!booleanValue(console, YES)) [blockers addObject:booleanValue(console, NO) ? @"not_console_session" : @"console_state_unknown"];
    if (!booleanValue(login, YES)) [blockers addObject:booleanValue(login, NO) ? @"login_incomplete" : @"login_state_unknown"];
    if (booleanValue(locked, YES)) [blockers addObject:@"screen_locked"];
    if (displayError != kCGErrorSuccess) [blockers addObject:@"display_query_failed"];
    BOOL activeAwake = NO;
    NSDictionary *main = nil;
    for (NSDictionary *display in displays) {
        if (booleanValue(display[@"online"], YES) && booleanValue(display[@"active"], YES)
            && booleanValue(display[@"asleep"], NO)) activeAwake = YES;
        if ([display[@"id"] unsignedIntValue] == mainDisplay) main = display;
    }
    if (!activeAwake) [blockers addObject:@"no_active_awake_display"];
    if (!main) [blockers addObject:@"main_display_unavailable"];
    else if (!booleanValue(main[@"online"], YES) || !booleanValue(main[@"active"], YES)
             || !booleanValue(main[@"asleep"], NO)) [blockers addObject:@"main_display_inactive_or_asleep"];
    return @{ @"no_known_session_blocker": @((BOOL)(blockers.count == 0)), @"session_usability_proven": @NO,
              @"blockers": blockers, @"session_present": @((BOOL)(session != nil)),
              @"on_console": console ?: NSNull.null, @"login_done": login ?: NSNull.null,
              @"screen_locked_value": locked ?: NSNull.null,
              @"lock_status": booleanValue(locked, YES) ? @"locked" : booleanValue(locked, NO) ? @"unlocked" : @"unknown",
              @"display_query_error": @(displayError), @"main_display": @(mainDisplay), @"displays": displays };
}
static NSDictionary *preflight(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    CGDirectDisplayID ids[16] = {0}; uint32_t count = 0;
    CGError error = CGGetOnlineDisplayList(16, ids, &count);
    NSMutableArray *displays = [NSMutableArray new];
    if (error == kCGErrorSuccess) for (uint32_t n = 0; n < count && n < 16; n++) {
        [displays addObject:displayState(ids[n], CGDisplayIsOnline(ids[n]), CGDisplayIsActive(ids[n]), CGDisplayIsAsleep(ids[n]))];
    }
    NSDictionary *gate = sessionGate(session, displays, error, CGMainDisplayID());
    BOOL trusted = AXIsProcessTrusted();
    return @{ @"accessibility_trusted": @(trusted), @"session": gate,
              @"preflight_passed": @((BOOL)(trusted && [gate[@"no_known_session_blocker"] boolValue])),
              @"permission_requested": @NO, @"mutation_attempted": @NO };
}
#ifdef DW_FRAME_LIVE_PREFLIGHT_REGRESSION
static int preflightRegression(void) {
    NSDictionary *awake = displayState(1, 1, 1, 0);
    NSDictionary *asleep = displayState(1, 1, 0, 1);
    NSMutableDictionary *session = [@{ (__bridge NSString *)kCGSessionOnConsoleKey: @YES,
                                      (__bridge NSString *)kCGSessionLoginDoneKey: @YES } mutableCopy];
    NSDictionary *gate = sessionGate(session, @[awake], kCGErrorSuccess, 1);
    require(booleanValue(gate[@"no_known_session_blocker"], YES) && [gate[@"lock_status"] isEqual:@"unknown"]
            && ![gate[@"session_usability_proven"] boolValue], @"missing private lock key is unknown, never usable-session proof");
    session[@"CGSSessionScreenIsLocked"] = @"malformed";
    gate = sessionGate(session, @[awake], kCGErrorSuccess, 1);
    require([gate[@"no_known_session_blocker"] boolValue] && [gate[@"lock_status"] isEqual:@"unknown"], @"malformed private lock key stays unknown");
    session[@"CGSSessionScreenIsLocked"] = @YES;
    require(![sessionGate(session, @[awake], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"known locked session refused");
    session[@"CGSSessionScreenIsLocked"] = @NO;
    require(![sessionGate(session, @[asleep], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"asleep display refused");
    require(![sessionGate(session, @[], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"no display refused");
    require(![sessionGate(session, @[awake], kCGErrorFailure, 1)[@"no_known_session_blocker"] boolValue], @"failed display query refused");
    require(![sessionGate(session, @[awake], kCGErrorSuccess, 2)[@"no_known_session_blocker"] boolValue], @"unavailable main display refused");
    require(![sessionGate(nil, @[awake], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"no Quartz session refused");
    for (id value in @[@NO, @1, @"malformed", NSNull.null]) {
        session[(__bridge NSString *)kCGSessionOnConsoleKey] = value;
        require(![sessionGate(session, @[awake], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"false or malformed console metadata refused");
    }
    [session removeObjectForKey:(__bridge NSString *)kCGSessionOnConsoleKey];
    require(![sessionGate(session, @[awake], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"missing console metadata refused");
    session[(__bridge NSString *)kCGSessionOnConsoleKey] = @YES;
    [session removeObjectForKey:(__bridge NSString *)kCGSessionLoginDoneKey];
    require(![sessionGate(session, @[awake], kCGErrorSuccess, 1)[@"no_known_session_blocker"] boolValue], @"missing login metadata refused");
    puts("PASS: substituted session/display preflight; no native windows or session queries");
    return 0;
}
#endif
int main(int argc, const char **argv) { @autoreleasepool {
#ifdef DW_FRAME_LIVE_PREFLIGHT_REGRESSION
    return preflightRegression();
#endif
    if (argc == 2 && !strcmp(argv[1], "--check")) {
        NSDictionary *check = preflight();
        writeJSON(check);
        return [check[@"preflight_passed"] boolValue] ? 0 : 2;
    }
    // The supervisor supplies its newly spawned child's PID separately. A ready
    // file cannot authorize a different process, even when the file is replaced.
    if (argc != 3) return 2;
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
    NSDictionary *ready = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    pid_t fixturePID = (pid_t)atoi(argv[2]);
    if (!ready || fixturePID <= 0 || [ready[@"pid"] intValue] != fixturePID || [ready[@"windows"] count] != 3) return 2;
    DWResizeIdentity ids[3] = {0};
    DWResizeSnapshot original = {0};
    NSMutableDictionary *evidence = [@{ @"passed": @NO, @"optical_proof": @NO, @"third_party_acceptance": @NO,
                                       @"actual_ax_calls": @YES, @"activation_calls": @0, @"input_posts": @0 } mutableCopy];
    NSMutableArray *before = [NSMutableArray new];
    int status = 1;
    @try {
        evidence[@"preflight_before_enrollment"] = preflight();
        require([evidence[@"preflight_before_enrollment"][@"preflight_passed"] boolValue], @"read-only authority/session/display preflight refused; see metadata");
        for (int n = 0; n < 3; n++) {
            BOOL enrolled = NO;
            for (int attempt = 0; attempt < 50 && !enrolled; attempt++) {
                enrolled = dw_resize_identity(fixturePID, [ready[@"windows"][n] unsignedIntValue], &ids[n]);
                if (!enrolled) usleep(20000);
            }
            require(enrolled, @"exact spawned fixture identity enrolled");
            DWResizeResult initial = observe(ids[n]);
            require(initial.observed, @"real AX and CG baseline agrees");
            NSDictionary *snapshot = independent(ids[n]);
            require([snapshot[@"bounds"] isEqual:rect(initial.actual_ax)], @"independent CG baseline equals actual AX frame exactly");
            [before addObject:snapshot];
            if (n == 0) original = (DWResizeSnapshot){ .identity = ids[0], .original = initial.actual_ax, .valid = true };
        }
        evidence[@"before"] = before;
        NSScreen *screen = NSScreen.mainScreen;
        require(screen != nil, @"fixture display available");
        CGFloat inset = MAX(screen.safeAreaInsets.top, MAX(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame)));
        CGSize fullscreen = CGSizeMake(screen.frame.size.width, screen.frame.size.height - ceil(inset));
        evidence[@"preflight_before_mutation"] = preflight();
        require([evidence[@"preflight_before_mutation"][@"preflight_passed"] boolValue], @"session/display changed before fixture mutation; see metadata");
        DWResizeResult expanded = dw_resize_apply(ids[0], fullscreen);
        evidence[@"fullscreen_request"] = @[@(fullscreen.width), @(fullscreen.height)];
        evidence[@"expanded"] = report(expanded);
        evidence[@"expanded_independent"] = independent(ids[0]);
        require(expanded.observed && expanded.mutation_attempted && !CGPointEqualToPoint(expanded.actual_ax.origin, original.original.origin),
                @"fullscreen-sized request moved the real native origin");
        require([evidence[@"expanded_independent"][@"bounds"] isEqual:rect(expanded.actual_ax)], @"expanded native frame independently matches AX");
        DWResizeResult legacy = dw_resize_restore(original);
        evidence[@"size_only_restore"] = report(legacy);
        evidence[@"size_only_independent"] = independent(ids[0]);
        require(legacy.observed && CGSizeEqualToSize(legacy.actual_ax.size, original.original.size)
                && !CGPointEqualToPoint(legacy.actual_ax.origin, original.original.origin),
                @"old size-only restoration leaves the actual fullscreen displacement");
        DWResizeResult restored = dw_resize_apply_frame(ids[0], original.original);
        evidence[@"frame_restore"] = report(restored);
        evidence[@"restored_independent"] = independent(ids[0]);
        require(restored.outcome == DWResizeApplied && restored.observed && CGRectEqualToRect(restored.actual_ax, original.original),
                @"production full-frame restore returns exact original AX frame even with size already restored");
        require([evidence[@"restored_independent"] isEqual:before[0]], @"independent native frame and transform exactly restored");
        // Repeat directly from the expanded state, so both size and origin need
        // restoration; the first case specifically covers origin-only recovery.
        evidence[@"preflight_before_second_mutation"] = preflight();
        require([evidence[@"preflight_before_second_mutation"][@"preflight_passed"] boolValue], @"session/display changed before second fixture mutation; see metadata");
        expanded = dw_resize_apply(ids[0], fullscreen);
        evidence[@"expanded_again"] = report(expanded);
        require(expanded.observed && !CGPointEqualToPoint(expanded.actual_ax.origin, original.original.origin)
                && !CGSizeEqualToSize(expanded.actual_ax.size, original.original.size), @"second live expansion changes both origin and extent");
        restored = dw_resize_apply_frame(ids[0], original.original);
        evidence[@"full_frame_restore"] = report(restored);
        require(restored.outcome == DWResizeApplied && restored.observed && CGRectEqualToRect(restored.actual_ax, original.original),
                @"production size-position-size path restores both original origin and extent");
        for (int n = 0; n < 3; n++) require([independent(ids[n]) isEqual:before[n]], @"selected original restored and both same-title decoys unchanged");
        status = 0;
    } @catch (NSException *error) {
        evidence[@"failure"] = error.reason ?: error.name;
    } @finally {
        if (original.valid) {
            @try {
                DWResizeResult cleanup = dw_resize_apply_frame(ids[0], original.original);
                evidence[@"cleanup"] = report(cleanup);
                NSMutableArray *after = [NSMutableArray new];
                for (NSUInteger n = 0; n < before.count; n++) [after addObject:independent(ids[n])];
                evidence[@"after"] = after;
                BOOL exact = [after isEqual:before];
                evidence[@"independent_restoration_passed"] = @(exact);
                if (!exact) status = 1;
            } @catch (NSException *error) {
                evidence[@"cleanup_failure"] = error.reason ?: error.name;
                status = 1;
            }
        }
    }
    evidence[@"passed"] = @(status == 0);
    writeJSON(evidence);
    return status;
} }
