// SPDX-License-Identifier: GPL-3.0-or-later
// Link the production graveyard and exercise only its CPU ownership fences.
// No renderer, Metal device, native window, capture or input is created.
// This file uses manual reference counting to model an explicitly autoreleased
// framework dependency without ARC's return-value autorelease elision.
#import <Foundation/Foundation.h>
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
