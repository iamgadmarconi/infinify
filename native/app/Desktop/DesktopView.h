// SPDX-License-Identifier: GPL-3.0-or-later
// A canvas panel's view: pointer, press, scroll and touch handling over one panel's outputs.
#import <AppKit/AppKit.h>
#import "DWPointerHover.h"
#import "FlippedView.h"
@class Desktop, LiveSource;
@interface DesktopView : FlippedView
- (NSDictionary *)hit:(CGPoint)point output:(NSNumber *)output;
- (NSDictionary *)resizeBorderForButton:(NSInteger)button flags:(NSEventModifierFlags)flags hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output;
@property (weak) Desktop *desktop;
@property NSMutableArray<NSNumber *> *outputs;
@property CGRect globalBounds;
@property CGPoint startPoint;
@property CGPoint lastPoint;
@property NSNumber *dragOutput;
@property NSNumber *lastOutput; // most recently interacted output
@property LiveSource *pressedSource;
@property NSDictionary *pressedTarget;
@property BOOL pressedTablet;
@property NSNumber *pressedTabletDevice;
@property BOOL pressedPointerGrab;
@property CGPoint pressedLocal;
@property int64_t pressedButton; // CGMouseButton held down in pressedSource
// An unbound press on a window whose native focus is still being asked for, kept back until that request is answered
// (-holdPress:window:intent:at:output:): the press, its exact recipient before focus changes, where and on which output it fell,
// its latest drag, whether its button is up again, and any navigation waiting for that click to finish.
@property NSEvent *heldPress,*heldDrag,*heldRelease;
@property NSNumber *heldWindow,*heldOutput;
@property NSDictionary *heldIntent;
@property BOOL heldNavigate;
@property CGPoint heldPoint,heldDragPoint;
@property BOOL heldReleased;
@property CFTimeInterval heldSince;
@property NSTimer *heldTimer;
@property NSNumber *resizeTransaction;
@property NSInteger gesture; // 1 pan, 2 logical world drag, 3 native pointer, 4 native resize
@property NSInteger gestureButton; // NSEvent button number that began the gesture
// An event intercepted above a real native window keeps its global Quartz point;
// its AppKit location belongs to that window, not to this canvas panel.
@property BOOL nativePointValid;
@property CGPoint nativePoint;
// Only for a freshly validated native child recipient outside its root's tile.
// This supplies the root's binding context, never synthetic app input.
@property NSDictionary *nativeFamilyHit;
// Only a positively identified native root drag region installs this intent.
// It keeps the binding/output of the swallowed physical pair, never app input.
@property NSDictionary *nativeTitlePress;
@property BOOL nativeTitleMoved,nativeTitleReleased;
- (BOOL)nativeTitlePressCurrent;
@property CFTimeInterval lastScrollPan; // last finger scroll that panned, 0 for none
@property BOOL clearsFocus; // a pan begun on empty canvas that has not moved 5 points yet: released so, it unfocuses
@property NSNumber *clickWindow; // the window an unbound press focused: released within 5 points, it is a completed click
@property NSNumber *scrollPan; // the output the trackpad scroll under way, or just lifted, panned; nil for none
@property NSTimeInterval scrollPanTime; // event time of that scroll's last pan, 0 once a press has ended it
@property NSTimeInterval lastDragPan; // event time of the last timed pan under this drag pan's button, its own or a scroll's; 0 for none
@property CFTimeInterval liftSeen; // when the gesture's button was first read as up while its gesture is still held; 0 while it is down
@property CFTimeInterval takenOverAt; // a native window drag taken over (-[Desktop takeOverNativeDrag:event:]): when; 0 for any other gesture
// --debug-pointer: a press the DebugPointer request made is down, with no physical button behind it; the timer ends one its test abandoned.
@property BOOL injected;
@property NSTimer *injectedTimer;
// That press: where it is now, a global screen point (where it went down, then where its last drag took it), where it went down, its
// button (0 left, 1 right, 2 middle) and the modifiers held with it.
@property CGPoint injectedPoint,injectedStart;
@property NSInteger injectedButton;
@property NSEventModifierFlags injectedFlags;
- (void)released:(CGPoint)p at:(NSTimeInterval)time;
- (void)render:(NSDictionary *)snapshot;
- (NSNumber *)outputAt:(CGPoint)p;
- (NSNumber *)actionOutput;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)p output:(NSNumber *)output;
@end
@interface DesktopView ()
@property DWPointerHover *hover;
@end
@interface DesktopView (Pointer) <DWPointerHost>
- (void)refreshCursor;
@end
// Implemented in DesktopView.m; called from Desktop (Hover), (Input), and (Windows)/(Rendering)/(Session).
@interface DesktopView ()
- (NSDictionary *)inputIntentForHit:(NSDictionary *)hit output:(NSNumber *)output;
- (void)beginResize:(NSNumber *)window edges:(NSString *)edges snapped:(BOOL)snapped at:(CGPoint)p output:(NSNumber *)output;
- (void)releasePressed;
@end
