// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include "driftwm_desktop.h"

// Filesystem work runs on a serial worker with an independent controller copy.
// At most one running and one pending snapshot; the latest pending save wins.
// Submitting and draining are main-thread operations. No native action occurs.
@interface DWSceneWriter : NSObject
// Copies the exclusively accessed controller before returning. NO on failure to
// prepare a copy/request; YES means queued, not yet durable.
- (BOOL)submit:(DriftDesktop *)controller path:(NSString *)path;
// Wait for queued saves at shutdown or before a synchronous save. Remains usable.
- (void)drain;
// Latest save failed. Main queue; older failures are logged but do not retry an
// already superseded snapshot. The owner can mark its current scene dirty again.
@property (copy) void (^failed)(NSString *reason);
@end
