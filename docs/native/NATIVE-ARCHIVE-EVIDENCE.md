# Native archive compile-only evidence

Baseline `14aa30b` and the archive code were compiled in the UTM `macOS` guest,
never on the editing host. Nothing was launched. No test or fixture was built,
run, written or changed. This establishes build structure and symbol retention,
not usable native-window behaviour.

## Commands and products

Guest setup and the existing actool resource-copy shim are described in
`~/infinify-work/BUILD-NOTES.md`. Source was synced to
`~/infinify-work/arch-archives` with:

```sh
rsync -a --delete --exclude .git --exclude target ./ admin@192.168.64.2:infinify-work/arch-archives/
```

Guest commands, all exit 0 except the deliberate negative compilation checks
listed below:

```sh
cargo fmt --check
python3 scripts/native-modules.py validate
CARGO_BUILD_JOBS=2 INFINIFY_NATIVE_JOBS=2 ./scripts/build-app.sh
INFINIFY_NATIVE_CLEAN=1 CARGO_BUILD_JOBS=2 INFINIFY_NATIVE_JOBS=2 ./scripts/build-app.sh
```

The baseline full build passed; the first intermediate header split found one
missing transitive declaration (`main.m`'s `driftwm_desktop_msg` call). Adding
the owning Rust header to `main.m` fixed it. The next privileged-archive/full-app
build passed. The app-archive build passed in 30 seconds. No Rust was changed,
so clippy was not run. Source/SDK/compiler flags are retained; dependency-file
generation and separate `-c` outputs are new build bookkeeping.

Let `F(ARCH)` mean `-O2 -arch ARCH -mmacosx-version-min=26.0 -Wall -Wextra -Werror`.
Ordering of independent flags is immaterial; the following before/after values
are equal:

| Product/input | Before | After |
| --- | --- | --- |
| App Objective-C, including Lifecycle and daemon request | `F(arm64) -fobjc-arc` | same |
| Client library, including the app's client | `F(arm64) -std=gnu11`, no ARC | same |
| Loader client | `F(arm64e) -std=gnu11`, no ARC | same |
| Doctor | `F(arm64)`, no ARC | same |
| Payload | `F(ARCH) -fobjc-arc`; `ARCH=arm64e` production, `arm64` fixture-host variant | same |
| Loader and its Lifecycle objects | `F(arm64e)`, no ARC | same |
| Daemon and its request/Lifecycle objects | `F(arm64) -fobjc-arc -DINFINIFY_LOADER_SHA256="DIGEST" -DINFINIFY_PAYLOAD_SHA256="DIGEST"` | same |

Payload link flags remain `-dynamiclib
-Wl,-install_name,@rpath/payload-ARCH.dylib`. Each product's frameworks retain
their original order in the manifest; the Rust archive is still linked normally.
Native archives add only `-Wl,-force_load,ARCHIVE` to keep all objects. Loader,
doctor, daemon and app entry objects are explicit. Support is header-only;
Loader uses entry object sets because its doctor and loader each define `main`.
All other source-bearing module libraries use `xcrun libtool -static`.
ARC/non-ARC copies of Lifecycle are separate product variants, not shared objects.

## Binary equivalence

Guest collection script: `/tmp/arch-archives-equivalence.py`. It invokes, for the
app and each helper:

```sh
xcrun nm -U -j BINARY
xcrun nm -gU -j BINARY
xcrun otool -ov BINARY
xcrun otool -l BINARY
```

It sorts symbol names (addresses are intentionally excluded), extracts class
names and category owners from Objective-C method symbols, compares method
symbols and classlist/catlist section sizes, and preserves verbose metadata for
inspection. Modern ld merges categories into primary class lists: no separate
`__objc_catlist` remains in either build. Category method symbols retain owners.
Bundle relative file lists and decoded `Contents/Info.plist` were compared too.

| Product | Defined symbol count | External defined | Classes | Categories | Method symbols | Classlist bytes |
| --- | --- | --- | --- | --- | --- | --- |
| Infinify | 24,688 | 4,640 | 192 | 39 | 4,168 | 1,536 |
| doctor | 7 | 2 | 0 | 0 | 0 | 0 |
| loader-arm64e | 136 | 26 | 2 | 0 | 8 | 16 |
| payload-arm64e.dylib | 301 | 48 | 2 | 0 | 2 | 16 |
| loadd | 214 | 34 | 3 | 0 | 18 | 24 |

These counts match baseline. More importantly, every sorted external-symbol,
class, category and method-symbol list is **identical**, as are classlist and
catlist sizes, the 16-file bundle relative path list, and decoded `Info.plist`.
Every helper's full `nm -U -j` list is identical.

The app's full `nm -U -j` multiset has exactly two local-label multiplicity
differences: `_OUTLINED_FUNCTION_0` occurs 16 → 15 times and
`_OUTLINED_FUNCTION_1` occurs 7 → 8 times. Distinct symbol names and total count
are unchanged. These are compilation-unit-local machine-outliner labels, not stable identities
across object regrouping; link order changes their local-label selection.
No externally visible function, class, category or Objective-C method differs.
Use `nm -gU` for compilation-unit-independent function equivalence.

Source audit found 2,101 explicit method definitions with no receiver/kind/selector
duplicates, no `+load`, and one constructor in Payload's unchanged textual unit.
An additional binary-symbol check includes synthesized methods: match full names
with `([+-])\[([^( ]+)(?:\(([^)]+)\))? (.+)\]`, then group by kind, receiver
and selector. Compiler `.cold.N` fragments are not additional method definitions.
The app has 4,127 full method-body symbols and no duplicate keys; helpers also
have no duplicate keys. Thus no category override depends on archive member order.

Byte-for-byte binary/signature or helper manifest identity is not claimed:
Mach-O layout changes with object ordering; signing and build/source provenance
also change. `Info.plist` and the bundle layout do not change. Full audit and
deferred test-interface inventory: [ARCHIVE-MIGRATION.md](ARCHIVE-MIGRATION.md).

## Incremental and failure checks

Guest command: `python3 /tmp/arch-archives-incremental.py` (exit 0).
This performs only source timestamps, temporary production import changes and
compilation/archive inspection; it creates no test sources and runs no binary.
All production source bytes and original input timestamps are restored afterward.
For each step it invokes
`python3 scripts/native-modules.py module app app-Canvas` with jobs=2.

| Change | Exit | Seconds | Compiled objects | Archives rebuilt |
| --- | --- | --- | --- | --- |
| None | 0 | 0.240 | 0 | 0 |
| Touch `Canvas/DWCanvasAttachment.m` | 0 | 0.441 | 1 Canvas | 1 |
| Touch public `Canvas/DWCanvasAttachment.h` | 0 | 7.144 | 7 Canvas, 4 CompositorMode, 24 Desktop | 3 |
| Touch private `Canvas/Private/IFBGTiffSource.h` | 0 | 2.016 | 8 Canvas, none elsewhere | 1 |
| Remove `Canvas/DWBackgroundFiles.m` and its description entry | 0 | 0.250 | 0 | 1 |
| Restore that source and description | 0 | 0.235 | 0 | 1 |
| Missing system header in the real Canvas TU | 1, expected | 0.393 | 1 attempted | 0 |
| Restore and recover from failed compile | 0 | 0.416 | 1 | 1 |

`xcrun ar -t target/native-modules/app/arm64/app-Canvas/module.a` after removal
confirms `DWBackgroundFiles.m.o` is absent. The removed source is not retained by
an in-place archive update. Restoring its description rebuilds the archive.

A compile using the production Canvas argv, after temporarily importing
`Desktop+Private.h`, exits 1 with `'Desktop+Private.h' file not found`.
Temporarily importing public `DWHotKeys.h` (Input is transitively visible but
not a direct Canvas dependency) makes `validate` exit 1 with:

```text
native-modules: native/app/Canvas/DWCanvasAttachment.m:1: DWHotKeys.h is private or its module app-Input is undeclared
```

The missing-header compilation failure removes Canvas's archive before attempting
the compile. After failure, `module.a` does not exist. Recovery rebuilds one object
and one archive. Subsequent consumers cannot obtain current link flags from the
driver until validation and compilation succeed.

Logs/metadata remain in the guest:
`~/infinify-work/arch-archives-{baseline,evidence}` and
`~/infinify-work/arch-archives-{baseline,stage1,stage1b,stage2}.log`.
The incremental scripts and symbol collectors are inspection artifacts outside
the repository, not committed tests. No live verification was performed.

## Production script changes

- `build-app.sh` adds a clean-cache switch before privileged compilation and
  replaces its flat source/compiler/framework command with the manifest driver.
  Existing staging, cleanup, packaging, signing and final message are untouched.
- `build-privileged.sh` replaces the doctor, payload, client, loader and daemon
  native compile lists with product descriptions. Hash computation, daemon digest
  inputs, install names, signing and the non-production fixture commands remain.
- `build-release.sh` changes only its app-build invocation (old line 39, new line
  40) to prefix `INFINIFY_NATIVE_CLEAN=1`, plus one explanatory comment. Thus it
  starts from an empty native object directory; version, build number, repository,
  signing, notarization and packaging steps remain unchanged.
- `check.sh` and `publish-release.sh` need no change: neither contains a native
  source list; check delegates to build-app, publish publishes existing artifacts.
- `native-includes.sh` now derives flat legacy header paths from the manifest,
  including `Private/`, while production compiles use owner-restricted paths.

The Developer ID/notarized release script was not run: the guest has no signing
identity or Xcode. Its empty-cache app-build path was compiled ad hoc instead;
the existing actool shim supplies assets from the guest's installed app.
