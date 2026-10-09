// SPDX-License-Identifier: GPL-3.0-or-later
// New code. Upstream's default bindings (malbiruk/driftwm
// 352333a8fa1b22171492d4b71a54102045c9a19d, src/config/defaults.rs) run
// swaylock, wpctl, brightnessctl, playerctl and grim, which a Mac does not
// have. Nothing upstream decides what stands for them; this does.
//! What a default binding does when its Linux program is not installed.
use driftwm_core::config::Action;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;

/// What stands for upstream's `swaylock`: the displays go dark at once, and
/// macOS asks for the password according to the user's own Lock Screen
/// setting. macOS has no public command that locks whatever that setting says.
const LOCK: &str = "/usr/bin/pmset displaysleepnow";
/// `NX_KEYTYPE_*` of the keys macOS acts on by itself, by what they change.
const VOLUME_KEYS: [u8; 3] = [0, 1, 7];
const BRIGHTNESS_KEYS: [u8; 5] = [2, 3, 21, 22, 23];
/// Where `sh` looks when there is no `PATH` at all.
const DEFAULT_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Words `sh` runs itself, so no file on `PATH` has to exist for them.
const SHELL_WORDS: &[&str] = &[
    ".", ":", "alias", "bg", "break", "case", "cd", "command", "continue", "echo", "eval", "exec",
    "exit", "export", "false", "fg", "for", "getopts", "hash", "if", "jobs", "kill", "printf",
    "pwd", "read", "readonly", "return", "set", "shift", "test", "time", "times", "trap", "true",
    "type", "ulimit", "umask", "unalias", "unset", "until", "wait", "while",
];

/// What takes the place of a default binding whose program is missing.
pub(crate) enum Equivalent {
    /// A macOS command that does the same job.
    Substitute(Action),
    /// macOS already does the job on that key: nothing is registered.
    Platform(&'static str),
    Nothing,
}

/// The program an `exec` or `spawn` action starts, when its command begins
/// with a plain word: no assignment, quoting, expansion or shell syntax.
pub(crate) fn program(action: &Action) -> Option<&str> {
    let (Action::Exec(command) | Action::Spawn(command)) = action else {
        return None;
    };
    let word = command.split_whitespace().next()?;
    let plain = word
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "_-.+/".contains(c));
    (plain && !SHELL_WORDS.contains(&word)).then_some(word)
}

/// The directories an `exec` effect's `sh` searches: the config's own `PATH`
/// when its `[env]` sets one, else this process's.
pub(crate) struct SearchPath(OsString);
impl SearchPath {
    pub(crate) fn new(child_path: Option<&String>) -> Self {
        Self(
            child_path
                .map(OsString::from)
                .or_else(|| std::env::var_os("PATH"))
                .unwrap_or_else(|| DEFAULT_PATH.into()),
        )
    }
    /// Would `sh` find `program`? An absolute path is looked at directly, and
    /// a relative one is taken as found: where it is run from is the shell's.
    pub(crate) fn finds(&self, program: &str) -> bool {
        let executable = |path: &std::path::Path| {
            std::fs::metadata(path)
                .is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
        };
        if program.contains('/') {
            return !program.starts_with('/') || executable(program.as_ref());
        }
        std::env::split_paths(&self.0)
            .filter(|directory| directory.is_absolute())
            .any(|directory| executable(&directory.join(program)))
    }
}

/// What stands for a default binding that runs the missing `program`, on a
/// media key of type `media_key` or on an ordinary key.
pub(crate) fn equivalent(program: &str, media_key: Option<u8>) -> Equivalent {
    match media_key {
        Some(key) if VOLUME_KEYS.contains(&key) => {
            Equivalent::Platform("macOS handles the volume keys itself")
        }
        Some(key) if BRIGHTNESS_KEYS.contains(&key) => {
            Equivalent::Platform("macOS handles the brightness keys itself")
        }
        Some(_) => Equivalent::Platform("macOS handles the media keys itself"),
        // `exec`, not upstream's `spawn`: a held chord must not ask for the
        // lock again at the repeat rate.
        None if program == "swaylock" => Equivalent::Substitute(Action::Exec(LOCK.to_owned())),
        None => Equivalent::Nothing,
    }
}
