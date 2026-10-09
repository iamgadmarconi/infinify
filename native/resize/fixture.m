// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#include <signal.h>
#include <unistd.h>
static volatile sig_atomic_t quitting;
static void stop(int sig) { (void)sig; quitting=1; }
@interface LockedWindow : NSWindow @end
@implementation LockedWindow
- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute {
    if ([attribute isEqualToString:NSAccessibilitySizeAttribute]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [super accessibilityIsAttributeSettable:attribute];
#pragma clang diagnostic pop
}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector==@selector(setAccessibilitySize:)) return NO;
    return [super isAccessibilitySelectorAllowed:selector];
}
@end
@interface RejectingWindow : NSWindow @end
@implementation RejectingWindow
- (void)setAccessibilitySize:(NSSize)size { (void)size; }
- (void)accessibilitySetValue:(id)value forAttribute:(NSString *)attribute {
    if ([attribute isEqualToString:NSAccessibilitySizeAttribute]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [super accessibilitySetValue:value forAttribute:attribute];
#pragma clang diagnostic pop
}
@end
static NSArray *frame(NSWindow *w) { NSRect r=w.frame; return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; }
static void save(NSString *path,NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:path atomically:YES];
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=3) return 2;
    NSString *dir=@(argv[1]); pid_t parent=atoi(argv[2]);
    signal(SIGTERM,stop); signal(SIGINT,stop);
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSMutableArray<NSWindow *> *windows=[NSMutableArray new]; NSMutableArray *original=[NSMutableArray new];
    NSArray *classes=@[[NSWindow class],[LockedWindow class],[RejectingWindow class]];
    for(int n=0;n<3;n++) {
        NSWindow *w=[[classes[n] alloc] initWithContentRect:NSMakeRect(90+40*n,120+40*n,460,300) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        w.releasedWhenClosed=NO; w.animationBehavior=NSWindowAnimationBehaviorNone; w.title=@"Owned resize fixture"; // Intentionally identical titles.
        w.minSize=NSMakeSize(280,200); w.maxSize=NSMakeSize(900,700);
        [w orderFront:nil]; [w display]; [windows addObject:w]; [original addObject:frame(w)];
    }
    [NSApp finishLaunching];
    save([dir stringByAppendingPathComponent:@"ready.json"],@{@"pid":@(getpid()),@"windows":@[@(windows[0].windowNumber),@(windows[1].windowNumber),@(windows[2].windowNumber)],@"original":original});
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:30];
    while(!quitting && getppid()==parent && limit.timeIntervalSinceNow>0) {
        @autoreleasepool {
            NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.02] inMode:NSDefaultRunLoopMode dequeue:YES];
            if(e) [NSApp sendEvent:e]; [NSApp updateWindows];
            NSString *block=[dir stringByAppendingPathComponent:@"block"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:block]) {
                [[NSFileManager defaultManager] removeItemAtPath:block error:NULL];
                save([dir stringByAppendingPathComponent:@"blocking.json"],@{@"blocking":@YES});
                // Deliberately stall AX servicing briefly, without SIGSTOP disabling cleanup.
                usleep(1500000);
            }
            NSString *move=[dir stringByAppendingPathComponent:@"move"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:move]) {
                [[NSFileManager defaultManager] removeItemAtPath:move error:NULL];
                NSPoint p=windows[0].frame.origin; [windows[0] setFrameOrigin:NSMakePoint(p.x+75,p.y+55)];
                save([dir stringByAppendingPathComponent:@"moved.json"],@{@"frame":frame(windows[0])});
            }
        }
    }
    NSMutableArray *before=[NSMutableArray new],*after=[NSMutableArray new];
    for(NSUInteger n=0;n<windows.count;n++) {
        NSWindow *w=windows[n]; [before addObject:frame(w)]; NSArray *r=original[n];
        [w setFrame:NSMakeRect([r[0] doubleValue],[r[1] doubleValue],[r[2] doubleValue],[r[3] doubleValue]) display:NO]; [after addObject:frame(w)];
    }
    save([dir stringByAppendingPathComponent:@"exit.json"],@{@"before_restore":before,@"restored":after,@"original":original,@"restoration_passed":@([after isEqual:original]),@"reason":quitting?@"signal":(getppid()!=parent?@"parent_exit":@"deadline")});
    for(NSWindow *w in windows) [w close]; return 0;
} }
