// SPDX-License-Identifier: GPL-3.0-or-later
use std::{
    collections::HashSet,
    fs,
    path::{Component, Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use driftwm_canvas::{OutputId, Point, Rect, Scene, Size, Viewport, Window, WindowId};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scenario {
    version: u32,
    name: String,
    operations: Vec<Operation>,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    AddWindow {
        id: u64,
        rect: Bounds,
        #[serde(default)]
        title: String,
    },
    AddOutput {
        id: u64,
        bounds: Bounds,
        camera: [f64; 2],
        zoom: f64,
    },
    Pan {
        output: u64,
        delta: [f64; 2],
    },
    Zoom {
        output: u64,
        zoom: f64,
        anchor: [f64; 2],
    },
    SetWindowRect {
        window: u64,
        rect: Bounds,
    },
    AssertPositions {
        placements: Vec<ExpectedPlacement>,
    },
    AssertHit {
        output: u64,
        point: [f64; 2],
        #[serde(deserialize_with = "required_window")]
        window: Option<u64>,
        #[serde(default)]
        local: Option<[f64; 2]>,
    },
    Save {
        path: PathBuf,
    },
    Load {
        path: PathBuf,
    },
}

fn required_window<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<u64>, D::Error> {
    Option::<u64>::deserialize(deserializer)
}

#[derive(Clone, Copy, Deserialize)]
struct Bounds([f64; 4]);

impl Bounds {
    fn rect(self) -> Rect {
        Rect {
            origin: point([self.0[0], self.0[1]]),
            size: Size {
                width: self.0[2],
                height: self.0[3],
            },
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExpectedPlacement {
    window: u64,
    output: u64,
    screen: Bounds,
    #[serde(default)]
    clip: Option<Bounds>,
    #[serde(default)]
    source: Option<Bounds>,
}

#[derive(Serialize)]
pub struct ReplayReport {
    name: String,
    evidence: &'static str,
    operations_completed: usize,
    assertions_passed: usize,
    native_windows_mutated: bool,
    scene: serde_json::Value,
}

pub fn replay(path: &Path, state_dir: Option<&Path>) -> Result<ReplayReport> {
    let source =
        fs::read_to_string(path).with_context(|| format!("reading scenario {}", path.display()))?;
    let scenario: Scenario = serde_json::from_str(&source).context("invalid scenario JSON")?;
    if scenario.version != 1 {
        bail!("unsupported scenario version {}", scenario.version);
    }
    if scenario.operations.is_empty() {
        bail!("scenario must contain at least one operation");
    }
    let base = state_dir.unwrap_or_else(|| path.parent().unwrap_or_else(|| Path::new(".")));
    let mut scene = Scene::default();
    let mut assertions = 0;
    for (index, operation) in scenario.operations.iter().enumerate() {
        let count = apply(&mut scene, operation, base)
            .with_context(|| format!("scenario {:?}, operation {}", scenario.name, index + 1))?;
        assertions += count;
    }
    Ok(ReplayReport {
        name: scenario.name,
        evidence: "canvas_reducer_and_persistence_only",
        operations_completed: scenario.operations.len(),
        assertions_passed: assertions,
        native_windows_mutated: false,
        scene: serde_json::from_str(&scene.to_json()?)?,
    })
}

fn apply(scene: &mut Scene, operation: &Operation, base: &Path) -> Result<usize> {
    match operation {
        Operation::AddWindow { id, rect, title } => {
            scene.add_window(Window {
                id: WindowId(*id),
                world_rect: rect.rect(),
                native: None,
                title: title.clone(),
            })?;
        }
        Operation::AddOutput {
            id,
            bounds,
            camera,
            zoom,
        } => {
            scene.add_output(Viewport {
                id: OutputId(*id),
                camera: point(*camera),
                zoom: *zoom,
                screen_bounds: bounds.rect(),
            })?;
        }
        Operation::Pan { output, delta } => scene.pan(OutputId(*output), point(*delta))?,
        Operation::Zoom {
            output,
            zoom,
            anchor,
        } => scene.zoom_at(OutputId(*output), *zoom, point(*anchor))?,
        Operation::SetWindowRect { window, rect } => {
            scene.set_window_rect(WindowId(*window), rect.rect())?
        }
        Operation::AssertPositions {
            placements: expected,
        } => {
            let actual = scene.placements();
            if actual.len() != expected.len() {
                bail!(
                    "placement count: expected {}, got {}",
                    expected.len(),
                    actual.len()
                );
            }
            let mut keys = HashSet::new();
            for wanted in expected {
                if !keys.insert((wanted.window, wanted.output)) {
                    bail!(
                        "duplicate expected placement for window {} on output {}",
                        wanted.window,
                        wanted.output
                    );
                }
                let found = actual
                    .iter()
                    .find(|placement| {
                        placement.window == WindowId(wanted.window)
                            && placement.output == OutputId(wanted.output)
                    })
                    .with_context(|| {
                        format!(
                            "missing placement for window {} on output {}",
                            wanted.window, wanted.output
                        )
                    })?;
                check_rect("screen", found.screen_rect, wanted.screen.rect())?;
                if let Some(clip) = wanted.clip {
                    check_rect("clip", found.clip_rect, clip.rect())?;
                }
                if let Some(source) = wanted.source {
                    check_rect("source", found.source_rect, source.rect())?;
                }
            }
            return Ok(1);
        }
        Operation::AssertHit {
            output,
            point: position,
            window,
            local,
        } => {
            scene
                .output(OutputId(*output))
                .with_context(|| format!("unknown output {output} in hit assertion"))?;
            let hit = scene.hit_test(OutputId(*output), point(*position));
            let window = *window;
            if hit.as_ref().map(|hit| hit.window.0) != window {
                bail!(
                    "hit at {position:?}: expected window {window:?}, got {:?}",
                    hit.as_ref().map(|hit| hit.window.0)
                );
            }
            if let Some(local) = local {
                let hit = hit.context("local coordinates asserted for an empty hit")?;
                check_scalar("local x", hit.local.x, local[0])?;
                check_scalar("local y", hit.local.y, local[1])?;
            }
            return Ok(1);
        }
        Operation::Save { path } => {
            scene.save_atomic(state_path(base, path)?)?;
        }
        Operation::Load { path } => {
            *scene = Scene::load(state_path(base, path)?)?;
        }
    }
    Ok(0)
}

fn point([x, y]: [f64; 2]) -> Point {
    Point { x, y }
}

fn state_path(base: &Path, path: &Path) -> Result<PathBuf> {
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        bail!("save/load path must be a relative path without parent traversal");
    }
    Ok(base.join(path))
}

fn check_rect(label: &str, actual: Rect, expected: Rect) -> Result<()> {
    for (axis, actual, expected) in [
        ("x", actual.origin.x, expected.origin.x),
        ("y", actual.origin.y, expected.origin.y),
        ("width", actual.size.width, expected.size.width),
        ("height", actual.size.height, expected.size.height),
    ] {
        check_scalar(&format!("{label}.{axis}"), actual, expected)?;
    }
    Ok(())
}

fn check_scalar(label: &str, actual: f64, expected: f64) -> Result<()> {
    if !actual.is_finite() || !expected.is_finite() || (actual - expected).abs() > 1e-6 {
        bail!("{label}: expected {expected}, got {actual}");
    }
    Ok(())
}
