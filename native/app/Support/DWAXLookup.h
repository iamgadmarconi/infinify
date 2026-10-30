// SPDX-License-Identifier: GPL-3.0-or-later
// What the Accessibility focus and resize adapters (native/app/Navigation/DWNativeFocus.m, native/app/Navigation/DWNativeResize.m)
// share: the monotonic clock, a process's birth time, and the parts of the AX window lookup that
// differ between them only by a timeout and a log tag.
// Signature precedent for the lookup they both do: yabai (https://github.com/asmvik/yabai, MIT)
// commit dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:8 and src/misc/helpers.h:499-504.
// Licence text: native/app/Resources/YABAI-NOTICE.txt.
#ifndef INFINIFY_AX_LOOKUP_H
#define INFINIFY_AX_LOOKUP_H
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static inline double DWMonotonicSeconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }

// A process's start time as the kernel records it, the second half of the identity (pid, birth) every
// adapter call is checked against. False for a pid that is not positive or a process that is gone.
static inline bool DWProcessBirth(pid_t pid,uint64_t *seconds,uint64_t *microseconds) {
    struct proc_bsdinfo info={0};
    if(!seconds||!microseconds||pid<=0||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return false;
    *seconds=info.pbi_start_tvsec;*microseconds=info.pbi_start_tvusec;return true;
}

// The messaging timeout of one AX call: what is left until `deadline`, at most `limit` seconds.
static inline AXError DWAXTimeout(AXUIElementRef element,double deadline,double limit) {
    double remaining=deadline-DWMonotonicSeconds();
    return remaining>0?AXUIElementSetMessagingTimeout(element,(float)fmin(limit,remaining)):kAXErrorCannotComplete;
}

// Under INFINIFY_DEBUG, why `_AXUIElementGetWindow` failed for the element at `index` of a window list.
static inline void DWAXLogWindowLookup(const char *tag,double limit,AXUIElementRef element,pid_t expectedPID,uint32_t expectedWindow,CFIndex index,AXError error,double deadline) {
    if(!getenv("INFINIFY_DEBUG"))return;
    CFTypeRef role=NULL,subrole=NULL;pid_t candidatePID=0;
    AXError pidError=AXUIElementGetPid(element,&candidatePID);
    AXError roleError=DWAXTimeout(element,deadline,limit);
    if(!roleError)roleError=AXUIElementCopyAttributeValue(element,kAXRoleAttribute,&role);
    AXError subroleError=DWAXTimeout(element,deadline,limit);
    if(!subroleError)subroleError=AXUIElementCopyAttributeValue(element,kAXSubroleAttribute,&subrole);
    const char *roleName=role&&CFGetTypeID(role)==CFStringGetTypeID()?[(__bridge NSString *)role UTF8String]:"unavailable";
    const char *subroleName=subrole&&CFGetTypeID(subrole)==CFStringGetTypeID()?[(__bridge NSString *)subrole UTF8String]:"unavailable";
    fprintf(stderr,"[infinify-debug] %s AX window lookup pid=%d target=%u index=%ld error=%d candidate_pid=%d pid_error=%d role=%s role_error=%d subrole=%s subrole_error=%d\n",tag,expectedPID,expectedWindow,(long)index,error,candidatePID,pidError,roleName,roleError,subroleName,subroleError);
    if(role)CFRelease(role);if(subrole)CFRelease(subrole);
}

// Finder includes its same-process desktop AXScrollArea in AXWindows. It has
// no WindowServer ID; only that verified non-window role may be skipped.
static inline bool DWAXWindowlessScrollArea(AXUIElementRef element,pid_t expectedPID,double deadline,double limit) {
    pid_t pid=0;if(AXUIElementGetPid(element,&pid)!=kAXErrorSuccess||pid!=expectedPID)return false;
    CFTypeRef role=NULL;AXError error=DWAXTimeout(element,deadline,limit);
    if(error==kAXErrorSuccess)error=AXUIElementCopyAttributeValue(element,kAXRoleAttribute,&role);
    bool known=error==kAXErrorSuccess&&role&&CFGetTypeID(role)==CFStringGetTypeID()&&CFEqual(role,kAXScrollAreaRole);
    if(role)CFRelease(role);return known;
}
#endif
