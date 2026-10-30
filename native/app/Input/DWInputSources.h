// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// macOS's stand-in for upstream's xkb layout list: the keyboard input sources the
// user has enabled and can select, in the system's own order, which is what the
// input menu offers. Nothing is enabled, disabled, installed or reordered here;
// selecting one of them is the only write. Main thread only.

// The selected source as the fields of the controller's layout_changed command:
// "name" (its localized name, where upstream reports xkb's layout name), "short"
// (its first language code such as "en" or "ru", the nearest thing macOS has to an
// xkb layout code; else the last component of its identifier), its "index" in the
// list and the list's "count". nil when the selected source is not in the list.
NSDictionary *DWCurrentLayout(void);
// Upstream's SwitchLayout for one {"op":"switch_layout","target":…,"index":…}
// effect: target "next" or "prev" steps through the list and wraps, and target
// "index" selects the 0-based "index". Returns nil when the wanted source is
// selected, else why nothing changed: an index out of range changes nothing, as
// upstream.
NSString *DWSwitchLayout(NSDictionary *effect);
