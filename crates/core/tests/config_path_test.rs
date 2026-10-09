// SPDX-License-Identifier: GPL-3.0-or-later
// Not an upstream file (upstream has no test for `config_path`). Checks the one
// behaviour this port changes on purpose: the config file lives in the
// `infinify` directory. The precedence around it is upstream's.
//
// One test function, in its own test binary: it edits the process environment,
// which nothing else may read meanwhile.
use std::path::PathBuf;

use driftwm_core::config::{CONFIG_DIR_NAME, config_path};

fn set(key: &str, value: Option<&str>) {
    // SAFETY: this binary runs a single test, so no other thread touches the
    // environment while it is being changed.
    unsafe {
        match value {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
    }
}

#[test]
fn config_file_location_follows_upstream_precedence_in_the_infinify_directory() {
    assert_eq!(CONFIG_DIR_NAME, "infinify");

    // 1. An explicit path wins over everything, with `~/` expanded.
    set("HOME", Some("/home/u"));
    set("XDG_CONFIG_HOME", Some("/xdg"));
    set("DRIFTWM_CONFIG", Some("/etc/custom.toml"));
    assert_eq!(config_path(), PathBuf::from("/etc/custom.toml"));
    set("DRIFTWM_CONFIG", Some("~/custom.toml"));
    assert_eq!(config_path(), PathBuf::from("/home/u/custom.toml"));

    // 2. Otherwise `$XDG_CONFIG_HOME/infinify/config.toml`.
    set("DRIFTWM_CONFIG", None);
    assert_eq!(config_path(), PathBuf::from("/xdg/infinify/config.toml"));

    // 3. Otherwise `~/.config/infinify/config.toml`.
    set("XDG_CONFIG_HOME", None);
    assert_eq!(
        config_path(),
        PathBuf::from("/home/u/.config/infinify/config.toml")
    );

    // 4. With no home directory either, relative to the working directory.
    set("HOME", None);
    assert_eq!(
        config_path(),
        PathBuf::from("./.config/infinify/config.toml")
    );
}
