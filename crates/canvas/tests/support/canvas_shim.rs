// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only Smithay geometry storage/arithmetic and config Direction adapter.
// No fit, selection, visibility, bookmark, zoom, or momentum policy lives here.
pub mod utils {
    use std::marker::PhantomData;
    use std::ops::{Add, Sub};

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Logical;
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Point<T, Space> {
        pub x: T,
        pub y: T,
        space: PhantomData<Space>,
    }
    impl<T, Space> From<(T, T)> for Point<T, Space> {
        fn from((x, y): (T, T)) -> Self {
            Self {
                x,
                y,
                space: PhantomData,
            }
        }
    }
    impl<T: Add<Output = T>, Space> Add for Point<T, Space> {
        type Output = Self;
        fn add(self, other: Self) -> Self {
            (self.x + other.x, self.y + other.y).into()
        }
    }
    impl<T: Sub<Output = T>, Space> Sub for Point<T, Space> {
        type Output = Self;
        fn sub(self, other: Self) -> Self {
            (self.x - other.x, self.y - other.y).into()
        }
    }
    impl<Space> Point<i32, Space> {
        pub fn to_f64(self) -> Point<f64, Space> {
            (f64::from(self.x), f64::from(self.y)).into()
        }
    }
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Size<T, Space> {
        pub w: T,
        pub h: T,
        space: PhantomData<Space>,
    }
    impl<T, Space> From<(T, T)> for Size<T, Space> {
        fn from((w, h): (T, T)) -> Self {
            Self {
                w,
                h,
                space: PhantomData,
            }
        }
    }
    impl<Space> Size<i32, Space> {
        pub fn to_f64(self) -> Size<f64, Space> {
            (f64::from(self.w), f64::from(self.h)).into()
        }
    }
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Rectangle<T, Space> {
        pub loc: Point<T, Space>,
        pub size: Size<T, Space>,
    }
    impl<T, Space> Rectangle<T, Space> {
        pub fn new(loc: Point<T, Space>, size: Size<T, Space>) -> Self {
            Self { loc, size }
        }
    }
    impl<Space> Rectangle<i32, Space> {
        pub fn to_f64(self) -> Rectangle<f64, Space> {
            Rectangle::new(self.loc.to_f64(), self.size.to_f64())
        }
    }
}

// Exact direction variants/vector constants from config/types.rs at pinned
// commit 352333a8fa1b22171492d4b71a54102045c9a19d. Independent of production policy.
pub mod config {
    use std::f64::consts::FRAC_1_SQRT_2;
    #[derive(Clone, Debug, PartialEq)]
    pub enum Direction {
        Up,
        Down,
        Left,
        Right,
        UpLeft,
        UpRight,
        DownLeft,
        DownRight,
    }
    impl Direction {
        pub fn to_unit_vec(&self) -> (f64, f64) {
            match self {
                Direction::Up => (0.0, -1.0),
                Direction::Down => (0.0, 1.0),
                Direction::Left => (-1.0, 0.0),
                Direction::Right => (1.0, 0.0),
                Direction::UpLeft => (-FRAC_1_SQRT_2, -FRAC_1_SQRT_2),
                Direction::UpRight => (FRAC_1_SQRT_2, -FRAC_1_SQRT_2),
                Direction::DownLeft => (-FRAC_1_SQRT_2, FRAC_1_SQRT_2),
                Direction::DownRight => (FRAC_1_SQRT_2, FRAC_1_SQRT_2),
            }
        }
    }
}
