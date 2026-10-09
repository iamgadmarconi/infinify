#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Print every textual difference between this crate and malbiruk/driftwm at
# 352333a8fa1b22171492d4b71a54102045c9a19d. Read-only: it writes nothing.
#
#   tools/diff-upstream.sh /path/to/driftwm-checkout
#
# 1. Checks that the checkout holds the originals this crate was ported from
#    (tools/upstream.sha256, the SHA-256 of every upstream file used).
# 2. For each ported Rust file, drops the provenance header and prints the
#    unified diff of the rest against the upstream file of the same path
#    (`---` upstream, `+++` this crate). The header is the leading run of `//`
#    comment lines, plus the one blank line that follows it where there is one;
#    no upstream file starts with a `// ` line or a blank line, so nothing of
#    upstream's is dropped. The output is the complete list of code changes.
# 3. Checks the files that are copied byte for byte (SHA256SUMS).
#
# Exit status: 0 when both hash checks pass (differences in step 2 are
# expected and listed in PORT.md), 1 otherwise.
set -eu
upstream=${1:?usage: tools/diff-upstream.sh /path/to/driftwm-checkout}
upstream=$(cd "$upstream" && pwd)
crate=$(cd "$(dirname "$0")/.." && pwd)
status=0

body() {
    awk '
        state == 0 && /^\/\/( |$)/ { next }
        state == 0 { state = 1; if ($0 == "") next }
        { print }
    ' "$1"
}

echo "=== upstream originals (tools/upstream.sha256)"
(cd "$upstream" && shasum -a 256 -c "$crate/tools/upstream.sha256") || status=1

identical=0
changed=0
for f in \
    src/canvas.rs \
    src/config/mod.rs src/config/types.rs src/config/parse.rs \
    src/config/parse_helpers.rs src/config/toml.rs src/config/defaults.rs \
    src/layout/mod.rs src/layout/snap.rs src/layout/cluster.rs \
    src/layout/auto_placement.rs src/layout/fill.rs \
    src/session.rs \
    src/stage/mod.rs src/stage/element.rs src/stage/mock.rs src/stage/tests.rs \
    src/window_ext.rs \
    src/grabs/touch_recognizer.rs src/grabs/touch_recognizer/tests.rs \
    src/input/gestures.rs \
    tests/canvas_navigation_test.rs tests/canvas_transforms_test.rs \
    tests/canvas_zoom_test.rs \
    tests/config_bindings_test.rs tests/config_docs_test.rs \
    tests/config_parse_test.rs tests/config_reference_test.rs \
    tests/config_robustness_test.rs tests/config_toml_test.rs \
    tests/window_rules_test.rs \
    tests/snap_test.rs
do
    echo "=== $f"
    if body "$crate/$f" | diff -u -L "upstream/$f" -L "driftwm-core/$f" "$upstream/$f" -; then
        echo "(identical below the header)"
        identical=$((identical + 1))
    else
        changed=$((changed + 1))
    fi
done
echo "=== $((identical + changed)) ported files: $identical identical below the header, $changed with the changes printed above"

echo "=== byte-identical copies (SHA256SUMS)"
(cd "$crate" && shasum -a 256 -c SHA256SUMS) || status=1
exit $status
