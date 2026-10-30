# Vendored: DriftWM v0.21.0

Verbatim, unmodified copy for reference and porting. Do not edit; Infinify's own code copies or translates from here and names the file it took.

| Field | Value |
|---|---|
| Upstream | https://github.com/malbiruk/driftwm |
| Tag | `v0.21.0` (lightweight tag, pointing directly at the commit) |
| Full commit hash | `df3de27b26c7998e8a460cffd8a4925cbed3a322` |
| Commit | "Bump version to v0.21.0", 2026-10-27 21:44:56 +04:00 |
| Date vendored | 2026-10-29 |
| Licence | GPL-3.0-or-later (upstream `Cargo.toml`: `license = "GPL-3.0-or-later"`). Licence text: [`LICENSE`](LICENSE), copied byte for byte from the tag. |
| Copied from | A fresh `git clone https://github.com/malbiruk/driftwm.git` into `target/upstream/driftwm` (untracked), checked out at `v0.21.0`, clean working tree |

## Copy rules

1. Select tracked files only: `git ls-files` in the clone.
2. Included pathspecs: `src/`, `tests/`, `docs/`, `resources/`, `proptest-regressions/`, `Cargo.toml`, `Cargo.lock`, `config.reference.toml`, `README.md`, `LICENSE`, `Makefile`.
3. Excluded: every other tracked path, including `.github/`, `nix/`, `flake.nix`, `flake.lock`, `assets/`, `extras/`, `dev/`, and the root files `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `clippy.toml`, `.gitignore`, `.git-blame-ignore-revs`. `.git` is never copied.
4. Keep a selected file only if `file --mime-type` reports `text/*`, `application/json`, `application/toml` or `application/xml`. Any other file is skipped and listed below.
5. Copy each kept file byte for byte (`cp -p`) to the same relative path. No edits, no reformatting, no line-ending changes.

Result: 253 files copied (6,151,722 bytes) from 254 selected tracked files. Per tree: `src/` 220, `tests/` 11, `docs/` 7, `resources/` 6, `proptest-regressions/` 3, root files 6.

## Skipped files

Selected but not text (1):


Tracked but outside the copy rules (76):

```
.git-blame-ignore-revs
.github/workflows/aur-release.yml
.github/workflows/ci.yml
.github/workflows/codeberg-mirror.yml
.github/workflows/docs.yml
.github/workflows/release-vendor.yml
.gitignore
AGENTS.md
CLAUDE.md
CONTRIBUTING.md
assets/logo.jpg
assets/tshirt.png
clippy.toml
dev/docs/caveats.md
dev/docs/cross-distro-builds.md
dev/docs/profiling.md
dev/docs/reference-config-format.md
dev/docs/smithay-api.md
dev/docs/testing.md
dev/docs/todo.md
dev/scripts/build-docs-site
dev/scripts/ci-local
dev/scripts/fake-pen
dev/scripts/tracy_analyze.py
dev/site/book.toml
dev/site/custom.css
dev/site/src/SUMMARY.md
extras/README.md
extras/config.toml
extras/fuzzel/fuzzel.ini
extras/install.sh
extras/quickshell/Battery.qml
extras/quickshell/Bluetooth.qml
extras/quickshell/Brightness.qml
extras/quickshell/Clock.qml
extras/quickshell/Cpu.qml
extras/quickshell/Dashboard.qml
extras/quickshell/FlatButton.qml
extras/quickshell/KbdLayout.qml
extras/quickshell/ListRow.qml
extras/quickshell/MonthView.qml
extras/quickshell/Mpris.qml
extras/quickshell/Network.qml
extras/quickshell/Popover.qml
extras/quickshell/Popups.qml
extras/quickshell/PowerMenu.qml
extras/quickshell/Ram.qml
extras/quickshell/Theme.qml
extras/quickshell/ThinSlider.qml
extras/quickshell/Tile.qml
extras/quickshell/Tray.qml
extras/quickshell/Volume.qml
extras/quickshell/qmldir
extras/quickshell/shell.qml
extras/scripts/battery_notify.sh
extras/scripts/driftwm-decal
extras/scripts/spotlight.sh
extras/swaync/style.css
extras/wallpapers/animated/acid_lava.glsl
extras/wallpapers/animated/dense_clouds.glsl
extras/wallpapers/animated/fast_smoke.glsl
extras/wallpapers/dot_grid.glsl
extras/wallpapers/static/blue_drift.glsl
extras/wallpapers/static/compass_grid.glsl
extras/wallpapers/static/dark_sea.glsl
extras/wallpapers/static/pink_cloud.glsl
extras/wallpapers/textured/mirrored_parallax.glsl
extras/wallpapers/textured/ripple.glsl
extras/waybar/touchbar.css
extras/waybar/touchbar.jsonc
extras/waybar/wvkbd-toggle.sh
flake.lock
flake.nix
nix/home-module.nix
nix/nixos-module.nix
nix/test.nix
```

## Notes

- Not built or tested by Infinify. This is a Cargo package with a Smithay git dependency. It is not a member of the root workspace, and the root `Cargo.toml` lists `third_party` in `exclude`, so a `cargo` run inside this directory treats it as a standalone package rather than failing against the root workspace.
- `resources/fallback_cursor.rgba` (2304 bytes, raw RGBA cursor frame embedded by `src/state/cursor.rs` with `include_bytes!`) is included byte for byte although it is binary, so the copy is complete; it was added after the first pass on 2026-10-29 and SHA256SUMS covers it.
- The other `include_str!` targets resolve inside the copy: `src/shaders/*.glsl`, `config.reference.toml`, `docs/window-rules.md`.

## Checksums

`SHA256SUMS` covers every other file in this directory: the 253 copied files and this `VENDORED.md`. It is sorted by path and was made with `shasum -a 256` run from this directory. Verify with:

```sh
cd third_party/driftwm && shasum -a 256 -c SHA256SUMS --quiet
```
