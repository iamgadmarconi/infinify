# Loader and launcher

The explicit production launcher: the loader, the doctor, the manifest and `scripts/native-desktop-launcher.sh` (code in `native/dock-helper/Loader`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Explicit production launcher

The installed owner entrypoint is
`~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop`, run from a
terminal. Its `native-desktop --check` form validates the bundled manifest,
artifact hashes and deep app signature, then runs the doctor without sudo,
runtime creation, loading or app launch. The bundled launcher uses only macOS
system tools and files inside its own app, so it does not need Python, Homebrew,
or the checkout. It never changes SIP, permissions or settings, restarts Dock,
or retries an uncertain injection automatically.

The repository wrapper `./scripts/start-native-desktop.sh` is checkout-aware.
It verifies the selected bundle against current source and the standard app's
`target/app/BUILD.json` schema 1 record before calling its bundled launcher.
That record binds the post-sign app executable, native manifest, payload and
complete tracked/nonignored source snapshot. Pass `--app /absolute/path/Infinify.app`
to check an installed bundle; `--build` explicitly rebuilds production artifacts
and the app first. A stale bundle requires a rebuild. This checks delivery
freshness, not native usability.

The bundled launcher obtains Dock's exact PID, process birth, UID and stable
boot-session UUID from the loader's read-only `--dock-identity` query. It pins
the current Dock during the explicit loader step and binds the `pending`/`ready`
launch record (schema 3) to the Dock PID, process birth, boot-session UUID and
bundled payload SHA-256. Reuse also hashes the payload the recorded Dock opened and
requires it to match both the bundle and record: the runtime's own private copy when the sudo
loader loaded it, or, when the launch daemon did, the daemon's root-owned staged copy
(`Infinify native-desktop daemon staged RUNTIME`, which applies the loader's own path rule
read-only; see [below](../Daemon/README.md#what-the-daemon-is-and-does)). A ready record for the
exact same Dock instance and boot session can be reused after those payload
checks pass.

The boot identity is the canonical uppercase `kern.bootsessionuuid`. XNU's
[`kern_sysctl.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c)
exposes that UUID read-only, while
[`clock.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/clock.c)
shows that `clock_boottime` can change with calendar adjustment. No XNU implementation code is copied into Infinify.

For a retired Dock, the launcher accepts only a committed schema-3 journal
written by the recorded Dock process, same login UID and same
`kern.bootsessionuuid`. The loader rechecks the journal's private file and
directory, exact writer identity, positive old-process retirement and schema-3
header, then copies its bytes to
the new private runtime as `recovery-source.json`. The sidecar binds the copy by
SHA-256 and recorded writer identity; the payload validates its complete schema
and identities before any restore setter. On first import, the fresh runtime has
no committed journal yet, so this exact source supplies the initial recovery
state. The payload commits that state under the new writer before any restore
setter. On later starts, the new runtime's committed `v2-journal.json` is the
replay authority; a malformed committed journal never falls back to the older
source. When that runtime is retired, its own current journal is the only handoff
input. Any retained `recovery-source.json` is hash-checked historical provenance,
never merged or used as a fallback.

When a ready schema-3 record belongs to a different boot session, the launcher
archives its exact bytes and starts fresh without replaying the old journal;
any remaining runtime and journal are left untouched. A missing runtime in the
same boot session remains an error. Pending/unknown outcomes remain refused,
including across a reboot. A launch record of any other version, or without the boot UUID,
is refused with an inspection error and preserved; it is never inferred or upgraded.

The launcher keeps the previous ready record until the recovery loader reports
authenticated readiness. A private `launch.pending.plist` marker blocks any
retry after an interrupted or uncertain recovery. On success, the old record is
archived byte-for-byte and the new ready record is promoted. The old runtime and
journal remain untouched. Journals of any schema but 3 are refused: schema 3 is the one
that retains the originals needed for safe connection handoff, and the
launcher never reconstructs transforms from native bounds. A same-boot journal
with a mismatched boot-session UUID, unresolved recovery, a live or uncertain
prior Dock, or invalid payloads blocks startup and preserves all state. There is
no fallback or automatic injection retry. The launcher runs only
the loader as root (through sudo in the owner's terminal, or through the launch
daemon the owner approved once, below) and starts the app as the login user. The login
item starts compositor mode only after `native-desktop enable`; until then it is the
capture-mode startup and does not invoke this helper path.

Direct loader invocation also requires explicit prepared-machine authorization:

```text
loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --desktop
  [--expected-dock PID BIRTH_SEC BIRTH_USEC]

loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --desktop --expected-dock PID BIRTH_SEC BIRTH_USEC
  --recover-journal ABS_OLD_RUNTIME/v2-journal.json
  --expected-retired-dock OLD_PID OLD_BIRTH_SEC OLD_BIRTH_USEC
```

`--desktop` is required: it selects same-login-user scope, the only scope the loader offers.
The payload is one of two classes, told apart by its path so that neither can stand in for the
other: any ordinary path must be the login user's own regular file that no one else can write (the
sudo path above), while a path of the exact form
`/private/var/run/infinify-payload.XXXXXX/payload-arm64e.dylib` is a copy the launch daemon staged, accepted
only by a root loader and only if the whole path is root's: every directory above is root's, not
writable by others and writable by a group only if the login user is not in it
(`/private/var/run` is `root:daemon 0775`), the staged directory is root's and writable by no
one else, and the payload is root's regular file, not group/other-writable, with one link; no
component may be a link (`native/dock-helper/Loader/DWStagedPayload.h`, shared with the daemon).
The runtime directory, the nonce file and the journals stay the login user's, private (0700, 0600).
The nonce is a cryptographically random 32-byte value encoded as 64 lowercase
hexadecimal characters, in a login-user-owned regular file with mode 0600; one
trailing newline is accepted. Nonce bytes are never accepted in the loader's
argv. A private, adjacent `ABS_PAYLOAD.json` sidecar opts in the constructor with
the runtime, the nonce and, for a recovery, the recovery source digest and writer identity
(the payload also accepts an exact-process `allowlist` key, which the loader never writes).
No sidecar means no listener.
The recovery form accepts only a committed same-boot schema-3 journal from the
positively retired Dock recorded by the launcher. It copies those exact bytes to
the fresh runtime and binds their digest and writer identity in the sidecar. The
payload validates the complete journal, then commits the new writer's journal
before any restore setter. Later recovery uses that committed journal; if it is
malformed, the retained import source is not a fallback. The launcher adds a
private pending marker before sudo and promotes its ready record only after
authenticated readiness; an interrupted or uncertain handoff blocks retry.
Journals of any other schema are refused.
After loading, readiness authenticates v2, verifies scope/process identity,
required restoration/scope/inspection capabilities, `held=restoring=table_count=0`
and `journal_pending=0`, then disconnects without submitting a frame. A missing
or failed v2 listener is startup failure, with no alternate server.
