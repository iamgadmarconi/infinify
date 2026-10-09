// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/config/mod.rs (Config::lookup, tap_lookup and the mouse_*_lookup_ctx
// lookups), src/config/types.rs (ContextBindings::lookup: the pointer's own
// context before `anywhere`) and src/input/pointer.rs (how a button press and
// an axis event choose their context and trigger). The bindings themselves are
// driftwm-core's, upstream's own code. The macOS modifier and key mapping below
// is new.
//! Upstream bindings as macOS chords.
//!
//! Upstream modifiers are `ctrl`, `alt`, `shift`, `logo` (written `super`, and
//! `mod` when `mod_key = "super"`, the default) and `mod3`. On macOS:
//!
//! - `ctrl` is Control, `alt` is Option, `shift` is Shift.
//! - `logo` is a physical chord, Control+Option unless `set_platform` chooses
//!   another subset of Control, Option and Command.
//! - A binding that holds `logo` together with a modifier the chord already
//!   contains would vanish into the chord, so that modifier is displaced:
//!   `ctrl` becomes Command, `alt` becomes Command+Shift. When the chord itself
//!   contains Command there is nowhere to displace to and the binding is skipped.
//! - `mod3` has no macOS equivalent: such bindings are skipped.
//!
//! The mapping is not one to one, so two bindings can land on one chord. Sorted
//! by upstream combo text, the first keeps the chord and the rest are reported.
//! Control+Option+Escape is the shell's exit chord unless a binding claims it.
//!
//! A default binding that runs a program this Mac does not have is replaced by
//! its macOS equivalent or left out; see `default_commands`.
use super::actions::{action_string, runs_here};
use super::default_commands::{Equivalent, SearchPath, equivalent, program};
use super::*;
use driftwm_core::config::{
    Action, BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, Config, ModKey, Modifiers, MouseAction, MouseBinding,
    MouseTrigger,
};
use driftwm_core::platform::backend::input::AxisSource;
use driftwm_core::platform::input::keyboard::{Keysym, ModifiersState, keysyms as sym};

/// Linux input codes of the two side buttons. Upstream's mouse grammar names
/// only left, right and middle, so nothing can be bound to these yet.
const BTN_SIDE: u32 = 0x113;
const BTN_EXTRA: u32 = 0x114;
/// `kVK_Escape`, the key of the shell's exit chord.
const EXIT_KEY_CODE: u16 = 0x35;

/// The physical modifiers of a macOS chord.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MacModifiers {
    #[serde(default)]
    pub control: bool,
    #[serde(default)]
    pub option: bool,
    #[serde(default)]
    pub shift: bool,
    #[serde(default)]
    pub command: bool,
}
impl MacModifiers {
    /// The chord as macOS menus write it.
    fn symbols(self) -> String {
        [
            (self.control, '⌃'),
            (self.option, '⌥'),
            (self.shift, '⇧'),
            (self.command, '⌘'),
        ]
        .into_iter()
        .filter_map(|(held, symbol)| held.then_some(symbol))
        .collect()
    }
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerTrigger {
    Left,
    Right,
    Middle,
    Back,
    Forward,
    Scroll,
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrollSource {
    Finger,
    Wheel,
    Continuous,
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerContext {
    Window,
    Canvas,
}

/// The physical chord that stands for upstream's `logo` modifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Platform {
    chord: MacModifiers,
}
impl Default for Platform {
    fn default() -> Self {
        Self {
            chord: MacModifiers {
                control: true,
                option: true,
                ..MacModifiers::default()
            },
        }
    }
}
impl Platform {
    /// A `+`-joined, non-empty subset of `ctrl`, `alt` and `cmd`.
    pub(crate) fn parse(text: &str) -> Result<Self, String> {
        let mut chord = MacModifiers::default();
        for part in text.split('+') {
            match part.trim().to_lowercase().as_str() {
                "ctrl" => chord.control = true,
                "alt" => chord.option = true,
                "cmd" => chord.command = true,
                _ => {
                    return Err(format!(
                        "invalid super chord '{text}': expected a +-joined subset of ctrl, alt, cmd"
                    ));
                }
            }
        }
        Ok(Self { chord })
    }
    pub(crate) fn super_text(self) -> String {
        [
            (self.chord.control, "ctrl"),
            (self.chord.option, "alt"),
            (self.chord.command, "cmd"),
        ]
        .into_iter()
        .filter_map(|(held, name)| held.then_some(name))
        .collect::<Vec<_>>()
        .join("+")
    }
    /// The macOS chord of an upstream modifier set, or why it has none.
    fn physical(self, modifiers: &Modifiers) -> Result<MacModifiers, String> {
        if modifiers.mod3 {
            return Err("macOS has no Mod3 modifier".to_owned());
        }
        let mut chord = MacModifiers {
            control: modifiers.ctrl,
            option: modifiers.alt,
            shift: modifiers.shift,
            command: false,
        };
        if !modifiers.logo {
            return Ok(chord);
        }
        // A modifier the chord already holds cannot also be held on its own.
        let (ctrl, alt) = (
            modifiers.ctrl && self.chord.control,
            modifiers.alt && self.chord.option,
        );
        if (ctrl || alt) && self.chord.command {
            return Err(format!(
                "super is {}: it holds {} and Command, so nothing is left to stand for {} on its own",
                self.super_text(),
                if ctrl { "ctrl" } else { "alt" },
                if ctrl { "ctrl" } else { "alt" },
            ));
        }
        chord.control |= self.chord.control;
        chord.option |= self.chord.option;
        chord.command = self.chord.command || ctrl || alt;
        // Displaced alt takes Shift with it, which keeps it apart from displaced ctrl.
        chord.shift |= alt;
        Ok(chord)
    }
}

/// Where a keysym lives on a Mac keyboard.
#[derive(Clone, Copy)]
enum Place {
    /// A printable key: its US ANSI virtual key code and the character it types
    /// unshifted, which the shell looks up in the current keyboard layout.
    Ansi(u16, char),
    /// A key that is the same in every layout: its virtual key code.
    Code(u16),
    /// A media key: its `NX_KEYTYPE_*`. Not a virtual key code, so it cannot be
    /// a Carbon hot key.
    Media(u8),
    /// No Mac key.
    Nowhere,
}
struct Key {
    sym: u32,
    name: &'static str,
    place: Place,
}
const fn ansi(name: &'static str, character: char, code: u16) -> Key {
    // A Latin-1 keysym is its own code point.
    Key {
        sym: character as u32,
        name,
        place: Place::Ansi(code, character),
    }
}
const fn code(name: &'static str, sym: u32, code: u16) -> Key {
    Key {
        sym,
        name,
        place: Place::Code(code),
    }
}
const fn media(name: &'static str, sym: u32, key_type: u8) -> Key {
    Key {
        sym,
        name,
        place: Place::Media(key_type),
    }
}
const fn nowhere(name: &'static str, sym: u32) -> Key {
    Key {
        sym,
        name,
        place: Place::Nowhere,
    }
}
/// Every keysym a binding can be registered on, with upstream's key name, plus
/// the keysyms of upstream's default bindings that have no Mac key. Virtual key
/// codes are HIToolbox `Events.h` `kVK_*`; media key types are IOKit
/// `ev_keymap.h` `NX_KEYTYPE_*`. Letters are lowercase: upstream folds case.
const KEYS: &[Key] = &[
    ansi("a", 'a', 0x00),
    ansi("s", 's', 0x01),
    ansi("d", 'd', 0x02),
    ansi("f", 'f', 0x03),
    ansi("h", 'h', 0x04),
    ansi("g", 'g', 0x05),
    ansi("z", 'z', 0x06),
    ansi("x", 'x', 0x07),
    ansi("c", 'c', 0x08),
    ansi("v", 'v', 0x09),
    ansi("b", 'b', 0x0B),
    ansi("q", 'q', 0x0C),
    ansi("w", 'w', 0x0D),
    ansi("e", 'e', 0x0E),
    ansi("r", 'r', 0x0F),
    ansi("y", 'y', 0x10),
    ansi("t", 't', 0x11),
    ansi("1", '1', 0x12),
    ansi("2", '2', 0x13),
    ansi("3", '3', 0x14),
    ansi("4", '4', 0x15),
    ansi("6", '6', 0x16),
    ansi("5", '5', 0x17),
    ansi("equal", '=', 0x18),
    ansi("9", '9', 0x19),
    ansi("7", '7', 0x1A),
    ansi("minus", '-', 0x1B),
    ansi("8", '8', 0x1C),
    ansi("0", '0', 0x1D),
    ansi("bracketright", ']', 0x1E),
    ansi("o", 'o', 0x1F),
    ansi("u", 'u', 0x20),
    ansi("bracketleft", '[', 0x21),
    ansi("i", 'i', 0x22),
    ansi("p", 'p', 0x23),
    ansi("l", 'l', 0x25),
    ansi("j", 'j', 0x26),
    ansi("apostrophe", '\'', 0x27),
    ansi("k", 'k', 0x28),
    ansi("semicolon", ';', 0x29),
    ansi("backslash", '\\', 0x2A),
    ansi("comma", ',', 0x2B),
    ansi("slash", '/', 0x2C),
    ansi("n", 'n', 0x2D),
    ansi("m", 'm', 0x2E),
    ansi("period", '.', 0x2F),
    ansi("grave", '`', 0x32),
    code("Return", sym::KEY_Return, 0x24),
    code("Tab", sym::KEY_Tab, 0x30),
    code("space", sym::KEY_space, 0x31),
    code("BackSpace", sym::KEY_BackSpace, 0x33),
    code("Escape", sym::KEY_Escape, 0x35),
    code("Delete", sym::KEY_Delete, 0x75),
    code("Home", sym::KEY_Home, 0x73),
    code("End", sym::KEY_End, 0x77),
    code("Page_Up", sym::KEY_Page_Up, 0x74),
    code("Page_Down", sym::KEY_Page_Down, 0x79),
    code("Left", sym::KEY_Left, 0x7B),
    code("Right", sym::KEY_Right, 0x7C),
    code("Down", sym::KEY_Down, 0x7D),
    code("Up", sym::KEY_Up, 0x7E),
    // A PC keyboard's Insert key is the Mac's Help key.
    code("Help", sym::KEY_Help, 0x72),
    code("Insert", sym::KEY_Insert, 0x72),
    code("Menu", sym::KEY_Menu, 0x6E),
    code("F1", sym::KEY_F1, 0x7A),
    code("F2", sym::KEY_F2, 0x78),
    code("F3", sym::KEY_F3, 0x63),
    code("F4", sym::KEY_F4, 0x76),
    code("F5", sym::KEY_F5, 0x60),
    code("F6", sym::KEY_F6, 0x61),
    code("F7", sym::KEY_F7, 0x62),
    code("F8", sym::KEY_F8, 0x64),
    code("F9", sym::KEY_F9, 0x65),
    code("F10", sym::KEY_F10, 0x6D),
    code("F11", sym::KEY_F11, 0x67),
    code("F12", sym::KEY_F12, 0x6F),
    code("F13", sym::KEY_F13, 0x69),
    code("F14", sym::KEY_F14, 0x6B),
    code("F15", sym::KEY_F15, 0x71),
    code("F16", sym::KEY_F16, 0x6A),
    code("F17", sym::KEY_F17, 0x40),
    code("F18", sym::KEY_F18, 0x4F),
    code("F19", sym::KEY_F19, 0x50),
    code("F20", sym::KEY_F20, 0x5A),
    code("KP_0", sym::KEY_KP_0, 0x52),
    code("KP_1", sym::KEY_KP_1, 0x53),
    code("KP_2", sym::KEY_KP_2, 0x54),
    code("KP_3", sym::KEY_KP_3, 0x55),
    code("KP_4", sym::KEY_KP_4, 0x56),
    code("KP_5", sym::KEY_KP_5, 0x57),
    code("KP_6", sym::KEY_KP_6, 0x58),
    code("KP_7", sym::KEY_KP_7, 0x59),
    code("KP_8", sym::KEY_KP_8, 0x5B),
    code("KP_9", sym::KEY_KP_9, 0x5C),
    code("KP_Decimal", sym::KEY_KP_Decimal, 0x41),
    code("KP_Multiply", sym::KEY_KP_Multiply, 0x43),
    code("KP_Add", sym::KEY_KP_Add, 0x45),
    code("KP_Subtract", sym::KEY_KP_Subtract, 0x4E),
    code("KP_Divide", sym::KEY_KP_Divide, 0x4B),
    code("KP_Enter", sym::KEY_KP_Enter, 0x4C),
    code("KP_Equal", sym::KEY_KP_Equal, 0x51),
    // The Mac keypad has Clear where a PC keypad has Num Lock.
    code("Clear", sym::KEY_Clear, 0x47),
    code("Num_Lock", sym::KEY_Num_Lock, 0x47),
    media("XF86AudioRaiseVolume", sym::KEY_XF86AudioRaiseVolume, 0),
    media("XF86AudioLowerVolume", sym::KEY_XF86AudioLowerVolume, 1),
    media("XF86MonBrightnessUp", sym::KEY_XF86MonBrightnessUp, 2),
    media("XF86MonBrightnessDown", sym::KEY_XF86MonBrightnessDown, 3),
    media("XF86AudioMute", sym::KEY_XF86AudioMute, 7),
    media("XF86Eject", sym::KEY_XF86Eject, 14),
    media("XF86AudioPlay", sym::KEY_XF86AudioPlay, 16),
    media("XF86AudioNext", sym::KEY_XF86AudioNext, 17),
    media("XF86AudioPrev", sym::KEY_XF86AudioPrev, 18),
    media("XF86AudioForward", sym::KEY_XF86AudioForward, 19),
    media("XF86AudioRewind", sym::KEY_XF86AudioRewind, 20),
    media("XF86KbdBrightnessUp", sym::KEY_XF86KbdBrightnessUp, 21),
    media("XF86KbdBrightnessDown", sym::KEY_XF86KbdBrightnessDown, 22),
    media("XF86KbdLightOnOff", sym::KEY_XF86KbdLightOnOff, 23),
    // Bound by upstream's defaults, absent from a Mac keyboard.
    nowhere("XF86AudioPause", sym::KEY_XF86AudioPause),
    nowhere("XF86AudioStop", sym::KEY_XF86AudioStop),
    nowhere("Print", sym::KEY_Print),
];
pub(crate) fn key_known(keysym: u32) -> bool {
    KEYS.iter().any(|key| key.sym == keysym)
}

/// The 32 modifier sets a binding can hold.
fn modifier_sets() -> impl Iterator<Item = Modifiers> {
    (0..32u8).map(|bits| Modifiers {
        ctrl: bits & 1 != 0,
        alt: bits & 2 != 0,
        shift: bits & 4 != 0,
        logo: bits & 8 != 0,
        mod3: bits & 16 != 0,
    })
}
fn state(modifiers: &Modifiers) -> ModifiersState {
    ModifiersState {
        ctrl: modifiers.ctrl,
        alt: modifiers.alt,
        shift: modifiers.shift,
        logo: modifiers.logo,
        iso_level5_shift: modifiers.mod3,
        ..ModifiersState::default()
    }
}
/// A modifier set followed by a key or trigger name, as a config file spells
/// it: the mod key's own modifier is `mod`, the others keep their names.
fn combo_text(modifiers: &Modifiers, mod_key: ModKey, last: Option<&str>) -> String {
    let base = |key: ModKey| mod_key == key;
    [
        (
            match mod_key {
                ModKey::Alt => modifiers.alt,
                ModKey::Super => modifiers.logo,
                ModKey::Mod3 => modifiers.mod3,
            },
            "mod",
        ),
        (modifiers.ctrl, "ctrl"),
        (modifiers.alt && !base(ModKey::Alt), "alt"),
        (modifiers.shift, "shift"),
        (modifiers.logo && !base(ModKey::Super), "super"),
        (modifiers.mod3 && !base(ModKey::Mod3), "mod3"),
    ]
    .into_iter()
    .filter_map(|(held, name)| held.then_some(name))
    .chain(last)
    .collect::<Vec<_>>()
    .join("+")
}
/// The defaults upstream builds for one mod key: a binding found here is
/// upstream's, not the user's.
fn defaults(mod_key: ModKey) -> Config {
    let name = match mod_key {
        ModKey::Alt => "alt",
        ModKey::Super => "super",
        ModKey::Mod3 => "mod3",
    };
    Config::from_toml(&format!("mod_key = \"{name}\"")).unwrap_or_default()
}
/// One key binding found in the config.
struct Bound<'a> {
    combo: String,
    modifiers: Modifiers,
    sym: u32,
    place: Place,
    action: &'a Action,
}

impl Controller {
    /// Every key binding of the config. Its table is private to driftwm-core,
    /// so each known keysym is asked for under each modifier set. Sorted by
    /// combo text, which makes upstream's unordered table deterministic.
    fn key_bindings(&self) -> Vec<Bound<'_>> {
        let config = self.config();
        let extra = self.settings.extra_keysyms.iter().map(|(sym, name)| {
            (
                *sym,
                name.as_str(),
                // A keysym outside the key table has no Mac key by definition.
                Place::Nowhere,
            )
        });
        let mut bound = Vec::new();
        for (sym, name, place) in KEYS
            .iter()
            .map(|key| (key.sym, key.name, key.place))
            .chain(extra)
        {
            for modifiers in modifier_sets() {
                if let Some(action) = config.lookup(&state(&modifiers), Keysym::from(sym)) {
                    bound.push(Bound {
                        combo: combo_text(&modifiers, config.mod_key, Some(name)),
                        modifiers,
                        sym,
                        place,
                        action,
                    });
                }
            }
        }
        bound.sort_by(|a, b| a.combo.cmp(&b.combo).then(a.sym.cmp(&b.sym)));
        bound
    }
    /// What the pointer gestures need from `[navigation]` and `[zoom]`, named as
    /// upstream's `Config` fields. JSON has no infinity, so each is bounded.
    /// Upstream pans a scroll by `trackpad_speed` and a drag by `mouse_speed`,
    /// zooms a wheel by `zoom_step ^ (-v / 30 * zoom_mouse_speed)`, and scales
    /// a pinch by `zoom_trackpad_speed`.
    fn pointer_settings(&self) -> Value {
        let config = self.config();
        let finite = |value: f64| value.min(1e9);
        json!({
            "trackpad_speed":finite(config.trackpad_speed),
            "mouse_speed":finite(config.mouse_speed),
            "zoom_step":finite(config.zoom_step),
            "zoom_mouse_speed":finite(config.zoom_mouse_speed),
            "zoom_trackpad_speed":finite(config.zoom_trackpad_speed),
        })
    }
    /// The key bindings as macOS chords, for the shell to register, and each
    /// registered output's hot corners, for it to watch.
    pub(crate) fn bindings(&self) -> Value {
        let config = self.config();
        let defaults = defaults(config.mod_key);
        let path = SearchPath::new(config.child_env.get("PATH"));
        let (mut keys, mut media_keys, mut skipped, mut warnings, mut unrepeated) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let mut skip = |combo: &str, action: &Action, reason: String, warn: bool| {
            let action = action_string(action);
            if warn {
                warnings.push(format!("binding '{combo}' = '{action}' skipped: {reason}"));
            }
            skipped.push(json!({"combo":combo,"action":action,"reason":reason}));
        };
        // (media key?, code, chord) to the combo that holds it.
        let mut claimed: BTreeMap<(bool, u16, MacModifiers), String> = BTreeMap::new();
        for bound in self.key_bindings() {
            let (media_key, key) = match bound.place {
                Place::Ansi(key, _) | Place::Code(key) => (None, key),
                Place::Media(key_type) => (Some(key_type), u16::from(key_type)),
                Place::Nowhere => {
                    // Upstream's own defaults on keys a Mac lacks are listed
                    // without a warning: the user did not ask for them.
                    let default = defaults
                        .lookup(&state(&bound.modifiers), Keysym::from(bound.sym))
                        == Some(bound.action);
                    skip(
                        &bound.combo,
                        bound.action,
                        "the key has no macOS equivalent".to_owned(),
                        !default,
                    );
                    continue;
                }
            };
            // A program `sh` would not find: a default is then replaced by its
            // macOS equivalent or left out, and what the file wrote stays as
            // written, but must not start a failing shell at the repeat rate.
            let missing = program(bound.action).filter(|program| !path.finds(program));
            let is_media = media_key.is_some();
            let substitute = match missing {
                Some(program) if !self.settings.wrote(&bound.modifiers, bound.sym) => {
                    match equivalent(program, media_key) {
                        Equivalent::Substitute(action) => Some(action),
                        Equivalent::Platform(reason) => {
                            skip(&bound.combo, bound.action, reason.to_owned(), false);
                            continue;
                        }
                        Equivalent::Nothing => {
                            let reason =
                                format!("'{program}' is not installed and has no macOS equivalent");
                            skip(&bound.combo, bound.action, reason, false);
                            continue;
                        }
                    }
                }
                _ => None,
            };
            let action = substitute.as_ref().unwrap_or(bound.action);
            let chord = match self.platform.physical(&bound.modifiers) {
                Ok(chord) => chord,
                Err(reason) => {
                    skip(&bound.combo, action, reason, true);
                    continue;
                }
            };
            if let Some(winner) = claimed.get(&(is_media, key, chord)) {
                let reason = format!("'{winner}' already holds this macOS chord");
                skip(&bound.combo, action, reason, true);
                continue;
            }
            claimed.insert((is_media, key, chord), bound.combo.clone());
            let stalled = missing.filter(|_| substitute.is_none() && action.is_repeatable());
            if let Some(program) = stalled {
                unrepeated.push(format!(
                    "binding '{}' = '{}': '{program}' was not found, so it will not repeat while held",
                    bound.combo,
                    action_string(action)
                ));
            }
            let mut entry = json!({
                "modifiers":chord,
                "action":action_string(action),
                "combo":bound.combo,
                "chord":format!("{}{}", chord.symbols(), key_label(bound.sym)),
                "repeat":action.is_repeatable() && stalled.is_none(),
                "implemented":runs_here(action),
            });
            if substitute.is_some() {
                entry["upstream"] = json!(action_string(bound.action));
            }
            if is_media {
                entry["nx_key_type"] = json!(key);
                media_keys.push(entry);
            } else {
                entry["key_code"] = json!(key);
                entry["character"] = match bound.place {
                    Place::Ansi(_, character) => json!(character),
                    _ => Value::Null,
                };
                keys.push(entry);
            }
        }
        // A bare modifier chord cannot be a hot key.
        for modifiers in modifier_sets() {
            if let Some(action) = config.tap_lookup(&modifiers) {
                skip(
                    &combo_text(&modifiers, config.mod_key, None),
                    action,
                    "tap-modifier bindings are not supported on macOS".to_owned(),
                    true,
                );
            }
        }
        let exit = MacModifiers {
            control: true,
            option: true,
            ..MacModifiers::default()
        };
        warnings.extend(unrepeated);
        json!({
            "keys":keys,
            "media_keys":media_keys,
            "skipped":skipped,
            "hot_corners":self.hot_corners(),
            "reserved":[{"purpose":"exit","key_code":EXIT_KEY_CODE,"modifiers":exit,"claimed_by":claimed.get(&(false, EXIT_KEY_CODE, exit))}],
            "layout_independent":config.layout_independent,
            "repeat_delay_ms":config.repeat_delay,
            "repeat_rate_hz":config.repeat_rate,
            "super":self.platform.super_text(),
            // The physical modifiers that hold an Alt-Tab cycle open, or null
            // when upstream's set has no macOS chord.
            "cycle_hold":self.platform.physical(&config.cycle_hold).ok(),
            "settings":self.pointer_settings(),
            "warnings":warnings,
        })
    }
    /// Upstream's pointer binding lookup for a physical macOS chord. The chord
    /// may stand for more than one upstream modifier set. As
    /// `ContextBindings::lookup` prefers the pointer's own context over
    /// `anywhere`, every set is tried in combo order in the pointer's own
    /// context table before any is tried in `anywhere`.
    pub(crate) fn mouse_binding(
        &self,
        trigger: PointerTrigger,
        source: Option<ScrollSource>,
        modifiers: MacModifiers,
        context: PointerContext,
    ) -> Value {
        let config = self.config();
        let (trigger, name) = match trigger {
            PointerTrigger::Left => (MouseTrigger::Button(BTN_LEFT), "left"),
            PointerTrigger::Right => (MouseTrigger::Button(BTN_RIGHT), "right"),
            PointerTrigger::Middle => (MouseTrigger::Button(BTN_MIDDLE), "middle"),
            PointerTrigger::Back => (MouseTrigger::Button(BTN_SIDE), "back"),
            PointerTrigger::Forward => (MouseTrigger::Button(BTN_EXTRA), "forward"),
            // Upstream: a finger scrolls as the trackpad, every other source as a wheel.
            PointerTrigger::Scroll => match source {
                Some(ScrollSource::Finger) => (
                    MouseTrigger::for_axis_source(AxisSource::Finger),
                    "trackpad-scroll",
                ),
                Some(ScrollSource::Continuous) => (
                    MouseTrigger::for_axis_source(AxisSource::Continuous),
                    "wheel-scroll",
                ),
                Some(ScrollSource::Wheel) | None => (
                    MouseTrigger::for_axis_source(AxisSource::Wheel),
                    "wheel-scroll",
                ),
            },
        };
        let own = match context {
            PointerContext::Window => &config.mouse.on_window,
            PointerContext::Canvas => &config.mouse.on_canvas,
        };
        let mut candidates: Vec<_> = modifier_sets()
            .filter(|set| self.platform.physical(set) == Ok(modifiers))
            .map(|set| (combo_text(&set, config.mod_key, Some(name)), set))
            .collect();
        candidates.sort_by(|a, b| a.0.cmp(&b.0));
        let found = [own, &config.mouse.anywhere].into_iter().find_map(|table| {
            candidates.iter().find_map(|(combo, set)| {
                let key = MouseBinding {
                    modifiers: set.clone(),
                    trigger: trigger.clone(),
                };
                Some((combo, table.get(&key)?))
            })
        });
        let binding = found.map(|(combo, bound)| {
            let (kind, action) = match bound {
                MouseAction::MoveWindow => ("move_window", None),
                MouseAction::MoveSnappedWindows => ("move_snapped_windows", None),
                MouseAction::ResizeWindow => ("resize_window", None),
                MouseAction::ResizeWindowSnapped => ("resize_window_snapped", None),
                MouseAction::PanViewport => ("pan_viewport", None),
                MouseAction::Zoom => ("zoom", None),
                MouseAction::CenterNearest => ("center_nearest", None),
                MouseAction::Action(action) => ("action", Some(action)),
            };
            let mut binding = json!({
                "kind":kind,
                "action":action.map(action_string),
                "combo":combo,
                "implemented":action.map(runs_here),
            });
            // The speeds the bound gesture scales by ride along with it.
            if let (Some(binding), Value::Object(settings)) =
                (binding.as_object_mut(), self.pointer_settings())
            {
                binding.extend(settings);
            }
            binding
        });
        json!({"binding":binding})
    }
}
/// The key of a chord as a person reads it.
fn key_label(keysym: u32) -> String {
    match KEYS.iter().find(|key| key.sym == keysym) {
        Some(Key {
            place: Place::Ansi(_, character),
            ..
        }) => character.to_uppercase().collect(),
        Some(key) => key.name.to_owned(),
        None => format!("0x{keysym:x}"),
    }
}
