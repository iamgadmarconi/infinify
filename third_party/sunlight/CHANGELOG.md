# Changelog

## 0.1.3

- Setup no longer covers System Settings or macOS's permission prompts: the setup window steps aside as you press Allow Accessibility, Allow Screen Recording or approve the background helper, and only stays above other apps while Sunlight is in front. The Uninstall window does the same.
- Sunlight shows a Dock icon while setup is open, so you can click back to it from System Settings. The icon goes away when setup closes.

## 0.1.2

- Open Here…: double-click or right-click the empty canvas, type an app's name and press ⏎, and its new window opens on the spot you clicked (⌘⏎ also goes into it). An app that's already running is asked for a new window; one that can't make one has its last-used window brought over instead.
- The first-launch tutorial (trackpad) shows going into a window as a click or pinching in, side by side with an "or" between them, and ends with panning from anywhere with four fingers. Instructions > The Basics lists the four-finger pan too.
- Apps whose window never shows on the canvas (a panel, an overlay, a tiny or invisible window) now stay in front when you switch to them from the canvas, instead of being sent back behind it.

## 0.1.1

- Quick ⌘Tab switches no longer flash the window you just left at full size (Dock add-on sunlight-14).
  Sunlight loads the new add-on by itself the first time it starts after the update, which restarts the
  Dock once. With live windows allowed in Login Items that needs nothing from you; otherwise Sunlight asks
  for your administrator password once.
- Quick ⌘Tab taps from a window now fly the windows into place like a held ⌘ does, instead of jumping.

## 0.1

The first public release.

**The canvas**
- Every open window on one infinite canvas you pan and zoom with the trackpad: pinch or ⌥-scroll to zoom,
  two-finger scroll to pan, and four-finger drag to pan from anywhere.
- Click a window to enter it at 1:1, centred, with no seam between the canvas and the real window. A
  four-finger tap or the Mission Control key (F3) goes back, and again goes back into the window. (Settings › Trackpad can make
  See All a four-finger swipe up instead.) A window at 1:1 can be used directly, without entering it.
- Desktop widgets and Finder's desktop files sit on the canvas, with Show Desktop (F11 or the four-finger
  spread), and you can drag files into windows.
- Hidden and minimized windows keep their place, shown as dashed outlines in the minimap.
- Coming to rest almost exactly on a full screen window (a pan, pinch or minimap jump that lands near 1:1
  with its edges nearly lined up) nudges the canvas onto it on a quick spring and enters it. Settings ›
  Canvas › Snap to full screen windows turns it off.
- Windows snap to alignment guides and a grid as you drag, can be resized from their edges, and can push
  each other aside if you want (Settings › Windows).
- Move & Resize: ⌃⌥ shortcuts for halves, quarters, thirds, two-thirds, full screen and centre.
- Saved layouts (⌘S, ⌘1–⌘9) reopen missing apps and documents. The canvas remembers itself between launches.
- Backgrounds: your Mac's wallpaper, Photos, files, colours or gradients, with blur and dim that follow
  the zoom.
- Takeover mode: hides the Dock and makes ⌘Tab, Mission Control and Show Desktop work on the canvas, and
  puts every setting it changed back when you quit.
- Experimental, off by default (Settings › General › Experimental): Arrange and Tidy, and strip mode.
- A canvas on every display, behind Settings › General › Experimental › Multiple displays (off by
  default). Each window is on the canvas of the display it's on, and goes to another
  display's canvas when moved there, from inside it or with ⌃⌥⇧ → ← (Window › Move to Next Display, or its
  right-click menu). ⌘Tab reaches the windows of every display. While you work in a window on one display,
  the others keep their canvas up. Displays plugged in or out are picked up as they come and go.

**Live windows**
- The real windows themselves, scaled on the canvas by a small add-on in the Dock. They need part of
  System Integrity Protection turned off. Until then, preview mode shows windows as live pictures.
- Set Up Sunlight, a step-by-step wizard covering permissions, the Recovery restart (with a QR code for
  your phone) and the background helper, so nothing asks for a password afterwards.
- Live windows on every display, with the Dock add-on sunlight-13 (one lease per display's canvas).
- Diagnose… copies a plain-text report for bug reports. Uninstall Sunlight… walks the whole setup back.

**Getting it**
- A notarized DMG, Homebrew (`brew install spacefarm-digital/tap/sunlight`), and updates through Sparkle.
- macOS 15 or later, Apple silicon. Primary display only for now.
