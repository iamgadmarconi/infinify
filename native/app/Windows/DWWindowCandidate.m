// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm (https://github.com/malbiruk/driftwm) 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/handlers/xdg_shell.rs (new_toplevel, toplevel_destroyed: every toplevel is
// managed from the moment it exists), src/handlers/compositor.rs (a new window is
// placed on its first sized commit, not before), src/input/actions.rs (CloseWindow:
// send_close to the focused client) and src/state/suspended.rs (relaunch_suspended:
// resolve the app afresh, report one that no longer resolves). New implementation
// over the macOS window list, ScreenCaptureKit, Accessibility and NSWorkspace; the
// placement, matching and focus rules stay in the controller.
// Event-driven tracking is adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT;
// licence text in YABAI-NOTICE.txt), src/event_loop.c:
// WINDOW_CREATED, WINDOW_DEMINIMIZED and APPLICATION_VISIBLE look for the window at once, APPLICATION_LAUNCHED for all of an
// application's. DWWindowEvents.h has the observers and the rest of the provenance. Here creation hints coalesce into the
// host's single-flight worker observation; existing bound-window events are delivered to the host immediately.
#import "DWWindowCandidate.h"
@implementation DWWindowCandidate
+ (instancetype)candidateWithShareable:(SCWindow *)shareable {
    DWWindowCandidate *candidate=[self new];candidate.pid=shareable.owningApplication.processID;candidate.window=shareable.windowID;candidate.bundleIdentifier=shareable.owningApplication.bundleIdentifier;
    candidate.applicationName=shareable.owningApplication.applicationName;candidate.title=shareable.title;candidate.frame=shareable.frame;candidate.shareable=shareable;return candidate;
}
@end
