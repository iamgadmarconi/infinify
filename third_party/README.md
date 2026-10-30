# third_party

Read-only, verbatim reference snapshots of upstream source. Infinify's build and tests never use them. Porters copy or translate from them and name the file they took.

| Directory | Upstream | Version | Licence |
|---|---|---|---|
| `driftwm/` | https://github.com/malbiruk/driftwm | v0.21.0 (`df3de27b26c7998e8a460cffd8a4925cbed3a322`) | GPL-3.0-or-later |
| `sunlight/` | https://github.com/spacefarm-digital/sunlight | afeea74 (`afeea74b18e70ca49bf462d6fe462cf65deb2b32`) | MIT |

Each directory has `VENDORED.md` (source, hash, licence, copy rules, skipped files) and `SHA256SUMS`. Do not edit anything here. Verify a directory with `cd third_party/<dir> && shasum -a 256 -c SHA256SUMS --quiet`.

To refresh one at a new tag or commit:

1. Clone upstream into `target/upstream/<dir>` (untracked) and check out the new tag or commit.
2. Remove the old copy's files, then re-copy with the rules in that directory's `VENDORED.md`: tracked files only, the same included paths, text types only, byte for byte.
3. Rewrite `VENDORED.md` (tag or commit, hash, date, skipped files) and regenerate `SHA256SUMS` from inside the directory: `find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS`.
4. Update the NOTICE paragraph on vendored copies if a version changes. Then run the `shasum -c` check above and `cargo metadata --format-version 1 --no-deps >/dev/null` from the repo root.
