#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
mkdir -p target/focus
flags='-arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror'
xcrun clang $flags -c native/focus/focus.m -o target/focus/focus.o
xcrun clang $flags native/focus/probe.m target/focus/focus.o -framework AppKit -o target/focus/probe
xcrun clang $flags native/focus/fixture.m target/focus/focus.o -framework AppKit -o target/focus/fixture
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra -Werror -c native/focus/geometry-check.c -o target/focus/geometry-check.o
xcrun clang target/focus/geometry-check.o target/focus/focus.o -framework AppKit -o target/focus/geometry-check
printf '%s\n' 'Built focus adapter, ordinary-window fixtures and gate; nothing launched.'
