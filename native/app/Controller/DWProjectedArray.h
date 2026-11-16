// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
// Private indexed projection; building the array does not visit its elements.
@interface DWProjectedArray : NSArray
- (instancetype)initWithArray:(NSArray *)array valueClass:(Class)valueClass;
@end
