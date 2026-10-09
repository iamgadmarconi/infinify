// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
static NSWindow *window;
static NSTextField *editor;
static NSScrollView *scroll;
static NSPopUpButton *popup;
static NSButton *button;
static NSPoint lastMouseLocation;
static NSUInteger taggedMouseEvents;
static NSUInteger actions, edits, mouseEvents, keyEvents, scrollEvents;
@interface DWFixtureTarget : NSObject <NSTextFieldDelegate>
- (void)action:(id)sender;
@end
@implementation DWFixtureTarget
- (void)action:(id)sender { (void)sender; actions++; }
- (void)controlTextDidChange:(NSNotification *)note { (void)note; edits++; }
@end
static DWFixtureTarget *target;
uint32_t dw_fixture_open(const char *nonce) { @autoreleasepool {
    if (![NSThread isMainThread] || window) return 0;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 100, 480, 340) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    // Keep this disposable probe visible on the current Space, including full-screen apps,
    // without switching Spaces or changing any user window.
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
    window.title = [@"DriftWM fixture " stringByAppendingString:[NSString stringWithUTF8String:nonce]];
    target = [DWFixtureTarget new];
    button = [NSButton buttonWithTitle:@"Fixture action" target:target action:@selector(action:)];
    button.frame = NSMakeRect(20, 275, 150, 32); [window.contentView addSubview:button];
    editor = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 230, 430, 30)];
    editor.stringValue = @"Editable native fixture text"; editor.delegate = target; [window.contentView addSubview:editor];
    popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(200, 275, 240, 32) pullsDown:NO];
    [popup addItemsWithTitles:@[@"Native popup", @"Second option", @"Third option"]]; popup.target = target; popup.action = @selector(action:); [window.contentView addSubview:popup];
    scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 430, 190)]; scroll.hasVerticalScroller = YES;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 410, 1200)];
    NSMutableString *lines = [NSMutableString new]; for (int i=0;i<50;i++) [lines appendFormat:@"Scrollable fixture line %d\n",i];
    text.string = lines; scroll.documentView = text; [window.contentView addSubview:scroll];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskKeyDown | NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
        if (event.window == window) { if (event.type == NSEventTypeLeftMouseDown) { mouseEvents++; lastMouseLocation=event.locationInWindow; if (event.CGEvent && CGEventGetIntegerValueField(event.CGEvent,kCGEventSourceUserData)==0x44575052) taggedMouseEvents++; } if (event.type == NSEventTypeKeyDown) keyEvents++; if (event.type == NSEventTypeScrollWheel) scrollEvents++; } return event;
    }];
    [window orderFront:nil]; [window display]; [NSApp finishLaunching];
    return (uint32_t)window.windowNumber;
} }
void dw_fixture_pump(void) { @autoreleasepool {
    NSEvent *event; while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
    [NSApp updateWindows];
} }
char *dw_fixture_telemetry(void) { @autoreleasepool {
    NSDictionary *value = @{@"actions": @(actions), @"text_edits": @(edits), @"mouse_down_events": @(mouseEvents), @"key_down_events": @(keyEvents), @"scroll_events": @(scrollEvents), @"text": editor.stringValue ?: @"", @"popup_index": @(popup.indexOfSelectedItem), @"scroll_y": @(scroll.contentView.bounds.origin.y), @"tagged_mouse_down_events": @(taggedMouseEvents), @"last_mouse_in_window": @[@(lastMouseLocation.x),@(lastMouseLocation.y)], @"input_validation": @"inspect input_probe report; counters alone do not establish transformed hit testing"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; char *result = calloc(data.length+1,1); if(result) memcpy(result,data.bytes,data.length); return result;
} }
void dw_fixture_close(void) { @autoreleasepool { [window close]; window=nil; } }

char *dw_fixture_layout(void) { @autoreleasepool {
    [window orderFront:nil];
    NSPoint center = [button convertPoint:NSMakePoint(button.bounds.size.width/2,button.bounds.size.height/2) toView:nil];
    NSDictionary *value=@{@"button_buffer_point": @[@(center.x),@(window.frame.size.height-center.y)], @"appkit_frame": @[@(window.frame.origin.x),@(window.frame.origin.y),@(window.frame.size.width),@(window.frame.size.height)]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];char *result=calloc(data.length+1,1);if(result)memcpy(result,data.bytes,data.length);return result;
} }
