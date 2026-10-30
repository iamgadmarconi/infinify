// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable AppKit drag source and destination used to measure drag-and-drop under WindowServer transforms (compositor
// mode), where a window is drawn away from its native frame. See tests/e2e/compositor-dnd.sh. It owns one titled window;
// its top half starts an NSDraggingSession carrying a file URL, its whole content registers as a destination, and every
// callback appends one JSON line (window-local point, screen point from the native frame, the pointer's own position) to
// the log, so the destination's conversion can be compared with where the pointer really is.
// usage: native-dnd-probe NAME X Y W H LOGFILE FILEPATH   (X, Y, W, H: top-left screen points of the content rectangle)
#import <AppKit/AppKit.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static FILE *lf;
static NSString *gName;
static double primaryH(void) { return NSScreen.screens.firstObject.frame.size.height; }
static NSPoint topLeft(NSPoint p) { return NSMakePoint(p.x, primaryH() - p.y); }
static void logj(NSString *ev, NSDictionary *extra) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:extra];
    d[@"ev"] = ev; d[@"app"] = gName; d[@"t"] = @(CACurrentMediaTime());
    NSPoint m = topLeft(NSEvent.mouseLocation); d[@"mouse"] = @[@(m.x), @(m.y)];
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    fwrite(j.bytes, 1, j.length, lf); fputc('\n', lf); fflush(lf);
}
static NSArray *pt(NSPoint p) { return @[@(p.x), @(p.y)]; }

@interface DView : NSView <NSDraggingSource, NSDraggingDestination>
@property NSString *filePath; @property NSPoint downPoint; @property BOOL began; @property NSInteger mark;
@end
@implementation DView
- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)drawRect:(NSRect)r {
    [[NSColor colorWithCalibratedRed:.92 green:.92 blue:.98 alpha:1] setFill]; NSRectFill(self.bounds);
    NSRect top = NSMakeRect(0, self.bounds.size.height / 2, self.bounds.size.width, self.bounds.size.height / 2);
    [[NSColor colorWithCalibratedRed:.9 green:.6 blue:.2 alpha:1] setFill]; NSRectFill(top);
    NSDictionary *a = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:22]};
    [[NSString stringWithFormat:@"%@ SOURCE (drag me)", gName] drawAtPoint:NSMakePoint(10, self.bounds.size.height - 40) withAttributes:a];
    [[NSString stringWithFormat:@"%@ DROP HERE", gName] drawAtPoint:NSMakePoint(10, 20) withAttributes:a];
    // 8x8 grid lines so screenshots show the hit position
    [[NSColor grayColor] setStroke];
    for (int i = 1; i < 8; i++) { NSBezierPath *p = [NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(self.bounds.size.width * i / 8, 0)]; [p lineToPoint:NSMakePoint(self.bounds.size.width * i / 8, self.bounds.size.height)]; [p stroke]; }
}
- (void)mouseDown:(NSEvent *)e { self.downPoint = [self convertPoint:e.locationInWindow fromView:nil]; self.began = NO; logj(@"mouseDown", @{@"winLoc": pt(e.locationInWindow)}); }
- (void)mouseUp:(NSEvent *)e { logj(@"mouseUp", @{@"winLoc": pt(e.locationInWindow)}); }
- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (self.began || hypot(p.x - self.downPoint.x, p.y - self.downPoint.y) < 4) return;
    if (self.downPoint.y < self.bounds.size.height / 2) return; // only the top half is a source
    self.began = YES;
    NSMutableArray *items = [NSMutableArray array];
    NSImage *img = [NSImage imageWithSize:NSMakeSize(120, 60) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor colorWithCalibratedRed:.1 green:.6 blue:.2 alpha:.9] setFill]; NSRectFill(r);
        [@"DRAG" drawAtPoint:NSMakePoint(8, 20) withAttributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:24]}]; return YES; }];
    NSURL *u = [NSURL fileURLWithPath:self.filePath];
    NSDraggingItem *it = [[NSDraggingItem alloc] initWithPasteboardWriter:u];
    [it setDraggingFrame:NSMakeRect(self.downPoint.x - 60, self.downPoint.y - 30, 120, 60) contents:img];
    [items addObject:it];
    NSDraggingSession *s = [self beginDraggingSessionWithItems:items event:e source:self];
    s.animatesToStartingPositionsOnCancelOrFail = YES;
    logj(@"beginSession", @{@"down": pt(self.downPoint), @"winLoc": pt(e.locationInWindow)});
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c { return NSDragOperationCopy | NSDragOperationGeneric; }
- (void)draggingSession:(NSDraggingSession *)s willBeginAtPoint:(NSPoint)p { logj(@"willBegin", @{@"screen": pt(topLeft(p))}); }
- (void)draggingSession:(NSDraggingSession *)s movedToPoint:(NSPoint)p { logj(@"moved", @{@"screen": pt(topLeft(p))}); }
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op { logj(@"ended", @{@"screen": pt(topLeft(p)), @"op": @(op)}); }
- (void)rec:(NSString *)ev info:(id<NSDraggingInfo>)i {
    NSPoint wl = i.draggingLocation; NSWindow *w = self.window;
    NSPoint sc = [w convertPointToScreen:wl];
    NSRect f = w.frame; NSRect cf = [w contentRectForFrameRect:f];
    logj(ev, @{@"winLoc": pt(wl), @"viewLoc": pt([self convertPoint:wl fromView:nil]), @"screen": pt(topLeft(sc)),
               @"imageLoc": pt(topLeft([w convertPointToScreen:i.draggedImageLocation])),
               @"contentTL": pt(NSMakePoint(cf.origin.x, primaryH() - cf.origin.y - cf.size.height)), @"contentSize": @[@(cf.size.width),@(cf.size.height)],
               @"types": i.draggingPasteboard.types ?: @[], @"mask": @((NSUInteger)i.draggingSourceOperationMask)});
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)i { [self rec:@"entered" info:i]; return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)i { static int n; if ((n++ % 6) == 0) [self rec:@"updated" info:i]; return NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)i { logj(@"exited", @{}); }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)i { [self rec:@"prepare" info:i]; return YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)i {
    [self rec:@"perform" info:i];
    NSString *s = [i.draggingPasteboard stringForType:NSPasteboardTypeString];
    NSArray *urls = [i.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:nil];
    logj(@"payload", @{@"string": s ?: @"", @"urls": [urls valueForKey:@"absoluteString"] ?: @[]});
    return YES;
}
- (void)concludeDragOperation:(id<NSDraggingInfo>)i { logj(@"conclude", @{}); }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 8) { fprintf(stderr, "usage\n"); return 2; }
        gName = [NSString stringWithUTF8String:argv[1]];
        double x = atof(argv[2]), y = atof(argv[3]), w = atof(argv[4]), h = atof(argv[5]);
        lf = fopen(argv[6], "a");
        NSApplication *app = NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect cr = NSMakeRect(x, primaryH() - y - h, w, h);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:cr styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        win.title = gName; win.releasedWhenClosed = NO;
        DView *v = [[DView alloc] initWithFrame:NSMakeRect(0, 0, w, h)]; v.filePath = [NSString stringWithUTF8String:argv[7]];
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [v registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL, NSPasteboardTypeString, NSPasteboardTypeTIFF, NSPasteboardTypePNG, @"public.url", @"com.apple.pasteboard.promised-file-url"]];
        win.contentView = v; [win setFrameOrigin:[win frameRectForContentRect:cr].origin];
        [win makeKeyAndOrderFront:nil]; [app activateIgnoringOtherApps:YES];
        logj(@"ready", @{@"windowNumber": @(win.windowNumber), @"pid": @(getpid())});
        [app run];
    }
    return 0;
}
