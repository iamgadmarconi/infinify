// SPDX-License-Identifier: GPL-3.0-or-later
#include "mac-wallpaper-refresh.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    unsigned checks=0;
#define CHECK(expression) do { assert(expression);checks++; } while(0)
    CHECK(DWMacWallpaperRefreshDelay(100,0,false)==0);
    CHECK(DWMacWallpaperRefreshDelay(100,0,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(104,100,false)==1);
    CHECK(DWMacWallpaperRefreshDelay(105,100,false)==0);
    CHECK(DWMacWallpaperRefreshDelay(106,100,false)==0);
    CHECK(DWMacWallpaperRefreshDelay(105,100,true)==5);
    CHECK(DWMacWallpaperRefreshDelay(126,100,true)==4);
    CHECK(DWMacWallpaperRefreshDelay(130,100,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(131,100,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(110,100,false)==0);
    // Requests and worker completions do not change the observation clock.
    for(unsigned age=0;age<=30;age++) {
        double delay=DWMacWallpaperRefreshDelay(100+age,100,true);
        CHECK(delay>=0&&delay<=5);
        CHECK(age<30?delay>0:delay==0);
    }
    // An actual event-driven query starts a new quiet/busy observation period.
    CHECK(DWMacWallpaperRefreshDelay(132,129,false)==2);
    CHECK(DWMacWallpaperRefreshDelay(132,129,true)==5);
    CHECK(DWMacWallpaperRefreshDelay(159,129,true)==0);
    // Refreshing a second display must not renew the older display's deadline.
    CHECK(DWMacWallpaperRefreshDelay(130,fmin(100,129),true)==0);
    CHECK(DWMacWallpaperRefreshDelay(126,fmin(100,125),true)==4);
    CHECK(DWMacWallpaperRefreshDelay(90,100,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(NAN,100,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(100,NAN,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(INFINITY,100,true)==0);
    CHECK(DWMacWallpaperRefreshDelay(100,INFINITY,true)==0);
    printf("wallpaper refresh policy: %u checks passed (no AppKit or native calls)\n",checks);
    return 0;
}
