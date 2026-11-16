# Native modules

`scripts/native-modules.json` is the production source, header and dependency
description. `build-app.sh` and `build-privileged.sh` consume it through
`native-modules.py`; `check.sh` and `build-release.sh` delegate to the app build.
Resources are packaged data, not a compiled module. `main.m`, the doctor, loader
and daemon main functions are explicit entry objects, not force-loaded libraries.
Payload fragments remain textual imports of the single `DWPayload.m` unit.

## Visibility

Public headers stay at the module root. Internal headers are in `Private/`.
A compile sees its own private directory and the public roots of its dependency
closure, needed for declarations imported by exported headers. Before compiling,
the driver checks each native import against the **direct** declared edge and
the target's public-header list. Thus transitive search paths do not silently
authorize a new direct dependency. Relative/path-qualified native imports are
rejected, including attempts to bypass private visibility. Public headers cannot
include private headers. Source and public header inventories are checked against
the description; adding a file requires changing that description.

The graph deliberately contains cycles. These are existing dependencies, not
permission to add more. [Migration notes](ARCHIVE-MIGRATION.md) record the edges
and existing internal vocabulary exposed by them. Archives do not require a
topological compile order; graph traversal deduplicates cycles.

Only Controller, System and the app entry point receive `-Icrates/desktop/src`.
The entry point now directly imports the Rust interface it calls. The opaque
`DriftDesktop` declaration in `DWSceneWriter.h` no longer re-exports Rust's C
header through `Desktop.h`; its implementation imports that header privately.

`scripts/native-includes.sh` derives its historical flat `native_includes` and
`helper_includes` variables from the description, including private directories.
These are for direct legacy compiles, not production module isolation.

## Rebuilds

Objects and dependency records live under `target/native-modules/PRODUCT/ARCH`.
Each command uses the previous compiler dependency file to fingerprint the source
and every included project header (mtime, size and SHA-256), plus compiler identity,
SDK path and the exact compile command. Touching an input rebuilds its importers;
a source-list change rebuilds its archive without retaining removed members.
`libtool -static` writes each archive afresh, then replaces it atomically.
A dirty module's archive is removed before compiling; a failed compile cannot
leave an archive considered current. The next build retries missing objects.
A cache lock serializes driver invocations; `INFINIFY_NATIVE_JOBS` bounds compile
parallelism within one invocation (default 2). Separate profiles preserve ARC,
architecture, C dialect and daemon digest defines.

`INFINIFY_NATIVE_CLEAN=1 ./scripts/build-app.sh` discards the native object cache
before any production compile. The release script always selects this mode.
No package, signing or promotion paths are cached.

Every native production archive is linked with `-force_load`; entry objects are
linked explicitly and Rust's static library is linked normally. This keeps
classes used only by runtime lookup and every Objective-C category. Frameworks,
compiler diagnostics, optimization and deployment targets are unchanged.

## Linking a module in a later test phase

Run from the repository root, on the authorized build machine. These commands
are examples, not verification performed during the architecture change.
`native_module_build` compiles the exact production product variant, without
entry-point objects, for the named module and its dependency closure. It does
not compile the Rust archive; build that separately when referenced.

Keep **all objects of the module under test**, but resolve dependencies normally.
This permits a stand-in to satisfy a collaborator without forcing that
collaborator's object into the executable:

```sh
. scripts/native-modules.sh
native_module_build app app-Navigation >/dev/null
cflags=$(native_module_cflags app app-Navigation)
ldflags=$(native_module_ldflags app app-Navigation --dependencies normal)
eval "xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $cflags MyNavigationScenario.m $ldflags target/release/libdriftwm_desktop.a -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon -framework Metal -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate -framework Security -framework SystemConfiguration -framework ServiceManagement -framework UserNotifications -o /tmp/navigation-scenario"
```

Keep every object of both the module and dependencies (the production link
policy), for integration scenarios that supply no competing implementations:

```sh
. scripts/native-modules.sh
native_module_build app app-Navigation >/dev/null
cflags=$(native_module_cflags app app-Navigation)
ldflags=$(native_module_ldflags app app-Navigation --dependencies force)
eval "xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $cflags MyNavigationIntegration.m $ldflags target/release/libdriftwm_desktop.a -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon -framework Metal -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate -framework Security -framework SystemConfiguration -framework ServiceManagement -framework UserNotifications -o /tmp/navigation-integration"
```

A cycle can bring Desktop objects into a fully force-loaded integration link;
the scenario must provide its process's `DWStopSignal`, as `main.m` does.
Ordinary dependency linking can also require real external libraries when the
tested implementation references them. It is not a promise that arbitrary fake
receiver layouts can link unchanged. Public compile flags never expose Private.
