// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativePresenter.h"
#import "DWNativeTransition.h"
#import "DWNavigationCoordinator.h"
#import "DWController.h"

// Internal picture adapter contracts. The whole handoff is exercised through
// DWSizeTransition; callers do not wire presentation policy at this lower seam.
@protocol DWNativeResizePicture <NSObject>
- (BOOL)show;
- (BOOL)setScreenRect:(CGRect)rect;
- (void)finish;
- (void)cancel;
@end
@protocol DWNativeResizePresenter <NSObject>
- (DWNativeHiddenRoot *)beginTransitionForWindow:(NSDictionary *)identity;
- (BOOL)hideTransition:(DWNativeHiddenRoot *)root;
- (BOOL)isTransitionHidden:(DWNativeHiddenRoot *)root;
- (BOOL)isTransitionHideOwned:(DWNativeHiddenRoot *)root;
- (BOOL)revealTransition:(DWNativeHiddenRoot *)root screen:(CGRect)screen alpha:(double)alpha;
- (BOOL)isTransitionRevealed:(DWNativeHiddenRoot *)root;
- (void)resumeWindow:(NSDictionary *)identity;
@end
// Returns a capture cancellation job. Completion must be asynchronous, on main.
typedef DWJob (^DWResizeCapture)(DWNativeHiddenRoot *root, BOOL (^valid)(void),
    void (^completion)(id<DWNativeResizePicture> picture, NSString *failure));

typedef struct {
    BOOL valid,finished,restored,recoverable,drained;
    CGRect screenRect;
    double alpha;
} DWNativeResizePresentationState;

// One root-only interactive native resize. The controller still owns all sizes
// and observations; this object owns only the temporary, static stretched image.
// No native setter is admitted until the picture is visible AND hide is ACKed.
@interface DWNativeResizePresentation : NSObject
// Right/bottom-only drags do not need compensation or capture permission.
+ (BOOL)requiresBridgeForTransaction:(DWResizeTransaction *)transaction;
- (instancetype)initWithPresenter:(id<DWNativeResizePresenter>)presenter capture:(DWResizeCapture)capture;
@property (readonly) DWSizeEffect *effect;
@property (readonly) BOOL active;
// Invalid includes generation/output/session/camera/identity changes.
// Recoverable is separate: a healthy current identity/session can still ACK
// ordinary restoration after camera/output/generation invalidation.
@property (copy) DWNativeResizePresentationState (^state)(void);
@property (copy) DWJob render,retired;
@property (copy) void (^failed)(NSString *reason);
@property (copy) NSTimeInterval (^clock)(void);
@property (copy) void (^delay)(NSTimeInterval seconds, DWJob job);
- (void)prepareEffect:(DWSizeEffect *)effect ready:(void (^)(BOOL))ready;
- (void)update;
// Main-thread worker gate: freshly checks root-only hide eligibility.
- (BOOL)allowsEffect:(DWSizeEffect *)effect;
// Invalidate callbacks first, settle preparation NO, resume the exact root and
// remove the picture. Emergency recovery, not successful optical completion.
- (void)cancel;
@end
