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
