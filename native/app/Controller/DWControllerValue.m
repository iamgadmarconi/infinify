// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
#import "DWProjectedArray.h"

@implementation DWControllerValue {
    NSDictionary *_rawDictionary;
    NSMutableDictionary<NSString *,id> *_projections;
}
- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if((self=[super init]))_rawDictionary=dictionary;
    return self;
}
- (NSDictionary *)rawDictionary { return _rawDictionary; }
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
- (void)cacheProjection:(NSString *)key value:(id)value {
    if(!_projections)_projections=[NSMutableDictionary dictionary];_projections[key]=value?:NSNull.null;
}
- (void)seedCachedProjectionForKey:(NSString *)key fromValue:(DWControllerValue *)other {
    id cached=other->_projections[key];if(!cached)return;
    if(!_projections)_projections=[NSMutableDictionary dictionary];_projections[key]=cached;
}
- (id)cachedProjection:(NSString *)key make:(id (^)(void))make {
    id value=_projections[key];if(value)return value==NSNull.null?nil:value;
    value=make();if(!_projections)_projections=[NSMutableDictionary dictionary];
    _projections[key]=value?:NSNull.null;return value;
}
- (BOOL)isEqual:(id)other {
    if(self==other)return YES;if(![other isKindOfClass:DWControllerValue.class])return NO;
    NSDictionary *raw=[other rawDictionary];return _rawDictionary==raw||[_rawDictionary isEqual:raw];
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
// Parent-owned lazy caches retain projections. Decoded containers are already immutable;
// owned mutable records are frozen once at their construction site, never while projecting.
id DWProject(Class type,id dictionary) {
    if(type==DWScreenshotTarget.class&&DWString(dictionary))return [[DWScreenshotTarget alloc]initWithUnit:dictionary];
    dictionary=DWDictionary(dictionary);return dictionary?[[type alloc]initWithDictionary:dictionary]:nil;
}
NSArray *DWProjectArray(Class type,id array) {
    array=DWArray(array);return array?[[DWProjectedArray alloc]initWithArray:array valueClass:type]:nil;
}
DWEffect *DWProjectEffect(id dictionary) {
    NSDictionary *d=DWDictionary(dictionary);if(!d)return nil;
    NSString *op=DWString(d[@"op"]);Class type=DWShellEffect.class;
    if([op isEqual:@"focus_native_window"])type=DWFocusEffect.class;
    else if([op isEqual:@"resize_native_window"]||[op isEqual:@"observe_resize_source"])type=DWSizeEffect.class;
    return DWProject(type,d);
}
DWEffect *DWProjectCachedEffect(id dictionary,NSMutableArray<DWEffect *> *cache) {
    NSDictionary *raw=DWDictionary(dictionary);if(!raw)return nil;
    for(DWEffect *value in cache)if(value.rawDictionary==raw)return value;
    DWEffect *value=DWProjectEffect(raw);[cache addObject:value];return value;
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

CGRect DWNativeCoercingRect(id r) {
    return CGRectMake([r[@"origin"][@"x"]doubleValue],[r[@"origin"][@"y"]doubleValue],
        [r[@"size"][@"width"]doubleValue],[r[@"size"][@"height"]doubleValue]);
}
