# Finder search-header drag, 2026-10-22

The existing real Finder search window in the authorized UTM guest reproduced
a jump when dragging the blank search-scope row below its toolbar at 75% zoom.
The toolbar-only map missed that row, so Finder received the original press and
moved its native frame while the window was transformed. Infinify then adopted
the resulting displayed position.

The adapter now recognizes the measured `com.apple.finder` / `FinderWindow`
split-group hierarchy, `_NS:129` search header, neighboring `_NS:23` results
area, and four named controls. It excludes each whole control rectangle plus
one point. Every region's exclusions apply before accepting any drag region,
including controls overlapping an adjacent region. Unknown structure or an
extra-read deadline leaves only the independently validated toolbar map.

Physical UTM input against the production v30 app on macOS 27.0.1 (26A434):

- At zoom 0.75, a 30 × 20 screen-point header drag moved world position from
  `[-3, -2125]` to `[37, -2152]`; the reverse drag restored `[-3, -2125]`.
- At zoom 1, the same drag moved world position to `[27, -2145]`.
- Finder's native frame stayed `[14, 360, 2056, 1130]`. Forty-five independent
  geometry samples surrounding the first drag all retained that frame.
- Each header drag logged `native chrome owned ... kind=title gesture=2`.
  Scope and search-field clicks logged `native_control` and completed as
  unchanged native clicks. A drag in empty results content also left both the
  native frame and world position unchanged.
- The original world positions, camera, zoom and focused TextEdit window were
  restored after the checks.

The packaged executable SHA-256 was
`22833d77f3030018e70622c9e93910b28983c6bdac3b685f97088d15a6c425d0`.
The production build passed `-Wall -Wextra -Werror` and signing verification.
Local raw reads and input logs are under the ignored
`target/native-vm/ux-flow-20261022/v30-live-*` paths.

An earlier experiment cleared WindowServer tag bit 22 through Dock. Finder still
moved its native frame while the bit remained cleared, so that experiment was
reverted and the original tag restored. It is not a general drag-disable switch.
This result covers the observed Finder layout and the checks above; it does not
establish arbitrary custom-titlebar support, all Finder layouts, macOS 26 behavior,
or complete suppression of application-initiated window control.
