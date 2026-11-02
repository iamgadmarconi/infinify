// SPDX-License-Identifier: GPL-3.0-or-later
// Tool for tests/e2e/zero-screen-keys.sh, guest only: posts one Control-Option-Escape press at the HID level (Control and
// Option down, Escape down and up, Option and Control up), the shell's own exit chord. Nothing else is posted; the pointer
// is never moved. Run it only in a disposable guest: the chord reaches whatever owns it there.
//
//   ExitChordFixture
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <unistd.h>

static int post(CGEventSourceRef source,CGKeyCode key,bool down,CGEventFlags flags) {
    CGEventRef event=CGEventCreateKeyboardEvent(source,key,down);if(!event)return 1;
    CGEventSetFlags(event,flags);CGEventPost(kCGHIDEventTap,event);CFRelease(event);usleep(30000);return 0;
}

int main(int argc,char **argv) {
    (void)argv;if(argc!=1){fprintf(stderr,"usage: ExitChordFixture\n");return 2;}
    if(!AXIsProcessTrusted()){fprintf(stderr,"no Accessibility access: nothing posted\n");return 1;}
    CGEventSourceRef source=CGEventSourceCreate(kCGEventSourceStateHIDSystemState);if(!source)return 1;
    const CGEventFlags control=kCGEventFlagMaskControl,both=kCGEventFlagMaskControl|kCGEventFlagMaskAlternate;
    int failed=post(source,59,true,control)|post(source,58,true,both)|post(source,53,true,both)|post(source,53,false,both)|post(source,58,false,control)|post(source,59,false,0);
    CFRelease(source);
    if(failed){fprintf(stderr,"an event could not be created\n");return 1;}
    printf("POSTED control-option-escape\n");return 0;
}
