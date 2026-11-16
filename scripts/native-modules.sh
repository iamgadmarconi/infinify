#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Source from the repository root. Output flags are shell-quoted; use eval to
# expand them as argv, as in docs/native/NATIVE-MODULES.md.
native_module_build() { python3 scripts/native-modules.py module "$@"; }
native_module_cflags() { python3 scripts/native-modules.py cflags "$@"; }
native_module_ldflags() { python3 scripts/native-modules.py ldflags "$@"; }
