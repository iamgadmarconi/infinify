// SPDX-License-Identifier: GPL-3.0-or-later
#include "geometry.h"
#include "focus.h"
#include <assert.h>
int main(void) {
    DWCamera a={{20,40},{0,0},.75},b={{520,80},{35,25},1.5};DWPoint p;
    assert(dw_focus_inverse(a,(DWPoint){95,130},&p)&&p.x==100&&p.y==120);
    assert(dw_focus_inverse(b,(DWPoint){617.5,222.5},&p)&&p.x==100&&p.y==120);
    assert(!dw_focus_inverse((DWCamera){.zoom=0},(DWPoint){0,0},&p));
    assert(!dw_focus_inverse(a,(DWPoint){NAN,0},&p));
    DWFocusIdentity invalid={0};assert(!dw_focus_owner(invalid,NULL));
    assert(dw_focus_select(invalid,NULL,NULL).outcome==DWFocusInvalid);
    return 0;
}
