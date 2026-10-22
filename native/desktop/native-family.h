// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Read-only native parent/association query. Each member must belong to the
// supplied process instance and have an acyclic native parent chain to this root.
// Returns {root,identity,members:[{identity,native_bounds,parent}]} or nil with why.
// Native bounds are untransformed; this never expands a process scope or changes
// a window. Call from a serial observation worker, or a fresh event/input read.
NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why);
// Exact native-parent read; NO on missing/ambiguous/changed identity.
BOOL DWNativeWindowParent(NSDictionary *identity,uint32_t *parent);
// A fresh, bounded native parent chain, checked against the exact process
// instance at every step. Cached family membership alone never authorizes input.
BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *root);
// Worker-only candidate stability basis, separately from animated CG screen
// bounds. Exact same-user PID/birth/WID and on-screen ownership are read afresh
// before/after native bounds and affine-transform getters. No authority or lease.
NSDictionary *DWNativeWindowDiscoveryBasis(NSDictionary *identity);
// Experimental capture-control classification, read-only on an observation
// worker. Requires a freshly verified same-process direct child, contained
// unchanged native bounds, and one exact AXWindow/AXDialog with one same-process
// AXButton titled WindowSharingSessionButton. Missing/ambiguous/timed-out reads
// return NO. Never removes native family membership or restoration obligations.
BOOL DWNativeWindowIsCaptureControl(NSDictionary *member,NSDictionary *root,CGRect rootBounds,CGRect memberBounds);
