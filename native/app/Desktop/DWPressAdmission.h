// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "DWNativeResize.h"
@class Desktop, DesktopView, LiveSource, DWNativeAppliedPlacement, DWNativePresenter;
// Internal seams: real macOS/scene adapters in production, in-memory adapters
// in later interface tests. Failure is nil/NO, never a guessed native recipient.
@protocol DWPressNativeLookup <NSObject>
- (BOOL)trusted;
- (BOOL)scope:(NSDictionary *)scope contains:(pid_t)pid;
- (BOOL)physicalButton:(CGMouseButton)button;
- (NSUInteger)pressedButtons;
- (BOOL)foreignRecipient:(CGEventRef)event;
- (NSTimeInterval)uptime;
- (CFTimeInterval)mediaTime;
- (double)monotonicSeconds;
- (CGWindowID)windowAt:(CGPoint)point;
- (BOOL)parent:(NSDictionary *)identity result:(uint32_t *)parent;
- (BOOL)member:(NSDictionary *)member belongsTo:(NSDictionary *)root;
- (BOOL)placement:(DWNativeAppliedPlacement *)placement presenter:(DWNativePresenter *)presenter recipient:(NSDictionary *)recipient at:(CGPoint)point;
- (BOOL)endNativeDragAt:(CGPoint)point tag:(int64_t)tag;
- (DWResizeResult)reposition:(DWResizeIdentity)identity from:(CGRect)from to:(CGPoint)origin deadline:(double)deadline;
- (NSDictionary *)buttons:(NSDictionary *)identity;
- (NSDictionary *)recipient:(CGPoint)point;
- (NSArray *)windows:(CGWindowID)window;
- (NSDictionary *)windowInfo:(CGWindowID)window;
- (NSArray *)birth:(pid_t)pid;
- (BOOL)bounds:(CGWindowID)window result:(CGRect *)bounds;
- (BOOL)owner:(NSDictionary *)identity bounds:(CGRect *)bounds;
@end
@protocol DWPressSceneLookup <NSObject>
- (NSDictionary *)presentationSnapshot;
- (NSString *)standInPart:(NSNumber *)window output:(NSNumber *)output screen:(CGPoint)point snapshot:(NSDictionary *)snapshot;
- (NSDictionary *)call:(NSDictionary *)request;
- (NSDictionary *)hit:(CGPoint)point output:(NSNumber *)output view:(DesktopView *)view;
- (NSDictionary *)binding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window under:(NSNumber *)under pick:(BOOL)pick;
@end
typedef NS_ENUM(NSInteger,DWPressStage) { DWPressSession, DWPressAnnotated };
// Main-thread-only press ownership. Early/session admission must precede annotated
// admission. YES consumes the packet and keeps its paired tail here; NO leaves it
// native. Missing or stale evidence refuses admission, never infers app input.
@interface DWPressAdmission : NSObject
- (instancetype)initWithDesktop:(Desktop *)desktop scene:(id<DWPressSceneLookup>)scene native:(id<DWPressNativeLookup>)native;
- (NSDictionary *)hit:(CGPoint)point output:(NSNumber *)output view:(DesktopView *)view;
- (void)mouseDown:(NSEvent *)event view:(DesktopView *)view;
- (BOOL)prepareDrag:(NSEvent *)event at:(CGPoint)point view:(DesktopView *)view;
- (void)noteRelease:(NSEvent *)event view:(DesktopView *)view;
- (NSDictionary *)releaseTitleAt:(CGPoint)point view:(DesktopView *)view;
@property (readonly) DesktopView *gestureView;
- (void)forgetNativeMouseOwner;
- (void)displayTopologyChanged;
@property (readonly) NSDictionary *decorationPress;
@property (readonly) NSNumber *buttonHover;
- (void)refreshNativeButtons:(LiveSource *)source;
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point;
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output;
- (BOOL)consume:(CGEventType)type event:(CGEventRef)event stage:(DWPressStage)stage;
- (void)cancelNativeInput;
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point;
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons;
- (void)updateNativeMouseOwners;
@end
