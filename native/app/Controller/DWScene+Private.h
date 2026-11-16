// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Transport construction and wire representation never leave the Controller module.
#import "DWScene.h"
#import "DWControllerReply.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWControllerValue ()
@property(nonatomic,readonly) NSDictionary *rawDictionary;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (void)seedCachedProjectionForKey:(NSString *)key fromValue:(DWControllerValue *)other;
- (void)cacheProjection:(NSString *)key value:(nullable id)value;
- (nullable id)cachedProjection:(NSString *)key make:(id _Nullable (^)(void))make;
@end
@interface DWScene (Private)
+ (nullable instancetype)sceneWithDictionary:(nullable id)dictionary;
// Called once before publishing a new scene, after immutable shallow mirror/clock updates.
- (DWScene *)sceneBySeedingProjectionsFrom:(nullable DWScene *)previous;
@end
@interface DWControllerReply (Private)
+ (nullable instancetype)replyWithDictionary:(nullable id)dictionary;
@end
FOUNDATION_EXPORT id _Nullable DWProject(Class type,id _Nullable dictionary);
FOUNDATION_EXPORT NSArray * _Nullable DWProjectArray(Class type,id _Nullable array);
FOUNDATION_EXPORT DWEffect * _Nullable DWProjectEffect(id _Nullable dictionary);
FOUNDATION_EXPORT DWEffect * _Nullable DWProjectCachedEffect(id _Nullable dictionary,NSMutableArray<DWEffect *> *cache);
FOUNDATION_EXPORT DWValuePresence DWPresence(id _Nullable value,Class type);
FOUNDATION_EXPORT NSNumber * _Nullable DWNumber(id _Nullable value);
FOUNDATION_EXPORT NSString * _Nullable DWString(id _Nullable value);
FOUNDATION_EXPORT NSDictionary * _Nullable DWDictionary(id _Nullable value);
FOUNDATION_EXPORT NSArray * _Nullable DWArray(id _Nullable value);
FOUNDATION_EXPORT CGRect DWSceneRect(id _Nullable value);
FOUNDATION_EXPORT CGRect DWNativeCoercingRect(id _Nullable value);
FOUNDATION_EXPORT CGPoint DWScenePoint(id _Nullable value);
FOUNDATION_EXPORT CGSize DWSceneSize(id _Nullable value);
FOUNDATION_EXPORT NSDictionary *DWSceneRectDictionary(CGRect value);
FOUNDATION_EXPORT NSDictionary *DWScenePointDictionary(CGPoint value);
FOUNDATION_EXPORT NSDictionary *DWSceneSizeDictionary(CGSize value);
FOUNDATION_EXPORT BOOL DWSceneGeometryIsNumeric(id _Nullable value,NSUInteger shape);
@interface DWEffect (Private)
@property(nonatomic,readonly,nullable) NSString *operation;
@end
@interface DWControllerReply (EffectsPrivate)
- (nullable DWEffect *)cachedEffectFromDictionary:(nullable id)dictionary;
@property(nonatomic,readonly,nullable) DWEffect *navigationEffect;
@property(nonatomic,readonly,nullable) NSArray<DWEffect *> *effects;
@end
FOUNDATION_EXPORT DWRGBA * _Nullable DWProjectColor(id _Nullable array);
@interface DWScreenshotTarget (UnitPrivate)
- (instancetype)initWithUnit:(NSString *)unit;
@end
NS_ASSUME_NONNULL_END
