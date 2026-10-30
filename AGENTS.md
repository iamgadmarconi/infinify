# DriftWM macOS development rules

Target Apple Silicon, macOS 26 or later. The Rust canvas is platform-independent;
platform integration belongs in native/ adapters (native/app, native/dock-helper).

Preserve GPL-3.0-or-later attribution and exact upstream source provenance.
Keep camera/world geometry independent of native ownership and screen coordinates.
Do not label reducer tests, symbol presence, successful API return codes, or fixture
self-observations as proof of usable third-party native-window compositing.

Default host commands must be read-only. Native mutation experiments may touch only
the explicitly spawned disposable fixture. Preserve/restore the original transform
and clean up children on all exits. Do not change SIP, permissions, user settings,
or unrelated application windows as part of tests. Expanded runtime access needs an
explicitly authorized scope and evidence that the native path is safe.

Use focused end-to-end CLI scenarios and the test modules of changed files.
Do not run full suites unless the owner explicitly requests them. Prefer end-to-end
coverage over unit tests. Format touched Rust files and run targeted clippy/check.
Do not commit generated build products, local scene saves, or runtime credentials.

## Layout and naming

- Native code lives in `native/app/<Module>` (Desktop, Canvas, Windows, Input, CompositorMode, Navigation, System, Support,
  Resources) and `native/dock-helper/<Module>` (Payload, Loader, Daemon, Client). `main.m` is the entry point only.
- A file that defines a class is named exactly after its primary class (`DWWindowManager.h/.m`); a category is
  `Class+Category.m`; a class's internal interface is `Class+Private.h`. A C-function-only module is
  `DW<Descriptive>.h/.m`. Prefixes: `DW` for the shell, `IF` for the compositor and background modules.
- A translation unit that is cut into textual fragments (`#import`ed `.m` files that are never compiled alone, as in
  `native/dock-helper/Payload`) names each fragment for its area; a fragment may define several small classes.
- Tests mirror the layout: `tests/native/<same path as the module>/<Module>Tests.m` (`.c`, `.py`), fixture programs are
  `<What>Fixture.*`, end-to-end scripts are `tests/e2e/<name>.sh` (kebab-case, like every shell script).
- The header search path for native compiles is defined once, in `scripts/native-includes.sh`; a new module directory or
  source file is added there and to the build list in `scripts/build-app.sh`.
- All Markdown under `native/` and `crates/` lives under `docs/` (`docs/native/...`, `docs/crates/<crate>/...`).
  Licence texts and notices bundled in the app stay next to what needs them.
