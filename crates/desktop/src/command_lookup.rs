// SPDX-License-Identifier: GPL-3.0-or-later
//! Identify simple commands so a user-authored `spawn` can avoid repeating a
//! failing launch when its executable is absent.
use driftwm_core::config::Action;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;

/// Where `sh` looks when there is no `PATH` at all.
const DEFAULT_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Words `sh` runs itself, so no file on `PATH` has to exist for them.
const SHELL_WORDS: &[&str] = &[
    ".", ":", "alias", "bg", "break", "case", "cd", "command", "continue", "echo", "eval", "exec",
    "exit", "export", "false", "fg", "for", "getopts", "hash", "if", "jobs", "kill", "printf",
    "pwd", "read", "readonly", "return", "set", "shift", "test", "time", "times", "trap", "true",
    "type", "ulimit", "umask", "unalias", "unset", "until", "wait", "while",
];

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
