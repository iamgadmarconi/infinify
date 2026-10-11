// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

// Main-thread-only cursor policy for Infinify's own canvas. This does not
// inspect or change a foreign application's cursor, cursor visibility or stack.
// The owner is a weak identity token; its lifetime is managed by the caller.
@interface DWCanvasCursor : NSObject
// Nil cursor/owner and calls off the main thread are ignored. Changing owners
// shares the existing override; it does not replace the saved initial cursor.
- (void)setCursor:(NSCursor *)cursor owner:(id)owner;
// Releasing another owner is a no-op. Restore the saved application cursor only
// while our exact last applied cursor is still the application's current one.
- (void)releaseOwner:(id)owner;
- (void)reset;
@end

// Public frame-resize cursors for the controller's eight snake_case edges.
// Unknown edges and calls off the main thread return nil.
NSCursor *DWCanvasResizeCursor(NSString *edges);
