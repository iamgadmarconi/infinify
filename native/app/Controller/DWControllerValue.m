// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
#import "DWProjectedArray.h"

@implementation DWControllerValue {
    NSDictionary *_rawDictionary;
    NSMutableDictionary<NSString *,id> *_projections;
}
- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if((self=[super init]))_rawDictionary=[dictionary copy];
    return self;
}
- (NSDictionary *)rawDictionary { return _rawDictionary; }
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
- (void)cacheProjection:(NSString *)key value:(id)value {
    if(!_projections)_projections=[NSMutableDictionary dictionary];_projections[key]=value?:NSNull.null;
}
- (id)cachedProjection:(NSString *)key make:(id (^)(void))make {
    id value=_projections[key];if(value)return value==NSNull.null?nil:value;
    value=make();if(!_projections)_projections=[NSMutableDictionary dictionary];
    _projections[key]=value?:NSNull.null;return value;
}
- (BOOL)isEqual:(id)other {
    return self==other||([other isKindOfClass:DWControllerValue.class]&&[_rawDictionary isEqual:[other rawDictionary]]);
}
- (NSUInteger)hash { return _rawDictionary.hash; }
@end

NSNumber *DWNumber(id value) { return [value isKindOfClass:NSNumber.class]?value:nil; }
NSString *DWString(id value) { return [value isKindOfClass:NSString.class]?value:nil; }
NSDictionary *DWDictionary(id value) { return [value isKindOfClass:NSDictionary.class]?value:nil; }
NSArray *DWArray(id value) { return [value isKindOfClass:NSArray.class]?value:nil; }
DWValuePresence DWPresence(id value,Class type) {
    if(!value)return DWValueAbsent;if(value==NSNull.null)return DWValueNull;
    return [value isKindOfClass:type]?DWValuePresent:DWValueMalformed;
}
// Main-queue-only weak interning: shared decoded sections retain their projection identity
// without retaining old snapshots. No decoded tree is traversed on construction.
id DWProject(Class type,id dictionary) {
    if(type==DWScreenshotTarget.class&&DWString(dictionary))dictionary=@{@"unit":dictionary};
    dictionary=DWDictionary(dictionary);if(!dictionary)return nil;
    static NSMapTable *values;static dispatch_once_t once;
    dispatch_once(&once,^{values=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];});
    NSMapTable *classes=[values objectForKey:dictionary];
    if(!classes){classes=[NSMapTable strongToWeakObjectsMapTable];[values setObject:classes forKey:dictionary];}
    id value=[classes objectForKey:type];
    if(!value){value=[[type alloc]initWithDictionary:dictionary];[classes setObject:value forKey:type];}
    return value;
}
NSArray *DWProjectArray(Class type,id array) {
    array=DWArray(array);if(!array)return nil;
    static NSMapTable *arrays;static dispatch_once_t once;
    dispatch_once(&once,^{arrays=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];});
    NSMapTable *classes=[arrays objectForKey:array];
    if(!classes){classes=[NSMapTable strongToWeakObjectsMapTable];[arrays setObject:classes forKey:array];}
    NSArray *value=[classes objectForKey:type];if(!value){value=[[DWProjectedArray alloc]initWithArray:array valueClass:type];[classes setObject:value forKey:type];}return value;
}
DWEffect *DWProjectEffect(id dictionary) {
    NSDictionary *d=DWDictionary(dictionary);if(!d)return nil;
    NSString *op=DWString(d[@"op"]);Class type=DWShellEffect.class;
    if([op isEqual:@"focus_native_window"])type=DWFocusEffect.class;
    else if([op isEqual:@"resize_native_window"]||[op isEqual:@"observe_resize_source"])type=DWSizeEffect.class;
    return DWProject(type,d);
}
CGPoint DWScenePoint(id value) {
    NSDictionary *d=DWDictionary(value);return CGPointMake([DWNumber(d[@"x"])doubleValue],[DWNumber(d[@"y"])doubleValue]);
}
CGSize DWSceneSize(id value) {
    NSDictionary *d=DWDictionary(value);return CGSizeMake([DWNumber(d[@"width"])doubleValue],[DWNumber(d[@"height"])doubleValue]);
}
CGRect DWSceneRect(id value) {
    NSDictionary *d=DWDictionary(value);return (CGRect){DWScenePoint(d[@"origin"]),DWSceneSize(d[@"size"])};
}
NSDictionary *DWScenePointDictionary(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
NSDictionary *DWSceneSizeDictionary(CGSize s) { return @{@"width":@(s.width),@"height":@(s.height)}; }
NSDictionary *DWSceneRectDictionary(CGRect r) { return @{@"origin":DWScenePointDictionary(r.origin),@"size":DWSceneSizeDictionary(r.size)}; }

BOOL DWSceneGeometryIsNumeric(id value,NSUInteger shape) {
    NSDictionary *d=DWDictionary(value);if(!d)return NO;
    if(shape==0)return DWNumber(d[@"x"])&&DWNumber(d[@"y"]);
    if(shape==1)return DWNumber(d[@"width"])&&DWNumber(d[@"height"]);
    return DWSceneGeometryIsNumeric(d[@"origin"],0)&&DWSceneGeometryIsNumeric(d[@"size"],1);
}
