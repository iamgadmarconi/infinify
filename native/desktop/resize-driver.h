// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
#import <CoreGraphics/CoreGraphics.h>
typedef NS_ENUM(NSInteger,DWNativeFillReadiness) {
    DWNativeFillUnsupportedGeometry=-1,
    DWNativeFillPending=0,
    DWNativeFillReady=1,
    DWNativeFillNeedsRebase=2,
    // Restore-only: the root is hidden behind a prepared snapshot. Apply the
    // exact saved frame directly, without starting a second native animation.
    DWNativeFillReadyForFrameRestore=3,
};
// Main-thread callbacks for one withheld, root-only family. None grants input.
@interface DWNativeFillRebase : NSObject
@property CGRect native,displayed;
@property (copy) BOOL (^publish)(CGRect observed, BOOL (^authorized)(void));
@property (copy) BOOL (^ready)(void);
@property (copy) void (^cancel)(void);
@end
@interface DWNativeResizeDriver : NSObject <DWResizeDriver>
// Desktop native presentation elects app-owned Fill. The main-thread gate must
// confirm that the helper has acknowledged withholding the entire native family.
@property BOOL nativeFill;
// Optional main-thread ownership gate. Refusal returns an ordinary unattempted
// unavailable result, so the controller still completes its pending effect.
@property (copy) BOOL (^canPerform)(NSDictionary *effect);
// Explicit snapshot handoffs may extend preparation to 2.5s. Zero keeps the
// ordinary .75s budget; the screen-update lease remains independently capped.
@property (atomic) NSTimeInterval fillPreparationTimeout;
@property (copy) DWNativeFillReadiness (^fillReady)(NSDictionary *effect);
@property (copy) DWNativeFillRebase *(^fillRebase)(NSDictionary *effect);
// Ready requires an explicit fullscreen-exit snapshot handoff. Unsupported
// keeps ordinary exact-frame restore; cleanup/background paths never opt in.
// Every prepared Restore waits here, including an enter that used ordinary
// sizing; only remembered native Fill permits the app's Unfill after Ready.
// A successful settled Unfill must match the saved frame exactly, otherwise
// one ordinary full-frame correction follows before the driver returns.
// ReadyForFrameRestore instead uses the exact frame setter without Unfill,
// even when native Fill succeeded; the snapshot owns the visible animation.
@property (copy) DWNativeFillReadiness (^restoreReady)(NSDictionary *effect);
// Safe from main or worker: only a successful actual app Fill qualifies.
- (BOOL)hasNativeFillForEffect:(NSDictionary *)effect;
// Called on the resize worker and an independent watchdog. NO starts one hold;
// YES balances it. Missing/failed hold support refuses rebasing before AX.
@property (copy) CGError (^screenUpdates)(BOOL enabled);
// Readback resizing keeps the adapter's fresh identity checks before and after every native call.
@property (copy) void (^didPerform)(NSDictionary *effect, NSDictionary *result);
@end
