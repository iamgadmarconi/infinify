// SPDX-License-Identifier: GPL-3.0-or-later
// The shell's side of the controller's snapshot transport: the last snapshot it rebuilt, kept apart from Desktop's own caches.
#import <Foundation/Foundation.h>
#include "driftwm_desktop.h"
// Asks the controller for the sections of its snapshot that changed since the last one this mirror rebuilt (driftwm_desktop_snapshot_delta)
// instead of a whole encoded snapshot. Whatever it cannot prove it holds, it resynchronises with a full snapshot. Main thread only.
@interface DWSnapshotMirror : NSObject
// The controller's current snapshot, equal to the "data" of a "snapshot" request, as an immutable dictionary that shares unchanged
// sections with the previous one; nil with *error set (the text a failed request leaves in the status) when the controller fails.
- (NSDictionary *)snapshotFrom:(DriftDesktop *)controller error:(NSString **)error;
// Forget the baseline: the next call asks for a full snapshot.
- (void)reset;
@end
