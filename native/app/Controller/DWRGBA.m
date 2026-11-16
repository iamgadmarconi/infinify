// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWRGBA {
    NSArray *_components;
}
- (instancetype)initWithComponents:(NSArray *)components { if((self=[super init]))_components=[components copy];return self; }
- (NSNumber *)red { return _components.count>0?DWNumber(_components[0]):nil; }
- (NSNumber *)green { return _components.count>1?DWNumber(_components[1]):nil; }
- (NSNumber *)blue { return _components.count>2?DWNumber(_components[2]):nil; }
- (NSNumber *)alpha { return _components.count>3?DWNumber(_components[3]):nil; }
- (BOOL)hasNumericComponents { return _components.count==4&&self.red&&self.green&&self.blue&&self.alpha; }
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
- (BOOL)isEqual:(id)other { return self==other||([other isKindOfClass:DWRGBA.class]&&[_components isEqual:((DWRGBA *)other)->_components]); }
- (NSUInteger)hash { return _components.hash; }
@end
DWRGBA *DWProjectColor(id array) { array=DWArray(array);return array?[[DWRGBA alloc]initWithComponents:array]:nil; }
