// SPDX-License-Identifier: GPL-3.0-or-later
// Internal interface of DWWindowManager, shared by DWWindowManager.m and DWWindowManager+Discovery.m: the class extension,
// the stability interval, the discovery category and the helper functions both files call.
// Split from native/desktop/window-manager.m at 37b27b1, moved verbatim.
#pragma once
#import "DWWindowManager.h"
#import "DWWindowEvents.h"
#import <AppKit/AppKit.h>
// Ordinary candidates wait for two stable observations. A positively identified
// standard native window may use the stricter post-AX basis check below instead.
static const NSTimeInterval still=.05;
@interface DWWindowManager () <DWWindowEventSink>
@property (weak) id<DWWindowHost> host;
@property DWWindowEvents *events;
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property (readwrite) BOOL capturing;
@property BOOL native;
// On-screen candidates already offered, found bound, or given up on.
@property NSMutableSet<NSNumber *> *offered;
// The windows -windowNotAdopted: has been told of, until they leave the screen.
@property NSMutableSet<NSNumber *> *declined;
// Candidates one read did not list: a second miss ends the asking.
@property NSMutableSet<NSNumber *> *missed;
// Candidates their application answered for without listing them among its windows: each is asked about once more.
// Its own count, not `missed`: a window the shareable windows missed first is still owed that second look.
@property NSMutableSet<NSNumber *> *unlisted;
// The previous pass's candidate bounds, by window number, and when each window was first seen with them.
@property NSDictionary<NSNumber *,NSDictionary *> *bounds;
@property NSDictionary<NSNumber *,NSDictionary *> *bases;
@property NSDictionary<NSNumber *,NSNumber *> *sampled;
@property NSDictionary<NSNumber *,NSNumber *> *since;
// An unavailable native title delays only this exact appearance/basis. Each
// read owns its ticket; a fresh CG title or change hint retires that ticket so
// an older AX reply cannot put the candidate back into a two-second wait.
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *titleRetries;
// Positive AX metadata may arrive during the native basis hold. Tickets bind
// it to one exact appearance, basis and CG-title version; negative early reads
// do not spend admission retries or invent a title.
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *nativeMetadata;
// One direct AX creation read, independent of the global discovery/AX flight.
// Raw events retire its ticket even while their ordinary hint is coalesced.
@property NSDictionary *creationTicket;
@property BOOL creationReading;
@property CFTimeInterval nativeSampleAt;
@property NSUInteger creationTraceLines; // DEBUG only, bounded for this manager lifetime
// The candidates of the last read, until it succeeds.
@property NSSet<NSNumber *> *requested;
// When each world window last had a placement.
@property NSMutableDictionary<NSNumber *,NSNumber *> *placed;
// When the first pass began; when a read that failed is tried again, 0 when none is owed; when the next reconciliation is
// due; and until when the poll keeps its own pace although the observers are in place.
@property NSTimeInterval began,retry,next,eager;
@property NSTimer *discoveryTimer;
@property NSTimeInterval discoveryDeadline;
@property BOOL reading, completed, stopped;
@end
// Implemented in DWWindowManager.m; called from DWWindowManager+Discovery.m.
@interface DWWindowManager ()
- (void)requestDiscoveryAfter:(NSTimeInterval)delay;
- (void)prefetchNativeMetadata:(NSDictionary<NSNumber *,NSNumber *> *)asked titles:(NSDictionary *)listedTitles records:(NSArray<NSDictionary *> *)records;
- (void)declineWindow:(NSNumber *)wid pid:(NSNumber *)pid;
@end
@interface DWWindowManager (Discovery)
- (void)passRecords:(NSArray<NSDictionary *> *)list nativeCandidateBases:(NSDictionary<NSNumber *,NSDictionary *> *)nativeCandidateBases sampledAt:(CFTimeInterval)sampledAt;
- (void)read:(SCShareableContent *)content error:(NSError *)error asked:(NSDictionary<NSNumber *,NSNumber *> *)asked front:(NSArray<NSNumber *> *)front subroles:(NSDictionary<NSNumber *,id> *)subroles titles:(NSDictionary<NSNumber *,NSString *> *)titles frames:(NSDictionary<NSNumber *,NSDictionary *> *)frames levels:(NSDictionary<NSNumber *,NSNumber *> *)levels basis:(NSDictionary<NSNumber *,NSDictionary *> *)basis titleTickets:(NSDictionary<NSNumber *,NSDictionary *> *)tickets earlyTickets:(NSDictionary<NSNumber *,NSDictionary *> *)earlyTickets;
- (void)complete:(SCShareableContent *)content;
@end
NSDictionary<NSNumber *,id> *DWWindowManagerSubroles(NSDictionary<NSNumber *,NSNumber *> *asked,NSMutableDictionary<NSNumber *,NSString *> *titles);
NSArray<NSDictionary *> *DWWindowManagerPreservedWindows(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope,NSSet<NSNumber *> *offered,NSInteger panelLevel,NSString *__autoreleasing *why);
BOOL DWWindowManagerIsToplevelSubrole(NSString *subrole);
BOOL DWWindowManagerIsCanonicalBasis(NSDictionary *basis);
