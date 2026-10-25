// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from koekeishiya/yabai dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund Vikane; the licence
// text is native/families/YABAI-NOTICE.txt): src/workspace.m (the NSWorkspace notifications an application is followed by),
// src/application.h and src/application.c (the application notification table, application_observe and application_unobserve:
// one AXObserver per application on the main run loop, and ax_retry for an application that does not answer yet), src/window.h
// and src/window.c (the window notification table, window_observe and window_unobserve: destroyed, miniaturized and
// deminiaturized are registered per window with the window as their context, because a destroyed element can no longer be asked
// which window it was), src/event_loop.c (what each event does, and APPLICATION_LAUNCHED's retry) and src/window_manager.c
// (window_manager_begin and window_manager_add_application_windows: every regular application that runs is observed and its
// windows are enumerated). New implementation: yabai keeps a model of every window and acts on it from its own event loop; this
// keeps none. An event only says which application or window to look at now, and the looking is the pass the poll makes.
// Public Accessibility and NSWorkspace API, and _AXUIElementGetWindow as window-manager.m uses it; no SkyLight call.
#import <AppKit/AppKit.h>
// What the observers report. Every call arrives on the main thread, from the main run loop, never from inside another call of
// this protocol. A report is a hint that something may have changed, never the change itself: the sink reads the window list
// again, so a report that is repeated, late or about a window the sink does not know changes nothing.
@protocol DWWindowEventSink <NSObject>
// Every report but -windowDestroyed:pid: is coalesced by what it names: a storm (a live resize reports every step) is one
// report at once and one per 80 ms after it, the last of them after the storm's last notification. So a single notification
// is reported twice, 80 ms apart: the window list may not show at once what the application has just said.
//
// The set of windows on screen may have changed for this application: it launched, it was shown again, one of its windows was
// created or came back from the Dock. 0: for any application, because the active Space changed.
- (void)windowsChanged:(pid_t)pid;
// Only AXMoved named this known window during this coalesced batch. This is still
// a hint, not proof of origin-only movement: the sink must validate fresh identity
// and extent. Any mixed change, or unknown-window change for its PID, takes the
// generic path instead. The trailing report retains the same conservative kind.
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid;
// This window was resized, retitled, miniaturized or shown again, its application was hidden, shown or ended, or a move
// could not be attributed to exactly one known window (or was coalesced with another change).
// `window` 0: some window of the application, which one is not known.
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid;
// Its application reported the window destroyed. At once; a -windowChanged: for it follows 80 ms later, because the window
// list may still show the window at this moment.
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid;
// Native focus may have moved: an application was activated, or an application's focused window changed.
- (void)focusChanged;
@optional
// Exact AXCreated/AXWindowCreated element, after the ordinary appearance hint.
// Borrowed for this call only; retain it for off-main AX reads. The birth is
// the observed application's original identity, never a newly resolved PID.
- (void)windowCreatedElement:(AXUIElementRef)element pid:(pid_t)pid birth:(NSArray<NSNumber *> *)birth;
// Raw geometry/title/lifecycle invalidation, before coalescing. PID 0 covers
// every application, including an active-Space change.
- (void)windowCreationInvalidated:(pid_t)pid;
// Miniaturized/deminiaturized is a hint to read AXMinimized for the exact
// current binding. Neither the notification nor its boolean establishes state.
- (void)windowVisibilityChanged:(CGWindowID)window pid:(pid_t)pid;
@end
// Event-driven window tracking, the way yabai does it. NSWorkspace says when an application launches, ends, is activated,
// hidden or shown, and when the active Space changes; with Accessibility access one AXObserver per regular application says
// when a window is created, moved, resized, retitled or focused, and each window it knows says when it is destroyed,
// miniaturized or deminiaturized. Read-only: it registers for notifications and reads a window's number and role, and never
// moves, focuses, resizes or closes anything. Every Accessibility message is sent off the main thread with a quarter-second
// timeout, so an application that does not answer delays nothing but its own observation, which is tried again five times a
// tenth of a second apart and then at every -reconcile. A window it did not answer for, or gave no window number for, is asked
// about again when a notification next names it, and its windows are listed again at every -reconcile until it does; until
// then that window's end is the poll's to find. A callback only looks its element up in a table and reports.
// Main thread only.
@interface DWWindowEvents : NSObject
// The NSWorkspace observers are in place from here on. Accessibility registration follows asynchronous application
// discovery when access is granted, including a grant made later at the next -reconcile. Application membership, PID,
// activation policy and termination changes are followed with KVO; catalog and dynamic metadata are read off main. `scope`, when not nil,
// is `--only-pid`'s (DWInScope below): no
// Accessibility observer is then created on any other application, and "every regular application" below reads "every
// regular application in scope".
- (instancetype)initWithSink:(id<DWWindowEventSink>)sink scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope;
// YES while Accessibility access stood at the last -reconcile and every regular application known is observed for every
// notification: the observers then report what a poll would find, so a poll is a reconciliation and can be slow. NO while
// one application is still being asked, does not answer, or refused a notification for good: its windows would otherwise
// be followed more slowly than the poll followed them.
@property (readonly) BOOL live;
// The poll's part, which the window manager calls once a second (at most twice a second however often it is called): reads
// Accessibility access afresh (granted since: every regular application is observed; withdrawn: every observer is removed),
// revalidates admitted process births, tries again one that did not answer, and lists again the windows of one that did not
// answer for a window or gave it no number. Application membership is read initially/on collection KVO, not polled here.
- (void)reconcile;
// Removes every observer, run-loop source and timer; no report follows. Required before release.
- (void)stop;
@end
// `--only-pid`: is this process one the run was told to manage? `scope` is pid → its start time [seconds, microseconds] as
// read when the run began, so a process that ended and whose pid another took since is not. YES for every process when there is
// no scope. Read-only, any thread.
BOOL DWInScope(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope,pid_t pid);
