// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

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
- (void)reset;
@end
