// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
// A temporary picture of one native family. Main thread only, including release.
// Rectangles use global CoreGraphics screen points (top-left of the main display;
// other displays may have negative origins). The caller owns capture permission,
// image freshness, native hiding/restoration and the final reveal acknowledgement.
// Each rectangle bounds the ENTIRE supplied image. A decorated export's padding
// must be included in that rectangle or cropped by the caller before construction.
// Cancel on session/display changes. This object never activates or modifies an app.
@interface DWNativeTransition : NSObject
// Retains an immutable copy of the image. No panel is shown during construction.
- (nullable instancetype)initWithImage:(CGImageRef)image screenRect:(CGRect)rect;
// Copies a packed premultiplied 32BGRA buffer before returning; later changes to
// the source cannot change the picture. Uses its color space, or sRGB if absent.
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)buffer screenRect:(CGRect)rect;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic,readonly,getter=isVisible) BOOL visible;
@property(nonatomic,readonly,getter=isAnimating) BOOL animating;
@property(nonatomic,readonly,getter=isClosed) BOOL closed;
// Orders only this noninteractive panel above normal app windows, below Dock and
// menu levels, without making it key. Holds the initial picture until animated.
- (BOOL)show;
// One 100 ms AppKit frame animation with an ease-out curve. The underlying app
// is already sized while hidden; only this picture animates. An unchanged frame
// completes without a visual hold.
// YES accepts the request and calls completion exactly once on the main thread:
// YES at the final frame, NO if cancelled/finished/released before completion.
// NO refuses the request without invoking completion. The image stays visible
// after successful animation until finish, which the caller waits to invoke until
// the real family has been revealed and its placement acknowledged.
- (BOOL)animateToScreenRect:(CGRect)rect completion:(void (^)(BOOL completed))completion;
// Idempotent. Both close only this panel; neither restores the native family.
- (void)finish;
- (void)cancel;
@end

// A request-owned raw root image: no compositor border, shadow or export padding.
// The image remains owned by this result; retain the result while using image.
@interface DWNativeTransitionCaptureResult : NSObject
@property(nonatomic,readonly) CGImageRef image;
@property(nonatomic,readonly) CGRect screenRect,nativeBounds;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
// Fresh one-shot capture for a verified root with NO attached windows. A family
// with children is refused so the caller can use its ordinary resize fallback.
// Main-thread API. The request completes exactly once on main, including refusal,
// cancellation and its two-second deadline; no late capture can be published.
@interface DWNativeTransitionCapture : NSObject
// identity is the native presenter PID/birth/WID tuple (owner absent or null).
// nativeBounds and the helper's screenRect mapping must remain current during
// capture. The observed CG window rect may round each edge by less than one
// screen point; that independently sampled rect is then pinned
// exactly throughout capture. The returned screenRect preserves the mapping.
// validate runs only on main: caller checks its generation, ownership, transaction
// and session. It must not mutate the source. Permission is preflighted only.
// Completion is always asynchronous to this factory. A successful result maps
// its ENTIRE raw image to screenRect; it does not use global screenshot state.
+ (instancetype)captureIdentity:(NSDictionary *)identity
                  nativeBounds:(CGRect)nativeBounds
                    screenRect:(CGRect)screenRect
                      validate:(BOOL (^)(void))validate
                    completion:(void (^)(DWNativeTransitionCaptureResult * _Nullable result,NSString * _Nullable failure))completion;
@property(nonatomic,readonly,getter=isCompleted) BOOL completed;
- (void)cancel;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
