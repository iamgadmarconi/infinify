// Target-machine test. Creates and transforms only its own three windows; no capture API or TCC grants.
// Build: clang smoke-live.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o smoke-live
#import <Cocoa/Cocoa.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pwd.h>
#include <unistd.h>
#include <assert.h>
#include <math.h>
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowTransform(int, uint32_t, CGAffineTransform *);

static int connection(uint8_t op) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    snprintf(address.sun_path, sizeof(address.sun_path), "/tmp/sunlight-live_%s.socket", getpwuid(getuid())->pw_name);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { perror("connect"); exit(2); }
    struct timeval timeout = {.tv_sec = 1};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    uint8_t bytes[] = {1, 0, op}; send(fd, bytes, 3, 0);
    char magic[9];
    if (recv(fd, magic, 9, MSG_WAITALL) != 9 || memcmp(magic, "SUNBEAM1\n", 9)) {
        fprintf(stderr, "Sunlight's live-window add-on is not loaded\n"); exit(2);
    }
    return fd;
}
static void frame(int fd, uint32_t wid, uint32_t backdrop, uint32_t overlay, float zoom, float x, float y) {
    char bytes[41] = {0}; int16_t length = 39; uint16_t count = 1;
    float matrix[] = {1/zoom, 0, 0, 1/zoom, -x/zoom, -y/zoom};
    memcpy(bytes, &length, 2); bytes[2] = 0x72;
    memcpy(bytes + 3, &backdrop, 4); memcpy(bytes + 7, &overlay, 4); memcpy(bytes + 11, &count, 2);
    memcpy(bytes + 13, &wid, 4); memcpy(bytes + 17, matrix, 24);
    assert(send(fd, bytes, 41, 0) == 41); uint8_t ack = 1;
    assert(recv(fd, &ack, 1, MSG_WAITALL) == 1 && ack == 0);
}
static NSWindow *window(NSRect rect, NSColor *color, NSString *title) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO; w.backgroundColor = color; w.title = title; w.opaque = NO;
    [w orderFront:nil]; return w;
}
static void run(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
int main(void) {
    @autoreleasepool {
        close(connection(0x70));
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *backdrop = window(NSMakeRect(100, 150, 1000, 700), NSColor.darkGrayColor, @"Sunlight test backdrop");
        NSWindow *subject = window(NSMakeRect(160, 250, 600, 400), NSColor.systemTealColor, @"Sunlight live surface");
        NSTextField *label = [NSTextField labelWithString:@"Live WindowServer surface"];
        label.frame = NSMakeRect(30, 180, 560, 100); label.font = [NSFont boldSystemFontOfSize:38];
        [subject.contentView addSubview:label];
        NSWindow *overlay = window(backdrop.frame, NSColor.clearColor, @"Sunlight test overlay");
        overlay.ignoresMouseEvents = YES;
        [NSApp activateIgnoringOtherApps:YES];
        run(0.2);
        uint32_t wid = (uint32_t)subject.windowNumber;
        CGAffineTransform original; assert(SLSGetWindowTransform(SLSMainConnectionID(), wid, &original) == 0);
        int fd = connection(0x71);
        double worst = 0, total = 0;
        for (int i = 0; i < 300; ++i) {
            float z = 0.65f + 0.25f * sinf(i / 35.0f), x = 200 + 90 * sinf(i / 45.0f), y = 300;
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            frame(fd, wid, (uint32_t)backdrop.windowNumber, (uint32_t)overlay.windowNumber, z, x, y);
            double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000; total += ms; if (ms > worst) worst = ms;
            CGAffineTransform actual; assert(SLSGetWindowTransform(SLSMainConnectionID(), wid, &actual) == 0);
            assert(fabs(actual.a - 1/z) < 0.001 && fabs(actual.tx + x/z) < 0.01);
            label.stringValue = [NSString stringWithFormat:@"Live frame %d\nScale %.0f%%", i, z * 100];
            run(1.0/60.0);
        }
        close(fd); run(0.15);
        CGAffineTransform restored; assert(SLSGetWindowTransform(SLSMainConnectionID(), wid, &restored) == 0);
        assert(CGAffineTransformEqualToTransform(original, restored));
        printf("PASS: 300 live transforms; mean %.2f ms, worst %.2f ms; disconnect restored exact transform\n", total/300, worst);

        fd = connection(0x71);
        frame(fd, wid, (uint32_t)backdrop.windowNumber, (uint32_t)overlay.windowNumber, 1, 260, 300);
        char bytes[15]; int16_t length = 13; float x = 260, y = 300;
        memcpy(bytes, &length, 2); bytes[2] = 0x73; memcpy(bytes+3, &wid, 4); memcpy(bytes+7, &x, 4); memcpy(bytes+11, &y, 4);
        assert(send(fd, bytes, 15, 0) == 15); uint8_t ack = 1;
        assert(recv(fd, &ack, 1, MSG_WAITALL) == 1 && ack == 0); close(fd); run(0.15);
        assert(SLSGetWindowTransform(SLSMainConnectionID(), wid, &restored) == 0);
        assert(restored.a == 1 && restored.d == 1 && fabs(restored.tx + x) < 1 && fabs(restored.ty + y) < 1);
        puts("PASS: handoff restored native scale at the requested position without capture");
        [overlay close]; [subject close]; [backdrop close];
    }
}
