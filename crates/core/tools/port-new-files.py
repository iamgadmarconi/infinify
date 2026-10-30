#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Re-create, or check, the files this crate ports from malbiruk/driftwm beyond
the driftwm-config and driftwm-layout ports: canvas, stage, window_ext, the
touch recogniser and `direction_from_vector`, with their tests.

Not part of the build. It is the record of how those twelve files were made:
each is the upstream file plus a provenance header and the exact edits listed
below. Every edit states how many times its source text must occur, so an
upstream text that is not the pinned one stops the script instead of being
silently skipped.

    tools/port-new-files.py /path/to/driftwm-checkout            # check
    tools/port-new-files.py /path/to/driftwm-checkout --write    # regenerate

Check mode writes nothing and exits 1 if a file in the crate differs from what
the script produces. The files of the two earlier ports (src/config, src/layout,
src/session.rs and their tests) are not produced here; tools/diff-upstream.sh
covers all of them.
"""
import hashlib
import sys
from pathlib import Path

if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--write"):
    sys.exit(__doc__)
UP = Path(sys.argv[1])
OUT = Path(__file__).resolve().parent.parent
WRITE = len(sys.argv) == 3
COMMIT = "df3de27b26c7998e8a460cffd8a4925cbed3a322"
STALE = []


def header(path, sha, changes):
    lines = [
        "// SPDX-License-Identifier: GPL-3.0-or-later",
        "//",
        "// Ported from DriftWM (GPL-3.0-or-later)",
        "//   repository: https://github.com/malbiruk/driftwm",
        f"//   commit:     {COMMIT}",
        f"//   path:       {path}",
        f"//   sha-256:    {sha} (upstream file)",
    ]
    lines += ["// " + c if c else "//" for c in changes]
    lines.append("// See PORT.md in the crate root for the full change log.")
    return "\n".join(lines) + "\n\n"


def replace_exact(text, old, new, count):
    n = text.count(old)
    if n != count:
        sys.exit(f"expected {count} occurrence(s) of {old!r}, found {n}")
    return text.replace(old, new)


def cut_lines(text, first, last, expect_first, expect_last):
    """Remove 1-based inclusive line range, checking its first and last line."""
    lines = text.split("\n")
    if lines[first - 1] != expect_first:
        sys.exit(f"line {first}: expected {expect_first!r}, found {lines[first - 1]!r}")
    if lines[last - 1] != expect_last:
        sys.exit(f"line {last}: expected {expect_last!r}, found {lines[last - 1]!r}")
    return "\n".join(lines[: first - 1] + lines[last:])


def port(src, dst, changes, edit):
    raw = (UP / src).read_bytes()
    sha = hashlib.sha256(raw).hexdigest()
    text = edit(raw.decode("utf-8"))
    out = OUT / dst
    data = (header(src, sha, changes) + text).encode("utf-8")
    if WRITE:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
        print(f"wrote      {dst}  (upstream sha-256 {sha})")
    elif out.is_file() and out.read_bytes() == data:
        print(f"identical  {dst}  (upstream sha-256 {sha})")
    else:
        print(f"DIFFERS    {dst}  (upstream sha-256 {sha})")
        STALE.append(dst)


# --- canvas -----------------------------------------------------------------
port(
    "src/canvas.rs",
    "src/canvas.rs",
    [
        "Changes from upstream: this header, and the one Smithay import",
        "(`use smithay::utils::{Logical, Point, Rectangle, Size};`) reads",
        "`crate::platform::utils`. Everything else is unmodified.",
    ],
    lambda t: replace_exact(
        t,
        "use smithay::utils::{Logical, Point, Rectangle, Size};\n",
        "use crate::platform::utils::{Logical, Point, Rectangle, Size};\n",
        1,
    ),
)

port(
    "tests/canvas_navigation_test.rs",
    "tests/canvas_navigation_test.rs",
    [
        "Changes from upstream: this header, and crate paths only: `driftwm::`",
        "reads `driftwm_core::` (2 imports) and `smithay::` reads",
        "`driftwm_core::platform::` (1 import). Everything else is unmodified.",
    ],
    lambda t: replace_exact(
        replace_exact(
            replace_exact(
                t,
                "use driftwm::canvas::find_nearest;\n",
                "use driftwm_core::canvas::find_nearest;\n",
                1,
            ),
            "use driftwm::config::Direction;\n",
            "use driftwm_core::config::Direction;\n",
            1,
        ),
        "use smithay::utils::{Logical, Point};\n",
        "use driftwm_core::platform::utils::{Logical, Point};\n",
        1,
    ),
)


FMT_STMT = (
    "    // driftwm-core: kept on one line as upstream has it; the longer crate path\n"
    "    // takes it past 100 columns and rustfmt would re-wrap it.\n"
    "    #[rustfmt::skip]\n"
)


def fmt_import(indent):
    return (
        indent + "// driftwm-core: keeps upstream's import order; rustfmt would sort the\n"
        + indent + "// `crate::platform` paths (upstream: `smithay`) ahead of this one.\n"
        + indent + "#[rustfmt::skip]\n"
    )


def canvas_transforms(t):
    t = replace_exact(t, "use driftwm::canvas::{\n", "use driftwm_core::canvas::{\n", 1)
    t = replace_exact(
        t,
        "use smithay::utils::{Point, Size};\n",
        "use driftwm_core::platform::utils::{Point, Size};\n",
        1,
    )
    t = replace_exact(
        t,
        ", smithay::utils::Logical> = ",
        ", driftwm_core::platform::utils::Logical> = ",
        4,
    )
    for tail in ("Point::from((80.0, 40.0));", "Point::from((120.0, -60.0));"):
        stmt = (
            "    let delta_canvas: Point<f64, driftwm_core::platform::utils::Logical> = "
            + tail
            + "\n"
        )
        assert len(stmt) - 1 > 100, stmt
        t = replace_exact(t, stmt, FMT_STMT + stmt, 1)
    return t


port(
    "tests/canvas_transforms_test.rs",
    "tests/canvas_transforms_test.rs",
    [
        "Changes from upstream: this header, and crate paths only: `driftwm::`",
        "reads `driftwm_core::` (1 import) and `smithay::` reads",
        "`driftwm_core::platform::` (1 import, 4 inline type paths); and two",
        "`let delta_canvas…` statements carry `#[rustfmt::skip]` plus a comment so",
        "they stay on one line as upstream has them. Everything else is unmodified.",
    ],
    canvas_transforms,
)

port(
    "tests/canvas_zoom_test.rs",
    "tests/canvas_zoom_test.rs",
    [
        "Changes from upstream: this header, and crate paths only: `driftwm::`",
        "reads `driftwm_core::` (1 import) and `smithay::` reads",
        "`driftwm_core::platform::` (1 import). Everything else is unmodified.",
    ],
    lambda t: replace_exact(
        replace_exact(t, "use driftwm::canvas::{\n", "use driftwm_core::canvas::{\n", 1),
        "use smithay::utils::{Logical, Point, Rectangle, Size};\n",
        "use driftwm_core::platform::utils::{Logical, Point, Rectangle, Size};\n",
        1,
    ),
)

# --- stage ------------------------------------------------------------------
port(
    "src/stage/mod.rs",
    "src/stage/mod.rs",
    [
        "Changes from upstream: this header, and the one Smithay import",
        "(`use smithay::utils::{Logical, Point, Size};`) reads",
        "`crate::platform::utils`. Everything else is unmodified.",
    ],
    lambda t: replace_exact(
        t,
        "use smithay::utils::{Logical, Point, Size};\n",
        "use crate::platform::utils::{Logical, Point, Size};\n",
        1,
    ),
)


def stage_element(t):
    # The Wayland impl (`impl StageElement for Window`, upstream lines 20-34,
    # with the blank line 19 before it) and the three imports only it needs.
    t = cut_lines(t, 19, 34, "", "}")
    t = replace_exact(t, "use smithay::desktop::Window;\n", "", 1)
    t = replace_exact(
        t,
        "use smithay::utils::{IsAlive, Logical, Size};\n",
        "use crate::platform::utils::{Logical, Size};\n",
        1,
    )
    t = replace_exact(t, "use smithay::wayland::seat::WaylandFocus;\n", "", 1)
    return t


port(
    "src/stage/element.rs",
    "src/stage/element.rs",
    [
        "Changes from upstream: this header; `impl StageElement for Window` (the",
        "Smithay Wayland window, upstream lines 20-34) is left out together with",
        "the imports only it used (`smithay::desktop::Window`,",
        "`smithay::utils::IsAlive`, `smithay::wayland::seat::WaylandFocus`); the",
        "remaining import reads `crate::platform::utils::{Logical, Size}`. The",
        "`StageElement` trait itself is unmodified.",
    ],
    stage_element,
)

port(
    "src/stage/mock.rs",
    "src/stage/mock.rs",
    [
        "Changes from upstream: this header, and the two Smithay imports read",
        "`crate::platform::reexports::wayland_server::protocol::wl_surface::WlSurface`",
        "and `crate::platform::utils::{Logical, Size}`. Everything else is",
        "unmodified.",
    ],
    lambda t: replace_exact(
        replace_exact(
            t,
            "use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;\n",
            "use crate::platform::reexports::wayland_server::protocol::wl_surface::WlSurface;\n",
            1,
        ),
        "use smithay::utils::{Logical, Size};\n",
        "use crate::platform::utils::{Logical, Size};\n",
        1,
    ),
)

port(
    "src/stage/tests.rs",
    "src/stage/tests.rs",
    [
        "Changes from upstream: this header, and the two Smithay imports",
        "(`use smithay::utils::{Point, Size};` at the top and",
        "`use smithay::utils::{Logical, Point, Size};` in `mod harness`) read",
        "`crate::platform::utils`; and `use proptest::prelude::*;` in `mod harness`",
        "carries `#[rustfmt::skip]` plus a comment so the import order stays",
        "upstream's. Everything else is unmodified.",
    ],
    lambda t: replace_exact(
        replace_exact(
            replace_exact(
                t,
                "use smithay::utils::{Point, Size};\n",
                "use crate::platform::utils::{Point, Size};\n",
                1,
            ),
            "    use smithay::utils::{Logical, Point, Size};\n",
            "    use crate::platform::utils::{Logical, Point, Size};\n",
            1,
        ),
        "    use proptest::prelude::*;\n",
        fmt_import("    ") + "    use proptest::prelude::*;\n",
        1,
    ),
)


# --- window_ext -------------------------------------------------------------
def window_ext(t):
    # `impl WindowExt for Window` (upstream lines 92-211, blank line 91 before).
    t = cut_lines(t, 91, 211, "", "}")
    # `set_tiled_states`, `unset_tiled_states`, `decoration_mode_to_wire` and,
    # new in v0.21.0, `decoration_mode_to_kde_manager`, `decoration_mode_to_kde`
    # (upstream lines 6-65 with their doc comments, and the blank line 66).
    t = cut_lines(
        t,
        6,
        66,
        "/// Set all four Tiled states. GTK et al. read Tiled as \"drop your shadow +",
        "",
    )
    t = replace_exact(t, "use smithay::desktop::Window;\n", "", 1)
    t = replace_exact(
        t,
        "use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;\n",
        "use crate::platform::reexports::wayland_server::protocol::wl_surface::WlSurface;\n",
        1,
    )
    t = replace_exact(
        t,
        "use smithay::utils::{Logical, Size};\n",
        "use crate::platform::utils::{Logical, Size};\n",
        1,
    )
    t = replace_exact(t, "use smithay::wayland::shell::xdg::ToplevelSurface;\n", "", 1)
    return t


port(
    "src/window_ext.rs",
    "src/window_ext.rs",
    [
        "Changes from upstream: this header; only the `WindowExt` trait is kept",
        "(upstream lines 67-90, unmodified). Left out, because each needs the",
        "Wayland stack: `set_tiled_states`, `unset_tiled_states`,",
        "`decoration_mode_to_wire`, `decoration_mode_to_kde_manager` and",
        "`decoration_mode_to_kde` (lines 6-65), `impl WindowExt for Window`",
        "(lines 92-211), and the imports only they used",
        "(`smithay::desktop::Window`, `smithay::wayland::shell::xdg::ToplevelSurface`).",
        "The two remaining imports read `crate::platform::`.",
    ],
    window_ext,
)


# --- gestures ---------------------------------------------------------------
def recognizer(t):
    t = replace_exact(
        t,
        "use smithay::backend::input::TouchSlot;\n",
        "use crate::platform::backend::input::TouchSlot;\n",
        1,
    )
    t = replace_exact(
        t,
        "use smithay::utils::{Logical, Point};\n",
        "use crate::platform::utils::{Logical, Point};\n",
        1,
    )
    t = replace_exact(t, "use driftwm::config::{\n", "use crate::config::{\n", 1)
    t = replace_exact(
        t,
        "    fn swipe_threshold_for(&self, dir: driftwm::config::Direction) -> Option<ThresholdAction> {\n",
        "    fn swipe_threshold_for(&self, dir: crate::config::Direction) -> Option<ThresholdAction> {\n",
        1,
    )
    t = replace_exact(
        t,
        "        use driftwm::config::Direction;\n",
        "        use crate::config::Direction;\n",
        1,
    )
    return t


port(
    "src/grabs/touch_recognizer.rs",
    "src/grabs/touch_recognizer.rs",
    [
        "Changes from upstream: this header, and path prefixes only: `smithay::`",
        "reads `crate::platform::` (2 imports) and `driftwm::` reads `crate::`",
        "(1 import, 2 inline paths in `swipe_threshold_for`); upstream has this",
        "file in its binary crate, where the library is the extern crate",
        "`driftwm`. Everything else is unmodified.",
    ],
    recognizer,
)


def recognizer_tests(t):
    t = replace_exact(
        t,
        "use smithay::backend::input::TouchSlot;\n",
        "use crate::platform::backend::input::TouchSlot;\n",
        1,
    )
    t = replace_exact(
        t,
        "use smithay::utils::{Logical, Point};\n",
        "use crate::platform::utils::{Logical, Point};\n",
        1,
    )
    t = replace_exact(
        t,
        "use driftwm::config::{Action, ContextBindings, ContinuousAction, Direction};\n",
        "use crate::config::{Action, ContextBindings, ContinuousAction, Direction};\n",
        1,
    )
    t = replace_exact(
        t,
        "use proptest::prelude::*;\n",
        fmt_import("") + "use proptest::prelude::*;\n",
        1,
    )
    return t


port(
    "src/grabs/touch_recognizer/tests.rs",
    "src/grabs/touch_recognizer/tests.rs",
    [
        "Changes from upstream: this header, and path prefixes only: `smithay::`",
        "reads `crate::platform::` (2 imports) and `driftwm::` reads `crate::`",
        "(1 import); and `use proptest::prelude::*;` carries `#[rustfmt::skip]`",
        "plus a comment so the import order stays upstream's. Everything else is",
        "unmodified.",
    ],
    recognizer_tests,
)


def gestures(t):
    # Keep `direction_from_vector` only (upstream lines 86-113).
    lines = t.split("\n")
    assert lines[85] == "/// Map a 2D vector to the nearest of 8 directions (4 cardinal + 4 diagonal).", lines[85]
    assert lines[87] == "pub(crate) fn direction_from_vector(v: Point<f64, Logical>) -> Direction {", lines[87]
    assert lines[112] == "}" and lines[113] == "" and len(lines) == 114, (lines[112:], len(lines))
    assert lines[6] == "use smithay::utils::{Logical, Point};", lines[6]
    assert lines[8] == "use driftwm::config::{Action, Direction, ThresholdAction};", lines[8]
    body = lines[85:113]
    body[2] = "pub fn direction_from_vector(v: Point<f64, Logical>) -> Direction {"
    head = [
        "use crate::platform::utils::{Logical, Point};",
        "",
        "use crate::config::Direction;",
        "",
    ]
    return "\n".join(head + body) + "\n"


port(
    "src/input/gestures.rs",
    "src/input/gestures.rs",
    [
        "This is an EXTRACT, not the whole file. Kept: `direction_from_vector`",
        "(upstream lines 86-113, body unmodified), which is the pure helper the",
        "touch recognizer calls. Changes from upstream:",
        "  - visibility widened from `pub(crate)` to `pub`: upstream also calls",
        "    it from `src/input/gestures/swipe.rs` and `src/grabs/navigate_grab.rs`",
        "    (binary crate), so the native backend crate needs to reach it;",
        "  - imports reduced to what the function uses, with the prefixes",
        "    `smithay::` -> `crate::platform::` and `driftwm::` -> `crate::`",
        "    (`use smithay::utils::{Logical, Point};`,",
        "    `use driftwm::config::{Action, Direction, ThresholdAction};`);",
        "  - left out (lines 1-85): the submodules `device_config`, `hold`,",
        "    `pinch`, `swipe`; `enum GestureState`; `DOUBLE_TAP_WINDOW_MS`; and",
        "    `impl DriftWm { gesture_camera_zoom, gesture_output_or_active,",
        "    gesture_output_fullscreen, cancel_animations }`, which are compositor",
        "    state or libinput pointer-gesture handling.",
    ],
    gestures,
)

if STALE:
    sys.exit(f"{len(STALE)} file(s) differ from what this script produces: {STALE}")
