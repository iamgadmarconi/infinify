// SPDX-License-Identifier: GPL-3.0-or-later
// Diagnostic-only query ABI/call sequence from native/backend/bridge.m and
// native/privileged/payload.m, checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd. See YABAI-NOTICE.txt.
// No mutators are resolved. Values never feed capture geometry or input routing.
typedef struct {
    int (*connection)(void);
    CGError (*bounds)(int, uint32_t, CGRect *);
    CGError (*screenRect)(int, uint32_t, CGRect *);
    CGError (*transform)(int, uint32_t, CGAffineTransform *);
} GeometryAPI;
static GeometryAPI geometryAPI;
static void loadGeometryAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
        if(!handle)return;
        geometryAPI.connection=dlsym(handle,"SLSMainConnectionID");
        geometryAPI.bounds=dlsym(handle,"SLSGetWindowBounds");
        geometryAPI.screenRect=dlsym(handle,"SLSGetScreenRectForWindow");
        geometryAPI.transform=dlsym(handle,"SLSGetWindowTransform");
    });
}
static BOOL finiteGeometry(NSArray *values) {
    for(NSNumber *value in values)if(!isfinite(value.doubleValue))return NO;
    return YES;
}
static NSDictionary *geometryReadback(uint32_t wid,pid_t pid,NSArray *enrolledBirth,int query) {
    NSString *basis=query==2?@"Raw WindowServer affine coefficients [a,b,c,d,tx,ty]; private basis, not converted":
        @"Raw WindowServer rectangle [x,y,width,height]; private basis, not converted or assumed equivalent to CG/AppKit";
    NSMutableDictionary *result=[@{@"valid":@NO,@"coordinate_basis":basis,@"status":@"identity_stale",@"api_status":NSNull.null}mutableCopy];
    // Revalidate the exact enrolled PID/birth/CGID before EACH private query.
    if(!ownedCGWindow(wid,pid,enrolledBirth))return result;
    loadGeometryAPI();
    if(!geometryAPI.connection||(query==0&&!geometryAPI.bounds)||(query==1&&!geometryAPI.screenRect)||(query==2&&!geometryAPI.transform)){
        result[@"status"]=@"unavailable";return result;
    }
    CGRect r=CGRectZero;CGAffineTransform t=CGAffineTransformIdentity;
    int connection=geometryAPI.connection();
    CGError status=query==0?geometryAPI.bounds(connection,wid,&r):query==1?geometryAPI.screenRect(connection,wid,&r):geometryAPI.transform(connection,wid,&t);
    result[@"api_status"]=@(status);
    // Never publish values whose ownership became stale during the call.
    if(!ownedCGWindow(wid,pid,enrolledBirth))return result;
    if(status!=kCGErrorSuccess){result[@"status"]=@"api_error";return result;}
    NSArray *values=query==2?@[@(t.a),@(t.b),@(t.c),@(t.d),@(t.tx),@(t.ty)]:rect(r);
    if(!finiteGeometry(values)){result[@"status"]=@"nonfinite_result";return result;}
    result[@"valid"]=@YES;result[@"status"]=@"ok";result[@"value"]=values;return result;
}
static NSDictionary *ownedGeometry(uint32_t wid,pid_t pid,NSArray *enrolledBirth,NSWindow *ownedWindow) {
    NSMutableDictionary *result=[@{@"diagnostic_only":@YES,@"id":@(wid),@"pid":@(pid),@"process_birth":enrolledBirth?:@[],
        @"sample_start_uptime_seconds":@(NSProcessInfo.processInfo.systemUptime),@"valid":@NO}mutableCopy];
    BOOL before=ownedCGWindow(wid,pid,enrolledBirth)!=nil;
    NSMutableDictionary *app=[@{@"valid":@NO,@"status":@"unavailable_in_host",
        @"coordinate_basis":@"AppKit logical screen points, bottom-left origin, y up; content frame converted to screen coordinates"}mutableCopy];
    if(ownedWindow){
        app[@"status"]=@"identity_stale";
        if(before&&pid==getpid()&&(uint32_t)ownedWindow.windowNumber==wid){
            NSArray *frame=rect(NSRectToCGRect(ownedWindow.frame));
            NSView *view=ownedWindow.contentView;
            NSArray *content=rect(NSRectToCGRect([ownedWindow convertRectToScreen:[view convertRect:view.bounds toView:nil]]));
            if(view&&finiteGeometry(frame)&&finiteGeometry(content)){
                app[@"valid"]=@YES;app[@"status"]=@"ok";app[@"frame"]=frame;app[@"content_frame"]=content;
            }else app[@"status"]=@"nonfinite_result";
        }
    }
    result[@"appkit"]=app;
    NSMutableDictionary *server=[NSMutableDictionary dictionary];
    NSArray *names=@[@"SLSGetWindowBounds",@"SLSGetScreenRectForWindow",@"SLSGetWindowTransform"];
    for(int i=0;i<3;i++)server[names[i]]=geometryReadback(wid,pid,enrolledBirth,i);
    result[@"window_server"]=server;
    BOOL after=ownedCGWindow(wid,pid,enrolledBirth)!=nil&&(!ownedWindow||(uint32_t)ownedWindow.windowNumber==wid);
    if(!before||!after){
        // Reject the whole diagnostic sample, including earlier successful calls.
        result[@"appkit"]=@{@"valid":@NO,@"status":@"identity_stale",@"coordinate_basis":app[@"coordinate_basis"]};
        for(NSString *name in names){NSMutableDictionary *field=[server[name]mutableCopy];field[@"valid"]=@NO;field[@"status"]=@"identity_stale";[field removeObjectForKey:@"value"];server[name]=field;}
    }
    result[@"identity_valid_before"]=@(before);result[@"identity_valid_after"]=@(after);
    BOOL complete=before&&after&&[app[@"valid"]boolValue];
    for(NSString *name in names)complete&=[server[name][@"valid"]boolValue];
    result[@"valid"]=@(complete);result[@"status"]=!before||!after?@"identity_stale":complete?@"ok":@"partial_or_unavailable";
    result[@"sample_end_uptime_seconds"]=@(NSProcessInfo.processInfo.systemUptime);
    return result;
}
