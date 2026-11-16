// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWBackingArray.h"
#import "DWScene+Private.h"
@implementation DWBackingArray {
    NSArray *_values;
}
- (instancetype)initWithValues:(NSArray *)values { if((self=[super init]))_values=values;return self; }
- (NSUInteger)count { return _values.count; }
- (id)objectAtIndex:(NSUInteger)index { return [(DWControllerValue *)_values[index]rawDictionary]; }
- (BOOL)isEqualToArray:(NSArray *)other {
    if(self==other)return YES;
    if([other isKindOfClass:DWBackingArray.class]){
        NSArray *values=((DWBackingArray *)other)->_values;return _values==values||[_values isEqualToArray:values];
    }return [super isEqualToArray:other];
}
- (BOOL)isEqual:(id)other { return self==other||([other isKindOfClass:NSArray.class]&&[self isEqualToArray:other]); }
- (NSUInteger)hash { return _values.hash; }
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
@end
