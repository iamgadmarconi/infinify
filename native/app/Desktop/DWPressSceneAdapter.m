// SPDX-License-Identifier: GPL-3.0-or-later
// Scene facts and controller commands keep their existing JSON form behind this adapter.
#import "DWPressSceneAdapter.h"
#import "Desktop+Private.h"
#import "DWControllerHit.h"
#import "DWGeometryJSON.h"
@interface DWPressSceneAdapter ()
@property (weak) Desktop *desktop;
@end
@implementation DWPressSceneAdapter
- (instancetype)initWithDesktop:(Desktop *)desktop { if((self=[super init]))_desktop=desktop;return self; }
- (NSDictionary *)call:(NSDictionary *)request { return [self.desktop call:request]; }
- (NSDictionary *)binding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window under:(NSNumber *)under pick:(BOOL)pick {
    return [self.desktop mouseBinding:trigger source:source flags:flags window:window under:under pick:pick];
}
- (NSDictionary *)hit:(CGPoint)p output:(NSNumber *)output view:(DesktopView *)view {
    if(view.nativePointValid&&view.nativeFamilyHit)return view.nativeFamilyHit;
    // Controller input intentionally rejects placeholders. Find their geometry only
    // for the explicit dismiss action; this result never authorizes native delivery.
    NSDictionary *snapshot=[view.desktop presentationSnapshot];NSNumber *under=nil;
    BOOL inOutput=NO;for(NSDictionary *item in snapshot[@"outputs"])if([item[@"id"]isEqual:output]&&CGRectContainsPoint(DWRectFromJSON(item[@"screen_bounds"]),p))inOutput=YES;if(!inOutput)return nil;
    NSArray *tokens=[view.desktop.compositor appliedOrderForOutput:output snapshot:snapshot];
    // Stale pixels/layout cannot authorize a differently ordered replica hit.
    if(!tokens){
        return nil;
    }
    NSMutableDictionary *placements=[NSMutableDictionary dictionary];for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"output"]isEqual:output])placements[placement[@"window"]]=placement;
    // Native replicas use exactly the renderer's described root/child order.
    // Placeholders still only authorize canvas actions, never native delivery.
    for(NSDictionary *token in [tokens reverseObjectEnumerator]){
        if(!DWTyped(token[@"window"],NSNumber.class))continue;
        NSDictionary *placement=placements[token[@"window"]];if(!placement||![placement[@"output"]isEqual:output])continue;
        NSString *key=DWTyped(token[@"key"],NSString.class);
        LiveSource *source=view.desktop.sources[placement[@"window"]];CGRect site=DWRectFromJSON(placement[@"screen_rect"]),own=CGRectZero;
        if(source.router.bounds)CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own);
        if(key&&source.pixels&&!source.error&&!source.detached&&(!view.desktop.native||[view.desktop.nativeViews replica:source.logical output:output])&&site.size.width>0&&site.size.height>0){
            CGPoint local=CGPointMake((p.x-site.origin.x)*own.size.width/site.size.width,(p.y-site.origin.y)*own.size.height/site.size.height);
            NSDictionary *member=key?[view.desktop.nativeFamilies hit:source.logical key:key local:local]:[view.desktop.nativeFamilies hit:source.logical local:local];
            if(member){NSMutableDictionary *context=[@{@"window":source.logical,@"local":pointJSON(local),@"native_member":member,@"generation":member[@"generation"]}mutableCopy];
                for(NSString *flag in @[@"widget",@"pinned"])if([DWTyped(placement[flag],NSNumber.class)boolValue])context[flag]=@YES;
                return context[@"widget"]||context[@"pinned"]||[placement[@"fullscreen"]boolValue]?context:DWPickHit(context,snapshot,output);
            }
        }
        if(key)continue;
        // A family-only projection has no visible root content. Only an exact
        // captured child hit above can authorize a recipient in its clip.
        if([placement[@"family_only"]boolValue]||!CGRectContainsPoint(DWRectFromJSON(placement[@"clip_rect"]),p))continue;
        if(!source){NSMutableDictionary *held=[@{@"window":placement[@"window"],@"placeholder":@YES} mutableCopy];for(NSString *flag in @[@"widget",@"pinned"])if([DWTyped(placement[flag],NSNumber.class)boolValue])held[flag]=@YES;return held[@"widget"]||held[@"pinned"]?held:DWPickHit(held,snapshot,output);}under=placement[@"window"];break;
    }
    if(!under)return nil;
    NSDictionary *reply=[self call:@{@"op":@"hit",@"output":output,@"screen":pointJSON(p)}];
    return DWControllerHit(reply[@"hit"],YES,under);
}
@end
