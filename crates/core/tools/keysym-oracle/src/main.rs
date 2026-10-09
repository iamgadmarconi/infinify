// SPDX-License-Identifier: GPL-3.0-or-later
// Not an upstream file, and not part of the driftwm-core build. Compares
// `driftwm_core::platform::input::keyboard::xkb::keysym_from_name` with
// `xkbcommon_rs::keysym::keysym_from_name` (xkbcommon-rs 0.1.2, a Rust port of
// libxkbcommon 1.7.0) and prints every input on which they disagree.

use std::collections::BTreeMap;
use std::panic;

use driftwm_core::platform::input::keyboard::{Keysym, xkb};
use xkbcommon_rs::keysym::{KeysymFlags, keysym_from_name};

const KEYSYMS_RS: &str = include_str!("../../../src/platform/input/keyboard/keysyms.rs");

/// What the port answers: the raw keysym, 0 for "no such name".
fn ours(name: &str, icase: bool) -> u32 {
    let flags = if icase {
        xkb::KEYSYM_CASE_INSENSITIVE
    } else {
        xkb::KEYSYM_NO_FLAGS
    };
    xkb::keysym_from_name(name, flags).raw()
}

/// What xkbcommon-rs answers, or `None` if it panicked.
fn theirs(name: &str, icase: bool) -> Option<u32> {
    let flags = if icase {
        KeysymFlags::CASE_INSENSITIVE
    } else {
        KeysymFlags::NO_FLAGS
    };
    panic::catch_unwind(|| keysym_from_name(name, flags).map_or(0, |k| k.raw())).ok()
}

fn swap_case(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_lowercase() {
                c.to_ascii_uppercase()
            } else {
                c.to_ascii_lowercase()
            }
        })
        .collect()
}

/// Small deterministic generator, so the run is reproducible without a
/// dependency.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }
}

fn main() {
    panic::set_hook(Box::new(|_| {}));

    let names: Vec<&str> = KEYSYMS_RS
        .lines()
        .filter_map(|l| l.strip_prefix("pub const KEY_"))
        .filter_map(|l| l.split_once(':').map(|(name, _)| name))
        .collect();

    let mut corpus: Vec<(&'static str, String)> = Vec::new();
    for name in &names {
        let mut flipped = name.to_string();
        if let Some(first) = flipped.get(..1) {
            let f = swap_case(first);
            flipped.replace_range(..1, &f);
        }
        for spelling in [
            name.to_string(),
            name.to_ascii_lowercase(),
            name.to_ascii_uppercase(),
            swap_case(name),
            flipped,
        ] {
            corpus.push(("table name spellings", spelling));
        }
        // Near misses: one character more, one fewer, legacy underscore.
        corpus.push(("near misses", format!("{name}_")));
        corpus.push(("near misses", format!("_{name}")));
        corpus.push(("near misses", name[..name.len() - 1].to_string()));
        if let Some(rest) = name.strip_prefix("XF86") {
            corpus.push(("legacy XF86_ spellings", format!("XF86_{rest}")));
            corpus.push(("legacy XF86_ spellings", format!("xf86_{rest}")));
            corpus.push(("legacy XF86_ spellings", format!("XF86__{rest}")));
        }
    }

    for s in [
        "",
        " ",
        "U",
        "u",
        "U41",
        "u41",
        "U0041",
        "U00000041",
        "U000000041",
        "U20AC",
        "u20ac",
        "U20ac",
        "U1F",
        "U20",
        "U7E",
        "U7F",
        "U9F",
        "UA0",
        "UFF",
        "U100",
        "U10FFFF",
        "U110000",
        "UFFFFFFFF",
        "U123456789",
        "U+41",
        "U 41",
        "U-41",
        "U0x41",
        "U41 ",
        "Ug",
        "0x",
        "0X",
        "0x41",
        "0X41",
        "0xff0d",
        "0XFF0D",
        "0x1fffffff",
        "0x20000000",
        "0xffffffff",
        "0x123456789",
        "0xg",
        "0x 41",
        "0x+41",
        "0",
        "00x41",
        "x41",
        "XF86",
        "XF86_",
        "xf86_",
        "XF86__",
        "XF86_NoSuchKey",
        "XF86NoSuchKey",
        "Return ",
        " Return",
        "Re turn",
        "return",
        "RETURN",
        "NoSymbol",
        "nosymbol",
        "VoidSymbol",
        "hpYdiaeresis",
        "HPYDIAERESIS",
        "mod",
        "ctrl",
        "shift",
        "alt",
        "super",
        "logo",
        "control",
        "mod3",
        "left",
        "right",
        "middle",
        "+",
        "-",
        "plus",
        "minus",
        "é",
        "É",
        "\u{212a}",
        "\u{17f}",
        "\u{ff31}",
        "a\u{301}",
        "\u{130}",
        "Ω",
        "ω",
        "Returñ",
        "XF86é",
        "Ué",
        "0xé",
        "日本語",
    ] {
        corpus.push(("hand-picked", s.to_string()));
    }

    // Random short identifiers, to walk the binary search off the table names.
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    let mut rng = Lcg(0x5eed);
    for _ in 0..300_000 {
        let len = 1 + (rng.next() % 6) as usize;
        let s: String = (0..len)
            .map(|_| ALPHABET[(rng.next() % ALPHABET.len() as u64) as usize] as char)
            .collect();
        corpus.push(("random identifiers", s));
    }
    // Random hex-ish strings behind the numeric prefixes.
    const HEXISH: &[u8] = b"0123456789abcdefABCDEFgx+- ";
    for _ in 0..100_000 {
        let prefix = ["U", "u", "0x", "0X"][(rng.next() % 4) as usize];
        let len = (rng.next() % 10) as usize;
        let s: String = (0..len)
            .map(|_| HEXISH[(rng.next() % HEXISH.len() as u64) as usize] as char)
            .collect();
        corpus.push(("random numeric forms", format!("{prefix}{s}")));
    }

    let mut compared: BTreeMap<&str, usize> = BTreeMap::new();
    let mut mismatches: Vec<String> = Vec::new();
    for (class, input) in &corpus {
        for icase in [false, true] {
            *compared.entry(class).or_default() += 1;
            let a = ours(input, icase);
            let b = theirs(input, icase);
            if b != Some(a) {
                let b = b.map_or("panic".to_string(), |v| format!("{v:#x}"));
                mismatches.push(format!(
                    "[{class}] {input:?} icase={icase}: driftwm-core {a:#x}, xkbcommon-rs {b}"
                ));
            }
        }
    }

    // Names that differ only by case. Where the members are one character in
    // two cases the contract is "lower case wins"; list the groups where they
    // are not, since there the answer is only what the table order gives.
    let mut groups: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for name in &names {
        groups
            .entry(name.to_ascii_lowercase())
            .or_default()
            .push(name);
    }
    groups.retain(|_, members| members.len() > 1);
    let unrelated: Vec<String> = groups
        .values()
        .filter(|members| {
            let winner = Keysym::new(ours(members[0], true));
            let Some(lower) = winner.key_char() else {
                return true;
            };
            !members.iter().all(|m| {
                Keysym::new(ours(m, false))
                    .key_char()
                    .is_some_and(|c| c == lower || c.to_lowercase().eq([lower]))
            })
        })
        .map(|members| format!("{} -> {:#x}", members.join("/"), ours(members[0], true)))
        .collect();
    println!("names differing only by case: {} groups", groups.len());
    println!(
        "  of which not one character in two cases: {}",
        unrelated.len()
    );
    for g in &unrelated {
        println!("    {g}");
    }

    println!("table names: {}", names.len());
    for (class, n) in &compared {
        println!("compared {n:>7} lookups: {class}");
    }
    println!("mismatches: {}", mismatches.len());
    for m in &mismatches {
        println!("  {m}");
    }
}
