// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// The controller's answer to a hit query, as the pointer paths use it. It answers {"hit": null} when no source lies under
// the point, and that happens while the renderer's applied order still shows a placement there (`under`). JSON null
// arrives as NSNull, which is not a dictionary: subscripting it raises NSInvalidArgumentException inside the event tap.
// On the ordered path the controller's hit must also be the very window the renderer put on top.
static inline NSDictionary *DWControllerHit(id hit,BOOL ordered,NSNumber *under) {
    NSDictionary *found=[hit isKindOfClass:NSDictionary.class]?hit:nil;
    return ordered&&(!under||![found[@"window"]isEqual:under])?nil:found;
}
