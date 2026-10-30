# Vendored: Sunlight afeea74

Verbatim, unmodified copy for reference and porting. Do not edit; Infinify's own code copies or translates from here and names the file it took.

| Field | Value |
|---|---|
| Upstream | https://github.com/spacefarm-digital/sunlight |
| Tag | none (no tag points at this commit) |
| Full commit hash | `afeea74b18e70ca49bf462d6fe462cf65deb2b32` |
| Commit | "Sunlight 0.1.3: setup stays out of the way of System Settings and prompts", 2026-10-30 00:39:16 +02:00 |
| Date vendored | 2026-10-29 |
| Licence | MIT, Copyright (c) 2026 spacefarm. Licence text: [`LICENSE`](LICENSE), copied byte for byte from the commit. |
| Copied from | A fresh `git clone https://github.com/spacefarm-digital/sunlight.git` into `target/upstream/sunlight` (untracked), checked out at `afeea74b18e70ca49bf462d6fe462cf65deb2b32`, clean working tree |

## Copy rules

1. Select tracked files only: `git ls-files` in the clone.
2. Included pathspecs: `Sources/`, `LiveWindows/`, `Tests/`, `docs/how-it-works.md`, `README.md`, `INSTALL.md`, `CHANGELOG.md`, `LICENSE`, `Package.swift`, `Package.resolved`, `Info.plist`, `Makefile`, `scripts/`, `Resources/LaunchDaemons/`.
3. Excluded: every other tracked path, including `packaging/`, `.github/`, the images and icons (`docs/images/`, `Resources/Sunlight.icns`, `Resources/Sunlight.icon/` with its SVG assets and `icon.json`), and the root files `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `.gitignore`.
4. Keep a selected file only if `file --mime-type` reports `text/*`, `application/json`, `application/toml` or `application/xml`, and its name does not end in `.icns`, `.png`, `.gif`, `.jpg`, `.jpeg` or `.svg`. Every selected file is text, so none were skipped.
5. Copy each kept file byte for byte (`cp -p`) to the same relative path. No edits, no reformatting, no line-ending changes.

Result: 166 files copied (1,996,698 bytes) from 166 selected tracked files. Per tree: `Sources/` 88, `Tests/` 48, `LiveWindows/` 10, `scripts/` 10, `Resources/LaunchDaemons/` 1, `docs/how-it-works.md` 1, root files 8.

## Skipped files

Selected but not text: none.

Tracked but outside the copy rules (24):

```
.github/ISSUE_TEMPLATE/bug_report.yml
.github/ISSUE_TEMPLATE/config.yml
.github/ISSUE_TEMPLATE/feature_request.yml
.github/pull_request_template.md
.github/workflows/ci.yml
.gitignore
CODE_OF_CONDUCT.md
CONTRIBUTING.md
Resources/Sunlight.icns
Resources/Sunlight.icon/Assets/disc.svg
Resources/Sunlight.icon/Assets/long-rays.svg
Resources/Sunlight.icon/Assets/short-rays.svg
Resources/Sunlight.icon/icon.json
SECURITY.md
docs/images/gestures.png
docs/images/hero.gif
docs/images/hero.png
docs/images/icon.png
packaging/dmg/README.md
packaging/dmg/background.png
packaging/dmg/background@2x.png
packaging/dmg/hill.jpg
packaging/homebrew/sunlight.rb
packaging/release.conf
```

## Notes

- Not built or tested by Infinify. Several copied files refer to paths that are not copied: `Makefile`, `scripts/package.sh` and `docs/how-it-works.md` use `packaging/`, `Resources/Sunlight.icns` and `Resources/Sunlight.icon`. Those scripts will not run from this copy as is.
- `LiveWindows/osax/LICENSE-yabai.txt` is copied. By its name it is the MIT licence for the yabai-derived code under `LiveWindows/osax/` (`The MIT License (MIT)`, Copyright (c) 2019 Åsmund Vikane).

## Checksums

`SHA256SUMS` covers every other file in this directory: the 166 copied files and this `VENDORED.md`. It is sorted by path and was made with `shasum -a 256` run from this directory. Verify with:

```sh
cd third_party/sunlight && shasum -a 256 -c SHA256SUMS --quiet
```
