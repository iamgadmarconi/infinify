// SPDX-License-Identifier: GPL-3.0-or-later
// Storage/types and side-effect recording only. Method bodies are extracted
// verbatim at test time from hash-verified pinned full source files.
#![allow(dead_code)]
use std::{
    cell::{RefCell, RefMut},
    io::{self, BufRead},
    time::Duration,
};
#[path = "GEOMETRY_PATH"]
mod geometry;
use geometry::utils::{Logical, Point, Rectangle, Size};
#[derive(Clone, Copy)]
struct ZoomAnimationAnchor {
    canvas: Point<f64, Logical>,
    screen: Point<f64, Logical>,
}
mod state {
    pub(super) use super::{ZoomAnimationAnchor, output_state};
}
// v0.21: `landing_view_on` calls `driftwm::canvas::zoom_anchor_camera`; the
// original function is extracted into this path, not reimplemented.
mod driftwm {
    pub mod canvas {
        use super::super::{Logical, Point};
        /*ZOOM_ANCHOR_CAMERA*/
    }
}
struct Momentum;
impl Momentum {
    fn stop(&mut self) {}
}
struct Output(RefCell<OutputState>);
struct OutputState {
    camera: Point<f64, Logical>,
    zoom: f64,
    camera_target: Option<Point<f64, Logical>>,
    zoom_target: Option<f64>,
    zoom_animation_anchor: Option<ZoomAnimationAnchor>,
    overview_return: Option<()>,
    momentum: Momentum,
}
fn output_state(output: &Output) -> RefMut<'_, OutputState> {
    output.0.borrow_mut()
}
#[derive(Clone, Copy)]
struct Chrome {
    bar: i32,
    border: i32,
}
impl Chrome {
    /*FRAME_SIZE*/
}
struct Config {
    camera_speed: f64,
    snap_outer_gap: f64,
}
impl Config {
    /*OUTER_FRAME_INSET*/
}
#[derive(Clone, Copy)]
enum FocusPlacement {
    Center,
    Top,
    Bottom,
    Left,
    Right,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}
impl FocusPlacement {
    /*PULL*/
}
struct Pointer;
impl Pointer {
    fn current_location(&self) -> Point<f64, Logical> {
        (0.0, 0.0).into()
    }
}
struct Seat;
impl Seat {
    fn get_pointer(&self) -> Option<Pointer> {
        Some(Pointer)
    }
}
struct DriftWm {
    config: Config,
    usable: Rectangle<i32, Logical>,
    placement: FocusPlacement,
    seat: Seat,
}
impl DriftWm {
    fn usable_area_on(&self, _: &Output) -> Rectangle<i32, Logical> {
        self.usable
    }
    fn focus_placement_on(&self, _: &Output) -> FocusPlacement {
        self.placement
    }
    fn set_camera_on(&mut self, output: &Output, camera: Point<f64, Logical>) {
        output_state(output).camera = camera;
    }
    fn warp_pointer(&mut self, _: Point<f64, Logical>) {}
    /*METHODS*/
}
/*VISUAL_FRAME_CENTER*/
fn main() {
    let output = Output(RefCell::new(OutputState {
        camera: (0.0, 0.0).into(),
        zoom: 1.0,
        camera_target: None,
        zoom_target: None,
        zoom_animation_anchor: None,
        overview_return: None,
        momentum: Momentum,
    }));
    let mut wm = DriftWm {
        config: Config {
            camera_speed: 0.3,
            snap_outer_gap: 0.0,
        },
        usable: Rectangle::new((0, 0).into(), (1000, 800).into()),
        placement: FocusPlacement::Center,
        seat: Seat,
    };
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let mut p = line.split_whitespace();
        let op = p.next().unwrap();
        let a: Vec<f64> = p.map(|s| s.parse().unwrap()).collect();
        match op {
            "pose" => {
                let mut os = output_state(&output);
                os.camera = (a[0], a[1]).into();
                os.zoom = a[2];
                os.camera_target = None;
                os.zoom_target = None;
                os.zoom_animation_anchor = None;
            }
            "context" => {
                wm.usable = Rectangle::new(
                    (a[0] as i32, a[1] as i32).into(),
                    (a[2] as i32, a[3] as i32).into(),
                );
                wm.placement = [
                    FocusPlacement::Center,
                    FocusPlacement::Top,
                    FocusPlacement::Bottom,
                    FocusPlacement::Left,
                    FocusPlacement::Right,
                    FocusPlacement::TopLeft,
                    FocusPlacement::TopRight,
                    FocusPlacement::BottomLeft,
                    FocusPlacement::BottomRight,
                ][a[4] as usize];
                wm.config.camera_speed = a[5];
                wm.config.snap_outer_gap = a[6];
            }
            "navigate" => {
                let z = wm.navigation_target_zoom(&output, a[4] != 0.0);
                let chrome = Chrome { bar: 0, border: 0 };
                let size = (a[2] as i32, a[3] as i32).into();
                let center = visual_frame_center((a[0] as i32, a[1] as i32).into(), size, 0.0);
                let screen = wm.align_point_on(&output, chrome, size, z);
                wm.set_camera_anchor(&output, center, screen, z);
            }
            "anchor" => {
                wm.set_camera_anchor(&output, (a[0], a[1]).into(), (a[2], a[3]).into(), a[4])
            }
            "align" => {
                let v = wm.align_point_on(
                    &output,
                    Chrome {
                        bar: 0,
                        border: a[2] as i32,
                    },
                    (a[0] as i32, a[1] as i32).into(),
                    a[3],
                );
                println!("{{\"x\":{},\"y\":{}}}", v.x, v.y);
                continue;
            }
            "tick" => {
                let dt = Duration::from_nanos(a[0] as u64);
                wm.tick_zoom_animation_on(&output, false, dt);
                wm.tick_camera_animation_on(&output, false, dt);
            }
            _ => panic!("unknown operation"),
        }
        let os = output_state(&output);
        println!(
            "{{\"x\":{:?},\"y\":{:?},\"zoom\":{:?},\"animating\":{}}}",
            os.camera.x,
            os.camera.y,
            os.zoom,
            os.camera_target.is_some() || os.zoom_target.is_some()
        );
    }
}
