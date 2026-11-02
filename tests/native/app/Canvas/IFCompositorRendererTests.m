// SPDX-License-Identifier: GPL-3.0-or-later
// Link the production graveyard and exercise only its CPU ownership fences.
// No renderer, Metal device, native window, capture or input is created.
// This file uses manual reference counting to model an explicitly autoreleased
// framework dependency without ARC's return-value autorelease elision.
#import <Foundation/Foundation.h>
#import "IFCompositor.h"
#include <unistd.h>

@interface IFCGraveyard : NSObject
- (void)began;
- (void)finished;
- (void)bury:(id)object;
@end

static NSUInteger checks,retiredReleased,dependenciesReleased,reentered;
static void check(BOOL condition,const char *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}

@interface IFCLifetimeDependency : NSObject
@end
@implementation IFCLifetimeDependency
- (void)dealloc {dependenciesReleased++;[super dealloc];}
@end

@interface IFCLifetimeRetired : NSObject {
    IFCLifetimeDependency *_dependency;
    IFCGraveyard *_owner; // Unretained: the test keeps its graveyard alive.
}
- (instancetype)initWithOwner:(IFCGraveyard *)owner;
@end
@implementation IFCLifetimeRetired
- (instancetype)initWithOwner:(IFCGraveyard *)owner {
    if((self=[super init])){_owner=owner;_dependency=[IFCLifetimeDependency new];}return self;
}
- (void)dealloc {
    retiredReleased++;
    // A framework may autorelease a temporary owner while destroying its
    // wrapper. The callback must drain this dependency before it returns too.
    [[[NSArray alloc]initWithObjects:_dependency,nil]autorelease];
    [_dependency release];
    // Reentrant disposal proves that retired objects are released outside the
    // graveyard's lock; it must not deadlock or alter the GPU fence counters.
    [_owner bury:@42];reentered++;
    [super dealloc];
}
@end

static void bury(IFCGraveyard *graveyard) {
    IFCLifetimeRetired *retired=[[IFCLifetimeRetired alloc]initWithOwner:graveyard];
    [graveyard bury:retired];[retired release];
}

int main(void) {
    alarm(10); // A future release-under-lock regression must fail, not hang.
    @autoreleasepool {
        IFCompositorChromeStyle *style=[IFCompositorChromeStyle new];
        style.titleBarHeight=30;style.fontSize=12;
        CGRect label=IFCompositorStandInLabelRect(@"Terminal",NO,CGSizeMake(860,469),2,style);
        check(!CGRectIsNull(label)&&CGRectContainsPoint(label,CGPointMake(430,219)),"stand-in centered label uses its actual fitted text bounds");
        check(!CGRectContainsPoint(label,CGPointMake(20,219)),"stand-in body outside text cannot relaunch");
        check(CGRectIsNull(IFCompositorStandInLabelRect(@"",NO,CGSizeMake(860,469),2,style)),"empty label has no relaunch target");
        CGRect tile=CGRectMake(20,30,800,600);
        CGRect matched=IFCompositorContentDestination(tile,CGSizeMake(400,300),CGSizeMake(400,300));
        check(CGRectEqualToRect(matched,tile),"matching capture fills the tile as before");
        CGRect stale=IFCompositorContentDestination(tile,CGSizeMake(200,150),CGSizeMake(400,300));
        check(CGRectEqualToRect(stale,CGRectMake(20,30,400,300)),"stale capture uses its own size anchored at the tile top-left");
        check(CGRectEqualToRect(IFCompositorContentDestination(tile,CGSizeMake(399.5,300.25),CGSizeMake(400,300)),tile),"sub-point rounding is not a stale capture");
        check(CGRectEqualToRect(IFCompositorContentDestination(tile,CGSizeMake(800,600),CGSizeMake(400,300)),tile),"an oversized stale capture is cropped, not shrunk");
        check(CGSizeEqualToSize(IFCompositorContentFraction(CGSizeMake(200,299.5),CGSizeMake(400,300)),CGSizeMake(.5,1)),"width-only stale fraction preserves a near-matching height");
        check(CGSizeEqualToSize(IFCompositorContentFraction(CGSizeMake(399.5,150),CGSizeMake(400,300)),CGSizeMake(1,.5)),"height-only stale fraction preserves a near-matching width");
        check(CGRectEqualToRect(IFCompositorContentDestination(tile,CGSizeMake(200,299.5),CGSizeMake(400,300)),CGRectMake(20,30,400,600)),"width-only stale destination keeps full tile height");
        check(CGRectEqualToRect(IFCompositorContentDestination(tile,CGSizeMake(399.5,150),CGSizeMake(400,300)),CGRectMake(20,30,800,300)),"height-only stale destination keeps full tile width");
        CGRect crop=CGRectMake(12,18,800,600);
        check(CGRectEqualToRect(IFCompositorContentSource(crop,CGSizeMake(800,600),CGSizeMake(400,300)),CGRectMake(12,18,400,300)),"oversized capture crops both source axes without moving the origin");
        check(CGRectEqualToRect(IFCompositorContentSource(crop,CGSizeMake(200,150),CGSizeMake(400,300)),crop),"undersized capture keeps the full source");
        check(CGRectEqualToRect(IFCompositorContentSource(crop,CGSizeMake(800,300.5),CGSizeMake(400,300)),CGRectMake(12,18,400,600)),"width-only source crop preserves a near-matching height");
        check(CGRectEqualToRect(IFCompositorContentSource(crop,CGSizeMake(400.5,600),CGSizeMake(400,300)),CGRectMake(12,18,800,300)),"height-only source crop preserves a near-matching width");
        CGRect right,bottom;
        IFCompositorContentBackdrop(tile,stale,&right,&bottom);
        check(CGRectEqualToRect(right,CGRectMake(420,30,400,600)),"backdrop right strip starts after the picture");
        check(CGRectEqualToRect(bottom,CGRectMake(20,330,400,300)),"backdrop bottom strip stops before the right strip");
        check(!CGRectIntersectsRect(right,stale)&&!CGRectIntersectsRect(bottom,stale)&&!CGRectIntersectsRect(right,bottom),"backdrop never underpaints translucent content or overlaps itself");
        check(right.size.width*right.size.height+bottom.size.width*bottom.size.height+stale.size.width*stale.size.height==tile.size.width*tile.size.height,"backdrop and picture exactly cover the tile");
        IFCompositorContentBackdrop(tile,tile,&right,&bottom);
        check(CGRectIsEmpty(right)&&CGRectIsEmpty(bottom),"matching or cropped-oversized content needs no backdrop");
        IFCompositorContentBackdrop(tile,CGRectMake(20,30,400,600),&right,&bottom);
        check(CGRectEqualToRect(right,CGRectMake(420,30,400,600))&&CGRectIsEmpty(bottom),"width-only undersize paints only the right strip");
        IFCompositorContentBackdrop(tile,CGRectMake(20,30,800,300),&right,&bottom);
        check(CGRectIsEmpty(right)&&CGRectEqualToRect(bottom,CGRectMake(20,330,800,300)),"height-only undersize paints only the bottom strip");
        IFCGraveyard *graveyard=[IFCGraveyard new];
        [graveyard began];bury(graveyard);
        check(retiredReleased==0&&dependenciesReleased==0,"GPU still using a retired image retains it");
        [graveyard finished];
        check(retiredReleased==1,"retired image is released by its completion callback");
        check(dependenciesReleased==1,"nested autoreleased image dependency is released before callback return");
        check(reentered==1,"image disposal may reenter the graveyard outside its lock");

        [graveyard began];bury(graveyard);[graveyard began];bury(graveyard);
        check(retiredReleased==1,"later commands do not release either pending image early");
        [graveyard finished];
        check(retiredReleased==2&&dependenciesReleased==2,"first completion releases only its eligible image");
        [graveyard finished];
        check(retiredReleased==3&&dependenciesReleased==3,"next completion releases the later image");

        [graveyard began];[graveyard began];bury(graveyard);
        [graveyard finished];
        check(retiredReleased==3,"image retired after two submissions waits for both");
        [graveyard finished];
        check(retiredReleased==4&&dependenciesReleased==4,"last required completion releases that image");

        // Keep this outer pool alive across a busy batch, as a completion worker
        // can. Every completed prefix must return its surfaces without waiting
        // for either later GPU commands or the worker's outer pool to drain.
        for(NSUInteger i=0;i<32;i++){[graveyard began];bury(graveyard);}
        for(NSUInteger i=0;i<32;i++){
            [graveyard finished];
            check(retiredReleased==5+i&&dependenciesReleased==5+i,"each completed batch prefix promptly releases exactly its dependencies");
        }
        check(reentered==retiredReleased,"all retired images dispose outside the lock");
        [graveyard release];
    }
    check(retiredReleased==36&&dependenciesReleased==36,"outer pool drain releases no additional completed images");
    alarm(0);
    printf("PASS: compositor image lifetime: %lu checks; no GPU, windows, capture or input\n",(unsigned long)checks);
    return 0;
}
