# Bounded native resize oracle provenance

Full unmodified GPL-3.0-or-later sources from https://github.com/malbiruk/driftwm
at `352333a8fa1b22171492d4b71a54102045c9a19d`. SHA256SUMS pins full files;
BLOCKS.json pins exact byte ranges and hashes. Tests verify both and extract
unchanged blocks into the type/IO shim in `support/resize_oracle.rs`.

Executed: original edge predicates, SizeConstraints::clamp, request displacement
and integer dimensions through clamp, and the ordinary unpinned incremental
settlement block in handle_resize_commit. The request block starts after screen
coordinate conversion; the shim supplies screen displacement directly. Aspect
ratio is disabled. Settlement supplies current position, last committed size,
and actual geometry; placement_owns_size is false. These are deliberately blocks,
not the complete resize grab, release handler, or commit handler.

No native calls, Wayland configure scheduling, client readback, capture, or
rendering execute here. Snap has its separate existing upstream oracle; this
oracle does not claim integrated snap/resize parity. Integer displacement traces
are compared. Existing floating-point reducer behavior for fractional displacement
still differs from upstream's integer truncation and is explicitly unresolved.
