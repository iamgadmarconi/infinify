// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWCanvasCursor.h"

// NSCursor.currentCursor belongs to this application, not the application whose
// cursor is physically displayed elsewhere on the desktop:
// https://developer.apple.com/documentation/appkit/nscursor/current
// Setting a cursor changes the current application cursor without pushing one:
// https://developer.apple.com/documentation/appkit/nscursor/set()
@implementation DWCanvasCursor {
    __weak id _owner;
    NSCursor *_saved;
    NSCursor *_applied;
}
- (void)setCursor:(NSCursor *)cursor owner:(id)owner {
    if(!NSThread.isMainThread||!cursor||!owner)return;
    NSCursor *current=NSCursor.currentCursor;
    if(_applied&&current!=_applied){
        // Another AppKit policy has taken over. A prior saved cursor no longer
        // represents the state before this new override, so discard it.
        _owner=nil;_saved=nil;_applied=nil;
    }
    if(!_applied)_saved=current;
    _owner=owner;_applied=cursor;
    // Policy is refreshed at display rate; leave an unchanged cursor alone.
    if(current!=cursor)[cursor set];
}
- (void)releaseOwner:(id)owner {
    if(!NSThread.isMainThread||!owner||owner!=_owner)return;
    [self reset];
}
- (void)reset {
    if(!NSThread.isMainThread)return;
    NSCursor *current=NSCursor.currentCursor,*saved=_saved;
    BOOL restore=_applied&&current==_applied&&saved&&saved!=current;
    // Detach ownership before the AppKit call, so a later policy begins a new
    // override rather than inheriting the baseline that has just been released.
    _owner=nil;_saved=nil;_applied=nil;
    if(restore)[saved set];
}
@end

NSCursor *DWCanvasResizeCursor(NSString *edges) {
    if(!NSThread.isMainThread||![edges isKindOfClass:NSString.class])return nil;
    // Public since macOS 15; the backend targets macOS 26 or later.
    // https://developer.apple.com/documentation/appkit/nscursor/frameresize(position:directions:)
    static NSDictionary<NSString *,NSCursor *> *cursors;
    if(!cursors){
        NSDictionary<NSString *,NSNumber *> *positions=@{
            @"top":@(NSCursorFrameResizePositionTop),
            @"top_left":@(NSCursorFrameResizePositionTopLeft),
            @"top_right":@(NSCursorFrameResizePositionTopRight),
            @"left":@(NSCursorFrameResizePositionLeft),
            @"right":@(NSCursorFrameResizePositionRight),
            @"bottom":@(NSCursorFrameResizePositionBottom),
            @"bottom_left":@(NSCursorFrameResizePositionBottomLeft),
            @"bottom_right":@(NSCursorFrameResizePositionBottomRight)
        };
        NSMutableDictionary<NSString *,NSCursor *> *values=[NSMutableDictionary dictionaryWithCapacity:positions.count];
        for(NSString *edge in positions){
            NSCursor *cursor=[NSCursor frameResizeCursorFromPosition:(NSCursorFrameResizePosition)[positions[edge]unsignedIntegerValue] inDirections:NSCursorFrameResizeDirectionsAll];
            if(cursor)values[edge]=cursor;
        }
        cursors=values.copy;
    }
    return cursors[edges];
}
