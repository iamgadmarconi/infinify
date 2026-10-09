// SPDX-License-Identifier: GPL-3.0-or-later
use std::{fs, path::Path, process::Command};

use serde_json::Value;

fn binary() -> Command {
    Command::new(env!("CARGO_BIN_EXE_driftwm"))
}

fn fixture(name: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/e2e/scenarios")
        .join(name)
}

#[test]
fn cli_replays_zoom_hits_and_persistent_restore() {
    let state = tempfile::tempdir().unwrap();
    let result = binary()
        .arg("scenario")
        .arg(fixture("pan_zoom_persist.json"))
        .arg("--state-dir")
        .arg(state.path())
        .arg("--json")
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let report: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(report["evidence"], "canvas_reducer_and_persistence_only");
    assert_eq!(report["assertions_passed"], 8);
    assert_eq!(report["native_windows_mutated"], false);
    let saved: Value =
        serde_json::from_str(&fs::read_to_string(state.path().join("session.json")).unwrap())
            .unwrap();
    assert_eq!(report["scene"], saved);
}

#[test]
fn cli_replays_independent_output_clipping_and_hit_boundaries() {
    let result = binary()
        .arg("scene")
        .arg(fixture("multiple_outputs.json"))
        .arg("--json")
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let report: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(report["assertions_passed"], 4);
}

#[test]
fn cli_reports_assertion_failure_with_operation_context() {
    let state = tempfile::tempdir().unwrap();
    let path = state.path().join("bad.json");
    fs::write(&path, r#"{"version":1,"name":"intentional failure","operations":[{"op":"add_output","id":1,"bounds":[0,0,100,100],"camera":[0,0],"zoom":1},{"op":"assert_hit","output":1,"point":[0,0],"window":9}]}"#).unwrap();
    let result = binary()
        .arg("scenario")
        .arg(&path)
        .arg("--json")
        .output()
        .unwrap();
    assert!(!result.status.success());
    let error = String::from_utf8_lossy(&result.stderr);
    assert!(
        error.contains("operation 2") && error.contains("expected window Some(9)"),
        "{error}"
    );
    assert!(result.stdout.is_empty());
}

#[test]
fn cli_rejects_invalid_scene_input_and_parent_traversal() {
    let state = tempfile::tempdir().unwrap();
    for (name, operation, expected) in [
        (
            "zoom",
            r#"{"op":"add_output","id":1,"bounds":[0,0,100,100],"camera":[0,0],"zoom":0}"#,
            "invalid",
        ),
        (
            "escape",
            r#"{"op":"save","path":"../escape.json"}"#,
            "relative path",
        ),
        (
            "typo",
            r#"{"op":"save","path":"session.json","typo":true}"#,
            "unknown field",
        ),
    ] {
        let path = state.path().join(format!("{name}.json"));
        fs::write(
            &path,
            format!(r#"{{"version":1,"name":"{name}","operations":[{operation}]}}"#),
        )
        .unwrap();
        let result = binary()
            .arg("scenario")
            .arg(path)
            .arg("--json")
            .output()
            .unwrap();
        assert!(!result.status.success(), "{name} unexpectedly succeeded");
        let error = String::from_utf8_lossy(&result.stderr);
        assert!(error.contains(expected), "{name}: {error}");
    }
}

#[test]
fn cli_requires_existing_output_and_explicit_hit_expectation() {
    let state = tempfile::tempdir().unwrap();
    for (name, assertion, expected) in [
        (
            "missing_output",
            r#"{"op":"assert_hit","output":999,"point":[0,0],"window":null}"#,
            "unknown output 999",
        ),
        (
            "missing_expectation",
            r#"{"op":"assert_hit","output":1,"point":[0,0]}"#,
            "missing field `window`",
        ),
    ] {
        let path = state.path().join(format!("{name}.json"));
        fs::write(&path, format!(r#"{{"version":1,"name":"{name}","operations":[{{"op":"add_output","id":1,"bounds":[0,0,100,100],"camera":[0,0],"zoom":1}},{assertion}]}}"#)).unwrap();
        let result = binary()
            .arg("scenario")
            .arg(path)
            .arg("--json")
            .output()
            .unwrap();
        assert!(!result.status.success(), "{name} unexpectedly succeeded");
        let error = String::from_utf8_lossy(&result.stderr);
        assert!(error.contains(expected), "{name}: {error}");
    }
}
