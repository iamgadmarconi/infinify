// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWBackingArray.h"
#import "DWScene+Private.h"
@implementation DWBackingArray {
    NSArray *_values;
}
- (instancetype)initWithValues:(NSArray *)values { if((self=[super init]))_values=[values copy];return self; }
- (NSUInteger)count { return _values.count; }
- (id)objectAtIndex:(NSUInteger)index { return [(DWControllerValue *)_values[index]rawDictionary]; }
- (id)copyWithZone:(NSZone *)zone { (void)zone;return self; }
@end
