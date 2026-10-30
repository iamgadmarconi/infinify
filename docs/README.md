# Documentation

The documentation of Infinify, apart from the repository's [README.md](../README.md) and [AGENTS.md](../AGENTS.md); the licence texts stay next to what needs them (`LICENSE`, `NOTICE`, `native/app/Resources`, `crates/core/SMITHAY-LICENSE.txt`).

Paths in the crate documents under `docs/crates/<crate>/` that name `tests/`, `include/` or `examples/` files are written from the repository root (`crates/<crate>/tests/...`); the `tests/e2e/` and `tests/native/` paths are the repository's own.

- [docs/parity/README.md](parity/README.md): the parity contract with DriftWM, and its inventory
- [docs/native/README.md](native/README.md): the native code (`native/app`, `native/dock-helper`): user guide, module docs, testing

## crates/canvas

- [docs/crates/canvas/SNAPPING.md](crates/canvas/SNAPPING.md): Canvas snapping contract
- [docs/crates/canvas/tests/upstream/README.md](crates/canvas/tests/upstream/README.md): Executable upstream oracle

## crates/core

- [docs/crates/core/PORT.md](crates/core/PORT.md): driftwm-core: provenance record
- [docs/crates/core/window-rules.md](crates/core/window-rules.md): Window Rules

## crates/desktop

- [docs/crates/desktop/CONFIG.md](crates/desktop/CONFIG.md): Configuration, ABI 1
- [docs/crates/desktop/EFFECTS.md](crates/desktop/EFFECTS.md): Effects contract, ABI 1
- [docs/crates/desktop/FOCUS.md](crates/desktop/FOCUS.md): Controller focus and cycle boundary
- [docs/crates/desktop/FULLSCREEN.md](crates/desktop/FULLSCREEN.md): Fullscreen
- [docs/crates/desktop/GESTURES.md](crates/desktop/GESTURES.md): Trackpad gestures
- [docs/crates/desktop/IPC.md](crates/desktop/IPC.md): Actions, bookmarks and IPC, ABI 1
- [docs/crates/desktop/LIFECYCLE.md](crates/desktop/LIFECYCLE.md): Window lifecycle, ABI 1
- [docs/crates/desktop/MOTION.md](crates/desktop/MOTION.md): Camera motion, ABI 1
- [docs/crates/desktop/NATIVE_RESIZE.md](crates/desktop/NATIVE_RESIZE.md): Native resize controller protocol (ABI 1)
- [docs/crates/desktop/NAVIGATION.md](crates/desktop/NAVIGATION.md): Normal-window navigation, ABI 1
- [docs/crates/desktop/POINTER.md](crates/desktop/POINTER.md): Pointer policy: hover, sloppy focus, pick mode and the pointer's center-nearest
- [docs/crates/desktop/README.md](crates/desktop/README.md): Desktop controller ABI v1
- [docs/crates/desktop/RENDER.md](crates/desktop/RENDER.md): Rendering contract, ABI 1
- [docs/crates/desktop/RULES.md](crates/desktop/RULES.md): Window rules, widgets and screen-pinned windows, ABI 1
- [docs/crates/desktop/SIZES.md](crates/desktop/SIZES.md): Window sizing actions
- [docs/crates/desktop/tests/resize_upstream/README.md](crates/desktop/tests/resize_upstream/README.md): Bounded native resize oracle provenance
- [docs/crates/desktop/tests/upstream/README.md](crates/desktop/tests/upstream/README.md): Navigation oracle provenance
