// SPDX-License-Identifier: GPL-3.0-or-later
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stddef.h>
// The part of a toolbar item that is a group which belongs to its controls. AppKit gives a toolbar item a group as tall as the
// toolbar, while the controls inside it are not: Safari's address field and its search button occupy 11 to 49 points of a
// 52-point group, with a strip of plain toolbar above and below them. Treating the whole group as native sent a press on that
// strip to Safari, where WindowServer starts a window drag from a transformed window only for some points (at zoom 0.5 it did
// not start for the strip's points, 4 of 4, and the press ended as an inert click). The group keeps its full width, so a field's
// rounded ends and a segmented control's edges stay with the control, and its vertical extent shrinks to the union of its
// children's frames (the caller still inflates by a point, as for every control). `children` are read from Accessibility and
// must all lie inside the group (to a point): a child that does not, an empty or non-finite one, or no children at all means the
// geometry cannot be trusted, and the answer is NO: the group stays whole.
static inline BOOL DWToolbarGroupExtent(CGRect group,const CGRect *children,size_t count,CGRect *out) {
    if(!count||!children||!out||!isfinite(group.origin.x)||!isfinite(group.origin.y)||!(group.size.width>0)||!(group.size.height>0))return NO;
    CGFloat top=INFINITY,bottom=-INFINITY;CGRect roomy=CGRectInset(group,-1,-1);
    for(size_t i=0;i<count;i++){
        CGRect child=children[i];
        if(!isfinite(child.origin.x)||!isfinite(child.origin.y)||!(child.size.width>0)||!(child.size.height>0)||!CGRectContainsRect(roomy,child))return NO;
        top=fmin(top,CGRectGetMinY(child));bottom=fmax(bottom,CGRectGetMaxY(child));
    }
    top=fmax(top,CGRectGetMinY(group));bottom=fmin(bottom,CGRectGetMaxY(group));
    if(!(bottom>top))return NO;
    *out=CGRectMake(group.origin.x,top,group.size.width,bottom-top);return YES;
}
