// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWApplicationCatalogWatch: the KVO record of NSWorkspace.runningApplications.
// Split from native/desktop/window-events.m at 37b27b1, moved verbatim.
#import <AppKit/AppKit.h>
#include <os/lock.h>
// NSRunningApplication.h explicitly recommends KVO of NSWorkspace.runningApplications instead of polling. The
// collection can change on any thread; one weak main notification carries its newest revision, not the array itself.
@interface DWApplicationCatalogWatch : NSObject {
    os_unfair_lock _lock;
    uint64_t _revision;
    BOOL _active, _queued, _observing;
}
@property (readonly) NSWorkspace *workspace;
@property (copy) void (^changed)(DWApplicationCatalogWatch *);
- (instancetype)initWithWorkspace:(NSWorkspace *)workspace;
- (uint64_t)revision;
- (BOOL)matches:(uint64_t)revision;
- (void)invalidate;
@end
