// SPDX-License-Identifier: GPL-3.0-or-later
// The production msg client, IPC server, controller and PNG writer. Only the
// rendered image is synthetic: no NSApplication, GPU, windows, capture or input.
#import "ipc-server.h"
#import "screenshot-writer.h"
#include "driftwm_desktop.h"
#include <signal.h>
#include <unistd.h>

static void check(BOOL ok,const char *why) { if(!ok){fprintf(stderr,"FAIL: %s\n",why);exit(2);} }
static NSDictionary *call(DriftDesktop *controller,NSDictionary *command) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command}options:0 error:nil];
    char *raw=driftwm_desktop_request(controller,bytes.bytes,bytes.length);check(raw!=NULL,"controller response");
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:strlen(raw)]options:0 error:nil];
    driftwm_desktop_response_free(raw);check([reply[@"ok"]boolValue],"controller accepted command");return reply[@"data"];
}
static NSDictionary *pixels(NSDictionary *effect,NSString *root) {
    NSString *path=effect[@"path"];NSUInteger width=[effect[@"width"]unsignedIntegerValue],height=[effect[@"height"]unsignedIntegerValue];
    check([path hasPrefix:[root stringByAppendingString:@"/"]],"writer stays in the disposable directory");
    check(width>0&&height>0&&width<=16&&height<=16,"bounded synthetic image");
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(NULL,width,height,8,0,color,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(color);
    check(context!=NULL,"synthetic bitmap");CGContextSetRGBFillColor(context,.2,.4,.8,1);CGContextFillRect(context,CGRectMake(0,0,width,height));
    CGImageRef image=CGBitmapContextCreateImage(context);CGContextRelease(context);check(image!=NULL,"synthetic image");
    return @{@"image":CFBridgingRelease(image),@"path":path,@"width":@(width),@"height":@(height)};
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc>1&&!strcmp(argv[1],"msg"))return driftwm_desktop_msg(argc-2,argv+2);
    // Only files/sockets in the driver's disposable directory; no AppKit/native
    // admission. Exercise the same pre-controller ownership used by main().
    if(argc==5&&!strcmp(argv[1],"ownership")){
        alarm(15);BOOL duplicate=NO;NSString *error=nil;
        __attribute__((objc_precise_lifetime)) DWRunOwnership *owner=[DWRunOwnership acquireSocket:@(argv[3]) state:@(argv[4]) duplicate:&duplicate error:&error];
        if(!owner){fprintf(stderr,"%s\n",error.UTF8String);puts(duplicate?"DUPLICATE":"ERROR");return duplicate?0:73;}
        puts("OWNED");fflush(stdout);
        if(!strcmp(argv[2],"hold")||!strcmp(argv[2],"exec")){char byte;(void)read(STDIN_FILENO,&byte,1);}
        if(!strcmp(argv[2],"exec")){execl("/bin/sleep","sleep","2",NULL);return 74;}
        return 0;
    }
    if(argc!=4||strcmp(argv[1],"serve"))return 64;
    alarm(30);
    NSString *socket=@(argv[2]),*root=@(argv[3]);DriftDesktop *controller=driftwm_desktop_create();check(controller!=NULL,"controller created");
    call(controller,@{@"op":@"register_output",@"stable_id":@"synthetic",@"screen_bounds":@{@"origin":@{@"x":@0,@"y":@0},@"size":@{@"width":@16,@"height":@16}}});
    NSString *error=nil;DWIPCServer *server=[DWIPCServer serverAtPath:socket handler:^NSData *(NSData *line,BOOL *subscribe,NSData **event){
        (void)subscribe;(void)event;
        id request=[NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:nil];check(request!=nil,"valid client request");
        NSDictionary *data=call(controller,@{@"op":@"ipc",@"output":@1,@"request":request});
        for(NSDictionary *effect in data[@"effects"]){
            check([effect[@"op"]isEqual:@"screenshot"],"only screenshot effects");
            NSMutableDictionary *result=[DWWriteScreenshotPixels(pixels(effect,root))mutableCopy];result[@"op"]=@"screenshot_result";data=call(controller,result);
        }
        check([data[@"reply"]isKindOfClass:NSDictionary.class],"reply after writer result");
        return [NSJSONSerialization dataWithJSONObject:data[@"reply"]options:0 error:nil];
    }error:&error];check(server!=nil,error.UTF8String?:"IPC server");
    signal(SIGTERM,SIG_IGN);dispatch_source_t termination=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(termination,^{[server stop];driftwm_desktop_destroy(controller);CFRunLoopStop(CFRunLoopGetMain());});dispatch_resume(termination);
    puts("READY");fflush(stdout);CFRunLoopRun();dispatch_source_cancel(termination);alarm(0);return 0;
} }
