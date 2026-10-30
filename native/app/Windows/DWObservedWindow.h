// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWObservedWindow: one watched window (what yabai's struct window is to its notifications).
// Split from native/app/Windows/DWWindowEvents.m (0b3f028; native/desktop/window-events.m at 37b27b1), moved verbatim.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
@class DWObservedApplication;
// One watched window: what yabai's struct window is to its notifications, their context.
@interface DWObservedWindow : NSObject
@property (weak) DWObservedApplication *application;
@property CGWindowID window;
@property AXUIElementRef element;
@property uint8_t registered; // one bit per windowNotifications entry; written on the worker before the window is handed over
@property NSTimeInterval destroyed; // when its destroyed notification arrived; 0 while the window is there
@end
