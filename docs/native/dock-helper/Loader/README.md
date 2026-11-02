# Loader and launcher

The explicit production launcher: the loader, the doctor, the manifest and `scripts/native-desktop-launcher.sh` (code in `native/dock-helper/Loader`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Explicit production launcher

The installed owner entrypoint is
`~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop`, run from a
terminal. Its `native-desktop --check` form validates the bundled manifest,
artifact hashes and deep app signature, then runs the doctor without sudo,
runtime creation, loading or app launch. The bundled launcher uses only macOS
system tools and files inside its own app, so it does not need Python, Homebrew,
or the checkout. It never changes SIP, permissions or settings, or retries an
uncertain injection automatically. It restarts the Dock in one case only, an update
whose helper code differs from the code in the recorded, still running Dock (below).

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

### Updates while the recorded Dock lives

An update (`brew upgrade --cask infinify`, a new disk image) replaces the bundle while the Dock keeps the
earlier build's helper. Every release signs the payload again with the Developer ID and a secure timestamp, so its
bytes and SHA-256 change even when its code does not: the 0.2.4 and 0.2.5 `payload-arm64e.dylib` differ in SHA-256
(`8106770c...` and `fb099c50...`) and are byte-identical after `codesign --remove-signature`, and both carry the same
CodeDirectory hash (`cb8f332a2a2e47a7d9d9b8f922f6e2da81107ba4`), identifier `payload-arm64e`, team `PBKWRHQV74` and
authority chain (Developer ID Application, Developer ID Certification Authority, Apple Root CA). Up to 0.2.5 the
launcher compared the SHA-256 alone and refused every update made while the Dock lived ("the recorded helper payload
differs from this bundle"). Now, in the same Dock:

- **Same bytes.** Reused, as before.
- **Same code, signed again.** The loader's read-only `--payload-identity PATH` (Security framework, strict signature
  validation) reports `identifier=`, `team=`, one `authority=` per certificate and `cdhash=` for the copy the Dock opened
  and for this bundle's payload. Equal identifier, team and authority chain and an equal CodeDirectory hash (which covers
  every code page, the identifier, the flags and the Info and requirements slots) mean the same code: the helper is reused.
  The record is not rewritten: its `payload_sha256` keeps naming the bytes the Dock opened (which every reuse checks again),
  so a later start decides the same way, and the next load (a Dock restart, a reboot) writes this bundle's digest.
  The launch record stays version 3 with the same keys; a record written by 0.2.5 is read unchanged.
- **Another signer.** Another team, identifier or authority chain is refused, whatever the code: the Dock is not restarted
  by itself, and the refusal says to restart the Dock (`killall Dock`) or log out and in, then start again.
- **Other code.** The helper is a real change. Where a load needs no password (the launch daemon is enabled and answers;
  a login start or a start by hand, never `--reload`), and after every check the retired-Dock path makes of the recorded
  runtime has passed (ready outcome, nothing pending, no pause for this payload, a journal that recovery would accept),
  the launcher restarts the Dock once, as Sunlight 0.2 does after an update: the loader's `--restart-dock PID SEC USEC`
  sends SIGTERM to the login user's Dock only if its PID and process birth are exactly the record's, read just before the
  signal, and never as root. The launcher prints one line saying so (the terminal, or `login.log`), waits for launchd's next
  Dock to read the same twice three seconds apart, and goes on through the retired-Dock path: journal handoff, recovery load
  through the daemon, a new ready record. It restarts at most once per run. Without the daemon the start is refused with
  what to do (`Infinify native-desktop enable`, or `killall Dock` and a start in Terminal). No Infinify runs at that point
  (the launcher refuses to start beside one), so no app's Dock reloader (`DWDockReloader`) sees this restart, and the
  crash guard counts only the load that follows it.

What the guest showed (macOS 27.0.1 26A434, SIP off, 2026-11-02; the screen stayed locked, so the app opened no canvas and placed
no window, and the launch daemon could not be approved without the GUI: the loads used the documented sudo path, passwordless in the
guest, at a pseudo-terminal). The 0.2.4 release loaded into Dock 365; the 0.2.5 release then refused in that Dock with "the recorded helper
payload differs from this bundle"; a Developer ID build of this change (payload SHA-256 `2e6de4db...`, CodeDirectory hash `cb8f332a...`)
reused the 0.2.4 helper with the launch record unchanged byte for byte. A build with a one-instruction change in the payload (CodeDirectory
hash `32851b7b...`) refused without the daemon, with the Dock untouched. Builds whose only other change let a sudo start at a terminal through
that gate (test-only, not shipped) restarted the Dock exactly once each (365 to 72590, then 72590 to 73552, sampled every 0.5 and 1 s):
once with a retired runtime holding no journal (fresh start), once while the C client fixture held two windows of a disposable fixture
at half size: the retired journal (schema 4, `holding`, two windows) became the new runtime's `recovery-source.json` byte for byte, the
new helper's `last_restore` reported both windows `restored` (`connection handoff`), and both were drawn at their own frames again.
Not shown live: the daemon-gated restart itself, and the app placing windows after it.

The boot identity is the canonical uppercase `kern.bootsessionuuid`. XNU's
[`kern_sysctl.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c)
exposes that UUID read-only, while
[`clock.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/clock.c)
shows that `clock_boottime` can change with calendar adjustment. No XNU implementation code is copied into Infinify.

For a retired Dock, the launcher accepts only a committed schema-4 journal
written by the recorded Dock process, same login UID and same
`kern.bootsessionuuid`. The loader rechecks the journal's private file and
directory, exact writer identity, positive old-process retirement and schema-4
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
journal remain untouched. Journals of any schema but 4 are refused as recovery input: schema 4 records each window's original as its placement-1 layer
(see [Payload](../Payload/README.md#the-original-is-the-layer)), which is what makes handoff exact, and the
launcher never reconstructs transforms from native bounds. A retired journal whose schema number is a different integer (the
absolute originals of schema 3) is not migrated and does not block: the launcher says so, archives the launch record and the journal
under `retired-launch.*`, leaves the retired runtime untouched and starts fresh, as for a record of an earlier boot
(`tests/e2e/native-launcher.sh` shows it, run in the guest because it needs a machine without a running Infinify). A journal with no
integer schema number still blocks, preserved for inspection. A same-boot journal
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
The recovery form accepts only a committed same-boot schema-4 journal from the
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
