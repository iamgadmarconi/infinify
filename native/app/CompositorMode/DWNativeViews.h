// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class DWNativeAppliedPlacement;

// One explicit replica-to-native request. Immutable correspondence only: it
// grants neither input nor optical/clipping authority. Every supersession and
// cancellation uses a new token, even when the target geometry is unchanged.
@interface DWNativeViewTransfer : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic,readonly,copy) NSUUID *requestID;
@property(nonatomic,readonly) uint64_t window,generation,output;
@property(nonatomic,readonly,copy) NSDictionary *identity;
@property(nonatomic,readonly) CGRect screenRect,clipRect,viewport;
// Complete sorted audited family, including the root, with exact identity,
// native_bounds and parent. Absence of a report never means root-only.
@property(nonatomic,readonly,copy) NSArray<NSDictionary *> *members;
@end
typedef BOOL (^DWNativeViewPlacementCheck)(DWNativeAppliedPlacement *placement);

// Pure adapter projection for either capture-overlay or native presentation.
// Normalizes output rectangles/cameras and exact root bindings, then adds only
// observed descendant placements whose root is outside an output. No owner is
// selected, no window is mutated, and no capture/input readiness is inferred.
// Invalid snapshots return nil; invalid bindings/families cannot add a site.
NSDictionary *DWNativeFamilyPresentationSnapshot(NSDictionary *snapshot,
    NSDictionary<NSNumber *,NSDictionary *> *bound,
    NSDictionary<NSNumber *,NSDictionary *> *families);

// Adapter-only presentation plan. A native window has one WindowServer
// transform; other output placements are live images with independent cameras.
// Current output rectangles and source identities are reconciled on every
// description. Owner stability and visible-area ties use logical points, never
// backing pixels; a display density change alone cannot move the real window.
// A site below one point in either dimension cannot be expressed by the native
// presenter and is a replica, even when no real placement is available.
// No world/camera state is changed here. This plan is not an acknowledgement of
// native clipping or capture readiness. Main thread only.
@interface DWNativeViews : NSObject
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities;
// Current audited geometry, independent of capture demand: logical root ->
// {identity,generation,native_bounds,members:[{identity,native_bounds,parent}]}.
// `parent` is the native parent window number. A family must match this
// snapshot's full source binding and observed root rectangle. Only descendants
// with a complete parent chain to that root can extend its presentation.
// Geometry can request capture; it never acknowledges pixels or native input.
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities families:(NSDictionary<NSNumber *,NSDictionary *> *)families;
// Full adapter presentation for rendering and capture demand. Controller
// windows, world rectangles and cameras are unchanged. Added placements have
// family_only:YES and show observed children while their root is outside this
// viewport; their screen_rect is the root's complete projection, clip_rect is
// the envelope of visible children, and root crop fields are null. A clip's
// empty gaps cannot authorize input: require a current captured member hit.
// They are
// always replicas, never physical ownership sites. Fullscreen roots stay on
// their own output; pins stay on their pinned display. Null until described.
@property(nonatomic,readonly) NSDictionary *presentationSnapshot;
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output;
- (NSDictionary *)placement:(NSNumber *)window output:(NSNumber *)output;
@property(nonatomic,readonly) NSSet<NSNumber *> *capturedWindows;
// Initial/automatic selection and same-output camera motion retain ordinary
// primary rendering. They are desired presentation, never input admission.
// Only an explicit transfer covers both old/new sites with captured copies.
- (NSNumber *)desiredOwnerForWindow:(NSNumber *)window;
// Current description has an eligible audited transfer site. This is policy
// eligibility only, not capture availability or native placement admission.
- (BOOL)canTransferWindow:(NSNumber *)window output:(NSNumber *)output;
- (DWNativeViewTransfer *)requestTransferForWindow:(NSNumber *)window output:(NSNumber *)output;
- (DWNativeViewTransfer *)currentTransferForWindow:(NSNumber *)window;
// Coverage can outlive a request when no complete recovery site is eligible.
// A press addressed to this exact family must still be refused as a whole pair.
- (BOOL)requiresPlacementAdmissionForWindow:(NSNumber *)window;
@property(nonatomic,readonly,copy) NSArray<DWNativeViewTransfer *> *pendingTransfers;
- (BOOL)isTransferCurrent:(DWNativeViewTransfer *)transfer;
// Cancelling a pending request stages a NEW recovery token for a fully visible
// ordinary primary (or another eligible site); copies stay until it settles.
// Geometry verification can settle that recovery without the pointer there.
// With no eligible full family, it stays unavailable until a later description.
// Cancelling a completed transfer releases its admission, not its committed
// ordinary primary. This method performs no native restoration or input.
- (void)cancelTransfer:(DWNativeViewTransfer *)transfer;
// current checks the presenter's exact ACK before and after validateGeometry,
// which must freshly verify the full native family, transforms and screen.
// Admission commits presentation ownership only. Before EACH input event,
// separately verify its exact event-eligible recipient/point and recheck this
// token + ACK; these callbacks establish no optical or native clip proof.
- (BOOL)completeTransfer:(DWNativeViewTransfer *)transfer placement:(DWNativeAppliedPlacement *)placement current:(DWNativeViewPlacementCheck)current validateGeometry:(DWNativeViewPlacementCheck)validateGeometry;
- (DWNativeAppliedPlacement *)admittedPlacementForWindow:(NSNumber *)window;
- (NSNumber *)admittedOwnerForWindow:(NSNumber *)window;
- (BOOL)isAdmissionCurrentForTransfer:(DWNativeViewTransfer *)transfer placement:(DWNativeAppliedPlacement *)placement;
// Main must include this in its native-description cache key and render again
// after a request/cancel/admission; ordinary describe alone does not increment.
@property(nonatomic,readonly) uint64_t transferRevision;
// Fresh presenter ACK is needed only for a new/recovery request, not the repaint
// that completes it. Main invalidates readiness once when this revision changes.
@property(nonatomic,readonly) uint64_t placementRequestRevision;
- (void)reset;
@end
