// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWObservedApplication: one observed application (yabai's struct application).
// Split from native/app/Windows/DWWindowEvents.m (0b3f028; native/desktop/window-events.m at 37b27b1), moved verbatim.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
@class DWWindowEvents, DWObservedWindow;
// One observed application: yabai's struct application. Main thread, but for what a block on the worker is handed by value.
@interface DWObservedApplication : NSObject
@property pid_t pid;
@property uint64_t seconds, microseconds;
@property NSRunningApplication *running;
@property (weak) DWWindowEvents *events;
@property AXUIElementRef element;
// Created on the worker; its run-loop source is on the main run loop from the moment it is set and until it is cleared.
@property AXObserverRef observer;
// Accessibility window element → DWObservedWindow, for the windows whose own notifications are registered.
@property CFMutableDictionaryRef windows;
// Elements whose window is being looked up, or that answered and are no window: none is asked about twice before the windows are
// listed again. One its application did not answer for, or gave no window number for, is not kept.
@property CFMutableSetRef asked;
// Every DWObservedWindow the observer was given as a context. A context is never released while the observer can still call
// back with it: a destroyed window's is kept ten seconds more, for a notification that was already under way.
@property NSMutableArray<DWObservedWindow *> *contexts;
@property uint8_t registered; // one bit per applicationNotifications entry
@property int attempts;
@property NSTimeInterval retry; // when the next quick attempt is due; 0 for none
@property BOOL busy, listing, final, gone;
// It did not answer when one of its windows was looked up or when they were listed, or a window of it had no number yet: they
// are listed again at the next -reconcile.
@property BOOL unanswered;
@end
