# Infinify

An infinite canvas for native Mac windows: windows keep a place in an unbounded world, and a camera shows part of it on each display. This glossary names the concepts the code and the documents use.

## Language

### Snapping

**Magnetic snap**:
The pull that holds a moving window, or a moving window edge, at a stop offered by a neighbouring window until the pointer has moved far enough to break away.
_Avoid_: Snapping to grid, edge snapping, sticky edges

**Stop**:
A position along one axis that a neighbouring window offers to a moving window or edge: docked beside it with the gap between them, aligned with one of its edges, or centred on it.
_Avoid_: Snap point, snap target, candidate (a candidate is the one stop currently nearest, not the stops themselves)

**Break cooldown**:
The interval after a moving edge breaks away from a stop during which that same stop cannot hold it again; it ends once the edge has left the stop's reach and the stop is no longer the nearest one.
_Avoid_: Hysteresis, debounce

### Native windows

**Size transition**:
One change of a window's native size together with the still picture that stands in for the window while it changes, from the request until the window's final placement on screen is confirmed.
_Avoid_: Fill handoff, resize presentation, snapshot bridge, resize animation

### Input

**Press admission**:
The decision, taken when a pointer button goes down, of who receives that press and everything that follows it until the release: the canvas, a window's title bar and buttons, or the application under the pointer.
_Avoid_: Hit testing, input routing, event dispatch, click handling

### Focus

**Focus and arrival policy**:
The rules that decide whether a window that appears, or an application that comes to the front, was asked for by the owner, and what follows from the answer: where the window is placed, whether it takes focus, and whether the camera moves to it.
_Avoid_: Focus stealing prevention, activation filter, focus rules

**Solicited**:
Asked for by the owner through something they just did: a click, an application switch, a launch, or work in the application that opens the window. A window or activation that is not solicited is unsolicited, and neither takes focus nor moves the camera.
_Avoid_: Authorized, user-initiated, expected

### Dock helper

**Helper lifecycle**:
The rules that tie a private helper runtime and its credentials to one Dock process and decide, at each start, whether to reuse the helper already loaded there, recover the state a retired one left behind, or load a new one.
_Avoid_: Launcher logic, injection flow, bootstrap

### Controller

**Controller**:
The platform-independent part of Infinify that holds the state of the canvas and decides every change to it. The native shell reports what happened, asks questions, and carries out what the controller asks for.
_Avoid_: Backend, core, engine, reducer

**Scene**:
The controller's description of the canvas at one moment: the windows, where each one is shown on each display, the focus, and the work still in progress. The shell reads a scene and never changes it.
_Avoid_: Snapshot dictionary, state, model

**Effect**:
Something the controller asks the shell to do to a native window or to the system, such as giving a window focus or changing its size. The shell performs it and reports the result back.
_Avoid_: Side effect, action, command (a command goes from the shell to the controller)
