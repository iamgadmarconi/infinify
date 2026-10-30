// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWWindowEvents's internal interface: the shared constants, the class extension and the category interfaces of the DWWindowEvents*.m files.
// Split from native/desktop/window-events.m at 37b27b1, moved verbatim.
#import "DWWindowEvents.h"
#include <signal.h>
#include <errno.h>
#include <string.h>
#import "DWNativeFocus.h"
#include <dlfcn.h>
#include <os/lock.h>
#import "DWApplicationWatch.h"
#import "DWApplicationCatalogWatch.h"
#import "DWApplicationMetadata.h"
#import "DWObservedApplication.h"
#import "DWObservedWindow.h"
// What an application is given to answer one Accessibility message. Asked on the worker only.
static const float answer=.25;
// One report per window per this long while notifications keep coming: the idle poll's period, so a window in a storm is
// looked at no more often than the poll looked at it.
static const NSTimeInterval coalesce=.08;
// yabai asks an application that did not answer again a tenth of a second later, for as long as it runs. Here that pace is
// kept for `quick` attempts; after them -reconcile asks, once a second.
static const NSTimeInterval retryDelay=.1;
static const int quick=5;
// yabai's application table (src/application.h) less the menu notifications, plus kAXWindowCreatedNotification. yabai has a new
// window from kAXCreatedNotification alone, which is posted for elements that are no window too; a window announced by either
// name is looked for, and watch() keeps only windows.
static CFStringRef const applicationNotifications[]={kAXCreatedNotification,kAXWindowCreatedNotification,kAXFocusedWindowChangedNotification,kAXWindowMovedNotification,kAXWindowResizedNotification,kAXTitleChangedNotification};
enum { applicationCount=6, every=(1<<applicationCount)-1 };
// In place of a window number in a coalescing key: the application's set of windows on screen may have changed.
static const CGWindowID appeared=UINT32_MAX;
// yabai's window table (src/window.h).
static CFStringRef const windowNotifications[]={kAXUIElementDestroyedNotification,kAXWindowMiniaturizedNotification,kAXWindowDeminiaturizedNotification};
enum { windowCount=3 };
enum { applicationAppeared=1, applicationChanged=2, applicationActivated=4 };
// The two serial queues (defined in DWWindowEvents.m: each is one queue for the process).
dispatch_queue_t DWWindowEventsQueue(void);
dispatch_queue_t DWWindowEventsApplicationQueue(void);
@interface DWWindowEvents ()
@property (weak) id<DWWindowEventSink> sink;
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property NSMutableDictionary<NSNumber *,DWObservedApplication *> *applications;
@property NSMapTable<NSRunningApplication *,DWApplicationWatch *> *applicationWatches;
@property DWApplicationCatalogWatch *applicationCatalogWatch;
@property NSNotificationCenter *workspaceNotifications;
@property uint64_t catalogRevision, observationEpoch, appliedCatalogRevision;
@property BOOL readingApplications, applicationReadQueued, hasApplicationCatalog, applicationCatalogDirty;
@property NSMutableArray<DWApplicationMetadata *> *applicationNotices;
@property BOOL resolvingApplicationNotices, applicationNoticeQueued;
// Coalescing, by pid<<32|window (`appeared` for an application's set of windows, 0 for native focus): when each was last
// reported, and which are owed one more report.
@property NSMutableDictionary<NSNumber *,NSNumber *> *sent;
@property NSMutableSet<NSNumber *> *owed;
// Subset of owed: every event in this pending batch was an exact known AXMoved.
// Generic changes only remove membership; a later move cannot narrow the batch.
@property NSMutableSet<NSNumber *> *moveOnly;
// The one timer: armed for the earliest report owed or quick attempt due.
@property NSTimer *timer;
@property NSTimeInterval checked;
@property NSTimeInterval creationTraceUntil; // DEBUG-only raw notifications for 150 ms after creation
@property pid_t creationTracePID;
@property NSUInteger creationTraceLines;
@property NSUInteger windowServerTraceLines; // DEBUG-only SkyLight 1325/1326 lines, counted apart from the Accessibility ones
@property BOOL trusted, stopped;
@property BOOL scanning; // one collection-KVO/initial catalog read is under way off the main thread
- (void)windowServerType:(uint32_t)type window:(CGWindowID)window;
@end
// Defined in DWWindowEvents.m, used by the categories.
@interface DWWindowEvents ()
- (void)deliver:(NSNumber *)key;
- (void)changed:(CGWindowID)window pid:(pid_t)pid;
- (void)changed:(CGWindowID)window pid:(pid_t)pid moveOnly:(BOOL)moved;
- (void)arm:(NSTimeInterval)delay;
- (void)due;
@end
// DWWindowEvents+Applications.m
@interface DWWindowEvents (Applications)
- (DWApplicationWatch *)watchApplication:(NSRunningApplication *)running;
- (void)forgetApplication:(DWApplicationWatch *)record ended:(BOOL)ended;
- (void)clearApplicationWatches;
- (void)observeApplicationCatalog;
- (void)reconcileApplications:(NSArray<NSRunningApplication *> *)running;
- (NSArray<DWApplicationMetadata *> *)applicationCatalogBindings;
- (BOOL)applicationBindingsCurrent:(NSArray<DWApplicationMetadata *> *)bindings;
- (BOOL)acceptApplicationCatalog:(NSArray<DWApplicationMetadata *> *)catalog;
- (void)scanApplications;
- (void)queueApplicationRead;
- (void)readApplications;
- (void)acceptApplication:(DWApplicationMetadata *)read;
- (void)applyApplicationNotice:(DWApplicationMetadata *)notice;
- (void)queueApplicationNotices;
- (void)resolveApplicationNotices;
- (void)applicationNotification:(NSNotification *)note hints:(NSUInteger)hints identity:(BOOL)identity;
- (void)launched:(NSNotification *)note;
- (void)terminated:(NSNotification *)note;
- (void)activated:(NSNotification *)note;
- (void)hidden:(NSNotification *)note;
- (void)unhidden:(NSNotification *)note;
- (void)spaceChanged:(NSNotification *)note;
@end
// DWWindowEvents+Observation.m
@interface DWWindowEvents (Observation)
- (void)observe:(DWObservedApplication *)application;
- (void)observed:(DWObservedApplication *)application observer:(AXObserverRef)observer element:(AXUIElementRef)element registered:(uint8_t)mask retry:(BOOL)retry final:(BOOL)final;
- (void)list:(DWObservedApplication *)application;
- (void)resolve:(AXUIElementRef)element application:(DWObservedApplication *)application;
- (void)watched:(NSArray<DWObservedWindow *> *)found application:(DWObservedApplication *)application;
- (void)unwatch:(DWObservedWindow *)window observer:(AXObserverRef)observer;
- (void)remove:(pid_t)pid ended:(BOOL)ended;
- (void)notified:(CFStringRef)notification element:(AXUIElementRef)element application:(DWObservedApplication *)application window:(DWObservedWindow *)window;
@end
