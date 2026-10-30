// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWApplicationWatch implementation.
// Split from native/app/Windows/DWWindowEvents.m (0b3f028; native/desktop/window-events.m at 37b27b1), moved verbatim.
#import "DWApplicationWatch.h"
#include <os/lock.h>
static void *applicationObservation=&applicationObservation;
static NSArray<NSString *> *applicationProperties(void) { return @[@"processIdentifier",@"activationPolicy",@"terminated"]; }
@implementation DWApplicationWatch
- (instancetype)initWithRunning:(NSRunningApplication *)running {
    if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;_running=running;_active=YES;_revision=1;_identityRevision=1;_pending=YES;
        NSAssert(NSThread.isMainThread,@"application observation is installed on main");
        for(NSString *key in applicationProperties())[running addObserver:self forKeyPath:key options:0 context:applicationObservation];
        _observing=YES;
    }return self;
}
- (uint64_t)revision { os_unfair_lock_lock(&_lock);uint64_t revision=_revision;os_unfair_lock_unlock(&_lock);return revision; }
- (uint64_t)identityRevision { os_unfair_lock_lock(&_lock);uint64_t revision=_identityRevision;os_unfair_lock_unlock(&_lock);return revision; }
- (BOOL)matches:(uint64_t)revision { os_unfair_lock_lock(&_lock);BOOL matches=_active&&_revision==revision;os_unfair_lock_unlock(&_lock);return matches; }
- (void)invalidateIdentity:(BOOL)identity {
    os_unfair_lock_lock(&_lock);BOOL schedule=_active&&!_queued;if(_active){_revision++;if(identity)_identityRevision++;_queued=YES;}os_unfair_lock_unlock(&_lock);
    if(!schedule)return;__weak DWApplicationWatch *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWApplicationWatch *record=weak;if(!record)return;
        os_unfair_lock_lock(&record->_lock);BOOL active=record->_active;record->_queued=NO;os_unfair_lock_unlock(&record->_lock);
        if(active&&record.changed)record.changed(record);
    });
}
- (void)invalidateMetadata { [self invalidateIdentity:NO]; }
- (void)invalidateIdentityMetadata { [self invalidateIdentity:YES]; }
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context==applicationObservation){[self invalidateIdentity:[key isEqualToString:@"processIdentifier"]||[key isEqualToString:@"terminated"]];return;}
    [super observeValueForKeyPath:key ofObject:object change:change context:context];
}
- (void)invalidate {
    os_unfair_lock_lock(&_lock);_active=NO;_revision++;os_unfair_lock_unlock(&_lock);
    // Never remove an observer under the callback lock: removal may synchronize with an in-flight notification.
    if(_observing){NSAssert(NSThread.isMainThread,@"application observation is removed on main");_observing=NO;for(NSString *key in applicationProperties())[_running removeObserver:self forKeyPath:key context:applicationObservation];}
    _changed=nil;
}
- (void)dealloc { [self invalidate]; }
@end
