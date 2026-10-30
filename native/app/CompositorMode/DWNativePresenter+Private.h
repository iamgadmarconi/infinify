// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWPayloadState.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/desktop/native-presenter.m (37b27b1): state shared by the DWNativePresenter implementation files and by
// tests/native/app/CompositorMode/DWNativePresenterTests.m, which imports those files. Not for other modules.
#import "DWNativePresenter.h"
#include <os/lock.h>
#include <stdatomic.h>
#include <time.h>
#include "DWHelperClient.h"

// Compact, immutable correspondence alongside an emitted frame. Public receipt
// dictionaries are made only when queried, never for every presentation member.
typedef struct {
    struct dw2_identity identity;
    uint64_t window,generation,output,revision;
    CGRect screen,clip,viewport;
} DWNativePlacementBinding;
typedef struct {
    struct dw2_record record;
    uint64_t targetSpace;
    CGRect native;
    uint32_t index,parent;
} DWNativePlacementMember;
@interface DWNativeHiddenRoot () {
@public NSUUID *session;struct dw2_record record;NSInteger phase;
}
@property(nonatomic,readwrite,copy) NSDictionary *identity;
@property(nonatomic,readwrite) CGRect nativeBounds,screenRect;
- (instancetype)initWithSession:(NSUUID *)value;
@end
@interface DWNativePlacementDescription : NSObject {
@public DWNativePlacementBinding binding;NSData *members;BOOL parked;
}
@end
static inline NSDictionary *DWNativePlacementIdentity(struct dw2_identity identity) {
    return @{@"pid":@(identity.pid),@"wid":@(identity.wid),@"birth_sec":@(identity.birth_sec),@"birth_usec":@(identity.birth_usec)};
}
static inline BOOL DWNativePlacementInteger(id value,uint64_t *integer) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()
        ||CFNumberIsFloatType((__bridge CFNumberRef)value)||[value compare:@0]==NSOrderedAscending)return NO;
    *integer=[value unsignedLongLongValue];return [value isEqual:@(*integer)];
}
@interface DWNativeAppliedPlacement ()
- (instancetype)initWithSession:(NSUUID *)session sequence:(uint64_t)sequence description:(DWNativePlacementDescription *)description;
@property(nonatomic,readonly) DWNativePlacementDescription *placementDescription;
@end

// The helper's lease clock and the library's: it stops while the machine sleeps, so a night asleep is not a hang.
static inline uint64_t uptime(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000000; }
// One bound window: who it is for the helper, its own frame, and whether an alpha was ever sent for it.
@interface DWNativeWindow : NSObject { @public struct dw2_identity identity;CGRect bounds;BOOL alpha,familyKnown,declined;NSNumber *logical;uint64_t releaseSeq,familyAt;uint32_t root,parent; } @end
@interface DWNativeSpaceReflow : NSObject { @public
    struct dw2_identity identity;
    CGRect original,before,observed;
    uint64_t target,submittedAt,changedAt,acknowledgedSequence;
    BOOL settled,changed,nativeInput;
} @end
@interface DWNativePresenterGroup : DWNativePresenter
@property NSArray<DWNativePresenter *> *sessions;
@property NSDictionary<NSNumber *,DWNativePresenter *> *owners;
@property BOOL groupEnded,finished;
@end
@interface DWNativePresenter () {
    // Every call into the library is made under this lock and for that call only (each is bounded: two seconds at most), and the
    // pointer is cleared under it, so the watchdog's close on its own queue never meets a call on the main thread.
    os_unfair_lock _lock;
    dw_client *_client;
    id _activity; // travels with the client to its final close, including asynchronous restoration
    struct dw_client_info _info;
    NSDictionary<NSNumber *,NSArray<NSNumber *> *> *_scope;
    BOOL _desktopWide;
    BOOL _veiling; // the helper holds each window an application opens invisible until a frame places it, a release lets it go, or its own bound passes
    uid_t _loginUID;
    NSArray<NSNumber *> *_dockBirth;
    _Atomic bool _preparing;
    _Atomic bool _ended;
    // When the main thread last turned its run loop or described a frame: written there, read by the watchdog.
    _Atomic uint64_t _turned;
    dispatch_source_t _watchdog;
    CFRunLoopObserverRef _observer;
    NSMutableDictionary<NSNumber *,DWNativeWindow *> *_windows; // by window number
    NSMutableDictionary<NSNumber *,DWNativeWindow *> *_releases; // originals to restore after unbinding
    NSMutableDictionary<NSNumber *,DWNativeSpaceReflow *> *_spaceReflows;
    NSMutableDictionary<NSNumber *,NSSet<NSNumber *> *> *_families;
    NSMutableDictionary<NSNumber *,NSDictionary *> *_withheld;
    NSMutableDictionary<NSNumber *,NSData *> *_rebases; // exact temporary neutral records
    NSMutableDictionary<NSNumber *,DWNativeHiddenRoot *> *_transitions;
    NSMutableSet<NSNumber *> *_rebased; // neutral ACK received; awaiting omission ACK
    _Atomic bool _releasing;
    _Atomic bool _retrying;
    uint64_t _lastSent,_submittedSeq;
    NSMutableData *_records;                                    // the frame last described
    NSData *_recordSpaces,*_sentSpaces;                         // parallel uint64 targets; zero preserves membership
    NSData *_sent;                                              // the frame last handed over
    NSArray<NSNumber *> *_order,*_sentOrder;                    // the world window of each of their records, for -debug:
    BOOL _described,_forced;
    // Unanswered frames, by sequence number, for a record status that comes back; and what was said of one.
    NSMutableDictionary<NSNumber *,NSData *> *_frames;
    NSMutableSet<NSString *> *_said;
    NSUUID *_placementSession;
    NSDictionary<NSNumber *,DWNativePlacementDescription *> *_desiredPlacements,*_acknowledgedPlacements;
    NSMutableDictionary<NSNumber *,NSDictionary<NSNumber *,DWNativePlacementDescription *> *> *_framePlacements;
    uint64_t _acknowledgedSequence,_placementRevision;
}
- (dw_client *)takeActivity:(id __strong *)activity;
- (NSArray<NSNumber *> *)admittedBirth:(NSDictionary *)identity;
@end
// Defined in one category file and called from another (the file is named beside each).
@interface DWNativePresenter (Private)
- (BOOL)placementDescriptionCurrent:(DWNativePlacementDescription *)description;
- (void)refused:(NSData *)statuses frame:(uint64_t)seq; // +Acknowledgement; frameResult in DWNativePresenter.m
- (void)invalidatePlacementReadiness; // +Acknowledgement; +Families, +Frames
- (BOOL)transitionCurrent:(DWNativeHiddenRoot *)transition; // +Withholding; +Frames
@end
