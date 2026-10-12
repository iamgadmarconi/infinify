// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_MAC_WALLPAPER_REFRESH_H
#define DW_MAC_WALLPAPER_REFRESH_H
#include <math.h>
#include <stdbool.h>

// Only the fallback poll uses this delay. Space, display, session and config
// changes still query immediately. Measure from the start of the last actual
// host query: a coalesced refresh request or an image decode cannot renew it.
// Recheck at most five seconds later so a quiet canvas need not wait for the
// busy deadline. Continuous frames defer polling for at most thirty seconds,
// subject to the main run loop being serviced.
static inline double DWMacWallpaperRefreshDelay(double now,double observedAt,bool busy) {
    if(!isfinite(now)||!isfinite(observedAt)||observedAt<=0||now<observedAt)return 0;
    return fmax(0,fmin(5,(busy?30:5)-(now-observedAt)));
}
#endif
