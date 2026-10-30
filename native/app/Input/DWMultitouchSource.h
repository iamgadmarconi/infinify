// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWDockGuard.h"
@class DWTrackpadGestures;
// Raw trackpad contacts from anywhere, for DWTrackpadGestures. AppKit hands a view
// NSTouches only while the pointer is over that view of the key window, so three or four
// fingers over a native window, or with another application key, reach nobody. The
// private MultitouchSupport framework (the one Mac gesture tools read) reports every
// contact of every trackpad to a callback, wherever the pointer is. This file is the
// part of it that is not the recogniser: DWMultitouchSource takes the framework's frames
// and DWMultitouchFeed turns them into the calls the recogniser has always had.
// Nothing here has run on a physical trackpad.
//
// The source is `delivering` only once a frame has arrived. Until then, and whenever the
// framework, a symbol or a device is missing, the NSTouch path of main.m is untouched;
// while it delivers, that path does not also feed the recogniser.

// One contact of a MultitouchSupport frame is a 96-byte record; these are the fields read.
// The layout is Sunlight's (and every other tool's that reads the framework); it is not
// documented by Apple and was not checked against a record of this machine's.
enum { DWContactSize=96,DWContactPath=16,DWContactState=20,DWContactX=32,DWContactY=36 };
// `state` of a contact that is on the surface: make-touch and touching. Hovering, breaking
// off the surface and lingering in range are not fingers.
enum { DWContactMake=3,DWContactTouching=4 };

// One frame of contacts of one device, ready for the main thread.
@interface DWMultitouchFrame : NSObject
// The fingers on the surface: @{@"path":NSNumber (stable while the finger stays down),
// @"x":0…1 left to right,@"y":0…1 bottom to top,@"state":NSNumber}. None for a lift of the last.
@property (readonly) NSArray<NSDictionary *> *contacts;
@property (readonly) CGSize surface;          // the device's surface in millimetres
@property (readonly) NSTimeInterval time;     // CACurrentMediaTime() when the framework called
@property (readonly) uint32_t contact;        // DWDockGuard's number of the touch these fingers belong to
@property (readonly) NSUInteger generation;   // which start of the source made it: a stale frame is dropped
+ (instancetype)frameWithContacts:(NSArray<NSDictionary *> *)contacts surface:(CGSize)surface time:(NSTimeInterval)time contact:(uint32_t)contact generation:(NSUInteger)generation;
@end

@interface DWMultitouchSource : NSObject
// `frames` is called on the main thread, in the order the frames came, for the one device
// that is being followed: the first with a contact, until its last contact lifts. `guard`
// (optional) is told the finger count on the framework's own thread, before the main
// thread has seen the frame, because the system's gestures do not wait for it.
- (instancetype)initWithGuard:(DWDockGuard *)guard frames:(void (^)(DWMultitouchFrame *frame))frames;
// Whether a contact is one the NSTouch path would call `resting` (a thumb on the pad, a
// palm) and so is left out of the frame. MultitouchSupport carries no such flag, and nothing
// in-tree classifies: with no block, every touching contact is a finger. Set before -start.
@property (copy) BOOL (^resting)(NSDictionary *contact);
// Called on the main thread when the source starts or stops delivering.
@property (copy) void (^deliveringChanged)(BOOL delivering);
@property (readonly) BOOL running;     // devices are registered and started
@property (readonly) BOOL delivering;  // running, and a frame has arrived since
// YES when at least one device with a surface size is started. NO leaves everything as it was and says why once on stderr.
- (BOOL)start;
- (void)stop;
// Decoding, device choice and the guard, without the framework: what the callback does with
// `count` records. NULL for a frame that is not to be delivered (another device is being followed).
- (DWMultitouchFrame *)intake:(const void *)records count:(int32_t)count device:(uintptr_t)device surface:(CGSize)surface at:(NSTimeInterval)now;
// The main-thread half, for a frame -intake: made.
- (void)deliver:(DWMultitouchFrame *)frame;
@end

// A frame at a time into the recogniser, on the main thread. The first frame of a touch with
// three or more fingers asks `admit` (is a button down, is there a canvas under the pointer,
// ...) and the answer holds until every finger has lifted; fingers before the third are
// counted and not passed on, as the NSTouch path does not pass them. Lifted fingers are
// ended explicitly, so a clean lift ends a gesture uncancelled.
@interface DWMultitouchFeed : NSObject
// `recogniser` is asked for the recogniser each time, since the shell makes and drops it.
- (instancetype)initWithRecogniser:(DWTrackpadGestures *(^)(void))recogniser admit:(BOOL (^)(NSUInteger fingers))admit;
// YES when the recogniser saw the frame.
- (BOOL)consume:(DWMultitouchFrame *)frame;
// The touches stop being a gesture's: the recogniser forgets its fingers and a gesture ends cancelled; if the
// touch had been admitted, the rest of it is ignored until every finger has lifted.
- (void)cancel:(NSTimeInterval)time;
@property (readonly) NSUInteger fingers;  // contacts in the last frame
@property (readonly) BOOL refused;        // this touch was declined by `admit`
@end
