// SPDX-License-Identifier: GPL-3.0-or-later
// Not an upstream file. Upstream resolves key names by calling libxkbcommon
// (`xkb::keysym_from_name` with `KEYSYM_CASE_INSENSITIVE`); this crate replaces
// that one call with `platform::input::keyboard::xkb`. These checks drive the
// replacement through the config parser, the way a config file reaches it.
//
// The expected values pin libxkbcommon 1.7.0's rules as docs/crates/core/PORT.md records them.
// They are not a comparison against the C library.
use driftwm_core::config::{
    Action, Config, KeyCombo, ModKey, Modifiers, PassKeys, parse_key_combo,
};
use driftwm_core::platform::input::keyboard::{Keysym, ModifiersState, keysyms};

fn sym(name: &str) -> u32 {
    parse_key_combo(name, ModKey::Super)
        .unwrap_or_else(|e| panic!("{name:?} should resolve: {e}"))
        .sym
        .raw()
}

#[test]
fn key_names_match_ignoring_case() {
    assert_eq!(sym("Return"), keysyms::KEY_Return);
    assert_eq!(sym("return"), keysyms::KEY_Return);
    assert_eq!(sym("RETURN"), keysyms::KEY_Return);
    assert_eq!(sym("iso_left_tab"), keysyms::KEY_ISO_Left_Tab);
    assert_eq!(
        sym("xf86audioraisevolume"),
        keysyms::KEY_XF86AudioRaiseVolume
    );
    assert_eq!(sym("bracketleft"), keysyms::KEY_bracketleft);
    assert_eq!(sym("1"), keysyms::KEY_1);
}

/// Where two names differ only by case the lower-case one wins, whichever
/// spelling the config uses. `pass_keys` relies on it: it stores the parsed
/// combo without normalizing, and matches it against a normalized key press.
#[test]
fn the_lower_case_keysym_wins_a_case_collision() {
    assert_eq!(sym("q"), keysyms::KEY_q);
    assert_eq!(sym("Q"), keysyms::KEY_q);
    assert_eq!(sym("Aacute"), keysyms::KEY_aacute);
    assert_eq!(sym("ETH"), keysyms::KEY_eth);
    assert_eq!(sym("Eth"), keysyms::KEY_eth);
    assert_eq!(sym("Cyrillic_A"), keysyms::KEY_Cyrillic_a);
    assert_eq!(sym("Greek_OMEGA"), keysyms::KEY_Greek_omega);
    // Not letter pairs, but still one name in two cases: the lower-case
    // spelling is the one returned.
    assert_eq!(sym("dead_A"), keysyms::KEY_dead_a);
    assert_eq!(sym("kana_TSU"), keysyms::KEY_kana_tsu);
    assert_eq!(sym("XF86ScreenSaver"), keysyms::KEY_XF86Screensaver);
}

#[test]
fn alias_names_share_a_keysym() {
    assert_eq!(sym("Prior"), sym("Page_Up"));
    assert_eq!(sym("Next"), sym("Page_Down"));
    assert_eq!(sym("quoteright"), sym("apostrophe"));
    assert_eq!(sym("guillemotleft"), sym("guillemetleft"));
}

#[test]
fn legacy_xf86_underscore_spelling_resolves() {
    assert_eq!(sym("XF86_AudioMute"), keysyms::KEY_XF86AudioMute);
    assert_eq!(sym("xf86_audiomute"), keysyms::KEY_XF86AudioMute);
}

#[test]
fn numeric_key_names_resolve() {
    // U<hex>: a Unicode code point. Latin-1 maps to itself, the rest is offset.
    assert_eq!(sym("U41"), 0x41);
    assert_eq!(sym("u41"), 0x41);
    assert_eq!(sym("U20AC"), 0x0100_20ac);
    // 0x<hex>: the raw keysym value.
    assert_eq!(sym("0xff0d"), keysyms::KEY_Return);
    assert_eq!(sym("0XFF0D"), keysyms::KEY_Return);
}

#[test]
fn names_that_are_not_keysyms_are_rejected() {
    for name in [
        "NotAKey",
        "",
        "Re turn",
        "U1F",
        "U110000",
        "U-41",
        "U123456789",
        "0x",
        "0x20000000",
        "XF86_NoSuchKey",
        "NoSymbol",
        "日本語",
        // The xkbcommon binding upstream calls panics on a NUL; this is an error.
        "a\0",
    ] {
        let err =
            parse_key_combo(&format!("mod+{name}"), ModKey::Super).expect_err("should not resolve");
        assert_eq!(err, format!("unknown keysym: {name}"));
    }
}

#[test]
fn pass_keys_written_in_upper_case_matches_the_pressed_key() {
    let config = Config::from_toml(
        r#"
        [[window_rules]]
        app_id = "game"
        pass_keys = ["mod+Q", "ctrl+XF86_AudioMute"]
        "#,
    )
    .unwrap();
    let rule = config.resolve_window_rules("game", "").unwrap();

    // `Q` and `XF86_AudioMute` resolve to the table's `q` and `XF86AudioMute`
    // keysyms, with `mod` read as the default Super key.
    assert_eq!(
        rule.pass_keys,
        PassKeys::Only(vec![
            KeyCombo {
                modifiers: Modifiers {
                    logo: true,
                    ..Modifiers::EMPTY
                },
                sym: Keysym::from(keysyms::KEY_q),
            },
            KeyCombo {
                modifiers: Modifiers {
                    ctrl: true,
                    ..Modifiers::EMPTY
                },
                sym: Keysym::from(keysyms::KEY_XF86AudioMute),
            },
        ])
    );
}

#[test]
fn keybinding_names_from_a_config_file_resolve() {
    let (config, warnings) = Config::from_toml_collect(
        r#"
        [keybindings]
        "mod+PAGE_UP" = "zoom-in"
        "mod+0xff56" = "zoom-out"
        "mod+NotAKey" = "quit"
        "mod+a\u0000" = "quit"
        "#,
    )
    .unwrap();
    let logo = ModifiersState {
        logo: true,
        ..Default::default()
    };
    assert_eq!(
        config.lookup(&logo, Keysym::from(keysyms::KEY_Prior)),
        Some(&Action::ZoomIn)
    );
    assert_eq!(
        config.lookup(&logo, Keysym::from(keysyms::KEY_Next)),
        Some(&Action::ZoomOut)
    );
    // The file's keys arrive in no fixed order, so compare as a sorted list.
    // The second key carries a NUL, which upstream's xkbcommon binding panics on.
    let mut warnings = warnings;
    warnings.sort();
    assert_eq!(
        warnings,
        vec![
            "config: invalid key combo 'mod+NotAKey': unknown keysym: NotAKey".to_string(),
            "config: invalid key combo 'mod+a\0': unknown keysym: a\0".to_string(),
        ]
    );
}
