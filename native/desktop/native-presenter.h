// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// The second way to present (`--native-helper`): the window server draws each real window
// where the canvas places it, moved and scaled by the transform helper of
// native/privileged (protocol v2, through dwclient). native-views selects its one
// physical placement; the canvas draws live copies on additional outputs. The
// first way, the overlay, is every run without that argument and
// uses nothing of this file.
//
// A window's own frame, untransformed, in global top-left points: where the window is
// and how large, whatever transform the helper has put on it. kCGWindowBounds follows
// the transform and is of no use for that (a 320x232 window drawn at half size reads
// 160x116 there); SLSGetWindowBounds, asked from this process about another's window,
// stays the window's own (measured 2026-10-11 on 27.2, on a cooperative host window:
// [80,937,320,232] untouched, at half size and parked). NO when the window server
// does not answer for that window. Any thread.
bool DWNativeBounds(uint32_t wid,CGRect *out);
// Desired rectangular display clipping in a member's own local coordinates.
// Pure geometry: native and rootNative are untransformed bounds; rootScreen is
// the canvas placement in global top-left points. The viewport is that output's
// screen_bounds, not the root's clip_rect (a popup may extend beyond its root).
// This does not read or replace the native window's original shape, shadow or
// event region, and is not evidence that WindowServer can enforce the clip.
typedef struct {
    CGRect screen,visible,local;
    bool required;
} DWNativeClipGeometry;
bool DWNativeClipPlacement(CGRect native,CGRect rootNative,CGRect rootScreen,CGRect viewport,DWNativeClipGeometry *out);
// Immutable receipt for one entire bound native family in one helper frame. The
// helper acknowledged these requested matrices; this is not observed geometry,
// an optical result, a native clipping receipt or authorization to send input.
// Before admission, independently check current identity/ancestry, transform,
// screen geometry and the exact event-eligible window, then recheck this token.
@interface DWNativeAppliedPlacement : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic,readonly,copy) NSUUID *session;
@property(nonatomic,readonly) uint64_t sequence,window,generation,output;
@property(nonatomic,readonly,copy) NSDictionary *identity;
// Identity uses the helper's exact PID/birth/window tuple. Controller sources
// may serialize owner:null; a populated owner is refused, never silently dropped.
@property(nonatomic,readonly) CGRect requestedScreenRect,requestedClipRect,requestedViewport;
// Sorted complete family: identity, native_bounds, audited parent WID (root:0), requested_transform,
// requested_alpha (null when not set), and the exact wire flags. Bounds are the
// cached native basis used to request the transform, not an independent read.
@property(nonatomic,readonly,copy) NSArray<NSDictionary *> *members;
@end
// Main thread only, but for the library's two callbacks and the watchdog, which touch
// only what is said of them in the implementation.
@interface DWNativePresenter : NSObject
// Opens the session before any canvas or IPC socket exists. The connection and
// a negotiated read-only scope audit each have a two-second deadline. `scope` is
// --only-pid's: cooperative helpers must own its one process; allowlist helpers
// must report exactly the same PIDs and birth timestamps, with no extra process.
// Same-user scope and unauditable allowlist helpers fail closed. nil, with `why`,
// otherwise. This never loads a helper or expands its authority.
+ (instancetype)presenterAt:(NSString *)runtime nonce:(NSString *)nonce64 scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope why:(NSString *__autoreleasing *)why;
// One to four explicit {runtime,nonce} endpoints. Every endpoint must audit its
// own process subset; their disjoint union must exactly match `scope`. Single
// endpoint behavior is unchanged. Nothing is loaded or implicitly enrolled.
+ (instancetype)presentersAt:(NSArray<NSDictionary *> *)endpoints scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope why:(NSString *__autoreleasing *)why;
// Recovery preparation, on a worker queue: same endpoints and exact process
// instances, authenticated enrollment required even for cooperative helpers,
// and an empty helper restore table. No frames or watchdog are started here.
+ (instancetype)reconnectedPresentersAt:(NSArray<NSDictionary *> *)endpoints scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope why:(NSString *__autoreleasing *)why;
// Explicit desktop-wide mode: one authenticated same-user helper hosted by the
// login user's Apple-signed Dock. Audits SAME_USER with zero finite enrollment
// entries and requires alpha readback, per-window restoration and an empty
// previous restoration table. Future same-user application
// processes are admitted by fresh UID/birth/window/root checks, not by a PID
// list captured at launch. No helper is loaded and no window is enrolled here.
// The caller must reject multiple endpoints rather than partition this mode.
+ (instancetype)desktopPresenterAt:(NSString *)runtime nonce:(NSString *)nonce64 why:(NSString *__autoreleasing *)why;
// Same admission on a worker queue, including the previous restoration table;
// no frames/watchdog until -activate. A restarted Dock is independently audited.
+ (instancetype)reconnectedDesktopPresenterAt:(NSString *)runtime nonce:(NSString *)nonce64 why:(NSString *__autoreleasing *)why;
// Main-thread admission after recovery preparation. NO if a helper was lost
// while the candidate was waiting. Does not bind or place a window.
- (BOOL)activate;
// Main thread: stop placement immediately, remove the run-loop watch, and drain
// restoration/connection closure off the main queue. Completion is on main.
- (void)suspendWithCompletion:(void (^)(void))completed;
// Broader allowlist helpers bind only verified native roots. Attached children
// follow that root's placement and do not become independent world windows.
- (BOOL)allowsWindow:(NSDictionary *)identity;
@property(nonatomic,readonly) BOOL familiesNeeded;
// Cached association for choosing a bound source; the caller must freshly
// validate PID/birth, recipient bounds and the native parent chain before input.
- (NSNumber *)rootWindowFor:(CGWindowID)window;
// A window was bound, or looked at again: {pid,birth_sec,birth_usec,wid} and its own
// frame. A frame that changed is drawn from at the next -submit even when its
// placement did not move: the transform maps onto the window's size.
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native;
// A serial observation worker can supply the read-only family report to keep
// its queries off the frame queue. nil performs a fresh query when required.
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family;
// Restore this identity's original transform and alpha through a negotiated
// per-window release record. It remains queued until acknowledged; other bound
// windows keep their placements. Every admitted helper must support this contract.
- (void)unbound:(NSDictionary *)identity;
// The frame this snapshot asks for: one record for every bound window (`identities`,
// logical id → identity), at its placement's screen_rect, or parked beyond every
// display when it has none. Nothing is sent. A snapshot without outputs (a display
// change between its two halves) describes nothing and leaves the last frame standing.
- (void)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities;
// Hands the described frame to the library's writer thread if it differs from the
// last one handed over, or a window's own frame changed since. Never waits.
- (void)submit;
// Main thread: supersede every receipt/pending ACK and require another eligible
// -describe and a newly submitted frame/ACK, even when its geometry is identical.
// Call once for each new consumer transfer/cancellation revision before describe.
// Grouped helpers invalidate their separate sessions together. This never sends
// prior records by itself; missing outputs/displays still leave the last frame
// standing and cannot acknowledge a new transition.
- (void)requireFreshPlacementAcknowledgement;
// Main-thread, read-only ACK lookup. nil until every family record in the exact
// current submitted frame was acknowledged APPLIED. Generation/output/family or
// requested geometry changes, a newer submission, unbinding and session loss
// revoke earlier receipts. Desired placement never becomes acknowledged merely
// because -describe or -submit succeeded. Grouped helpers retain separate session
// IDs and sequences; a receipt belongs only to its original owning session.
- (DWNativeAppliedPlacement *)acknowledgedPlacementForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation output:(NSNumber *)output;
// Call after the independent admission checks, immediately before input. This
// only fences the ACK against current presentation state; it performs no native
// getters or event-hit queries and never establishes usable input by itself.
- (BOOL)isAcknowledgedPlacementCurrent:(DWNativeAppliedPlacement *)placement;
// Main-thread, read-only desired clip plan from the last -describe. Every entry
// is tied to a still-bound full native identity, including family children.
// Native clipping is unsupported until the helper can snapshot, persist, apply,
// read back and restore the exact original shape/event/shadow regions. A plan
// is not a clipping acknowledgement, and never changes placement or authority.
- (NSArray<NSDictionary *> *)clippingPlan;
// Quit: every window put back, confirmed, within two seconds per helper; then each session is
// closed, which makes the helper restore whatever it still holds. One stderr line
// unless every window was restored or was gone.
- (void)finish;
// The DebugNative request (--debug-pointer): the library's counters, the helper's own
// probe (what it holds, with each window's transform, alpha and screen rectangle as
// the helper reads them), and the records last handed over. {"stall":N} answers and
// then keeps the main thread from its run loop for N seconds, at most 30.
- (NSData *)debug:(NSDictionary *)request;
// The helper is gone, the watchdog closed the session, or -finish ran. Nothing is
// described or sent from then on. Recovery creates a separately audited object.
@property (readonly) BOOL ended;
@end
