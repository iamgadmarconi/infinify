#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
mkdir -p target/resize
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -c native/resize/resize.m -o target/resize/resize.o
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror native/resize/probe.m target/resize/resize.o -framework AppKit -o target/resize/probe
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror native/resize/fixture.m -framework AppKit -o target/resize/fixture
printf '%s\n' 'Built focused native resize adapter and owned fixture; nothing launched.'
