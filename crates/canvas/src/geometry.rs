// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinate transforms adapted from malbiruk/driftwm src/canvas.rs at 352333a8fa1b22171492d4b71a54102045c9a19d.
// Native Rust geometry replaces Smithay's platform-specific geometry types.
use serde::{Deserialize, Serialize};

/// A logical point or displacement. Coordinates have a top-left origin, Y down.
#[derive(Debug, Default, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Point {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}
impl Point {
    /// Construct a point.
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
    pub(crate) fn valid(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.x.abs() <= 1e12 && self.y.abs() <= 1e12
    }
}
impl std::ops::Add for Point {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        Self::new(self.x + rhs.x, self.y + rhs.y)
    }
}
impl std::ops::Sub for Point {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        Self::new(self.x - rhs.x, self.y - rhs.y)
    }
}
impl std::ops::Mul<f64> for Point {
    type Output = Self;
    fn mul(self, rhs: f64) -> Self {
        Self::new(self.x * rhs, self.y * rhs)
    }
}
impl std::ops::Div<f64> for Point {
    type Output = Self;
    fn div(self, rhs: f64) -> Self {
        Self::new(self.x / rhs, self.y / rhs)
    }
}

/// Width and height in logical units.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Size {
    /// Horizontal extent.
    pub width: f64,
    /// Vertical extent.
    pub height: f64,
}
impl Size {
    /// Construct a size; scene entry points reject nonpositive sizes.
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

/// Axis-aligned rectangle, with half-open right and bottom edges for hit testing.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    /// Top-left position.
    pub origin: Point,
    /// Positive dimensions.
    pub size: Size,
}
impl Rect {
    /// Construct a rectangle; scene entry points validate its geometry.
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            origin: Point::new(x, y),
            size: Size::new(width, height),
        }
    }
    /// Right edge.
    pub fn right(self) -> f64 {
        self.origin.x + self.size.width
    }
    /// Bottom edge.
    pub fn bottom(self) -> f64 {
        self.origin.y + self.size.height
    }
    /// Rectangle center.
    pub fn center(self) -> Point {
        self.origin + Point::new(self.size.width / 2.0, self.size.height / 2.0)
    }
    /// Whether a point lies within this half-open rectangle.
    pub fn contains(self, p: Point) -> bool {
        p.x >= self.origin.x && p.x < self.right() && p.y >= self.origin.y && p.y < self.bottom()
    }
    /// Positive-area intersection, excluding touching edges.
    pub fn intersection(self, other: Self) -> Option<Self> {
        let x = self.origin.x.max(other.origin.x);
        let y = self.origin.y.max(other.origin.y);
        let width = self.right().min(other.right()) - x;
        let height = self.bottom().min(other.bottom()) - y;
        (width > 0.0 && height > 0.0).then(|| Self::new(x, y, width, height))
    }
    /// Translate without changing the size.
    pub fn translated(self, delta: Point) -> Self {
        Self {
            origin: self.origin + delta,
            ..self
        }
    }
    pub(crate) fn valid(self) -> bool {
        self.origin.valid()
            && Point::new(self.right(), self.bottom()).valid()
            && self.size.width.is_finite()
            && self.size.height.is_finite()
            && self.size.width > 0.0
            && self.size.height > 0.0
    }
}
