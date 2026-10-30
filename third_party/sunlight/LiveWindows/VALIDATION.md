# Target-machine validation

Machine: macOS 27.2, Apple Silicon. Original addition: 2.1.31.
Rollback bundle saved at `build/yabai-original.osax`; original CLI remains at `~/yabai-build/bin/yabai`.

## Verified

- User approved installation and Dock restart. Version `2.1.31-sunbeam1` was installed first;
  `2.1.31-sunbeam2` was installed and loaded after the return-path fix.
- The app's capability probe reports live-window protocol v1 available.
- The standalone native smoke test performed 300 transforms through the Dock socket:
  average acknowledgment time 5.79 ms; maximum 10.00 ms.
- WindowServer readback matched the requested inverse transforms on every frame.
- Disconnect restored the exact initial native transform.
- Handoff committed the requested position at native scale, without using capture APIs.
- Full app launch selected live mode and discovered ordinary windows and desktop widgets without
  ScreenCaptureKit enumeration.

## Return-path fix and full canvas

The full canvas fell back to capture on a rejected update after leaving for System Settings and
returning. Capture fallback was confirmed in the app logs; screenshots taken after that point are
not evidence of live mode.

The revised app requires a fresh on-screen window list before reacquiring a session and excludes
retained proxies for hidden/off-Space windows. Its payload also returns the failed WindowServer
stage in the acknowledgment. Version `2.1.31-sunbeam2` was loaded and confirmed by the capability
probe at 16:45. The specific WindowServer failure in the first revision was not isolated, so the
membership race remains a diagnosis rather than a proven root cause.

The 16:48–16:50 live-mode run exercised repeated Safari/ChatGPT handoffs, four-finger returns,
camera changes, app switching, and window creation/closure without a renderer failure or capture
fallback in the logs. The user answered **Visible and usable** when asked whether scaled windows
were visible and usable during pan and zoom.

WindowServer inspection read six managed windows at inverse scale 3.1614 (approximately 32% canvas
zoom). After quit, all five surviving windows were at native scale; the sixth window had closed.
Both desktop widgets returned from normal level to their original desktop level (-2147483601).
This checks native scale and widget levels after the full app; exact transform restoration was
checked separately by the native smoke test. App-window-only automation screenshots do not include
the other applications' composited surfaces and are not used as visual evidence for this mode.

A separate launch-argument issue was found: `-CanvasRemember NO` arrived as a string and the old
Boolean cast ignored it. The setting now uses UserDefaults Boolean parsing, so test runs can disable
layout restoration/persistence without changing the saved preference.

## Full takeover

A normal launch applied the existing takeover preferences and restarted Dock, unloading the addition.
The unavailable socket and capture fallback were confirmed. This is a lifecycle limitation, not a
successful live-mode run.

At the user's request, full takeover was started at 16:52, then the installed addition was reloaded
into that Dock. At 16:54:07, Settings switched from **Capture proxies** to **Scaled real windows**.
The running app logged the live renderer, and a separate WindowServer readback showed managed app
windows and widgets at inverse scale 2.563. Full takeover and live rendering were left running for
the user. The full-takeover session initially used capture before the explicit mode switch; it must
not be described as a capture-free launch.
The following 16:54–16:55 interactions included repeated Safari/ChatGPT/Finder handoffs, four-finger
returns and app switching with no renderer failure or capture fallback reported in the running log.

## Remaining limits

- Dock restarts require an administrator reload. There is no automatic privileged loader.
- Recovery from a Dock crash/restart during an active transform lease has not been validated.
- Native fullscreen, other Spaces, multiple displays and sleep/wake remain outside this validation.
- The user confirmed general pan/zoom usability; a separate drag-specific and long-duration performance
  acceptance run has not been recorded. The latency numbers above measure the native smoke test.
