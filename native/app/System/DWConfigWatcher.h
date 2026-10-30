// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// Calls `changed` on the main queue, debounced, when the watched file appears,
// disappears or changes. Its directory is observed for creation, replacement and
// removal, and the file itself for writes in place. While the directory does not
// exist the nearest existing ancestor is observed, so a config created later is
// still seen. Read-only: nothing is created. Main thread only.
@interface DWConfigWatcher : NSObject
- (instancetype)initWithChanged:(void (^)(void))changed;
// Watches `path` instead of any earlier one; a path already watched is left alone.
- (void)watch:(NSString *)path;
// Cancels every source and any pending call. Required before release.
- (void)stop;
@end
