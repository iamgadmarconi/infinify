# Native drag routing

The capture desktop currently forwards mouse packets into the selected native
recipient. That is enough to route a button press, but it is not a foreign
AppKit drag-and-drop session bridge. A destination in another application must
negotiate the original session's types, operations, promises, drop location and
completion with its source. Reading file URLs from the drag pasteboard, pasting
them or asking an application to open them does not preserve that contract.

Apple's [`NSDraggingSession`](https://developer.apple.com/documentation/appkit/nsdraggingsession)
is created by an application's source view. Its destination callbacks are
delivered to the registered destination view/window; its
[`NSDraggingInfo`](https://developer.apple.com/documentation/appkit/nsdragginginfo)
supplies that destination's location and the source's allowed operations.
[`File promises`](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises)
also keep a source/destination conversation alive after the pointer release.
Those APIs do not provide this controller with a supported way to take an
arbitrary foreign session and deliver it into another process at a remapped
captured-image coordinate.

Helper presentation supplies a real native ownership site for each window,
with the canvas panel behind ordinary native windows. A source-to-destination
drag between these real sites can remain with AppKit and WindowServer from
beginning through completion, with no Infinify pasteboard receiver or data
substitute. WindowServer owns the transformed destination's hit testing and
window-local conversion. Whether all third-party destinations correctly accept
that conversion under the helper's transform remains a runtime acceptance
requirement; compilation and transform readback cannot establish it.

An extra display's captured replica has no second real native destination.
Simply making its panel transparent or hiding it would reveal whichever native
window lies underneath, at its own native position. That would neither prove
the displayed replica's identity nor map its drop location. Correct replica
support needs either a proven foreign-session routing contract or a settled
native ownership transfer to the exact displayed destination, including its
process birth, binding generation, current member ancestry, native bounds,
output clip and helper acknowledgement before release. Neither is implemented
by the mouse-pair preservation change.

`native-input.m` now leaves an unclaimed original press addressed to a foreign
native window, its drag/motion packets and its release untouched even after
the pointer crosses the canvas or another application. Each physical button
has its own ownership; a second button cannot start a canvas action in that
native drag. Known lifetime-tagged posted copies bypass bookkeeping, and a tap
disable or stop retires stale native reservations. A swallowed canvas down
still suppresses its physical release after cancellation, so another
application cannot receive an unpaired up.

The earlier global trackpad tap records unowned original buttons and refuses a
new touch, Dock or magnify contact during them. An already admitted three-finger
canvas contact retains its generated mouse pair and can pan over windows. If
macOS delivers an application mouse-down before the first decodable three-finger
contact, the existing native pair stays native until release. Taking its tails
would steal an application drag that has already begun. Physical ordering of
macOS's accessibility three-finger-drag packets is unverified; the regression
checks both orderings as adapter policy and does not claim hardware parity.

Run `sh tests/e2e/native-input-policy.sh` for isolated packet-policy coverage.
It installs no event tap, creates no window or native session, reads no
pasteboard and posts no events. Its packet and decoded-contact substitutions
remain within that test process; its already-admitted-contact case seeds prior
ownership on the test object because no live tap exists. It does not establish usable cross-application
drag-and-drop through either real helper surfaces or captured replicas.
