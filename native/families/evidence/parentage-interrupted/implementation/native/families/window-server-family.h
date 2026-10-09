// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only private ABI/call sequence adapted from yabai (MIT), commit
// dd845723416f5fe92af49fad5ebab00369e07edd: src/window.c:872-897,
// src/misc/extern.h:9,66-72; src/window_manager.c:841-855.
// See YABAI-NOTICE.txt. This adapter only queries freshly validated owned windows.
typedef struct {
    void *handle;
    int (*mainConnection)(void);
    CFArrayRef (*associated)(int, uint32_t);
    CFTypeRef (*query)(int, CFArrayRef, int);
    CFTypeRef (*copyWindows)(CFTypeRef);
    int (*count)(CFTypeRef);
    bool (*advance)(CFTypeRef);
    uint32_t (*parent)(CFTypeRef);
    uint32_t (*window)(CFTypeRef);
    BOOL ready;
} FamilyAPI;
static FamilyAPI familyAPI;

static BOOL loadFamilyAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        familyAPI.handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
        if(!familyAPI.handle)return;
        familyAPI.mainConnection=dlsym(familyAPI.handle,"SLSMainConnectionID");
        familyAPI.associated=dlsym(familyAPI.handle,"SLSCopyAssociatedWindows");
        familyAPI.query=dlsym(familyAPI.handle,"SLSWindowQueryWindows");
        familyAPI.copyWindows=dlsym(familyAPI.handle,"SLSWindowQueryResultCopyWindows");
        familyAPI.count=dlsym(familyAPI.handle,"SLSWindowIteratorGetCount");
        familyAPI.advance=dlsym(familyAPI.handle,"SLSWindowIteratorAdvance");
        familyAPI.parent=dlsym(familyAPI.handle,"SLSWindowIteratorGetParentID");
        familyAPI.window=dlsym(familyAPI.handle,"SLSWindowIteratorGetWindowID");
        familyAPI.ready=familyAPI.mainConnection&&familyAPI.associated&&familyAPI.query&&familyAPI.copyWindows&&
            familyAPI.count&&familyAPI.advance&&familyAPI.parent&&familyAPI.window;
    });
    return familyAPI.ready;
}

static NSDictionary *ownedCGWindow(uint32_t wid,pid_t pid,NSArray *enrolledBirth) {
    if(!wid||pid<=1||!enrolledBirth||![birth(pid)isEqual:enrolledBirth])return nil;
    NSDictionary *info=cg(wid);return [info[(id)kCGWindowOwnerPID]intValue]==pid?info:nil;
}

static NSDictionary *queryOwnedParent(uint32_t wid,pid_t pid,NSArray *enrolledBirth) {
    if(!loadFamilyAPI()||!ownedCGWindow(wid,pid,enrolledBirth))return @{@"valid":@NO,@"error":@"Private ABI unavailable or source identity invalid"};
    CFArrayRef ids=(__bridge CFArrayRef)@[@(wid)];
    CFTypeRef query=familyAPI.query(familyAPI.mainConnection(),ids,1);
    if(!query)return @{@"valid":@NO,@"error":@"WindowServer query returned no result"};
    CFTypeRef iterator=familyAPI.copyWindows(query);
    int count=iterator?familyAPI.count(iterator):0;BOOL advanced=iterator&&count==1&&familyAPI.advance(iterator);
    uint32_t actual=advanced?familyAPI.window(iterator):0,parent=advanced?familyAPI.parent(iterator):0;
    BOOL extra=advanced&&familyAPI.advance(iterator);
    if(iterator)CFRelease(iterator);CFRelease(query);
    BOOL valid=advanced&&!extra&&actual==wid&&ownedCGWindow(wid,pid,enrolledBirth)!=nil;
    if(parent&&!ownedCGWindow(parent,pid,enrolledBirth))valid=NO;
    return @{@"valid":@(valid),@"id":@(wid),@"iterator_id":@(actual),@"parent_id":@(parent),@"iterator_count":@(count),
        @"error":valid?@"":@"Ambiguous iterator result or ownership changed"};
}

static NSDictionary *discoverOwnedFamily(uint32_t root,pid_t pid,NSArray *enrolledBirth) {
    NSMutableDictionary *result=[@{@"valid":@NO,@"root":@(root),@"pid":@(pid),@"process_birth":enrolledBirth?:@[],
        @"route":@"SLSCopyAssociatedWindows + exact SLSWindowQueryWindows parent IDs + CG bounds",@"members":@[]}mutableCopy];
    NSDictionary *rootQuery=queryOwnedParent(root,pid,enrolledBirth);result[@"root_query"]=rootQuery;
    if(![rootQuery[@"valid"]boolValue]||[rootQuery[@"parent_id"]unsignedIntValue]){result[@"error"]=@"Selected window is not a verified WindowServer root";return result;}
    CFArrayRef associated=familyAPI.associated(familyAPI.mainConnection(),root);
    if(!associated||CFGetTypeID(associated)!=CFArrayGetTypeID()||CFArrayGetCount(associated)>64){if(associated)CFRelease(associated);result[@"error"]=@"Missing or unbounded association result";return result;}
    NSArray *raw=CFBridgingRelease(associated);result[@"associated_ids"]=raw;
    NSMutableOrderedSet<NSNumber *> *ids=[NSMutableOrderedSet orderedSetWithObject:@(root)];
    for(id wid in raw){
        if(![wid isKindOfClass:NSNumber.class]||[wid longLongValue]<=0||[wid unsignedLongLongValue]>UINT32_MAX||!ownedCGWindow([wid unsignedIntValue],pid,enrolledBirth)){
            result[@"error"]=@"Association contains an unowned, vanished, or invalid identity";return result;
        }
        if(![wid isEqual:@(root)]&&[ids containsObject:wid]){result[@"error"]=@"Duplicate child association";return result;}
        [ids addObject:wid];
    }
    NSMutableDictionary<NSNumber *,NSDictionary *> *queries=[NSMutableDictionary dictionary];queries[@(root)]=rootQuery;
    for(NSNumber *wid in ids)if(wid.unsignedIntValue!=root){NSDictionary *q=queryOwnedParent(wid.unsignedIntValue,pid,enrolledBirth);queries[wid]=q;
        if(![q[@"valid"]boolValue]||![q[@"parent_id"]unsignedIntValue]){result[@"error"]=@"Associated child has no verified native parent";result[@"queries"]=queries.allValues;return result;}}
    // Require every association's actual ancestry to end at this root. No title,
    // geometry, AppKit fixture parent field, or process-wide grouping is used.
    for(NSNumber *wid in ids){NSNumber *cursor=wid;NSMutableSet *seen=[NSMutableSet set];
        while(![cursor isEqual:@(root)]){
            if([seen containsObject:cursor]||!queries[cursor]){result[@"error"]=@"Cyclic or incomplete native parent chain";return result;}
            [seen addObject:cursor];cursor=queries[cursor][@"parent_id"];
        }
    }
    CGRect extent=CGRectNull;NSMutableArray *members=[NSMutableArray array];
    for(NSNumber *wid in ids){NSDictionary *info=ownedCGWindow(wid.unsignedIntValue,pid,enrolledBirth);CGRect bounds=CGRectZero;
        BOOL valid=info&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)&&
            isfinite(bounds.origin.x)&&isfinite(bounds.origin.y)&&isfinite(bounds.size.width)&&isfinite(bounds.size.height)&&bounds.size.width>0&&bounds.size.height>0;
        if(!valid){result[@"error"]=@"Native member disappeared or has invalid bounds";return result;}
        extent=CGRectUnion(extent,bounds);NSMutableDictionary *member=[queries[wid]mutableCopy];member[@"cg_bounds"]=rect(bounds);member[@"cg_owner"]=@(pid);[members addObject:member];
    }
    if(![birth(pid)isEqual:enrolledBirth]||!ownedCGWindow(root,pid,enrolledBirth)){result[@"error"]=@"Process identity changed during discovery";return result;}
    result[@"valid"]=@YES;result[@"members"]=members;result[@"native_bounds"]=rect(extent);return result;
}
