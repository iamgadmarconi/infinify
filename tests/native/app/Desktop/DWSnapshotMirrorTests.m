// SPDX-License-Identifier: GPL-3.0-or-later
// The real controller's snapshot deltas rebuilt by the shell's mirror, compared with a full snapshot after every step: a camera flight,
// edits, a refused command, a scene load and a controller swap. No NSApplication, window, tap or native call.
#import <Foundation/Foundation.h>
#import "DWSnapshotMirror.h"
#include "driftwm_desktop.h"
static void check(BOOL ok,NSString *why){if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(2);}}
static NSDictionary *rect(double x,double y,double w,double h){return @{@"origin":@{@"x":@(x),@"y":@(y)},@"size":@{@"width":@(w),@"height":@(h)}};}
static NSDictionary *call(DriftDesktop *c,NSDictionary *command,BOOL *ok){
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command}options:0 error:nil];
    char *r=driftwm_desktop_request(c,data.bytes,data.length);check(r!=NULL,@"C ABI response");
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:r length:strlen(r)]options:0 error:nil];driftwm_desktop_response_free(r);
    if(ok)*ok=[reply[@"ok"]boolValue];return [reply[@"ok"]boolValue]?reply[@"data"]:nil;
}
static NSData *canonical(NSDictionary *d){return [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];}
static NSDictionary *identity(int wid){return @{@"pid":@123,@"birth_sec":@1800000000,@"birth_usec":@0,@"wid":@(wid)};}
static DriftDesktop *scene(void){
    DriftDesktop *c=driftwm_desktop_create();
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,50,1000,800)},NULL);call(c,@{@"op":@"register_output",@"stable_id":@"two",@"screen_bounds":rect(1000,50,1000,800)},NULL);
    call(c,@{@"op":@"attach",@"identity":identity(1),@"bundle_id":@"test",@"title":@"far",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(2000,1000,200,100),@"world_rect":rect(2000,1000,200,100)},NULL);
    call(c,@{@"op":@"attach",@"identity":identity(2),@"bundle_id":@"test",@"title":@"near",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(10,20,600,300),@"world_rect":rect(10,20,600,300)},NULL);
    return c;
}
int main(void){@autoreleasepool{
    DriftDesktop *c=scene();DWSnapshotMirror *m=[DWSnapshotMirror new];__block NSString *why=nil;
    NSMutableArray *returned=[NSMutableArray array],*frozen=[NSMutableArray array];
    // Rebuild, compare with a full snapshot, and remember the dictionary and what it encoded to: it is never mutated later.
    NSDictionary *(^step)(NSString *)=^NSDictionary *(NSString *label){
        NSDictionary *got=[m snapshotFrom:c error:&why],*full=call(c,@{@"op":@"snapshot"},NULL);
        check(got!=nil,[NSString stringWithFormat:@"%@: a snapshot is rebuilt (%@)",label,why]);check([got isEqual:full],[NSString stringWithFormat:@"%@: rebuilt equals a fresh full snapshot",label]);
        [returned addObject:got];[frozen addObject:canonical(got)];return got;};
    NSDictionary *prev=step(@"first");
    check([prev[@"windows"]count]==2,@"the first snapshot is the whole scene");
    call(c,@{@"op":@"navigate_window",@"window":@1,@"output":@1,@"zoom_policy":@"keep"},NULL);
    int shared=0,moved=0;
    for(int frame=0;frame<400;frame++){
        BOOL ok=NO;NSDictionary *tick=call(c,@{@"op":@"tick_navigation",@"timestamp_ns":@((unsigned long long)frame*16000000ULL)},&ok);check(ok,@"tick");
        NSDictionary *now=step([NSString stringWithFormat:@"flight frame %d",frame]);
        if(frame>0&&now[@"windows"]==prev[@"windows"]&&now[@"lifecycle"]==prev[@"lifecycle"])shared++;
        if(![now[@"outputs"]isEqual:prev[@"outputs"]])moved++;
        prev=now;if(frame>2&&[tick[@"clock_only"]isEqual:@YES])break;
    }
    check(moved>3,@"the flight moved the outputs");check(shared>=moved,@"unchanged sections are the previous snapshot's own objects");
    // A refused command leaves the baseline valid.
    BOOL ok=YES;call(c,@{@"op":@"no-such-op"},&ok);check(!ok,@"unknown op is refused");step(@"after a refused command");
    NSArray<NSDictionary *> *edits=@[
        @{@"op":@"action",@"output":@1,@"action":@"zoom-in"},@{@"op":@"hover",@"output":@1,@"screen":@{@"x":@300,@"y":@200}},
        @{@"op":@"observe",@"window":@2,@"identity":identity(2),@"source_rect":rect(30,40,640,320),@"buffer":@{@"width":@640,@"height":@320}},
        @{@"op":@"attach",@"identity":identity(3),@"bundle_id":@"test",@"title":@"third",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(500,500,300,200),@"world_rect":rect(500,500,300,200)},
        @{@"op":@"window_closed",@"window":@3,@"identity":identity(3)},@{@"op":@"action",@"output":@1,@"action":@"zoom-out"}];
    for(NSDictionary *edit in edits)call(c,edit,NULL),step(edit[@"op"]);
    // A failing controller reply, then recovery with a full snapshot.
    check([m snapshotFrom:NULL error:&why]==nil&&why.length,@"a NULL controller is refused with a reason");step(@"after a refusal");
    // A scene load replaces the state wholesale.
    NSString *path=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];call(c,@{@"op":@"save",@"path":path},NULL);
    call(c,@{@"op":@"action",@"output":@1,@"action":@"zoom-in"},NULL);step(@"edit before load");
    call(c,@{@"op":@"load",@"path":path},&ok);check(ok,@"load");[m reset];step(@"after load");[[NSFileManager defaultManager]removeItemAtPath:path error:nil];
    // The same mirror asked about another controller (or a clone) must not patch its baseline.
    DriftDesktop *other=driftwm_desktop_create();call(other,@{@"op":@"register_output",@"stable_id":@"solo",@"screen_bounds":rect(0,0,640,480)},NULL);
    NSDictionary *swapped=[m snapshotFrom:other error:&why];check([swapped isEqual:call(other,@{@"op":@"snapshot"},NULL)],@"a controller swap resynchronises");
    DriftDesktop *copy=driftwm_desktop_clone(c);NSDictionary *cloned=[m snapshotFrom:copy error:&why];check([cloned isEqual:call(copy,@{@"op":@"snapshot"},NULL)],@"a clone swap resynchronises");
    NSDictionary *back=[m snapshotFrom:c error:&why];check([back isEqual:call(c,@{@"op":@"snapshot"},NULL)],@"swapping back resynchronises");
    // Nothing returned earlier was changed by later rebuilds.
    for(NSUInteger i=0;i<returned.count;i++)check([canonical(returned[i])isEqual:frozen[i]],@"a previously returned snapshot is unchanged");
    fprintf(stderr,"ok: %lu snapshots rebuilt by delta equal full snapshots; %d flight frames shared unchanged sections; previous snapshots intact\n",(unsigned long)returned.count,shared);
    driftwm_desktop_destroy(copy);driftwm_desktop_destroy(other);driftwm_desktop_destroy(c);
}return 0;}
