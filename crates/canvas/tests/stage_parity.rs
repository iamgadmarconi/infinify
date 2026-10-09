// SPDX-License-Identifier: GPL-3.0-or-later
//! Public Scene trace against the complete, byte-for-byte upstream Stage.
use driftwm_canvas::{Rect, Scene, Window, WindowId};
use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Command, Stdio},
};

#[test]
fn parity_frozen_history_removal_and_interruption() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let temp = std::env::temp_dir().join(format!("stage-oracle-{}", std::process::id()));
    std::fs::create_dir_all(&temp).unwrap();
    let binary = temp.join("oracle");
    let status = Command::new("rustc")
        .args(["--edition=2024", "--crate-name", "stage_oracle"])
        .arg(root.join("tests/support/stage_oracle.rs"))
        .arg("-o")
        .arg(&binary)
        .status()
        .unwrap();
    assert!(status.success());
    // Fresh backward selects index one too; later backward wraps. Focus 4 is
    // deliberately excluded from history. Removal clamps the frozen index.
    let trace = "map 1\nmap 2\nmap 3\nmap 4\nfocus 1\nconfirm 1\nfocus 2\nconfirm 2\nfocus 3\nconfirm 3\nstep 1\nconfirm 2\nstep 1\nstep 1\nend\nfocus 4\nstep 0\nstep 0\nremove 3\nstep 0\nend\nfocus 1\nconfirm 1\nstep 0\ncancel\nfocus 4\nstep 0\ndrop 2\ncancel\nremove 2\nmap 2\nfocus 2\nconfirm 2\n";
    let mut child = Command::new(&binary)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(trace.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    std::fs::remove_dir_all(temp).unwrap();
    assert!(output.status.success());
    let expected = String::from_utf8(output.stdout).unwrap();
    let mut scene = Scene::new();
    for (command, expected) in trace.lines().zip(expected.lines()) {
        let mut parts = command.split_whitespace();
        let op = parts.next().unwrap();
        let id = WindowId(parts.next().unwrap_or("0").parse().unwrap());
        let mut selected = None;
        match op {
            "map" => scene
                .add_window(Window {
                    id,
                    world_rect: Rect::new(id.0 as f64 + 0.25, 0.5, 100.75, 100.125),
                    native: None,
                    title: id.0.to_string(),
                })
                .unwrap(),
            "focus" => scene.focus(id).unwrap(),
            "confirm" => scene.confirm_focus(id).unwrap(),
            "step" => selected = scene.cycle_focus(id.0 != 0).unwrap(),
            "end" => scene.end_cycle(),
            "cancel" => scene.cancel_cycle(),
            "drop" => scene.drop_focus_history(id),
            "remove" => {
                scene.remove_window(id).unwrap();
            }
            _ => unreachable!(),
        }
        let actual = json!({"z":scene.windows().iter().map(|w|w.id).collect::<Vec<_>>(),"history":scene.stage().focus_history(),"cycle":scene.stage().cycle_state(),"selected":selected});
        assert_eq!(
            actual,
            serde_json::from_str::<Value>(expected).unwrap(),
            "after {command}"
        );
        for w in scene.windows() {
            assert_eq!(w.world_rect.origin.x, w.id.0 as f64 + 0.25);
        }
    }
}
