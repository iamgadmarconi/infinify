// SPDX-License-Identifier: GPL-3.0-or-later
// Private ABI declarations checked against Chromium remote_layer_api.h,
// blob 8a11a77f1a502b601015793738ec690b74932b11. No implementation copied.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

@interface NSObject (SurfacePrivateABI)
+ (instancetype)contextWithCGSConnection:(uint32_t)connection options:(NSDictionary *)options;
- (uint32_t)contextId;
- (void)setContextId:(uint32_t)identifier;
- (void)setLayer:(CALayer *)layer;
@end

@interface SurfaceView : NSView
@end
@implementation SurfaceView
- (BOOL)isFlipped { return YES; }
@end

static volatile sig_atomic_t stopRequested;
static void stopSignal(int signalNumber) { stopRequested = signalNumber; }
static void pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!stopRequested && [end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static void json(NSDictionary *value, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}
static NSDictionary *readJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static CALayer *rectangle(CGRect frame, CGFloat r, CGFloat g, CGFloat b) {
    CALayer *layer = [CALayer layer]; layer.frame = frame;
    layer.backgroundColor = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1].CGColor;
    return layer;
}
static int source(NSString *directory, double seconds) {
    pid_t parent = getppid();
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    uint32_t (*connection)(void) = sky ? dlsym(sky, "CGSMainConnectionID") : NULL;
    if (!connection && sky) connection = dlsym(sky, "SLSMainConnectionID");
    Class contextClass = NSClassFromString(@"CAContext");
    if (!connection || ![contextClass respondsToSelector:@selector(contextWithCGSConnection:options:)]) return 2;
    id context = [contextClass contextWithCGSConnection:connection() options:@{}];
    if (!context || ![context respondsToSelector:@selector(contextId)] || ![context respondsToSelector:@selector(setLayer:)]) return 2;
    CALayer *scene = rectangle(CGRectMake(0, 0, 400, 300), 0.08, 0.08, 0.08);
    scene.geometryFlipped = YES;
    [scene addSublayer:rectangle(CGRectMake(60, 70, 50, 40), 0, 1, 0)];
    CALayer *changing = rectangle(CGRectMake(180, 100, 100, 80), 1, 0, 0);
    [scene addSublayer:changing];
    [context setLayer:scene]; [CATransaction flush];
    NSDate *started = [NSDate date]; NSInteger lastPhase = -1; unsigned updates = 0;
    while (!stopRequested && -started.timeIntervalSinceNow < seconds && getppid() == parent) {
        NSInteger phase = ((NSInteger)(-started.timeIntervalSinceNow)) % 2;
        if (phase != lastPhase) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            changing.backgroundColor = (phase ? NSColor.blueColor : NSColor.redColor).CGColor;
            [CATransaction commit]; [CATransaction flush]; lastPhase = phase; updates++;
            json(@{@"pid":@(getpid()), @"context_id":@([context contextId]), @"phase":@(phase),
                   @"updates":@(updates), @"scene_size":@[@400,@300]},
                 [directory stringByAppendingPathComponent:@"source.json"]);
        }
        pump(0.03);
    }
    [context setLayer:nil]; [CATransaction flush];
    json(@{@"pid":@(getpid()), @"reason":stopRequested ? @"signal" : (getppid() != parent ? @"parent_exit" : @"deadline"),
           @"signal":@(stopRequested), @"updates":@(updates)}, [directory stringByAppendingPathComponent:@"source-exit.json"]);
    return 0;
}

static CGImageRef captureOwnWindow(uint32_t windowID, NSError **error) {
    __block BOOL done = NO;
    __block SCShareableContent *content = nil;
    __block NSError *failure = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *result, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{ content = result; failure = e; done = YES; });
        }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done && !stopRequested && deadline.timeIntervalSinceNow > 0) pump(0.02);
    SCWindow *own = nil;
    for (SCWindow *window in content.windows)
        if (window.windowID == windowID && window.owningApplication.processID == getpid()) own = window;
    if (!own) { *error = failure ?: [NSError errorWithDomain:@"SurfaceProbe" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Exact own window unavailable, capture refused"}]; return NULL; }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:own];
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    configuration.width = 800; configuration.height = 360; configuration.showsCursor = NO;
    configuration.ignoreShadowsSingleWindow = YES;
    configuration.captureResolution = SCCaptureResolutionBest;
    done = NO; __block CGImageRef image = NULL; __block BOOL abandoned = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
        completionHandler:^(CGImageRef result, NSError *e) {
            CGImageRef retained = result ? CGImageRetain(result) : NULL;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (abandoned) { if (retained) CGImageRelease(retained); return; }
                image = retained; failure = e; done = YES;
            });
        }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done && !stopRequested && deadline.timeIntervalSinceNow > 0) pump(0.02);
    abandoned = !done; *error = failure; return image;
}

static NSDictionary *inspect(CGImageRef image, NSString *path) {
    NSBitmapImageRep *png = [[NSBitmapImageRep alloc] initWithCGImage:image];
    [[png representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    unsigned char *pixels = calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(bitmap, CGRectMake(0,0,width,height), image);
    NSMutableArray *views = [NSMutableArray array];
    for (int view = 0; view < 2; view++) {
        int lo = view ? 450 : 0, hi = view ? 790 : 440;
        int minX = (int)width, maxX = -1, minY = (int)height, maxY = -1;
        int minDX = (int)width, maxDX = -1, minDY = (int)height, maxDY = -1;
        unsigned green = 0, red = 0, blue = 0, outside = 0;
        for (int y=0; y<(int)height; y++) for (int x=lo; x<hi && x<(int)width; x++) {
            unsigned char *p = pixels + (y * width + x) * 4;
            BOOL g = p[1] > 200 && p[0] < 60 && p[2] < 60;
            BOOL r = p[0] > 200 && p[1] < 60 && p[2] < 60;
            BOOL b = p[2] > 200 && p[0] < 60 && p[1] < 60;
            if (g) { green++; minX=MIN(minX,x); maxX=MAX(maxX,x); minY=MIN(minY,y); maxY=MAX(maxY,y); }
            if (r || b) { minDX=MIN(minDX,x); maxDX=MAX(maxDX,x); minDY=MIN(minDY,y); maxDY=MAX(maxDY,y); }
            red += r; blue += b;
            // Both camera viewports are wholly inside y=20..319; camera B ends at x=759.
            if ((g || r || b) && (y<20 || y>=320 || (view ? (x<460 || x>=760) : (x<20 || x>=420)))) outside++;
        }
        [views addObject:@{@"green_bounds":@[@(minX),@(minY),@(maxX-minX+1),@(maxY-minY+1)],
                          @"changing_bounds":@[@(minDX),@(minDY),@(maxDX-minDX+1),@(maxDY-minDY+1)],
                          @"green_pixels":@(green), @"red_pixels":@(red), @"blue_pixels":@(blue),
                          @"colored_pixels_outside_clip":@(outside)}];
    }
    CGContextRelease(bitmap); CGColorSpaceRelease(space); free(pixels);
    return @{@"width":@(width), @"height":@(height), @"views":views, @"png":path};
}

static int host(NSString *directory, double seconds, NSString *executable) {
    NSTask *child = [NSTask new]; child.executableURL = [NSURL fileURLWithPath:executable];
    child.arguments = @[@"--source", directory, [NSString stringWithFormat:@"%.1f", seconds+3]];
    NSError *error = nil;
    if (![child launchAndReturnError:&error]) { fprintf(stderr,"source launch failed: %s\n",error.description.UTF8String); return 2; }
    NSDate *started = [NSDate date]; NSDictionary *ready = nil;
    while (!stopRequested && child.running && -started.timeIntervalSinceNow < MIN(seconds,3)) {
        ready = readJSON([directory stringByAppendingPathComponent:@"source.json"]);
        if (ready) break; pump(0.02);
    }
    NSMutableDictionary *report = [@{@"scope":@"cooperative_CAContext_two_processes_only", @"host_pid":@(getpid()),
       @"source_pid":@(child.processIdentifier), @"arbitrary_app_window_hosting_proven":@NO,
       @"input_proven":@NO, @"permission_requests":@0, @"unrelated_window_mutation_calls":@0,
       @"screen_capture_preflight":@(CGPreflightScreenCaptureAccess()), @"frames":[NSMutableArray array]} mutableCopy];
    NSWindow *window = nil;
    Class hostClass = NSClassFromString(@"CALayerHost");
    BOOL available = ready && [ready[@"pid"] intValue] == child.processIdentifier && [ready[@"context_id"] unsignedIntValue] != 0 &&
        [hostClass instancesRespondToSelector:@selector(setContextId:)];
    if (available && !stopRequested) {
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80,120,800,360) styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
        window.title = @"DriftWM cooperative live surfaces (fixture only)";
        window.releasedWhenClosed = NO;
        window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSView *view = [[SurfaceView alloc] initWithFrame:NSMakeRect(0,0,800,360)]; window.contentView = view; view.wantsLayer = YES;
        CALayer *root = rectangle(CGRectMake(0,0,800,360), 0.25,0.25,0.25); root.geometryFlipped = YES; view.layer = root;
        for (int i=0; i<2; i++) {
            CALayer *clip = rectangle(i ? CGRectMake(460,20,300,300) : CGRectMake(20,20,400,300),0.15,0.15,0.15);
            clip.masksToBounds = YES; [root addSublayer:clip];
            CALayer *remote = [hostClass layer]; remote.anchorPoint = CGPointZero; remote.bounds = CGRectMake(0,0,400,300);
            remote.position = i ? CGPointMake(-60,-45) : CGPointZero;
            remote.transform = CATransform3DMakeScale(i ? 1.5 : 1, i ? 1.5 : 1, 1);
            [(id)remote setContextId:[ready[@"context_id"] unsignedIntValue]]; [clip addSublayer:remote];
        }
        [window orderFrontRegardless]; [CATransaction flush];
        report[@"window_id"] = @((uint32_t)window.windowNumber); report[@"context_id"] = ready[@"context_id"];
        report[@"cameras"] = @[@{@"viewport":@[@20,@20,@400,@300],@"pan":@[@0,@0],@"zoom":@1},
                                 @{@"viewport":@[@460,@20,@300,@300],@"pan":@[@40,@30],@"zoom":@1.5}];
        double nextCapture = 0.7;
        while (!stopRequested && child.running && -started.timeIntervalSinceNow < seconds) {
            pump(0.02);
            if (CGPreflightScreenCaptureAccess() && -started.timeIntervalSinceNow >= nextCapture && [report[@"frames"] count] < 6) {
                NSError *captureError = nil; CGImageRef image = captureOwnWindow((uint32_t)window.windowNumber, &captureError);
                if (image) {
                    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%lu.png",(unsigned long)[report[@"frames"] count]]];
                    NSMutableDictionary *frame = [inspect(image,path) mutableCopy];
                    frame[@"elapsed_seconds"] = @(-started.timeIntervalSinceNow);
                    frame[@"source_observation"] = readJSON([directory stringByAppendingPathComponent:@"source.json"]) ?: @{};
                    [report[@"frames"] addObject:frame]; CGImageRelease(image);
                } else report[@"capture_error"] = captureError.description ?: @"Capture timed out or interrupted";
                nextCapture = -started.timeIntervalSinceNow + 0.7;
            }
        }
    } else report[@"api_error"] = @"Source CAContext or host CALayerHost unavailable";
    [window orderOut:nil]; [window close];
    if (child.running) [child terminate];
    // Always reap the exact child, including signal/deadline exits. The source also
    // monitors parent death and has its own deadline for SIGKILL/crash recovery.
    NSDate *cleanupDeadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (child.running && cleanupDeadline.timeIntervalSinceNow > 0) usleep(10000);
    if (child.running) kill(child.processIdentifier,SIGKILL);
    [child waitUntilExit];
    report[@"source_reaped"] = @(!child.running); report[@"source_exit_status"] = @(child.terminationStatus);
    report[@"exit_reason"] = stopRequested ? @"signal" : @"deadline";
    report[@"signal"] = @(stopRequested);
    report[@"private_api_available"] = @(available);
    json(report,[directory stringByAppendingPathComponent:@"receipt.json"]);
    return available ? 0 : 2;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4 || (strcmp(argv[1],"--host") && strcmp(argv[1],"--source"))) {
            fprintf(stderr,"usage: surfaces --host|--source NEW_EVIDENCE_DIRECTORY SECONDS(1..30)\n"); return 64;
        }
        char *end = NULL; double seconds = strtod(argv[3], &end);
        if (!end || *end || !isfinite(seconds) || seconds < 1 || seconds > 33) return 64;
        NSString *directory = @(argv[2]);
        if (![NSFileManager.defaultManager fileExistsAtPath:directory]) return 64;
        signal(SIGTERM,stopSignal); signal(SIGINT,stopSignal); signal(SIGHUP,stopSignal);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        if (!strcmp(argv[1],"--source")) return source(directory,seconds);
        if (seconds > 30 || [NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"source.json"]]) return 64;
        return host(directory,seconds,NSBundle.mainBundle.executablePath);
    }
}
