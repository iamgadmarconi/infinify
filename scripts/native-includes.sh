# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by scripts/build-app.sh and tests/e2e/*.sh from the repository root: the header search path of the
# native/ tree. Sources import each other by bare name, so each module directory is a search path.
# One list for every compile; a new module directory is added here and nowhere else.
helper_includes='-Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
native_includes="-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support $helper_includes"
