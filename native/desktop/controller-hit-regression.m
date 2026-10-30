// SPDX-License-Identifier: GPL-3.0-or-later
// The real controller's null hit, read the way the pointer paths read it. No NSApplication, tap, window or native call.
// Build c49eae1 aborted the owner's run with -[NSNull objectForKeyedSubscript:] when the renderer's order showed a
// placement the controller did not hit: `NSDictionary *hit=reply[@"hit"]` held NSNull and `hit[@"window"]` raised in the event tap.
#import <Foundation/Foundation.h>
#import "controller-hit.h"
#include "driftwm_desktop.h"
static void check(BOOL ok,NSString *why){if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(2);}else fprintf(stderr,"ok: %s\n",why.UTF8String);}
static NSDictionary *rect(double x,double y,double w,double h){return @{@"origin":@{@"x":@(x),@"y":@(y)},@"size":@{@"width":@(w),@"height":@(h)}};}
static NSDictionary *call(DriftDesktop *c,NSDictionary *command){
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command}options:0 error:nil];
    char *r=driftwm_desktop_request(c,data.bytes,data.length);check(r!=NULL,@"C ABI response");
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:r length:strlen(r)]options:0 error:nil];driftwm_desktop_response_free(r);
    return [reply[@"ok"]boolValue]?reply[@"data"]:nil;
}
int main(void){@autoreleasepool{
    DriftDesktop *c=driftwm_desktop_create();
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800),@"usable_rect_local":rect(0,30,1000,770)});
    NSDictionary *empty=call(c,@{@"op":@"hit",@"output":@1,@"screen":@{@"x":@500,@"y":@400}});
    check(empty!=nil&&[empty[@"hit"]isKindOfClass:NSNull.class],@"the controller answers {\"hit\": null} over empty canvas, which parses as NSNull");
    // The pre-fix expression, kept to show this scenario is the crash: NSNull has no keyed subscripting.
    BOOL raised=NO;@try{NSDictionary *old=empty[@"hit"];(void)[old[@"window"]isEqual:@7];}@catch(NSException *e){raised=[e.name isEqual:NSInvalidArgumentException];}
    check(raised,@"reading that null as a dictionary raised NSInvalidArgumentException, the owner's crash");
    check(DWControllerHit(empty[@"hit"],YES,@7)==nil,@"ordered path: a placement under the point but a null controller hit gives no hit");
    check(DWControllerHit(empty[@"hit"],NO,nil)==nil,@"unordered path: a null controller hit gives no hit, not NSNull");
    check(DWControllerHit(empty[@"hit"],YES,nil)==nil,@"ordered path with nothing under the point gives no hit");
    check(DWControllerHit(nil,YES,@7)==nil&&DWControllerHit(@"x",NO,nil)==nil&&DWControllerHit(@[],YES,@7)==nil,@"a missing or non-object hit is no hit");
    // A real hit still passes, and on the ordered path only for the window the renderer put on top.
    call(c,@{@"op":@"attach",@"identity":@{@"pid":@123,@"birth_sec":@1800000000,@"birth_usec":@5,@"wid":@1},@"bundle_id":@"test",@"title":@"source",
        @"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(100,100,400,300),@"world_rect":rect(100,100,400,300)});
    NSDictionary *snapshot=call(c,@{@"op":@"snapshot"}),*placement=[snapshot[@"placements"]firstObject];
    check(placement!=nil,@"the attached window has a placement");
    NSDictionary *at=placement[@"screen_rect"];CGPoint centre=CGPointMake([at[@"origin"][@"x"]doubleValue]+[at[@"size"][@"width"]doubleValue]/2,[at[@"origin"][@"y"]doubleValue]+[at[@"size"][@"height"]doubleValue]/2);
    NSDictionary *found=call(c,@{@"op":@"hit",@"output":@1,@"screen":@{@"x":@(centre.x),@"y":@(centre.y)}});
    NSNumber *window=found[@"hit"][@"window"];
    check([found[@"hit"]isKindOfClass:NSDictionary.class]&&window!=nil,@"a point inside the window gives an object hit");
    check([DWControllerHit(found[@"hit"],NO,nil)isEqual:found[@"hit"]]&&[DWControllerHit(found[@"hit"],YES,window)isEqual:found[@"hit"]],@"a real hit passes on both paths when the renderer agrees");
    check(DWControllerHit(found[@"hit"],YES,@(window.integerValue+1))==nil,@"on the ordered path a hit on another window than the renderer's top one is refused");
    driftwm_desktop_destroy(c);
    fprintf(stderr,"controller-hit: all checks passed\n");return 0;
}}
