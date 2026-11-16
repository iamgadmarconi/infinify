// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWProjectedArray.h"
#import "DWScene+Private.h"
@implementation DWProjectedArray {
    NSArray *_array;
    Class _valueClass;
    NSMutableDictionary<NSNumber *,id> *_values;
}
- (instancetype)initWithArray:(NSArray *)array valueClass:(Class)valueClass {
    if((self=[super init])){_array=[array copy];_valueClass=valueClass;}
    return self;
}
- (NSUInteger)count { return _array.count; }
- (id)objectAtIndex:(NSUInteger)index {
    id value=_values[@(index)];if(value)return value;
    id raw=_array[index];
    value=_valueClass==DWEffect.class?DWProjectEffect(raw):DWProject(_valueClass,raw);
    // Preserve positions of malformed entries; the decoded array was not filtered before.
    if(!value)value=NSNull.null;
    if(!_values)_values=[NSMutableDictionary dictionary];_values[@(index)]=value;return value;
}
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
@end
