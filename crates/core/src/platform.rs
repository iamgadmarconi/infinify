// SPDX-License-Identifier: GPL-3.0-or-later
// Not an upstream file. Local stand-ins for the items that the ported parts of
// malbiruk/driftwm (repository: https://github.com/malbiruk/driftwm; these
// stand-ins were written against commit
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/config, src/canvas.rs and
// src/input/gestures.rs) import from the Wayland stack, so the ported modules
// compile with no C library and no system dependency.
//
// The module tree mirrors the upstream paths one for one, so the only change
// in the ported sources is the prefix `smithay::` -> `crate::platform::`:
//
//   smithay::backend::input::AxisSource
//   smithay::input::keyboard::{Keysym, ModifiersState, keysyms, xkb}
//   smithay::utils::{Coordinate, Logical, Point, Rectangle, Size, Transform}
//
// Third-party origin (full list and licences: docs/crates/core/PORT.md, SMITHAY-LICENSE.txt at the repository root):
//
//   Smithay 0.7.0, MIT, Copyright (c) 2017 Victor Berger and Victoria Brekenfeld
//     repository: https://github.com/Smithay/smithay
//     git:        a166cf4c94b5aedc332a65aa1dd753e8148829c3 (the 0.7.0 release)
//     paths:      src/utils/geometry.rs        (Logical, Coordinate, Point, Size,
//                                               Rectangle: Smithay's own code,
//                                               reduced to what the ported modules
//                                               use; Transform: shape only)
//                 src/backend/input/mod.rs     (AxisSource: shape only)
//                 src/input/keyboard/modifiers_state.rs (ModifiersState: shape only)
//   xkeysym 0.2.1, MIT OR Apache-2.0 OR Zlib: `Keysym` is its type, and
//     keysyms.rs is generated from its names and values
//     repository: https://github.com/notgull/xkeysym
//   xkbcommon 0.9.0 (MIT): one constant (`hpYdiaeresis`) and the list of
//     `KEY_*` names it was checked against
//     repository: https://github.com/rust-x-bindings/xkbcommon-rs
//   xkbcommon-rs 0.1.2 (a Rust port of libxkbcommon 1.7.0): read for the
//     algorithm of `xkb::keysym_from_name` and its name table
//     repository: https://github.com/wysiwys/xkbcommon-rs
//   libxkbcommon (MIT/X11): `xkb::keysym_from_name` reimplements its
//     `xkb_keysym_from_name`.
//
// docs/crates/core/PORT.md lists what each stand-in keeps, what it leaves out, and where it
// differs.
//! Platform-neutral stand-ins for the Wayland-stack items the ported modules
//! import upstream. Only what those modules and their tests use is provided.

/// Stand-in for `smithay::backend`.
pub mod backend {
    /// Stand-in for `smithay::backend::input`.
    pub mod input {
        /// Source of an axis when scrolling. Same variants, order and derives as
        /// `smithay::backend::input::AxisSource`.
        #[derive(Debug, PartialEq, Eq, Clone, Copy)]
        pub enum AxisSource {
            /// Finger. Mostly used for trackpads.
            Finger,
            /// Continuous scrolling device.
            Continuous,
            /// Scroll wheel.
            Wheel,
            /// Scrolling through tilting the scroll wheel.
            WheelTilt,
        }
    }
}

/// Stand-in for `smithay::input`.
pub mod input {
    /// Stand-in for `smithay::input::keyboard`.
    pub mod keyboard {
        /// The keysym type. Upstream's `smithay::input::keyboard::Keysym` is
        /// this same `xkeysym::Keysym` (re-exported through xkbcommon 0.9.0).
        pub use xkeysym::Keysym;

        pub mod keysyms;

        /// Modifier state of a key or pointer event. Same boolean fields and
        /// derives as `smithay::input::keyboard::ModifiersState`; upstream's
        /// `serialized: SerializedMods` field (the `wl_keyboard` wire form) and
        /// its xkb-state methods are left out.
        #[derive(Copy, Clone, Debug, Default, PartialEq, Eq, Hash)]
        pub struct ModifiersState {
            /// The "control" key
            pub ctrl: bool,
            /// The "alt" key
            pub alt: bool,
            /// The "shift" key
            pub shift: bool,
            /// The "Caps lock" key
            pub caps_lock: bool,
            /// The "logo" key
            pub logo: bool,
            /// The "Num lock" key
            pub num_lock: bool,
            /// The "ISO level 3 shift" key
            pub iso_level3_shift: bool,
            /// The "ISO level 5 shift" key. Smithay fills it from xkb's Mod3.
            pub iso_level5_shift: bool,
        }

        /// Stand-in for `smithay::input::keyboard::xkb` (`xkbcommon::xkb`):
        /// keysym name lookup only.
        pub mod xkb {
            use super::Keysym;
            use super::keysyms::{KEY_NoSymbol, NAME_TO_KEYSYM};
            use std::cmp::Ordering;

            /// Flags for [`keysym_from_name`].
            pub type KeysymFlags = u32;
            /// Exact-case lookup.
            pub const KEYSYM_NO_FLAGS: u32 = 0;
            /// Find the keysym by case-insensitive search.
            pub const KEYSYM_CASE_INSENSITIVE: u32 = 1 << 0;

            const XKB_KEYSYM_MAX: u32 = 0x1fff_ffff;
            const XKB_KEYSYM_UNICODE_OFFSET: u32 = 0x0100_0000;

            /// Compare two names ignoring ASCII case, byte by byte — libxkbcommon's
            /// `istrcmp`. Only `A`–`Z` fold; nothing outside ASCII does.
            fn istrcmp(a: &str, b: &str) -> Ordering {
                a.bytes()
                    .map(|c| c.to_ascii_lowercase())
                    .cmp(b.bytes().map(|c| c.to_ascii_lowercase()))
            }

            /// One to eight hexadecimal digits and nothing else — libxkbcommon's
            /// `parse_keysym_hex`.
            fn parse_keysym_hex(s: &[u8]) -> Option<u32> {
                if s.is_empty() || s.len() > 8 {
                    return None;
                }
                let mut result: u32 = 0;
                for &c in s {
                    result = (result << 4) + char::from(c).to_digit(16)?;
                }
                Some(result)
            }

            /// Index of some table entry equal to `name` ignoring ASCII case.
            fn find_ignoring_case(name: &str) -> Option<usize> {
                NAME_TO_KEYSYM
                    .binary_search_by(|(entry, _)| istrcmp(entry, name))
                    .ok()
            }

            fn keysym_from_name_raw(name: &str, flags: KeysymFlags) -> u32 {
                let icase = flags & KEYSYM_CASE_INSENSITIVE != 0;

                if flags & !KEYSYM_CASE_INSENSITIVE != 0 {
                    return KEY_NoSymbol;
                }

                if let Some(found) = find_ignoring_case(name) {
                    // The table is ordered by case-folded name, so every spelling
                    // of one folded name is adjacent to `found`.
                    let same = |i: usize| istrcmp(NAME_TO_KEYSYM[i].0, name) == Ordering::Equal;
                    if icase {
                        // Keep going until the end of the table or a different
                        // name: the last spelling is the lower-case one.
                        let mut last = found;
                        while last + 1 < NAME_TO_KEYSYM.len() && same(last + 1) {
                            last += 1;
                        }
                        return NAME_TO_KEYSYM[last].1;
                    }
                    let mut first = found;
                    while first > 0 && same(first - 1) {
                        first -= 1;
                    }
                    let exact = NAME_TO_KEYSYM[first..]
                        .iter()
                        .take_while(|(entry, _)| istrcmp(entry, name) == Ordering::Equal)
                        .find(|(entry, _)| *entry == name);
                    if let Some((_, keysym)) = exact {
                        return *keysym;
                    }
                }

                let bytes = name.as_bytes();
                if bytes.first() == Some(&b'U') || (icase && bytes.first() == Some(&b'u')) {
                    let Some(val) = parse_keysym_hex(&bytes[1..]) else {
                        return KEY_NoSymbol;
                    };

                    if val < 0x20 || (val > 0x7e && val < 0xa0) {
                        return KEY_NoSymbol;
                    }
                    if val < 0x100 {
                        return val;
                    }
                    if val > 0x10_ffff {
                        return KEY_NoSymbol;
                    }
                    return val | XKB_KEYSYM_UNICODE_OFFSET;
                } else if bytes.first() == Some(&b'0')
                    && (bytes.get(1) == Some(&b'x') || (icase && bytes.get(1) == Some(&b'X')))
                {
                    let Some(val) = parse_keysym_hex(&bytes[2..]) else {
                        return KEY_NoSymbol;
                    };
                    if val > XKB_KEYSYM_MAX {
                        return KEY_NoSymbol;
                    }
                    return val;
                }

                // Try without the underscore, for the legacy `XF86_` spellings.
                if bytes.len() >= 5
                    && (&bytes[..5] == b"XF86_"
                        || (icase && bytes[..5].eq_ignore_ascii_case(b"XF86_")))
                {
                    // The first five bytes are ASCII, so both cuts are on
                    // character boundaries.
                    let without_underscore = format!("{}{}", &name[..4], &name[5..]);
                    return keysym_from_name_raw(&without_underscore, flags);
                }

                KEY_NoSymbol
            }

            /// Get a keysym from its name; [`Keysym::NoSymbol`] if the name is
            /// invalid or `flags` has unknown bits.
            ///
            /// Follows libxkbcommon 1.7.0's `xkb_keysym_from_name`: a table name,
            /// else `U<hex>` (Unicode code point), else `0x<hex>` (raw value),
            /// else the name again with a legacy `XF86_` prefix read as `XF86`.
            /// With [`KEYSYM_CASE_INSENSITIVE`] the name, the `U`/`0x` prefixes
            /// and `XF86_` match ignoring ASCII case, and where table names
            /// differ only by case the lower-case one wins (`"A"` gives
            /// `KEY_a`).
            ///
            /// Differs from `xkbcommon::xkb::keysym_from_name` in one case: a
            /// name containing a NUL character returns `NoSymbol` here, where
            /// the xkbcommon 0.9.0 binding panics building its C string.
            #[must_use]
            pub fn keysym_from_name(name: &str, flags: KeysymFlags) -> Keysym {
                if name.contains('\0') {
                    return Keysym::new(KEY_NoSymbol);
                }
                Keysym::new(keysym_from_name_raw(name, flags))
            }

            #[cfg(test)]
            mod tests {
                use super::*;

                /// The lookup binary-searches the table, and its tie-break relies
                /// on the lower-case spelling being last: both need this order.
                #[test]
                fn name_table_is_in_libxkbcommon_order() {
                    for pair in NAME_TO_KEYSYM.windows(2) {
                        let (a, b) = (pair[0].0, pair[1].0);
                        let order = istrcmp(a, b).then_with(|| a.cmp(b));
                        assert_eq!(order, Ordering::Less, "{a:?} must sort before {b:?}");
                    }
                }

                /// Every name resolves to its own value under an exact lookup,
                /// and under a case-insensitive one to the value of the last
                /// spelling of that name.
                #[test]
                fn every_table_name_resolves() {
                    for (i, (name, value)) in NAME_TO_KEYSYM.iter().enumerate() {
                        assert_eq!(
                            keysym_from_name(name, KEYSYM_NO_FLAGS).raw(),
                            *value,
                            "exact lookup of {name:?}"
                        );
                        let last = NAME_TO_KEYSYM[i..]
                            .iter()
                            .take_while(|(other, _)| other.eq_ignore_ascii_case(name))
                            .last()
                            .unwrap();
                        for spelling in [
                            name.to_string(),
                            name.to_ascii_lowercase(),
                            name.to_ascii_uppercase(),
                        ] {
                            assert_eq!(
                                keysym_from_name(&spelling, KEYSYM_CASE_INSENSITIVE).raw(),
                                last.1,
                                "case-insensitive lookup of {spelling:?}"
                            );
                        }
                    }
                }
            }
        }
    }
}

/// Stand-in for `smithay::utils`.
pub mod utils {
    use std::fmt;
    use std::ops::{Add, AddAssign, Sub};

    /// Type-level marker for the logical coordinate space.
    #[derive(Debug)]
    pub struct Logical;

    /// Trait for types serving as a coordinate for other geometry utils.
    ///
    /// Same supertraits as `smithay::utils::Coordinate`. Of its items only the
    /// ones the geometry below calls are kept (`to_f64`, `non_negative`,
    /// `saturating_add`, `saturating_sub`), and it is implemented for `i32`
    /// and `f64` only, the two coordinate types the ported modules use.
    pub trait Coordinate:
        Sized
        + Add<Self, Output = Self>
        + Sub<Self, Output = Self>
        + PartialOrd
        + Default
        + Copy
        + fmt::Debug
    {
        /// Convert the coordinate to a f64
        fn to_f64(self) -> f64;
        /// Test if the coordinate is not negative
        fn non_negative(self) -> bool;
        /// Saturating integer addition. Computes self + other, saturating at the numeric bounds instead of overflowing.
        fn saturating_add(self, other: Self) -> Self;
        /// Saturating integer subtraction. Computes self - other, saturating at the numeric bounds instead of overflowing.
        fn saturating_sub(self, other: Self) -> Self;
    }

    impl Coordinate for i32 {
        #[inline]
        fn to_f64(self) -> f64 {
            self as f64
        }

        #[inline]
        fn non_negative(self) -> bool {
            self >= 0
        }

        #[inline]
        fn saturating_add(self, other: Self) -> Self {
            self.saturating_add(other)
        }
        #[inline]
        fn saturating_sub(self, other: Self) -> Self {
            self.saturating_sub(other)
        }
    }

    impl Coordinate for f64 {
        #[inline]
        fn to_f64(self) -> f64 {
            self
        }

        #[inline]
        fn non_negative(self) -> bool {
            self >= 0.0
        }

        #[inline]
        fn saturating_add(self, other: Self) -> Self {
            self + other
        }
        #[inline]
        fn saturating_sub(self, other: Self) -> Self {
            self - other
        }
    }

    /// A point as defined by its x and y coordinates
    ///
    /// Operations on points are saturating.
    ///
    /// Field layout, constructors, the `Debug` form and the trait impls below
    /// follow `smithay::utils::Point`. Left out: `SubAssign`, `Eq`, the
    /// point/size conversions, scaling, rounding (`to_i32_round` and friends)
    /// and the conversions between coordinate spaces.
    #[repr(C)]
    pub struct Point<N, Kind> {
        /// horizontal coordinate
        pub x: N,
        /// vertical coordinate
        pub y: N,
        _kind: std::marker::PhantomData<Kind>,
    }

    impl<N, Kind> Point<N, Kind> {
        /// Create a new Point
        pub const fn new(x: N, y: N) -> Point<N, Kind> {
            Point {
                x,
                y,
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: Coordinate, Kind> Point<N, Kind> {
        /// Convert the underlying numerical type to f64 for floating point manipulations
        #[inline]
        pub fn to_f64(self) -> Point<f64, Kind> {
            Point {
                x: self.x.to_f64(),
                y: self.y.to_f64(),
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: fmt::Debug, S> fmt::Debug for Point<N, S> {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_fmt(format_args!("Point<{}>", std::any::type_name::<S>()))?;
            f.debug_struct("")
                .field("x", &self.x)
                .field("y", &self.y)
                .finish()
        }
    }

    impl<N, Kind> From<(N, N)> for Point<N, Kind> {
        #[inline]
        fn from((x, y): (N, N)) -> Point<N, Kind> {
            Point::new(x, y)
        }
    }

    impl<N: Coordinate, Kind> Add for Point<N, Kind> {
        type Output = Point<N, Kind>;
        #[inline]
        fn add(self, other: Point<N, Kind>) -> Point<N, Kind> {
            Point {
                x: self.x.saturating_add(other.x),
                y: self.y.saturating_add(other.y),
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: Coordinate, Kind> AddAssign for Point<N, Kind> {
        #[inline]
        fn add_assign(&mut self, rhs: Self) {
            self.x = self.x.saturating_add(rhs.x);
            self.y = self.y.saturating_add(rhs.y);
        }
    }

    impl<N: Coordinate, Kind> Sub for Point<N, Kind> {
        type Output = Point<N, Kind>;
        #[inline]
        fn sub(self, other: Point<N, Kind>) -> Point<N, Kind> {
            Point {
                x: self.x.saturating_sub(other.x),
                y: self.y.saturating_sub(other.y),
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: Clone, Kind> Clone for Point<N, Kind> {
        #[inline]
        fn clone(&self) -> Self {
            Point {
                x: self.x.clone(),
                y: self.y.clone(),
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: Copy, Kind> Copy for Point<N, Kind> {}

    impl<N: PartialEq, Kind> PartialEq for Point<N, Kind> {
        #[inline]
        fn eq(&self, other: &Self) -> bool {
            self.x == other.x && self.y == other.y
        }
    }

    impl<N: Default, Kind> Default for Point<N, Kind> {
        #[inline]
        fn default() -> Self {
            Point {
                x: N::default(),
                y: N::default(),
                _kind: std::marker::PhantomData,
            }
        }
    }

    /// A size as defined by its width and height
    ///
    /// Constructors of this type ensure that the values are always positive via
    /// `debug_assert!()`, however manually changing the values of the fields
    /// can break this invariant.
    ///
    /// Field layout, `new` with its `debug_assert!`, the tuple conversion, the
    /// `Debug` form and the trait impls below follow `smithay::utils::Size`.
    /// Left out: arithmetic, `Eq`, `clamp`, `is_empty`, the point conversion,
    /// scaling, rounding and the conversions between coordinate spaces.
    #[repr(C)]
    pub struct Size<N, Kind> {
        /// horizontal coordinate
        pub w: N,
        /// vertical coordinate
        pub h: N,
        _kind: std::marker::PhantomData<Kind>,
    }

    impl<N: Coordinate, Kind> Size<N, Kind> {
        /// Create a new Size
        pub fn new(w: N, h: N) -> Size<N, Kind> {
            debug_assert!(
                w.non_negative() && h.non_negative(),
                "Attempting to create a `Size` of negative size: {:?}",
                (w, h)
            );
            Size {
                w,
                h,
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: Coordinate, Kind> Size<N, Kind> {
        /// Convert the underlying numerical type to f64 for floating point manipulations
        #[inline]
        pub fn to_f64(self) -> Size<f64, Kind> {
            Size {
                w: self.w.to_f64(),
                h: self.h.to_f64(),
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: fmt::Debug, S> fmt::Debug for Size<N, S> {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_fmt(format_args!("Size<{}>", std::any::type_name::<S>()))?;
            f.debug_struct("")
                .field("w", &self.w)
                .field("h", &self.h)
                .finish()
        }
    }

    impl<N: Coordinate, Kind> From<(N, N)> for Size<N, Kind> {
        #[inline]
        fn from((w, h): (N, N)) -> Size<N, Kind> {
            Size::new(w, h)
        }
    }

    impl<N: Clone, Kind> Clone for Size<N, Kind> {
        #[inline]
        fn clone(&self) -> Self {
            Size {
                w: self.w.clone(),
                h: self.h.clone(),
                _kind: std::marker::PhantomData,
            }
        }
    }

    impl<N: Copy, Kind> Copy for Size<N, Kind> {}

    impl<N: PartialEq, Kind> PartialEq for Size<N, Kind> {
        #[inline]
        fn eq(&self, other: &Self) -> bool {
            self.w == other.w && self.h == other.h
        }
    }

    impl<N: Default, Kind> Default for Size<N, Kind> {
        #[inline]
        fn default() -> Self {
            Size {
                w: N::default(),
                h: N::default(),
                _kind: std::marker::PhantomData,
            }
        }
    }

    /// A rectangle defined by its top-left corner and dimensions
    ///
    /// Fields, `new`, `to_f64`, the `Debug` form and the trait impls below
    /// follow `smithay::utils::Rectangle`. Left out: `Eq`, `Default`, the other
    /// constructors, containment/overlap/intersection/subtraction, scaling,
    /// rounding and the conversions between coordinate spaces.
    #[repr(C)]
    pub struct Rectangle<N, Kind> {
        /// Location of the top-left corner of the rectangle
        pub loc: Point<N, Kind>,
        /// Size of the rectangle, as (width, height)
        pub size: Size<N, Kind>,
    }

    impl<N: Coordinate, Kind> Rectangle<N, Kind> {
        /// Convert the underlying numerical type to another
        pub fn to_f64(self) -> Rectangle<f64, Kind> {
            Rectangle {
                loc: self.loc.to_f64(),
                size: self.size.to_f64(),
            }
        }
    }

    impl<N: Coordinate, Kind> Rectangle<N, Kind> {
        /// Create a new [`Rectangle`] from the coordinates of its top-left corner and its dimensions
        #[inline]
        pub fn new(loc: Point<N, Kind>, size: Size<N, Kind>) -> Self {
            Rectangle { loc, size }
        }
    }

    impl<N: fmt::Debug, S> fmt::Debug for Rectangle<N, S> {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_fmt(format_args!("Rectangle<{}>", std::any::type_name::<S>()))?;
            f.debug_struct("")
                .field("x", &self.loc.x)
                .field("y", &self.loc.y)
                .field("width", &self.size.w)
                .field("height", &self.size.h)
                .finish()
        }
    }

    impl<N: Clone, Kind> Clone for Rectangle<N, Kind> {
        #[inline]
        fn clone(&self) -> Self {
            Rectangle {
                loc: self.loc.clone(),
                size: self.size.clone(),
            }
        }
    }

    impl<N: Copy, Kind> Copy for Rectangle<N, Kind> {}

    impl<N: PartialEq, Kind> PartialEq for Rectangle<N, Kind> {
        #[inline]
        fn eq(&self, other: &Self) -> bool {
            self.loc == other.loc && self.size == other.size
        }
    }

    /// Possible transformations to two-dimensional planes. Same variants, order
    /// and derives as `smithay::utils::Transform`; its methods are left out.
    #[derive(Debug, PartialEq, Eq, Hash, Clone, Copy, Default)]
    pub enum Transform {
        /// Identity transformation (plane is unaltered when applied)
        #[default]
        Normal,
        /// Plane is rotated by 90 degrees
        _90,
        /// Plane is rotated by 180 degrees
        _180,
        /// Plane is rotated by 270 degrees
        _270,
        /// Plane is flipped vertically
        Flipped,
        /// Plane is flipped vertically and rotated by 90 degrees
        Flipped90,
        /// Plane is flipped vertically and rotated by 180 degrees
        Flipped180,
        /// Plane is flipped vertically and rotated by 270 degrees
        Flipped270,
    }
}
