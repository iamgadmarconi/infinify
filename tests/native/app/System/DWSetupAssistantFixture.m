// SPDX-License-Identifier: GPL-3.0-or-later
// Draws every pane of the setup assistant (native/app/System/DWSetupAssistant.h) in the light and the dark appearance, from
// made-up states, into PNG files: DIRECTORY/<state>-<appearance>.png. Every seam is replaced, so nothing real is read or
// registered: no grant, no SIP query, no launch daemon, no login item, no other copy, no move, and the support directory is a
// scratch one (an older copy a move would replace is a stand-in there). Nothing is shown on screen; the views are drawn off screen. Usage: DWSetupAssistantFixture DIRECTORY [ICON.icns]
#import <AppKit/AppKit.h>
#import "DWSetupAssistant.h"
#import "DWSetupButton.h"
#import <ServiceManagement/ServiceManagement.h>

typedef struct {
    const char *name;DWSetupPane pane;
    BOOL input,capture,demo,compositorOn;
    DWSetupPolicy policy;DWLoaderState daemon;NSInteger login;
    const char *other,*refusal;
    BOOL notInstalled,placeTaken; // opened on the disk image: Move to Applications, to a free place or over an older copy
} Scene;

static BOOL draw(NSView *view,NSAppearance *appearance,NSString *path) {
    __block NSBitmapImageRep *rep=nil;
    [appearance performAsCurrentDrawingAppearance:^{
        [view layoutSubtreeIfNeeded];
        NSSize size=view.bounds.size;CGFloat scale=2;
        rep=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(size.width*scale) pixelsHigh:(NSInteger)(size.height*scale) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size=size;
        NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=context;
        [DWSetupCanvasColor() setFill];NSRectFill(view.bounds);
        CGContextRef cg=context.CGContext;
        // Layer-backed views (the buttons draw their fill in their layer) are drawn from their layers, the rest as views.
        [view displayIfNeeded];
        if(view.layer){[view.layer layoutIfNeeded];[view.layer renderInContext:cg];}
        else [view displayRectIgnoringOpacity:view.bounds inContext:context];
        [NSGraphicsContext restoreGraphicsState];
    }];
    NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc<2||argc>3){fprintf(stderr,"usage: DWSetupAssistantFixture DIRECTORY [ICON.icns]\n");return 64;}
    NSString *out=@(argv[1]);
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    if(argc==3){NSImage *icon=[[NSImage alloc]initWithContentsOfFile:@(argv[2])];if(icon)NSApp.applicationIconImage=icon;}
    DWSetupPolicy shut={.known=YES,.sipRelaxed=NO,.bootArgument=NO},open={.known=YES,.sipRelaxed=YES,.bootArgument=YES};
    Scene scenes[]={
        {"welcome",DWSetupPaneWelcome,NO,NO,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,NULL,NULL,NO,NO},
        {"welcome-move",DWSetupPaneWelcome,NO,NO,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,NULL,NULL,YES,NO},
        {"welcome-replace",DWSetupPaneWelcome,NO,NO,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,NULL,NULL,YES,YES},
        {"welcome-other-copy",DWSetupPaneWelcome,NO,NO,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,"/Users/you/Applications/Infinify.app",NULL,NO,NO},
        {"permissions",DWSetupPanePermissions,NO,NO,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,NULL,NULL,NO,NO},
        {"permissions-granted",DWSetupPanePermissions,YES,YES,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,NULL,NULL,NO,NO},
        {"login",DWSetupPaneLogin,YES,YES,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusNotRegistered,NULL,NULL,NO,NO},
        {"login-approval",DWSetupPaneLogin,YES,YES,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusRequiresApproval,NULL,NULL,NO,NO},
        {"compositor-sip",DWSetupPaneCompositor,YES,YES,NO,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusEnabled,NULL,NULL,NO,NO},
        {"compositor-enable",DWSetupPaneCompositor,YES,YES,NO,NO,open,DWLoaderNotRegistered,SMAppServiceStatusEnabled,NULL,NULL,NO,NO},
        {"compositor-approval",DWSetupPaneCompositor,YES,YES,NO,NO,open,DWLoaderNeedsApproval,SMAppServiceStatusEnabled,NULL,NULL,NO,NO},
        {"compositor-ad-hoc",DWSetupPaneCompositor,YES,YES,NO,NO,open,DWLoaderUnavailable,SMAppServiceStatusEnabled,NULL,NULL,NO,NO},
        {"compositor-refused",DWSetupPaneCompositor,YES,YES,NO,YES,open,DWLoaderEnabled,SMAppServiceStatusEnabled,NULL,"the Dock process identity did not settle.",NO,NO},
        {"ready",DWSetupPaneReady,YES,YES,NO,YES,open,DWLoaderEnabled,SMAppServiceStatusEnabled,NULL,NULL,NO,NO},
        {"ready-demo",DWSetupPaneReady,YES,YES,YES,NO,shut,DWLoaderNotRegistered,SMAppServiceStatusEnabled,NULL,NULL,NO,NO},
    };
    int written=0;
    for(size_t i=0;i<sizeof(scenes)/sizeof(scenes[0]);i++){
        Scene scene=scenes[i];
        NSString *support=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"setup-fixture-%d-%zu",getpid(),i]];
        [NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        if(scene.demo)DWSetupRecordDemo(support);
        DWSetupAssistant *assistant=[[DWSetupAssistant alloc]initWithSupportDirectory:support];
        assistant.accessibility=^BOOL{return scene.input;};
        assistant.screenRecording=^BOOL{return scene.capture;};
        assistant.policy=^DWSetupPolicy{return scene.policy;};
        assistant.daemonState=^DWLoaderState{return scene.daemon;};
        assistant.loginItemStatus=^NSInteger{return scene.login;};
        assistant.compositorAtLogin=^BOOL{return scene.compositorOn;};
        NSString *other=scene.other?@(scene.other):nil;
        assistant.otherCopies=^NSArray<NSString *> *{return other?@[other]:@[];};
        NSString *place=scene.notInstalled?[support stringByAppendingPathComponent:@"Applications/Infinify.app"]:nil;
        if(scene.placeTaken){
            [NSFileManager.defaultManager createDirectoryAtPath:[place stringByAppendingPathComponent:@"Contents"] withIntermediateDirectories:YES attributes:nil error:NULL];
            [@{@"CFBundleIdentifier":@"com.marengox.infinify"} writeToFile:[place stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES];
        }
        assistant.installPlace=^NSString *{return place;};
        if(scene.refusal)assistant.refusal=@(scene.refusal);
        for(NSString *appearanceName in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]){
            NSAppearance *appearance=[NSAppearance appearanceNamed:appearanceName];
            assistant.window.appearance=appearance;
            [assistant buildPane:scene.pane];
            if(assistant.pane!=scene.pane){fprintf(stderr,"%s: built pane %ld, not %ld\n",scene.name,(long)assistant.pane,(long)scene.pane);return 1;}
            NSString *path=[out stringByAppendingPathComponent:[NSString stringWithFormat:@"%s-%@.png",scene.name,appearanceName==NSAppearanceNameAqua?@"light":@"dark"]];
            if(!draw(assistant.window.contentView,appearance,path)){fprintf(stderr,"could not write %s\n",path.UTF8String);return 1;}
            written++;
        }
        [assistant close];
        [NSFileManager.defaultManager removeItemAtPath:support error:NULL];
    }
    printf("%d pictures in %s\n",written,out.UTF8String);
    return 0;
} }
