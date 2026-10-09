// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{Context, Result, ensure};
use driftwm_canvas::{OutputId, Point, Scene, WindowId};
use driftwm_runtime::{Identity, Session};
use serde::Deserialize;
use serde_json::json;
use std::{
    fs,
    io::{self, BufRead, Write},
    os::unix::fs::MetadataExt,
    path::PathBuf,
};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Pan {
        output: u64,
        delta: [f64; 2],
    },
    Zoom {
        output: u64,
        zoom: f64,
        anchor: [f64; 2],
    },
    Apply,
    Readback,
    Save {
        path: PathBuf,
    },
    Close,
    Disconnect,
}
fn emit(value: serde_json::Value) -> Result<()> {
    println!("{value}");
    io::stdout().flush()?;
    Ok(())
}
fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args == ["--help"] || args == ["help"] {
        println!(
            "driftwm-runtime: explicit selected-window Scene/native bridge\n\nRead-only default/help; never injects or changes permissions.\nprobe PRIVATE_DIRECTORY NONCE_FILE\nsession PRIVATE_DIRECTORY NONCE_FILE IDENTITY_FILE SCENE_FILE LOGICAL_WINDOW_ID\n\nSession requires a fresh full identity supplied explicitly, not saved scene identity.\nJSON lines on stdin: pan {{output,delta}}, zoom {{output,zoom,anchor}}, apply,\nreadback, save {{path}}, close, disconnect. Each includes op.\nPan/zoom only update desired Scene; apply requires native matrix AND screen rect\nreadback. One unclipped selected placement only; hidden world entries persist.\nEOF restores; disconnect exercises helper-side recovery without claiming success.\nNo native input routing or full desktop window management is provided."
        );
        return Ok(());
    }
    ensure!(
        matches!(args[0].as_str(), "probe" | "session"),
        "unknown command; use --help"
    );
    ensure!(
        (args[0] == "probe" && args.len() == 3) || (args[0] == "session" && args.len() == 6),
        "incorrect arguments; use --help"
    );
    let directory = PathBuf::from(&args[1]);
    let nonce_path = PathBuf::from(&args[2]);
    let metadata = fs::symlink_metadata(&nonce_path)?;
    // SAFETY: getuid takes no pointers.
    ensure!(
        metadata.is_file()
            && metadata.mode() & 0o777 == 0o600
            && metadata.uid() == unsafe { libc::getuid() }
            && metadata.len() <= 65,
        "nonce file must be a same-UID non-symlink 0600 file of at most 65 bytes"
    );
    let nonce = fs::read_to_string(nonce_path)?.trim().to_owned();
    if args[0] == "probe" {
        return emit(Session::probe(&directory, nonce)?);
    }
    ensure!(
        fs::metadata(&args[3])?.len() <= 4096,
        "identity file exceeds 4096 bytes"
    );
    let identity: Identity = serde_json::from_slice(&fs::read(&args[3])?)?;
    let scene = Scene::load(&args[4])?;
    let selected = WindowId(args[5].parse().context("invalid logical window ID")?);
    let mut session = Session::enroll(&directory, nonce, scene, selected, identity)?;
    emit(
        json!({"ok":true,"event":"enrolled","original":session.original(),"desired_revision":session.desired_revision()}),
    )?;
    let stdin = io::stdin();
    let mut input = stdin.lock();
    loop {
        let mut bytes = Vec::new();
        // Bound every command before allocation; a missing newline fails closed.
        use std::io::Read;
        let count = (&mut input).take(4097).read_until(b'\n', &mut bytes)?;
        if count == 0 {
            break;
        }
        ensure!(
            count <= 4096 && bytes.last() == Some(&b'\n'),
            "command exceeds 4096 bytes or has no newline"
        );
        match serde_json::from_slice::<Command>(&bytes)? {
            Command::Pan { output, delta } => {
                let mut scene = session.desired().clone();
                scene.pan(OutputId(output), Point::new(delta[0], delta[1]))?;
                session.set_desired(scene)?;
            }
            Command::Zoom {
                output,
                zoom,
                anchor,
            } => {
                let mut scene = session.desired().clone();
                scene.zoom_at(OutputId(output), zoom, Point::new(anchor[0], anchor[1]))?;
                session.set_desired(scene)?;
            }
            Command::Apply => {
                session.apply()?;
            }
            Command::Readback => {
                emit(json!({"ok":true,"event":"readback","readback":session.readback()?}))?;
                continue;
            }
            Command::Save { path } => {
                session.desired().save_atomic(path)?;
            }
            Command::Close => {
                emit(json!({"ok":true,"event":"restored","readback":session.close()?}))?;
                return Ok(());
            }
            Command::Disconnect => {
                session.disconnect();
                emit(
                    json!({"ok":true,"event":"disconnected","restoration":"requires independent verification"}),
                )?;
                return Ok(());
            }
        }
        emit(
            json!({"ok":true,"desired_revision":session.desired_revision(),"presented":session.presented(),"world_windows":session.desired().windows()}),
        )?;
    }
    let restored = session
        .close()
        .context("EOF restoration could not be verified")?;
    emit(json!({"ok":true,"event":"restored","readback":restored}))?;
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        let _ = emit(json!({"ok":false,"error":format!("{error:#}")}));
        eprintln!("driftwm-runtime: {error:#}");
        std::process::exit(1);
    }
}
