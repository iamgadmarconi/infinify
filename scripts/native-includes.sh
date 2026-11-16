# SPDX-License-Identifier: GPL-3.0-or-later
# Legacy flat search paths for direct native compiles (including test scripts).
# Production compiles use the restricted module graph in native-modules.json.
helper_includes=$(python3 scripts/native-modules.py legacy-includes helper)
native_includes=$(python3 scripts/native-modules.py legacy-includes app)
