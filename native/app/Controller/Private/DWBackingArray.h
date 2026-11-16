// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
// Private lazy wire view of an already-projected native presentation array.
@interface DWBackingArray : NSArray
- (instancetype)initWithValues:(NSArray *)values;
@end
