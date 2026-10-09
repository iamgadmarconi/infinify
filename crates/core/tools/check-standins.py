#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the geometry and touch-slot stand-ins in src/platform.rs with the
Smithay source they were taken from.

Not part of the build. Read-only: both inputs are read as text, nothing is
compiled or written.

    tools/check-standins.py /path/to/smithay-0.7.0

(the unpacked crates.io release, for example
~/.cargo/registry/src/index.crates.io-*/smithay-0.7.0).

For every item of `platform::utils` and for `platform::backend::input::TouchSlot`
with its two conversions, the item's text is looked up in Smithay's
`src/utils/geometry.rs` or `src/backend/input/mod.rs`. Comments and whitespace
are ignored (the stand-ins sit one or two modules deep, so rustfmt wraps some
lines differently, and their doc comments say what was left out). Each item is
reported as

    SAME   the item occurs character for character in the Smithay file
    DIFF   it does not

Four DIFFs are expected and listed in PORT.md: the `Coordinate` trait and its
two impls (reduced to the methods used, for `i32` and `f64` only) and
`Rectangle::new` (the same function, but alone in its impl block). `Transform`
is checked as well; its derive list is written as one attribute here and two
there, so it also reports DIFF. Any other DIFF means the stand-in has drifted.
Exit status is 0 when exactly those are reported, 1 otherwise.
"""
import re
import sys
from pathlib import Path

EXPECTED_DIFF = {
    "pub trait Coordinate:",
    "impl Coordinate for i32 {",
    "impl Coordinate for f64 {",
    "impl<N: Coordinate, Kind> Rectangle<N, Kind> { new",
    "pub enum Transform {",
}


def norm(text):
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)  # comment and doc lines
    text = re.sub(r"\s+", "", text)
    return text.replace(",}", "}").replace(",)", ")")  # commas added by wrapping


def module_body(text, name, indent):
    """Lines inside `pub mod <name> { ... }` declared at `indent`."""
    lines = text.split("\n")
    start = lines.index(f"{indent}pub mod {name} {{")
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == indent + "}")
    return lines[start + 1 : end]


def items(lines, indent):
    """Items declared at exactly `indent`: their attributes, then everything up
    to the closing brace (or the end of a one-line item)."""
    out, cur = [], None
    for line in lines:
        at_indent = line.startswith(indent) and not line.startswith(indent + " ")
        rest = line[len(indent) :] if at_indent else ""
        if cur is None:
            if not at_indent or rest.startswith(("//", "use ", "mod ", "pub mod ")):
                continue
            cur = [line]
        else:
            cur.append(line)
        if at_indent and not rest.startswith("#["):
            if rest == "}" or rest.endswith(("{}", ";")):
                out.append(cur)
                cur = None
    return out


def label(item, indent):
    """The item's first non-attribute line; inherent impls also name their fns."""
    head = next(l for l in item if not l[len(indent) :].startswith("#["))
    head = head[len(indent) :]
    if head.startswith("impl<") and " for " not in head:
        head += " " + ", ".join(re.findall(r"pub (?:const )?fn (\w+)", "\n".join(item)))
    return head


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    smithay = Path(sys.argv[1])
    crate = Path(__file__).resolve().parent.parent
    ours = (crate / "src/platform.rs").read_text(encoding="utf-8")
    geometry = norm((smithay / "src/utils/geometry.rs").read_text(encoding="utf-8"))
    input_mod = norm((smithay / "src/backend/input/mod.rs").read_text(encoding="utf-8"))

    diffs = set()
    count = 0

    def report(item, indent, haystack, where):
        nonlocal count
        name = label(item, indent)
        same = norm("\n".join(item)) in haystack
        count += 1
        if not same:
            diffs.add(name)
        print(f"{'SAME' if same else 'DIFF'}  {where}  {name}")

    for item in items(module_body(ours, "utils", ""), "    "):
        report(item, "    ", geometry, "utils/geometry.rs    ")

    backend_input = module_body("\n".join(module_body(ours, "backend", "")), "input", "    ")
    for item in items(backend_input, "        "):
        if "TouchSlot" in "\n".join(item):
            report(item, "        ", input_mod, "backend/input/mod.rs ")

    unexpected = sorted(diffs - EXPECTED_DIFF)
    missing = sorted(EXPECTED_DIFF - diffs)
    print(f"{count} items: {count - len(diffs)} SAME, {len(diffs)} DIFF")
    if unexpected or missing:
        sys.exit(f"unexpected DIFF: {unexpected}; expected DIFF not seen: {missing}")
    print("the DIFFs are the five expected ones")


main()
