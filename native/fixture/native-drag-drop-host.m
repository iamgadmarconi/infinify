// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>

static void writeReceipt(NSString *path, NSMutableDictionary *receipt) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "receipt write failed: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
    }
}

static NSURL *fileURLFromInfo(id<NSDraggingInfo> info) {
    NSPasteboard *pasteboard = info.draggingPasteboard;
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class]
                                                       options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    return urls.firstObject;
}

@interface DWDragSourceView : NSView <NSDraggingSource>
@property(copy) NSString *filePath;
@property(copy) NSString *nonce;
@property(copy) NSString *receiptPath;
@property NSMutableDictionary *receipt;
@property NSDraggingSession *session;
@end

@implementation DWDragSourceView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithCalibratedRed:.16 green:.35 blue:.58 alpha:1] setFill];
    NSRectFill(self.bounds);
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:21], NSForegroundColorAttributeName: NSColor.whiteColor};
    [@"Drag the test file to the green window" drawAtPoint:NSMakePoint(18, 22) withAttributes:attributes];
}
- (void)mouseDown:(NSEvent *)event {
    self.receipt[@"source_mouse_down"] = @YES;
    self.receipt[@"source_event_window"] = @(event.window.windowNumber);
    NSURL *url = [NSURL fileURLWithPath:self.filePath];
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [item setDraggingFrame:NSMakeRect(point.x - 8, point.y - 8, 16, 16) contents:nil];
    self.session = [self beginDraggingSessionWithItems:@[item] event:event source:self];
    self.receipt[@"source_session_started"] = @(self.session != nil);
    [self.receipt addEntriesFromDictionary:@{@"source_types": @[NSPasteboardTypeFileURL], @"source_allowed_operation": @(NSDragOperationCopy)}];
    writeReceipt(self.receiptPath, self.receipt);
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    NSMutableArray *contexts = self.receipt[@"source_dragging_contexts"];
    if (!contexts) self.receipt[@"source_dragging_contexts"] = contexts = [NSMutableArray array];
    if (![contexts containsObject:@(context)]) [contexts addObject:@(context)];
    writeReceipt(self.receiptPath, self.receipt);
    return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    (void)session;
    self.receipt[@"source_ended"] = @YES;
    self.receipt[@"source_end_screen_point"] = @[@(screenPoint.x), @(screenPoint.y)];
    self.receipt[@"source_end_operation"] = @(operation);
    writeReceipt(self.receiptPath, self.receipt);
}
@end

@interface DWDragDestinationView : NSView <NSDraggingDestination>
@property(copy) NSString *filePath;
@property(copy) NSString *nonce;
@property(copy) NSString *receiptPath;
@property NSMutableDictionary *receipt;
@end

@implementation DWDragDestinationView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithCalibratedRed:.17 green:.48 blue:.29 alpha:1] setFill];
    NSRectFill(self.bounds);
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:21], NSForegroundColorAttributeName: NSColor.whiteColor};
    [@"Drop the test file here" drawAtPoint:NSMakePoint(18, 22) withAttributes:attributes];
}
- (void)recordEvent:(NSString *)event info:(id<NSDraggingInfo>)info {
    NSMutableArray *events = self.receipt[@"destination_events"];
    if (![events isKindOfClass:NSMutableArray.class]) self.receipt[@"destination_events"] = events = [NSMutableArray array];
    [events addObject:event];
    NSPoint point = info.draggingLocation;
    self.receipt[@"destination_last_location"] = @[@(point.x), @(point.y)];
    self.receipt[@"destination_source_operation_mask"] = @((NSUInteger)info.draggingSourceOperationMask);
    writeReceipt(self.receiptPath, self.receipt);
}
- (BOOL)hasExpectedFile:(id<NSDraggingInfo>)info {
    NSURL *url = fileURLFromInfo(info);
    if (!url.isFileURL || ![url.path isEqualToString:self.filePath]) return NO;
    NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    return [contents isEqualToString:self.nonce];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    [self recordEvent:@"entered" info:info];
    BOOL hasType = [info.draggingPasteboard.types containsObject:NSPasteboardTypeFileURL];
    self.receipt[@"destination_file_url_type_seen"] = @(hasType);
    writeReceipt(self.receiptPath, self.receipt);
    return hasType ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    [self recordEvent:@"updated" info:info];
    return [self hasExpectedFile:info] ? NSDragOperationCopy : NSDragOperationNone;
}
- (void)draggingExited:(id<NSDraggingInfo>)info {
    [self recordEvent:@"exited" info:info];
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
    [self recordEvent:@"prepare" info:info];
    BOOL accepted = [self hasExpectedFile:info];
    self.receipt[@"destination_prepared"] = @(accepted);
    writeReceipt(self.receiptPath, self.receipt);
    return accepted;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    [self recordEvent:@"perform" info:info];
    NSURL *url = fileURLFromInfo(info);
    NSString *contents = url.isFileURL ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
    BOOL accepted = [url.path isEqualToString:self.filePath] && [contents isEqualToString:self.nonce];
    NSPoint point = info.draggingLocation;
    self.receipt[@"destination_performed"] = @(accepted);
    self.receipt[@"destination_received_path"] = url.path ?: @"";
    self.receipt[@"destination_received_contents"] = contents ?: @"";
    self.receipt[@"destination_location"] = @[@(point.x), @(point.y)];
    self.receipt[@"destination_view_bounds"] = @[@(self.bounds.origin.x), @(self.bounds.origin.y), @(self.bounds.size.width), @(self.bounds.size.height)];
    self.receipt[@"destination_source_operation_mask"] = @((NSUInteger)info.draggingSourceOperationMask);
    writeReceipt(self.receiptPath, self.receipt);
    return accepted;
}
- (void)concludeDragOperation:(id<NSDraggingInfo>)info {
    [self recordEvent:@"conclude" info:info];
    self.receipt[@"destination_concluded"] = @YES;
    writeReceipt(self.receiptPath, self.receipt);
}
@end

static NSWindow *makeWindow(NSRect frame, NSString *title, NSView *content) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = title;
    window.level = NSFloatingWindowLevel + 1;
    window.alphaValue = 1.0;
    window.opaque = YES;
    window.backgroundColor = NSColor.blackColor;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.contentView = content;
    [window orderFrontRegardless];
    return window;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 7 || (strcmp(argv[1], "source") && strcmp(argv[1], "destination"))) {
            fprintf(stderr, "usage: native-drag-drop-host source|destination payload.dylib runtime-dir nonce-file evidence-dir file-url-path\n");
            return 2;
        }
        NSString *role = [NSString stringWithUTF8String:argv[1]];
        BOOL isSource = [role isEqualToString:@"source"];
        NSString *payload = [NSString stringWithUTF8String:argv[2]];
        NSString *runtime = [NSString stringWithUTF8String:argv[3]];
        // Read the private token by descriptor; never put it in process arguments
        // or observable window titles.
        int fd = open(argv[4], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat st = {0};
        char token[66] = {0};
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()
            || (st.st_mode & 0777) != 0600 || st.st_size != 65 || read(fd, token, 65) != 65) {
            if (fd >= 0) close(fd);
            fprintf(stderr, "fixture needs a private nonce file\n"); return 2;
        }
        close(fd);
        if (token[64] != '\n') return 2;
        token[64] = 0;
        for (int i = 0; i < 64; i++) if (!token[i] || !strchr("0123456789abcdef", token[i])) return 2;
        NSString *authNonce = [NSString stringWithUTF8String:token];
        NSString *evidence = [NSString stringWithUTF8String:argv[5]];
        NSString *filePath = [NSString stringWithUTF8String:argv[6]];
        if (!payload.isAbsolutePath || !runtime.isAbsolutePath || !evidence.isAbsolutePath || !filePath.isAbsolutePath) {
            fprintf(stderr, "fixture paths must be absolute and nonce must be fresh\n");
            return 2;
        }
        fd = open(filePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        memset(token, 0, sizeof(token));
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()
            || (st.st_mode & 0777) != 0600 || st.st_size != 64 || read(fd, token, 65) != 64) {
            if (fd >= 0) close(fd);
            fprintf(stderr, "fixture file must contain a private file nonce\n");
            return 2;
        }
        close(fd);
        for (int i = 0; i < 64; i++) if (!token[i] || !strchr("0123456789abcdef", token[i])) return 2;
        NSString *nonce = [NSString stringWithUTF8String:token];

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSScreen *screen = NSScreen.mainScreen;
        if (!screen) { fprintf(stderr, "no main screen\n"); return 1; }
        NSRect visible = screen.visibleFrame;
        const CGFloat width = 320, height = 230, margin = 18;
        if (visible.size.width < width * 2 + margin * 3 || visible.size.height < height + margin * 2) {
            fprintf(stderr, "main display is too small for the two-window fixture\n");
            return 3;
        }
        CGFloat left = NSMinX(visible) + margin;
        CGFloat bottom = NSMinY(visible) + margin;
        NSMutableDictionary *receipt = [@{
            @"role": role, @"host_pid": @(getpid()), @"file_nonce": nonce
        } mutableCopy];
        NSString *receiptPath = [evidence stringByAppendingPathComponent:@"receipt.json"];
        NSView *content;
        if (isSource) {
            DWDragSourceView *source = [DWDragSourceView new];
            source.filePath = filePath; source.nonce = nonce; source.receiptPath = receiptPath; source.receipt = receipt;
            content = source;
        } else {
            DWDragDestinationView *destination = [DWDragDestinationView new];
            destination.filePath = filePath; destination.nonce = nonce; destination.receiptPath = receiptPath; destination.receipt = receipt;
            [destination registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
            content = destination;
        }
        NSWindow *window = makeWindow(NSMakeRect(left + (isSource ? 0 : width + margin), bottom, width, height),
                                     isSource ? @"DriftWM Native Drag Source" : @"DriftWM Native Drag Destination", content);
        receipt[@"wid"] = @(window.windowNumber);
        writeReceipt(receiptPath, receipt);
        [NSApp finishLaunching];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];

        void *handle = dlopen(payload.fileSystemRepresentation, RTLD_LOCAL | RTLD_NOW);
        if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
        int (*start)(const char *, const char *, const uint32_t *, uint32_t, const char *) = dlsym(handle, "dw_privileged_fixture_start_windows");
        uint32_t wid = (uint32_t)window.windowNumber;
        int status = start ? start(runtime.fileSystemRepresentation, authNonce.UTF8String, &wid, 1, NULL) : -1;
        if (status) { fprintf(stderr, "helper fixture start failed: %d\n", status); return 1; }
        printf("READY %s %d %u\n", role.UTF8String, getpid(), wid);
        fflush(stdout);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        [NSApp run];
        return 0;
    }
}
