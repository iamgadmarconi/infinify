// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "resize.h"
#include <math.h>
#include <unistd.h>
static bool enroll(pid_t pid, CGWindowID window, DWResizeIdentity *identity) {
    // Fixture ready-file publication can precede WindowServer's CG entry briefly.
    for(int n=0;n<100;n++) { if(dw_resize_identity(pid,window,identity)) return true; usleep(20000); }
    return false;
}
static DWResizeResult snapshot_ready(DWResizeIdentity identity, DWResizeSnapshot *snapshot) {
    DWResizeResult r={0};
    for(int n=0;n<30;n++) {
        r=dw_resize_snapshot(identity,snapshot);
        if(r.observed || r.outcome==DWResizeStaleIdentity || r.outcome==DWResizeUnavailable) return r;
        usleep(30000);
    }
    return r;
}
static NSArray *rect(CGRect r) { return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; }
static NSDictionary *report(DWResizeResult r) {
    return @{@"outcome":@(dw_resize_outcome_name(r.outcome)),@"ax_error":@(r.ax_error),@"mutation_attempted":@(r.mutation_attempted),@"observed":@(r.observed),@"moved":@(r.moved),@"ax":rect(r.actual_ax),@"cg":rect(r.actual_cg)};
}
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"failed: %s\n",#x); status=1; goto cleanup; } } while(0)
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2 && argc!=3) return 2;
    NSData *data=[NSData dataWithContentsOfFile:@(argv[1])]; NSDictionary *ready=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if(!ready) return 2;
    NSString *dir=[@(argv[1]) stringByDeletingLastPathComponent];
    if(argc==3) {
        bool once=!strcmp(argv[2],"--resize-once");
        if(!once && strcmp(argv[2],"--expect-unavailable")) return 2;
        DWResizeIdentity id={0};
        if(!enroll([ready[@"pid"] intValue],[ready[@"windows"][0] unsignedIntValue],&id)) return 1;
        if(once) {
            DWResizeSnapshot snapshot={0};
            if(!snapshot_ready(id,&snapshot).observed) return 1;
        }
        DWResizeResult unavailable=dw_resize_apply(id,CGSizeMake(650,450));
        NSData *out=[NSJSONSerialization dataWithJSONObject:report(unavailable) options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(out.bytes,1,out.length,stdout); putchar('\n');
        if(once) return !(unavailable.outcome==DWResizeApplied&&unavailable.observed);
        return !(!unavailable.mutation_attempted && !unavailable.observed && (unavailable.outcome==DWResizeUnavailable||unavailable.outcome==DWResizeTimedOut));
    }
    int status=0; bool moved=false; NSMutableDictionary *evidence=[NSMutableDictionary new];
    DWResizeIdentity ids[3]={0}; DWResizeSnapshot snapshots[3]={0}; DWResizeResult r;
    pid_t pid=[ready[@"pid"] intValue]; NSArray *windows=ready[@"windows"];
    for(int n=0;n<3;n++) { CHECK(enroll(pid,[windows[n] unsignedIntValue],&ids[n])); r=snapshot_ready(ids[n],&snapshots[n]); evidence[[NSString stringWithFormat:@"initial_%d",n]]=report(r); CHECK(r.observed); }
    r=dw_resize_apply(ids[0],CGSizeMake(620,440)); evidence[@"resize"]=report(r); CHECK(r.outcome==DWResizeApplied&&r.observed&&r.mutation_attempted);
    r=dw_resize_apply(ids[0],CGSizeMake(100,100)); evidence[@"minimum"]=report(r); CHECK(r.outcome==DWResizeClamped&&r.actual_ax.size.width>=280&&r.actual_ax.size.height>=200);
    r=dw_resize_apply(ids[1],CGSizeMake(600,400)); evidence[@"unsupported"]=report(r); CHECK(r.outcome==DWResizeUnsupported&&!r.mutation_attempted);
    r=dw_resize_apply(ids[2],CGSizeMake(600,400)); evidence[@"ignored_setter"]=report(r); CHECK(r.outcome==DWResizeRejected&&r.observed&&r.mutation_attempted);
    DWResizeIdentity stale=ids[0]; stale.birth_microseconds++; r=dw_resize_apply(stale,CGSizeMake(600,400)); evidence[@"stale_birth"]=report(r); CHECK(r.outcome==DWResizeStaleIdentity&&!r.mutation_attempted);
    stale=ids[0]; stale.window=UINT32_MAX; r=dw_resize_apply(stale,CGSizeMake(600,400)); evidence[@"stale_window"]=report(r); CHECK(r.outcome==DWResizeStaleIdentity&&!r.mutation_attempted);
    stale=ids[0]; stale.pid=getpid(); r=dw_resize_apply(stale,CGSizeMake(600,400)); evidence[@"wrong_owner"]=report(r); CHECK(r.outcome==DWResizeStaleIdentity&&!r.mutation_attempted);
    r=dw_resize_apply(ids[0],CGSizeMake(NAN,400)); evidence[@"invalid_size"]=report(r); CHECK(r.outcome==DWResizeInvalidRequest&&!r.mutation_attempted);
    r=dw_resize_apply(ids[0],CGSizeMake(32769,400)); evidence[@"oversized"]=report(r); CHECK(r.outcome==DWResizeInvalidRequest&&!r.mutation_attempted);
    for(int n=1;n<3;n++) { r=dw_resize_observe(ids[n]); evidence[[NSString stringWithFormat:@"unchanged_%d",n]]=report(r); CHECK(r.observed&&CGRectEqualToRect(r.actual_ax,snapshots[n].original)); }
    // The owned fixture moves itself; adapter retains identity and reports the new origin.
    CHECK([[@"move" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[dir stringByAppendingPathComponent:@"move"] atomically:YES]);
    for(int n=0;n<100&&![[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"moved.json"]];n++) usleep(20000);
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"moved.json"]]);
    moved=true; r=dw_resize_apply(ids[0],CGSizeMake(610,430)); evidence[@"after_native_move"]=report(r);
    CHECK(r.outcome==DWResizeApplied&&r.observed&&!CGPointEqualToPoint(r.actual_ax.origin,snapshots[0].original.origin));
cleanup:
    if(snapshots[0].valid) { r=dw_resize_restore(snapshots[0]); evidence[@"restore"]=report(r); if(!r.observed||(!moved&&!CGRectEqualToRect(r.actual_ax,snapshots[0].original))||!CGSizeEqualToSize(r.actual_ax.size,snapshots[0].original.size)) status=1; }
    evidence[@"passed"]=@(status==0); evidence[@"activation_calls"]=@0; evidence[@"input_posts"]=@0; 
    // A size that needs room on the screen is preceded by a position write (resize.m, room()), so none is no longer a constant:
    // the results that say the window was moved by one are counted. A write that was not honoured is not seen here.
    int moves=0; for(NSString *key in evidence) if([evidence[key] isKindOfClass:NSDictionary.class]&&[evidence[key][@"moved"] boolValue]) moves++;
    evidence[@"position_moves"]=@(moves);
    NSData *out=[NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:NULL]; fwrite(out.bytes,1,out.length,stdout); putchar('\n'); return status;
} }
