// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1: this entry point is what stays of it after the split.
// Infinify's entry point: the command line, the IPC/login-item/native-desktop dispatch before AppKit, and the run loop around Desktop.
#import "Desktop.h"
#import "DWDesktopSupport.h"
#import <libproc.h>
#import <signal.h>
#import <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#import "DWLoginItem.h"
#import "DWNativeDesktopCLI.h"
#import "DWOnboarding.h"
#import "DWOwnerFile.h"
#import "DWNativeFocus.h"
#import "DWNativeResize.h"
#import "DWChildProcess.h"
volatile sig_atomic_t DWStopSignal;
static void stopSignal(int s) { DWStopSignal = s; }
// WIDTHxHEIGHT in points, digits only. The least is 960x480.
static BOOL parseWindowSize(const char *text,NSSize *size) {
    char *end=NULL;unsigned long width=strtoul(text,&end,10);if(*end!='x'||!isdigit((unsigned char)end[1]))return NO;
    unsigned long height=strtoul(end+1,&end,10);if(*end||width<960||width>16384||height<480||height>16384)return NO;
    *size=NSMakeSize(width,height);return YES;
}
// --only-pid: the start time of a process the run may be told to manage, as [seconds, microseconds]; nil for one that does
// not exist or is another user's. Read once, at launch: DWInScope compares against it for as long as the run lasts.
static NSArray<NSNumber *> *scopeBirth(pid_t pid) {
    struct proc_bsdinfo p={0};if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof(p))!=sizeof(p)||p.pbi_uid!=getuid())return nil;
    return @[@(p.pbi_start_tvsec),@(p.pbi_start_tvusec)];
}
// --native-helper NONCE_FILE: the helper's nonce, 64 hexadecimal characters and at most a newline after them, in a regular file that is
// this user's and nobody else's to read. It is read from there so that it is never on a command line, where every process could see it.
static NSString *helperNonce(const char *path,const char **why) {
    struct stat st;int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);char text[66]={0};
    if(fd<0||fstat(fd,&st)){if(fd>=0)close(fd);*why="names a nonce file that cannot be opened";return nil;}
    ssize_t n=S_ISREG(st.st_mode)&&st.st_uid==getuid()&&(st.st_mode&0777)==0600?read(fd,text,sizeof(text)):-2;close(fd);
    if(n==-2){*why="needs a nonce file that is a regular file of this user's with mode 0600";return nil;}
    if(n==65&&text[64]=='\n')n=64;
    if(n!=64||strspn(text,"0123456789abcdefABCDEF")!=64){*why="needs a nonce file holding 64 hexadecimal characters";return nil;}
    return [[NSString alloc]initWithBytes:text length:64 encoding:NSASCIIStringEncoding];
}
static int helperRefused(const char *why) { fprintf(stderr,"Infinify: native helper %s\n",why);return 64; }
static int scopeRefused(const char *why,const char *value) { if(value)fprintf(stderr,"Infinify: --only-pid %s %s\n",value,why);else fprintf(stderr,"Infinify: --only-pid %s\n",why);return 64; }
// The normal run's settings takeover, for an exit() that does not come back through main(): it puts them back there too (idempotent).
static DWSystemTakeover *takeoverAtExit;
static void putBackAtExit(void) { NSString *note=nil;[takeoverAtExit restore:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String); }
int main(int argc,const char **argv) { @autoreleasepool {
    // The IPC client runs before any AppKit initialisation: no window, no privacy grant.
    if(argc>=2&&!strcmp(argv[1],"msg"))return driftwm_desktop_msg(argc-2,argv+2);
    // So does the login item: registered, unregistered or read, and nothing else of the app starts.
    if(argc>=2&&!strcmp(argv[1],"login-item"))return DWLoginItemCommand(argc-2,argv+2);
    // native-desktop starts the bundle's audited native bootstrap (an explicit terminal command, or the login item when the owner
    // enabled compositor mode) or manages that default. It replaces this process before AppKit, so the ordinary-instance guard
    // cannot mistake it for a running canvas. No checkout fallback.
    if(argc>=2&&!strcmp(argv[1],"native-desktop"))return DWNativeDesktopCommand(argc-2,argv+2);
    // The login item's program: compositor mode when the owner enabled it, else the capture-mode start it always was.
    if(argc==2&&!strcmp(argv[1],"login-start")){
        if(DWNativeLoginIsCompositor()){const char *login[]={"--login"};return DWNativeDesktopCommand(1,login);}
        argc=1;
    }
    DWRaiseOpenFileLimit();
    const char **launched=argv; // as given, for the onboarding window's Relaunch
    BOOL windowed=NO,logical=NO,manual=NO;const char *socket=NULL,*config=NULL,*chord=NULL;NSSize windowSize=NSMakeSize(1200,800);const char *filtered[argc+1];int count=0;
    BOOL undelivered=NO; // --no-hover-forwarding
    BOOL scoped=NO,debugPointer=NO,nativeDesktop=NO;NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *scope=[NSMutableDictionary dictionary]; // --only-pid, --debug-pointer
    NSMutableArray<NSMutableDictionary *> *helperEndpoints=[NSMutableArray array]; // --native-helper, at most four explicit sessions
    for(int i=0;i<argc;i++){
        if(i>0&&!strcmp(argv[i],"--no-native-focus")){if(logical)return 64;logical=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--no-hover-forwarding")){if(undelivered)return 64;undelivered=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--socket")){if(socket||i+1>=argc||argv[i+1][0]!='/')return 64;socket=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--config")){if(config||i+1>=argc||argv[i+1][0]!='/')return 64;config=argv[++i];continue;}
        // The chord's grammar is the controller's; one it rejects is reported in the resting status.
        if(i>0&&!strcmp(argv[i],"--super")){if(chord||i+1>=argc||!argv[i+1][0])return 64;chord=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--manual")){if(manual)return 64;manual=YES;continue;}
        // Every process named is looked at here, before anything opens: a scope that names nothing real must not become no scope.
        if(i>0&&!strcmp(argv[i],"--only-pid")){if(i+1>=argc)return scopeRefused("needs a process id",NULL);scoped=YES;const char *list=argv[++i],*at=list;
            for(;;){char *end=NULL;errno=0;long pid=isdigit((unsigned char)*at)?strtol(at,&end,10):0;
                if(!end||end==at||(*end&&*end!=',')||errno||pid<=0||pid>INT_MAX)return scopeRefused("is not a list of process ids",list);
                if(pid==getpid())return scopeRefused("names Infinify itself",list);
                if(scope[@(pid)])return scopeRefused("names a process twice",list);
                NSArray<NSNumber *> *born=scopeBirth((pid_t)pid);if(!born)return scopeRefused("names a process that is not running, or not one of this user's",list);
                scope[@(pid)]=born;if(!*end)break;at=end+1;}
            continue;}
        if(i>0&&!strcmp(argv[i],"--debug-pointer")){if(debugPointer)return 64;debugPointer=YES;continue;}
        if(i>0&&(!strcmp(argv[i],"--native-helper")||!strcmp(argv[i],"--native-desktop-helper"))){
            BOOL desktopSelection=!strcmp(argv[i],"--native-desktop-helper");
            if(nativeDesktop||(desktopSelection&&helperEndpoints.count))return helperRefused("desktop mode needs exactly one endpoint and cannot be combined with --native-helper");
            nativeDesktop=desktopSelection;
            if(helperEndpoints.count>=4)return helperRefused("accepts at most four explicit helper endpoints");if(i+2>=argc)return helperRefused("needs RUNTIME_DIR and NONCE_FILE");
            const char *runtime=argv[++i],*file=argv[++i];if(runtime[0]!='/'||file[0]!='/')return helperRefused("needs two absolute paths, RUNTIME_DIR and NONCE_FILE");
            NSString *canonical=[@(runtime)stringByResolvingSymlinksInPath];for(NSDictionary *endpoint in helperEndpoints)if([canonical isEqual:[endpoint[@"runtime"]stringByResolvingSymlinksInPath]])return helperRefused("names a runtime directory twice");
            [helperEndpoints addObject:[@{@"runtime":@(runtime),@"nonce_file":@(file)} mutableCopy]];continue;}
        if(i>0&&!strcmp(argv[i],"--windowed")){if(windowed)return 64;windowed=YES;if(i+1<argc&&isdigit((unsigned char)argv[i+1][0])&&!parseWindowSize(argv[++i],&windowSize))return 64;continue;}
        filtered[count++]=argv[i];}filtered[count]=NULL;argc=count;argv=filtered;

    if(argc==2&&!strcmp(argv[1],"--help")){puts("Infinify.app — macOS 26+ Apple Silicon: DriftWM's canvas as the desktop of native Mac windows\nDefault: the desktop. One canvas panel per display covers the whole display on every Space, under the menu bar and the Dock, which both stay; there is no toolbar, no status line and no chooser. Every real application window on screen (by Accessibility a standard window or a dialog, never a popup or a helper window; without Accessibility every window but an untitled one under 200x150) lives on the canvas: existing windows are adopted, a new one is placed by window_placement, a closed one leaves (or leaves a stand-in under session.suspend_on_close). This needs Screen Recording and Accessibility access: while one is missing a small window says so and offers the Allow buttons, Relaunch (Screen Recording reaches only a newly started app) and Quit, and the canvas opens once nothing is in the way. While the canvas is open the run switches off Stage Manager (it keeps every window outside the current stage as a thumbnail) and macOS window tiling (edge drag, top edge, option accelerator) in com.apple.WindowManager, with one line on stderr, and puts the user's own settings back when it ends (quit, SIGTERM, SIGINT, SIGHUP, log out); a run that was killed has them put back at the next launch from ~/Library/Application Support/Infinify/window-prefs-snapshot.plist. --windowed, --manual and --only-pid leave the settings alone.\nStatus notes go to stderr, one line each; what a config file has wrong is drawn in the error bar.\n--only-pid PID[,PID…] (may repeat): manage only the windows of these processes, each of which must be running and this user's; needs --windowed, and refuses --manual. It works without Screen Recording access too: the windows are then bound, focused and clicked as ever and their tiles have no picture.\n--debug-pointer: with --only-pid, serve the DebugPointer IPC request, by which a test presses and releases on a window without the pointer.\n--native-helper RUNTIME_DIR NONCE_FILE: with --only-pid, native presentation: the window server draws the managed windows themselves where the canvas places them, moved and scaled by the transform helper whose socket is in RUNTIME_DIR (its nonce is read from NONCE_FILE, mode 0600), and the canvas, behind them, draws live copies for additional independently zoomed display views when Screen Recording access is already available. A cooperative helper inside its named process, or an authenticated exact helper allowlist of the named process instances, must match --only-pid. Repeat this pair for up to four explicit helpers: each must audit its own disjoint process subset, and their union must exactly match --only-pid. Same-user helpers and allowlists that cannot be audited are refused; nothing is looked for or loaded. Losing one grouped helper ends presentation and restores its siblings. Without a native helper flag every run is the overlay.\n--native-desktop-helper RUNTIME_DIR NONCE_FILE: explicit whole-desktop native presentation for this login user, including newly opened applications. Requires one authenticated Apple Dock-hosted SAME_USER helper with scope audit and per-window restoration; cannot combine with --only-pid, --windowed or --manual. This only connects to a helper you already started; nothing is injected or installed by the app. Requires Accessibility access and Stage Manager off. Screen Recording is optional for the native primary and enables captured replicas on additional independent display views. Native clipping and application compatibility still need validation.\n--manual: show the chooser first and capture only explicitly selected windows; no window is adopted automatically. Open canvas shows the saved world without adding one. The chooser stays open above the canvas; closed there, it is gone for the run.\n--no-native-focus: window focus stays logical; no native window is activated or raised\n--no-hover-forwarding: pointer motion over a window is not delivered to its application; focus_follows_mouse and pick mode still follow the pointer\n--state ABSOLUTE_PATH: explicit persistent scene file (default Application Support/Infinify/scene.json)\n--socket ABSOLUTE_PATH: IPC socket of a normal run (default Application Support/Infinify/infinify.sock)\n--windowed [WIDTHxHEIGHT]: open the canvas at launch in one ordinary window instead, all of it canvas (default 1200x800, at least 960x480), with no global shortcuts and whatever access there is; with --manual the chooser comes up above it; msg action quit or Control-C in its terminal ends it\n--config ABSOLUTE_PATH: DriftWM config file of a normal run (default $XDG_CONFIG_HOME/infinify/config.toml, else ~/.config/infinify/config.toml; DriftWM's built-in defaults when it is missing); read again whenever it changes\n--super CHORD: the physical keys of DriftWM's super/mod, a +-joined subset of ctrl|alt|cmd (default ctrl+alt; --super cmd restores Command bindings)\nmsg [--json] [--socket PATH] COMMAND ...: DriftWM-style IPC client for the running app; opens no window\nnative-desktop [--check | --help | enable | disable | status]: run the bundled native desktop launcher from a terminal; enable makes compositor mode the login default (launch daemon approved once in Login Items, reload after Dock restarts), disable reverts it, status reports it. --check only verifies the package and reports policy; the explicit start authenticates or loads the helper through its sudo step, then starts native mode. It changes no SIP or settings and refuses an uncertain earlier load.\nlogin-item on | off | status: register, unregister or report the login item, a LaunchAgent inside the bundle that starts Infinify at login and again after a crash, never after a quit. on starts it at once, off ends the instance it started, status only reads; opens no window. For the installed copy: scripts/install-app.sh puts a signed bundle in ~/Applications\nKeys and pointer gestures are DriftWM's bindings from the config file: ctrl is Control, alt is Option, super (mod) is the --super chord. With no config file the canvas uses Control-Option, leaving native Command editing and Command-Tab with macOS. Explicit --super cmd and config bindings keep their authored choices. The registered defaults are:\n  Drag or two-finger scroll on empty canvas, Control-Option-drag anywhere, three-finger swipe: pan; a released pan coasts (navigation.drift). Hold Super (Control-Option by default) and scroll with a wheel or two fingers to zoom anywhere. Wheel or two-finger pinch on empty canvas, Control-Option-pinch anywhere, three-finger pinch: anchored zoom (max 1x).\n  Option-drag on a window: world move/snap; add Shift: cluster. Held at the view's edge, a move pans the canvas under the window (navigation.edge_pan).\n  Trackpad gestures use DriftWM's [gestures] bindings with Mac defaults: four-finger swipe up toggles overview; other directions select the nearest window. Four-finger hold: center the focused window. Four-finger pinch in / out: zoom-to-fit / home toggle. Three-finger swipe or drag pans over windows as well as empty canvas. Two-finger pinch zooms over windows too.\n  Desktop mode intercepts recognized trackpad and Dock swipe streams for canvas navigation; stopping releases interception without changing System Settings. Unknown system gesture formats pass through; hardware behavior needs runtime validation. Where MultitouchSupport reports the trackpad, three or more fingers are read from it wherever the pointer is, and the system's Dock-control gestures are held back only for finger counts a [gestures] binding takes, with a short tail (INFINIFY_NO_MULTITOUCH=1 leaves the views' own touches in charge; not yet run on a physical trackpad). Windowed mode keeps local gestures only.\n  View actions animate one view's camera only (global shortcuts while the canvas is open, or msg action; held zoom, pan and nudge keys repeat):\n  Control-Option-A: home toggle (origin at 1:1, again to return). Control-Option-Tab or F3: overview toggle (again returns). Control-Option-W: the same zoom-to-fit toggle. Control-Option-Shift-W: the same over the focused window's snap cluster.\n  Control-Option-Equals / Control-Option-Minus: zoom in / out. Control-Option-0 or Control-Option-Z: zoom 1:1.\n  Control-Option-Command-arrows: pan the view under the pointer. Control-Option-Shift-arrows: nudge the focused window.\n  Control-Option-1 to 4: fly to bookmark 1 to 4. Control-Option-Shift-1 to 4: set it.\n  Window navigation flies the camera and focuses the window, natively when Infinify has Accessibility access:\n  Option-Tab / Option-Shift-Tab: cycle windows, most recently focused first; letting go of Option commits the choice.\n  Control-Option-arrows: the nearest window in that direction. Control-Option-C: center the focused window. Control-Option-X: center the window under the pointer.\n  A click on a window gives it canvas focus and starts its native focus, then the click is forwarded; a click on empty canvas unfocuses. Focusing a canvas window in its own application is followed.\n  Pointer motion over a window is delivered to its application; with focus_follows_mouse = true it also focuses that window without raising it, a screen-pinned one before the canvas beneath it and never a widget.\n  Below [zoom] interact_min (off by default) a window on the canvas is one target: a click flies to it, a drag moves it, and no click, scroll or motion reaches its application. A screen-pinned window and a widget are not picked and keep their pointer.\n  Control-Option-Command-drag: center-nearest by pointer, DriftWM's swipe; the direction is taken 16 points from the press.\n  Control-Option-Return: exec-terminal ($TERMINAL, else a new Terminal window). Control-Option-D: exec-launcher ($LAUNCHER, else Apps).\n  Control-Option-Shift-Command-arrows: send-to-output, the focused window to the display on that side (a world move; nothing with one display).\n  The default Control-Option-L lock binding and default volume, brightness, media and screenshot program bindings are left to macOS; their Linux commands are never substituted or started.\n  macOS's Lock Screen and screenshot shortcuts stay available. Explicit config bindings still run exactly as authored.\n  Control-Option-Q: close-window. The focused window's own close button is pressed through Accessibility; a focused placeholder is dismissed.\nAn unbound click, drag or scroll on a window (left, right or middle button) is forwarded only to its selected, freshly validated source.\nNative keyboard/IME remain with the real app. Control-Option-Escape (until a binding takes that chord), Control-Option-Command-Shift-Q (quit), msg action quit or SIGTERM ends the run with exit status 0 and returns the native desktop: fullscreens ended, scene saved, panels closed, capture stopped, hot keys released.\nNo SIP/settings changes.");return 0;}
    BOOL state=argc==3&&!strcmp(argv[1],"--state");
    if(argc!=1&&!state)return 64;
    // A scope is for a windowed run that manages by itself. Without --windowed a launch without Screen Recording access would go to
    // the onboarding window; --manual's chooser attaches whatever is picked.
    if(scoped&&!windowed)return scopeRefused("needs --windowed",NULL);
    // A scoped run settles adoption with only its own windows present: on the default scene that would drop every saved slot of a real window.
    if(scoped&&!state)return scopeRefused("needs --state",NULL);
    if(scoped&&manual)return scopeRefused("cannot be combined with --manual",NULL);
    if(debugPointer&&!scoped){fputs("Infinify: --debug-pointer needs --only-pid\n",stderr);return 64;}
    // Native authority is explicit: exact --only-pid instances, or the login
    // user's desktop through a separately audited Dock helper. Missing scope
    // never silently expands a scoped launch into desktop authority.
    if(nativeDesktop&&(scoped||windowed||manual))return helperRefused("--native-desktop-helper cannot be combined with --only-pid, --windowed or --manual");
    if(helperEndpoints.count&&!scoped&&!nativeDesktop)return helperRefused("needs --only-pid; use --native-desktop-helper explicitly for the desktop");
    for(NSMutableDictionary *endpoint in helperEndpoints){struct stat st;const char *why=NULL;
        if(stat([endpoint[@"runtime"]fileSystemRepresentation],&st)||!S_ISDIR(st.st_mode))return helperRefused("names a runtime directory that is not a directory");
        NSString *nonce=helperNonce([endpoint[@"nonce_file"]fileSystemRepresentation],&why);if(!nonce)return helperRefused(why);
        endpoint[@"nonce"]=nonce;[endpoint removeObjectForKey:@"nonce_file"];}
    // Before AppKit, helper admission, scene/config load or autostart. Keep both
    // leases through final native cleanup and scene save; CLOEXEC releases them
    // only when a requested relaunch replaces this fully cleaned process.
    __attribute__((objc_precise_lifetime)) DWRunOwnership *ownership=nil;
    NSString *dir=DWSupportDirectory();
    if(state&&![@(argv[2])isAbsolutePath])return 64;
    if(!state||!socket){NSError *error=nil;if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){fprintf(stderr,"Infinify: cannot create support directory: %s\n",error.localizedDescription.UTF8String);return 73;}}
    BOOL duplicate=NO;NSString *error=nil;
    ownership=[DWRunOwnership acquireSocket:socket?@(socket):[dir stringByAppendingPathComponent:@"infinify.sock"] state:state?@(argv[2]):[dir stringByAppendingPathComponent:@"scene.json"] duplicate:&duplicate error:&error];
    if(!ownership){fprintf(stderr,"Infinify: %s\n",error.UTF8String);return duplicate?0:73;}
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    Desktop *desktop=[Desktop new];desktop.logicalFocus=logical;desktop.windowed=windowed;desktop.windowSize=windowSize;
    desktop.hoverUndelivered=undelivered;desktop.scope=scoped?[scope copy]:nil;desktop.debugPointer=debugPointer;desktop.nativeDesktopMode=nativeDesktop;
    // Do not continue after a socket setup failure. No helper or scene has been
    // admitted yet, so refusal must not run cleanup/save on another run's scene.
    if(ownership&&![desktop startIPC:ownership.socketPath])return 73;
    // The helper is asked for its session now: one that is not there, refuses, or is not this run's to drive ends the launch here,
    // with nothing opened (EX_UNAVAILABLE). From here on native focus and sizing read a window's own frame, as the presenter does:
    // their checks compare it with what Accessibility reports, which the window list's transformed bounds would never match.
    if(helperEndpoints.count){NSString *why=nil;NSDictionary *endpoint=helperEndpoints.firstObject;
        desktop.native=nativeDesktop?[DWNativePresenter desktopPresenterAt:endpoint[@"runtime"] nonce:endpoint[@"nonce"] why:&why]
            :[DWNativePresenter presentersAt:helperEndpoints scope:desktop.scope why:&why];
        if(!desktop.native){fprintf(stderr,"Infinify: native helper %s\n",why.UTF8String);[desktop.ipc stop];return 69;}
        NSMutableArray *savedEndpoints=[NSMutableArray array];for(NSDictionary *endpoint in helperEndpoints)[savedEndpoints addObject:@{@"runtime":endpoint[@"runtime"],@"nonce":endpoint[@"nonce"]}];desktop.nativeEndpoints=savedEndpoints.copy;
        dw_focus_set_bounds(DWNativeBounds);dw_resize_set_bounds(DWNativeBounds);
        // Compositor mode with the launch daemon on (the launcher says so by environment): the Dock is watched, and the payload that
        // went with a Dock that restarted is loaded into the new one by the launcher's --reload, whose helper then replaces the lost
        // endpoint and the ordinary authenticated re-admission puts the windows back (DWDockReloader.h).
        const char *reload=getenv("INFINIFY_DOCK_RELOAD"),*payloadSHA=getenv("INFINIFY_NATIVE_PAYLOAD_SHA256"),*loadedAt=getenv("INFINIFY_NATIVE_LOADED_AT");
        NSString *launcher=[NSBundle.mainBundle pathForResource:@"launch" ofType:@"sh" inDirectory:@"NativeDesktop"];
        if(nativeDesktop&&reload&&!strcmp(reload,"1")&&payloadSHA&&strlen(payloadSHA)==64&&launcher){
            DWDockReloader *reloader=[[DWDockReloader alloc]initWithLauncher:launcher payloadSHA256:@(payloadSHA) stateDirectory:DWDockReloadStateDirectory() loadedAt:loadedAt?atof(loadedAt):0];
            __weak Desktop *weak=desktop;
            reloader.onNote=^(NSString *note){[weak say:note];};
            reloader.onEndpoint=^(NSString *runtime,NSString *nonceFile){Desktop *d=weak;if(!d)return;
                const char *failure=NULL;NSString *nonce=helperNonce(nonceFile.fileSystemRepresentation,&failure);
                if(!nonce){[d say:[NSString stringWithFormat:@"The reloaded helper's nonce is unusable: %s",failure]];return;}
                d.nativeEndpoints=@[@{@"runtime":runtime,@"nonce":nonce}];d.nativeResumeFailures=0;d.nativeResumeAfter=0;[d say:@"Dock payload reloaded; reconnecting"];};
            reloader.onPaused=^{Desktop *d=weak;[d say:@"Compositor mode stops here. The Dock that restarted left the windows drawn at the screen's top-left corner (it reset their transforms); Infinify native-desktop, run by hand, restores them from its journal and tries again"];[d quit:nil];};
            desktop.dockReloader=reloader;[reloader watch:YES];
        }}
    desktop.statePath=ownership.statePath;
    // A normal run is the desktop and switches Stage Manager and window tiling off for as long as its canvas is open (-openCanvas:);
    // windowed, --manual and scoped runs leave the user's settings alone. Whatever an earlier run that did not end
    // left changed is put back now, after the single-instance lease above (a second launch never touches a running one's settings)
    // and whether or not this launch gets as far as a canvas. Every end after this one puts them back: the quit action, the exit chord,
    // SIGTERM, SIGINT, SIGHUP and a logout reach -cleanup; exit() from anywhere else reaches the atexit handler. Only a kill that
    // cannot be caught leaves them to the next launch.
    if(!windowed&&!manual&&!scoped){desktop.takeover=[DWSystemTakeover system];takeoverAtExit=desktop.takeover;atexit(putBackAtExit);
        NSString *note=nil;[desktop.takeover restore:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String);}
    // Before the config: its binding table counts DriftWM's sizing actions and toggle-fullscreen among those that run here.
    [desktop resizeCapability];
    // Before the scene: the config decides what a load restores.
    desktop.configPath=config?@(config):nil;desktop.superChord=chord?@(chord):nil;[desktop loadConfig:YES];
    [desktop loadScene:desktop.statePath];
    [[NSNotificationCenter defaultCenter]addObserver:desktop selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    // A quit that AppKit is asked for (log out, restart, shut down) ends like every other: -applicationShouldTerminate:.
    NSApp.delegate=desktop;
    // A desktop launch adopts existing toplevels when its required access is ready.
    // Capture overlays require Screen Recording and Accessibility; authenticated
    // native primary windows require Accessibility, with recording optional for
    // additional captured views. Onboarding waits for these prerequisites or
    // reports a failed scene load; Stage Manager is no prerequisite, a normal run
    // switches it off when the canvas opens (-takeOverWindowSettings). A windowed
    // run still opens immediately, and --manual keeps its chooser above it.
    desktop.managing=!manual;
    if(!desktop.startupError&&(windowed||(desktop.managing&&DWDesktopAccessReady(desktop.native==nil,CGPreflightScreenCaptureAccess(),AXIsProcessTrusted())))){[desktop openCanvas:nil];if(manual)[desktop showChooser:nil];}
    else if(manual)[desktop showChooser:nil];
    else [desktop onboard];
    // Upstream runs autostart on every backend, its nested one included: a managed, a windowed and a chooser-first launch all do.
    // A launch held at the onboarding window runs it when its canvas opens (-onboard).
    if(!desktop.onboarding)[desktop runAutostart];
    // A pool per turn: what a poll, its controller calls and the events it pumps autorelease ends with the turn.
    while(!DWStopSignal){@autoreleasepool{[desktop poll];DWDesktopPump(.08);}}
    // Stopped first: the pending quit reply is written, and no request can arrive during cleanup.
    [desktop.ipc stop];desktop.ipc=nil;[desktop cleanup];[desktop.chooser close];[desktop.onboarding close];[desktop putBackWindowSettings];
    // Relaunch: the same executable with the same arguments in this very process, once everything above has ended and the socket is free again.
    // The process keeps its place: under launchd it is still the login item's job, in a terminal still that terminal's. Not after a signal, which
    // asked for an end. The lines after execv are reached only if it failed.
    if(desktop.relaunch&&DWStopSignal==1){execv(NSBundle.mainBundle.executablePath.fileSystemRepresentation,(char *const *)launched);perror("Infinify: relaunch");return 1;}
    // The quit action, msg action quit, the exit chord and SIGTERM all end here, with status 0: launchd starts the login item again only after an end that is not this one.
    return 0;
} }
