// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativeResizePresentation.h"
#import "DWNativeResizeDriver.h"
#import "DWNativeViews.h"
#import "DWNativeFocus.h"
@class LiveSource;
@protocol DWSizeTransitionPicture <DWNativeResizePicture>
- (BOOL)animateToScreenRect:(CGRect)rect completion:(void (^)(BOOL completed))completion;
@end
@protocol DWSizeTransitionCaptureRequest <NSObject>
@property (readonly,getter=isCompleted) BOOL completed;
- (void)cancel;
@end
// Picture creation is deferred until the owner consumes a successful capture.
typedef id<DWSizeTransitionPicture> (^DWSizeTransitionPictureFactory)(void);
// Completion is asynchronous on main, even on refusal/cancellation. Interactive
// pictures round displayed origins down; Fill/Restore keep the exact mapping.
typedef id<DWSizeTransitionCaptureRequest> (^DWSizeTransitionCapture)(
    DWNativeHiddenRoot *root, BOOL interactive, BOOL (^valid)(void),
    void (^completion)(DWSizeTransitionPictureFactory picture, NSString *failure));
// Adapter facts/actions, not transition policy. Desktop is the macOS adapter;
// an in-memory host and pictures can exercise the whole glue at this seam.
@protocol DWSizeTransitionHost <NSObject>
@property (readonly) BOOL cleaning,sessionInactive,nativeDesktopMode;
@property (readonly) uint64_t nativeSessionEpoch;
@property (readonly) DWNativePresenter *native;
@property (readonly) DWNativeViews *nativeViews;
@property (readonly) DWScene *nativeOwnerSnapshot;
@property DWScene *nativeViewSnapshot;
@property NSString *statusText;
@property (readonly) id<DWResizeController> sizeController;
- (DWScene *)presentationSnapshot;
- (DWScene *)sizeTransitionSnapshot;
- (LiveSource *)sizeTransitionSource:(NSNumber *)window;
- (BOOL)sizeTransitionHeld:(NSNumber *)transaction;
- (BOOL)sizeTransitionRemovalAllowed:(NSNumber *)window allowed:(BOOL *)allowed;
- (BOOL)nativeUnavailable;
- (void)render;
- (void)resizeCapability;
- (void)track:(LiveSource *)source;
- (void)saveScene;
- (void)applyReply:(DWControllerReply *)reply;
- (void)flashStatus:(NSString *)text;
- (void)cancelNativeHoverForWindow:(NSNumber *)window;
- (void)cancelCapturedInputForWindow:(NSNumber *)window;
// Native observations are fresh on every invocation, including the 60 Hz
// hidden-root validity check. A failed observation never authorizes mutation.
- (BOOL)sizeTransitionCaptureAllowed;
- (NSDictionary *)sizeTransitionWindowInfo:(CGWindowID)window;
- (BOOL)sizeTransitionNativeBounds:(CGWindowID)window bounds:(CGRect *)bounds;
- (BOOL)sizeTransitionOwner:(DWFocusIdentity)identity bounds:(CGRect *)bounds;
- (NSDictionary *)sizeTransitionFamily:(NSDictionary *)identity why:(NSString *__autoreleasing *)why;
@end
