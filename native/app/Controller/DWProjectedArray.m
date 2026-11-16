// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWProjectedArray.h"
#import "DWScene+Private.h"
#include <stdlib.h>
@implementation DWProjectedArray {
    NSArray *_array;
    Class _valueClass;
    id __strong *_values;
    NSMutableArray<DWEffect *> *_effectCache;
}
- (instancetype)initWithArray:(NSArray *)array valueClass:(Class)valueClass {
    if((self=[super init])){_array=array;_valueClass=valueClass;}return self;
}
- (instancetype)initWithArray:(NSArray *)array valueClass:(Class)valueClass effectCache:(NSMutableArray<DWEffect *> *)cache {
    if((self=[self initWithArray:array valueClass:valueClass]))_effectCache=cache;return self;
}
- (NSUInteger)count { return _array.count; }
- (id)objectAtIndex:(NSUInteger)index {
    id raw=_array[index]; // Preserve NSArray's range exception even before cache allocation.
    if(_values&&_values[index])return _values[index];
    id value;
    if(_valueClass==DWEffect.class)value=_effectCache?DWProjectCachedEffect(raw,_effectCache):DWProjectEffect(raw);
    else value=DWProject(_valueClass,raw);
    if(!value)value=NSNull.null; // Malformed entries keep their original positions.
    if(!_values){
        _values=(id __strong *)calloc(_array.count,sizeof(*_values));
        if(!_values)[NSException raise:NSMallocException format:@"Could not allocate projected array cache"];
    }
    _values[index]=value;return value;
}
- (BOOL)isEqualToArray:(NSArray *)other {
    if(self==other)return YES;
    if([other isKindOfClass:DWProjectedArray.class]){
        NSArray *raw=((DWProjectedArray *)other)->_array;return _array==raw||[_array isEqualToArray:raw];
    }
    return [super isEqualToArray:other];
}
- (BOOL)isEqual:(id)other { return self==other||([other isKindOfClass:NSArray.class]&&[self isEqualToArray:other]); }
- (NSUInteger)hash { return _array.hash; }
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
- (void)dealloc { if(_values){for(NSUInteger i=0,n=_array.count;i<n;i++)_values[i]=nil;free(_values);} }
@end
