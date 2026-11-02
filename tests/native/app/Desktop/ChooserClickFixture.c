// SPDX-License-Identifier: GPL-3.0-or-later
// Tool for tests/e2e/zero-screen-keys.sh, guest only: one HID left click on the "Open canvas" button of Infinify's own
// --manual chooser window, owned by process PID. Infinify's Accessibility tree cannot be walked to the button (each child
// reports the application element), so the window is found in the window list (720 points wide, the chooser's content
// width) and the button's centre is taken from its frame in native/app/Desktop/Desktop+Chooser.m: x 405..525 and y 15..45
// from the content's bottom-left corner. The pointer moves there; nothing else is posted. It exits 0 after the click,
// 1 when no such window is on screen. Run it only in a disposable guest.
//
//   ChooserClickFixture PID
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static long number(CFDictionaryRef row,CFStringRef key) { long value=0;CFNumberRef n=CFDictionaryGetValue(row,key);if(n)CFNumberGetValue(n,kCFNumberLongType,&value);return value; }

int main(int argc,char **argv) {
    long pid=argc==2?strtol(argv[1],NULL,10):0;
    if(argc!=2||pid<=0){fprintf(stderr,"usage: ChooserClickFixture PID\n");return 2;}
    if(!AXIsProcessTrusted()){fprintf(stderr,"no Accessibility access: nothing posted\n");return 1;}
    CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);CGRect chooser=CGRectNull;
    for(CFIndex i=0;rows&&i<CFArrayGetCount(rows);i++){CFDictionaryRef row=CFArrayGetValueAtIndex(rows,i);CGRect bounds;
        if(number(row,kCGWindowOwnerPID)!=pid||!CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(row,kCGWindowBounds),&bounds))continue;
        if(bounds.size.width==720&&bounds.size.height>470&&bounds.size.height<540){chooser=bounds;break;}}
    if(rows)CFRelease(rows);
    if(CGRectIsNull(chooser)){fprintf(stderr,"no 720-point chooser window of process %ld on screen\n",pid);return 1;}
    CGPoint at=CGPointMake(chooser.origin.x+465,chooser.origin.y+chooser.size.height-30);
    CGEventSourceRef source=CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventType types[]={kCGEventMouseMoved,kCGEventLeftMouseDown,kCGEventLeftMouseUp};
    for(int i=0;i<3;i++){CGEventRef event=CGEventCreateMouseEvent(source,types[i],at,kCGMouseButtonLeft);if(!event)return 1;CGEventPost(kCGHIDEventTap,event);CFRelease(event);usleep(i?60000:150000);}
    if(source)CFRelease(source);
    printf("CLICKED Open canvas at %g,%g (chooser %g,%g %gx%g)\n",at.x,at.y,chooser.origin.x,chooser.origin.y,chooser.size.width,chooser.size.height);return 0;
}
