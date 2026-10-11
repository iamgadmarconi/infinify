// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Pointer delivery from an extra display view. The caller authorizes an already
// bound identity and validates the controller's hit. This adapter independently
// checks the process birth, owner and untransformed geometry immediately before
// posting. Local application points and transformed screen points stay separate.
BOOL DWNativeReplicaPost(CGEventRef event,CGEventSourceRef source,int64_t tag,
                         NSDictionary *identity,CGRect observed,CGPoint local);
