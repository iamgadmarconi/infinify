// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWApplicationCatalogWatch implementation.
// Split from native/app/Windows/DWWindowEvents.m (0b3f028; native/desktop/window-events.m at 37b27b1), moved verbatim.
#import "DWApplicationCatalogWatch.h"
#include <os/lock.h>
static void *catalogObservation=&catalogObservation;
@implementation DWApplicationCatalogWatch
- (instancetype)initWithWorkspace:(NSWorkspace *)workspace {
    if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;_workspace=workspace;_active=YES;_revision=1;
        NSAssert(NSThread.isMainThread,@"application catalog observation is installed on main");
        [workspace addObserver:self forKeyPath:@"runningApplications" options:0 context:catalogObservation];_observing=YES;
    }return self;
}
- (uint64_t)revision { os_unfair_lock_lock(&_lock);uint64_t revision=_revision;os_unfair_lock_unlock(&_lock);return revision; }
- (BOOL)matches:(uint64_t)revision { os_unfair_lock_lock(&_lock);BOOL matches=_active&&_revision==revision;os_unfair_lock_unlock(&_lock);return matches; }
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=catalogObservation){[super observeValueForKeyPath:key ofObject:object change:change context:context];return;}
    os_unfair_lock_lock(&_lock);BOOL schedule=_active&&!_queued;if(_active){_revision++;_queued=YES;}os_unfair_lock_unlock(&_lock);
    if(!schedule)return;__weak DWApplicationCatalogWatch *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWApplicationCatalogWatch *watch=weak;if(!watch)return;
        os_unfair_lock_lock(&watch->_lock);BOOL active=watch->_active;watch->_queued=NO;os_unfair_lock_unlock(&watch->_lock);
        if(active&&watch.changed)watch.changed(watch);
    });
}
- (void)invalidate {
    os_unfair_lock_lock(&_lock);_active=NO;_revision++;os_unfair_lock_unlock(&_lock);
    // As for application observers, removal is main-only and outside the callback lock.
    if(_observing){NSAssert(NSThread.isMainThread,@"application catalog observation is removed on main");_observing=NO;[_workspace removeObserver:self forKeyPath:@"runningApplications" context:catalogObservation];}
    _changed=nil;
}
- (void)dealloc { [self invalidate]; }
@end
