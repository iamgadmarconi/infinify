// SPDX-License-Identifier: GPL-3.0-or-later
//
// NEW FILE, not a port of upstream's src/input/mod.rs (malbiruk/driftwm at
// 352333a8fa1b22171492d4b71a54102045c9a19d). Upstream's file is the
// compositor's libinput event dispatch and declares seven input modules; none
// of that is ported. This file only declares `gestures`, of which one pure
// helper is kept (see src/input/gestures.rs).
//
// Visibility: upstream declares `pub(crate) mod gestures;` inside its binary
// crate. It is `pub` here because the native backend lives in another crate.
// See PORT.md in the crate root for the full change log.

pub mod gestures;
