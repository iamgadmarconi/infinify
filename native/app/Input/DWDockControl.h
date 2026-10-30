// SPDX-License-Identifier: GPL-3.0-or-later
// What the shell knows about Dock-control events (CGEventType 30), shared by the taps that see them and
// header-only so that each of them, and each regression, stays free of the others' object files.
//
// CGEventType 30 is the CGS event the system drives the Dock with for Mission Control, Spaces, App Exposé,
// Launchpad ("Apps") and Show Desktop. It is also the number of NSEventTypeMagnify, and that coincidence is
// why this header exists: a tap that hands a type-30 CGEvent to +[NSEvent eventWithCGEvent:] gets nil and AppKit
// logs "unrecognized type is 30" once per packet. Nothing may convert one: classify it here instead.
//
// DockSwipe field/type/phase decoding adapted from joshuarli/iss, repository https://github.com/joshuarli/iss,
// commit 493b008f2ea8e9215877c39700e8ea3add800e97, upstream path iss.c, lines 436-515 (cb) of that file at that commit:
// https://github.com/joshuarli/iss/blob/493b008f2ea8e9215877c39700e8ea3add800e97/iss.c
// Copyright (c) 2026 joshuarli
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted.
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
// OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.
// These are event fields, not linked private functions. Neither a successful tap nor these source references
// establishes what the Dock does with a dropped packet on a future ABI; the decode of a Launchpad or Show
// Desktop pinch in particular is unverified, which is why every type-30 event that does not decode is classified
// `Other` and decided by the tap's own rules instead of being guessed at.
#import <Foundation/Foundation.h>
#import "DWDebugTrace.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>

// TrackpadPan.dockControl, lines 61-63 of Sources/Canvas/TrackpadPan.swift in https://github.com/spacefarm-digital/sunlight at commit
// afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm; notice in SUNLIGHT-NOTICE.txt).
static const CGEventType DWDockControlType=(CGEventType)30;
static const CGEventField DWGestureRealType=55,DWGestureHIDType=110,DWGestureAxis=123,DWGesturePhase=132;
// How long after the fingers lift, or the gesture ends, Dock control is still dropped: the system's swipe ends a beat later.
// TrackpadPan.dockTail, lines 58-60 of the same file at that commit.
static const NSTimeInterval DWDockControlTail=.3;

// Where a packet sits in the system's stream: its beginning, its middle or its end, or `Other` for a type-30 packet
// that is not a DockSwipe this decoder knows (an unknown HID type, axis or phase).
typedef NS_ENUM(NSInteger,DWDockControlKind){DWDockControlOther,DWDockControlBegan,DWDockControlChanged,DWDockControlEnded};
// What a tap decided: drop the packet, let it through, or (no touch source holds the system back) leave it to the tap's own rules.
typedef NS_ENUM(NSInteger,DWDockControlVerdict){DWDockControlPass,DWDockControlDrop,DWDockControlUndecided};

static inline DWDockControlKind DWDockControlClassify(CGEventRef event,NSInteger *axis,NSInteger *phase) {
    if(!event||CGEventGetIntegerValueField(event,DWGestureRealType)!=30||CGEventGetIntegerValueField(event,DWGestureHIDType)!=23)return DWDockControlOther;
    NSInteger a=(NSInteger)CGEventGetIntegerValueField(event,DWGestureAxis),p=(NSInteger)CGEventGetIntegerValueField(event,DWGesturePhase);
    if(a<1||a>3)return DWDockControlOther;
    if(axis)*axis=a;if(phase)*phase=p;
    if(p==kCGGesturePhaseBegan||p==kCGGesturePhaseMayBegin)return DWDockControlBegan;
    if(p==kCGGesturePhaseChanged)return DWDockControlChanged;
    if(p==kCGGesturePhaseEnded||p==kCGGesturePhaseCancelled)return DWDockControlEnded;
    return DWDockControlOther;
}

// --- INFINIFY_DEBUG diagnostics ---------------------------------------------------------------------------------------
// Every integer field of the packet from 40 to 169 that is not zero, so that the first packet of a stream a decoder
// does not know can be read off a log. A field that holds a double reads as a huge integer; that is shown as ~.
static inline void DWDockControlFields(CGEventRef event,char *buffer,size_t size) {
    size_t used=0;buffer[0]=0;
    for(CGEventField field=40;field<170&&used+32<size;field++){
        int64_t value=CGEventGetIntegerValueField(event,field);if(!value)continue;
        if(value>1000000000LL||value<-1000000000LL)used+=(size_t)snprintf(buffer+used,size-used,"f%u~%.4g ",(unsigned)field,CGEventGetDoubleValueField(event,field));
        else used+=(size_t)snprintf(buffer+used,size-used,"f%u=%lld ",(unsigned)field,(long long)value);
    }
}
// One line per decision worth reading, never a flood: the first packet of a stream, its end and any change of verdict
// are always written; a packet that repeats the last one is counted and mentioned with the next line, at most every
// quarter second. `via` names the tap, `detail` is the caller's account of its own state.
static inline void DWDockControlTrace(const char *via,CGEventRef event,DWDockControlKind kind,DWDockControlVerdict verdict,const char *reason,const char *detail) {
    if(!DWDebugTrace())return;
    static os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;static NSTimeInterval last=0;static NSUInteger suppressed=0,total=0;
    static const char *lastVia=NULL,*lastReason=NULL;static DWDockControlVerdict lastVerdict=DWDockControlUndecided;
    static const char *kinds[]={"other","began","changed","ended"},*verdicts[]={"pass","DROP","undecided"};
    NSTimeInterval now=CACurrentMediaTime();
    os_unfair_lock_lock(&lock);total++;
    // Reasons and taps are string literals: the same decision is the same pointer.
    BOOL write=kind==DWDockControlBegan||kind==DWDockControlEnded||verdict!=lastVerdict||reason!=lastReason||via!=lastVia||now-last>=.25;
    NSUInteger quiet=suppressed;if(write){suppressed=0;last=now;lastVia=via;lastReason=reason;lastVerdict=verdict;}else suppressed++;
    NSUInteger number=total;os_unfair_lock_unlock(&lock);
    if(!write)return;
    char fields[512];fields[0]=0;
    // The raw fields once per stream and for anything undecoded: they are how a pinch of an unknown format gets decoded later.
    if(kind==DWDockControlBegan||kind==DWDockControlOther)DWDockControlFields(event,fields,sizeof fields);
    fprintf(stderr,"debug: dock-control #%lu via=%s %s verdict=%s reason=%s %s (+%lu similar not written) real=%lld hid=%lld axis=%lld phase=%lld%s%s\n",
        (unsigned long)number,via,kinds[kind],verdicts[verdict],reason,detail,(unsigned long)quiet,
        (long long)CGEventGetIntegerValueField(event,DWGestureRealType),(long long)CGEventGetIntegerValueField(event,DWGestureHIDType),
        (long long)CGEventGetIntegerValueField(event,DWGestureAxis),(long long)CGEventGetIntegerValueField(event,DWGesturePhase),fields[0]?" fields: ":"",fields);
}
