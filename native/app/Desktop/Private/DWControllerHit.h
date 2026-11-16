// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWScene.h"
// The controller's answer to a hit query, as the pointer paths use it. It answers {"hit": null} when no source lies under
// the point, and that happens while the renderer's applied order still shows a placement there (`under`). JSON null
// arrives as NSNull, which is not a dictionary: subscripting it raises NSInvalidArgumentException inside the event tap.
// On the ordered path the controller's hit must also be the very window the renderer put on top.
static inline DWHit *DWControllerHit(DWHit *hit,BOOL ordered,NSNumber *under) {
    DWHit *found=[hit isKindOfClass:DWHit.class]?hit:nil;
    return ordered&&(!under||![found.window isEqual:under])?nil:found;
}
// Is a mouse-moved packet at `point` one the application under it must not get? Below [zoom] interact_min a window takes no pointer
// input, hover included (docs/crates/desktop/POINTER.md; upstream's pointer_focus_under_pick): true when the output `outputs` (a snapshot's) lists under
// the point is in pick mode (`pick`) and what is there, as `hitAt` answers it for that output, is a pick target (a hit that carries
// `pick`; the controller's own, or one read from a placement). A widget, a screen-pinned and a fullscreen window are none. Every moved
// packet comes through here, so `hitAt` is asked only once the output is in pick mode; elsewhere this is a walk over the outputs.
static inline BOOL DWPickMotion(NSArray<DWOutput *> *outputs,CGPoint point,DWHit *(^hitAt)(NSNumber *output)) {
    if(![outputs isKindOfClass:NSArray.class])return NO;
    for(id listed in outputs){
        DWOutput *output=[listed isKindOfClass:DWOutput.class]?listed:nil;
        if(!output.screenBoundsHasOriginAndSize)continue;
        if(!CGRectContainsPoint(output.nativePointerScreenBounds,point))continue;
        if(![output.pick isEqual:@YES])return NO;
        DWHit *hit=hitAt?hitAt(output.identifier):nil;
        return [hit isKindOfClass:DWHit.class]&&[hit.pick isEqual:@YES];
    }
    return NO;
}
