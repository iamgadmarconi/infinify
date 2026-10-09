// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_FOCUS_GEOMETRY_H
#define DW_FOCUS_GEOMETRY_H
#include <stdbool.h>
#include <math.h>
typedef struct { double x,y; } DWPoint;
typedef struct { DWPoint viewport, pan; double zoom; } DWCamera;
static inline bool dw_focus_inverse(DWCamera c,DWPoint screen,DWPoint *local) {
    if(!local||!isfinite(c.zoom)||c.zoom<=0)return false;
    DWPoint p={(screen.x-c.viewport.x)/c.zoom+c.pan.x,(screen.y-c.viewport.y)/c.zoom+c.pan.y};
    if(!isfinite(p.x)||!isfinite(p.y))return false;*local=p;return true;
}
#endif
