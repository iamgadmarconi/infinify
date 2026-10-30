// SPDX-License-Identifier: GPL-3.0-or-later
// A value out of a decoded reply or property list, or nil when it is not of the class expected. Header-only, like DWOwnerFile.h.
#import <Foundation/Foundation.h>

static inline id DWTyped(id value,Class type) { return [value isKindOfClass:type]?value:nil; }
