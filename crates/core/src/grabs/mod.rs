// SPDX-License-Identifier: GPL-3.0-or-later
//
// NEW FILE, not a port of upstream's src/grabs/mod.rs (malbiruk/driftwm at
// 352333a8fa1b22171492d4b71a54102045c9a19d). Upstream's file holds the pointer
// grab plumbing of the compositor (`forward_pointer_grab_methods!`,
// `drag_map_window`) and declares seven grab modules, all of which drive
// Smithay seats; none of that is ported. This file only declares the one pure
// module of the directory.
//
// Visibility: upstream declares `mod touch_recognizer;` inside its binary
// crate. It is `pub` here because the native backend lives in another crate.
// See PORT.md in the crate root for the full change log.

pub mod touch_recognizer;
