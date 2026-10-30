// SPDX-License-Identifier: GPL-3.0-or-later
//! Public policy pipelines compared with unchanged upstream canvas.rs.
//! No Scene/controller/native feature integration is asserted.
extern crate self as smithay;
#[path = "support/canvas_shim.rs"]
mod shim;
pub use shim::{config, utils};
// v0.21's canvas.rs names `crate::layout::snap::SnapRect` (minimal_reveal_camera,
// leading_edge_camera): the original, unedited snap.rs provides it.
#[allow(dead_code, clippy::all)]
#[path = "upstream/snap.rs"]
mod upstream_snap;
mod layout {
    pub(crate) use crate::upstream_snap as snap;
}
#[allow(dead_code, clippy::all)]
#[path = "upstream/canvas.rs"]
mod upstream;

use driftwm_canvas::{Point, policy as p};
use std::collections::BTreeMap;
use std::time::Duration;
use utils::{Logical, Point as UPoint, Rectangle as URect};

fn rect(x: i32, y: i32, w: i32, h: i32) -> p::PixelRect {
    p::PixelRect::new((x, y).into(), (w, h).into())
}
fn upoint(point: Point) -> UPoint<f64, Logical> {
    (point.x, point.y).into()
}
fn urect(rect: p::PixelRect) -> URect<i32, Logical> {
    URect::new(
        (rect.loc.x, rect.loc.y).into(),
        (rect.size.w, rect.size.h).into(),
    )
}
fn equal_point(actual: Point, expected: UPoint<f64, Logical>) {
    assert_eq!(actual.x.to_bits(), expected.x.to_bits());
    assert_eq!(actual.y.to_bits(), expected.y.to_bits());
}
fn equal_rect(actual: p::PixelRect, expected: URect<i32, Logical>) {
    assert_eq!(
        (actual.loc.x, actual.loc.y, actual.size.w, actual.size.h),
        (
            expected.loc.x,
            expected.loc.y,
            expected.size.w,
            expected.size.h
        )
    );
}

#[test]
fn policy_fit_dynamic_min_and_camera_center_pipeline_matches_upstream() {
    for windows in [
        vec![],
        vec![rect(-2, -2, 5, 5)],
        vec![rect(-1531, 733, 2000, 1500)],
        vec![rect(-70000, -8000, 4000, 1), rect(50000, 10000, 1, 3000)],
        vec![rect(0, 0, 0, 0)],
        vec![rect(-10000000, 0, 20000000, 15000000)],
    ] {
        for viewport in [(1920, 1080), (300, 900), (0, 0)] {
            for padding in [-20.0, 0.0, 50.0, 1000.0] {
                let actual_bbox = p::all_windows_bbox(windows.iter().map(|r| (r.loc, r.size)));
                let expected_bbox = upstream::all_windows_bbox(windows.iter().map(|r| {
                    let r = urect(*r);
                    (r.loc, r.size)
                }));
                match (actual_bbox, expected_bbox) {
                    (Some(a), Some(b)) => {
                        equal_rect(a, b);
                        let fit = p::zoom_to_fit(a, viewport.into(), padding);
                        assert_eq!(
                            fit.to_bits(),
                            upstream::zoom_to_fit(b, viewport.into(), padding).to_bits()
                        );
                        let center = (
                            f64::from(a.loc.x) + f64::from(a.size.w) / 2.0,
                            -(f64::from(a.loc.y) + f64::from(a.size.h) / 2.0),
                        );
                        let camera = p::camera_for_center(center.0, center.1, fit, viewport.into());
                        let expected =
                            upstream::camera_for_center(center.0, center.1, fit, viewport.into());
                        equal_point(camera, expected);
                        assert_eq!(
                            p::viewport_center(camera, fit, viewport.into()),
                            upstream::viewport_center(expected, fit, viewport.into())
                        );
                    }
                    (None, None) => (),
                    _ => panic!("bbox presence mismatch"),
                }
                assert_eq!(
                    p::dynamic_min_zoom(
                        windows.iter().map(|r| (r.loc, r.size)),
                        viewport.into(),
                        padding
                    )
                    .to_bits(),
                    upstream::dynamic_min_zoom(
                        windows.iter().map(|r| {
                            let r = urect(*r);
                            (r.loc, r.size)
                        }),
                        viewport.into(),
                        padding
                    )
                    .to_bits()
                );
            }
        }
    }
}

#[test]
fn policy_visibility_culling_and_nearest_rect_points_match_upstream() {
    for camera in [
        Point::new(0.0, 0.0),
        Point::new(-100.5, 70.25),
        Point::new(9000.0, -10000.0),
    ] {
        for viewport in [(100, 80), (1920, 1080), (0, 0)] {
            for zoom in [1.0, 0.5, 0.001] {
                for r in [
                    rect(0, 0, 100, 80),
                    rect(-110, 60, 120, 90),
                    rect(9000, -10000, 100, 100),
                    rect(0, 0, 0, 100),
                    rect(0, 0, -10, 100),
                ] {
                    let ur = urect(r);
                    assert_eq!(
                        p::visible_fraction(r.loc, r.size, camera, viewport.into(), zoom).to_bits(),
                        upstream::visible_fraction(
                            ur.loc,
                            ur.size,
                            upoint(camera),
                            viewport.into(),
                            zoom
                        )
                        .to_bits()
                    );
                    if r.size.w >= 0 && r.size.h >= 0 {
                        equal_point(
                            p::closest_point_on_rect(camera, r.loc, r.size),
                            upstream::closest_point_on_rect(upoint(camera), ur.loc, ur.size),
                        );
                    }
                }
                for point in [
                    camera,
                    Point::new(
                        camera.x + f64::from(viewport.0) / zoom,
                        camera.y + f64::from(viewport.1) / zoom,
                    ),
                    Point::new(camera.x - 0.0001, camera.y),
                    Point::new(0.0, 0.0),
                ] {
                    assert_eq!(
                        p::is_point_visible(point, camera, viewport.into(), zoom),
                        upstream::is_point_visible(
                            upoint(point),
                            upoint(camera),
                            viewport.into(),
                            zoom
                        )
                    );
                }
                assert_eq!(
                    p::is_origin_visible(camera, viewport.into(), zoom),
                    upstream::is_origin_visible(upoint(camera), viewport.into(), zoom)
                );
                let rounded = (camera.x.round() as i32, camera.y.round() as i32);
                equal_rect(
                    p::visible_canvas_rect(rounded.into(), viewport.into(), zoom),
                    upstream::visible_canvas_rect(rounded.into(), viewport.into(), zoom),
                );
            }
        }
    }
}

#[test]
fn policy_all_directions_skip_cone_boundaries_and_ties_match_upstream() {
    let directions = [
        (p::Direction::Up, config::Direction::Up),
        (p::Direction::Down, config::Direction::Down),
        (p::Direction::Left, config::Direction::Left),
        (p::Direction::Right, config::Direction::Right),
        (p::Direction::UpLeft, config::Direction::UpLeft),
        (p::Direction::UpRight, config::Direction::UpRight),
        (p::Direction::DownLeft, config::Direction::DownLeft),
        (p::Direction::DownRight, config::Direction::DownRight),
    ];
    for (dir, udir) in directions {
        assert_eq!(dir.to_unit_vec(), udir.to_unit_vec());
        for origin in [Point::default(), Point::new(100.0, -100.0)] {
            for reverse in [false, true] {
                let mut items: Vec<_> = [
                    (0.0, 0.0),
                    (10.0, 10.0),
                    (10.0, -10.0),
                    (-10.0, 10.0),
                    (-10.0, -10.0),
                    (20.0, 0.0),
                    (-20.0, 0.0),
                    (0.0, 20.0),
                    (0.0, -20.0),
                    (10.0, 10.001),
                    (10.0, 9.999),
                ]
                .into_iter()
                .enumerate()
                .map(|(i, (x, y))| (i, origin + Point::new(x, y)))
                .collect();
                if reverse {
                    items.reverse();
                }
                for skip in [None, Some(0), Some(1), Some(5)] {
                    assert_eq!(
                        p::find_nearest(origin, &dir, items.iter().copied(), skip.as_ref()),
                        upstream::find_nearest(
                            upoint(origin),
                            &udir,
                            items.iter().map(|&(id, pt)| (id, upoint(pt))),
                            skip.as_ref()
                        )
                    );
                }
            }
        }
    }
}

#[test]
fn policy_active_bookmark_y_up_visibility_name_ties_and_hysteresis_match_upstream() {
    let bookmarks: BTreeMap<_, _> = [
        ("a".to_owned(), [40.0, -50.0]),
        ("b".to_owned(), [60.0, -50.0]),
        ("upper".to_owned(), [50.0, 50.0]),
        ("far".to_owned(), [2000.0, -3000.0]),
    ]
    .into();
    for zoom in [1.0, 0.5, 0.001] {
        for center in [Point::new(50.0, 50.0), Point::new(50.0, 35.0)] {
            let mut incumbent = None;
            let mut oracle_incumbent = None;
            for x in [
                0.0,
                0.4,
                0.5,
                0.5263157894736842,
                0.6,
                1.0,
                20.0,
                200.0,
                -200.0,
                0.0,
            ] {
                let camera = Point::new(x, 0.0);
                let actual = p::active_bookmark(
                    &bookmarks,
                    camera,
                    (100, 100).into(),
                    zoom,
                    center,
                    incumbent.as_deref(),
                );
                let expected = upstream::active_bookmark(
                    &bookmarks,
                    upoint(camera),
                    (100, 100).into(),
                    zoom,
                    upoint(center),
                    oracle_incumbent.as_deref(),
                );
                assert_eq!(actual, expected, "camera={camera:?} zoom={zoom}");
                incumbent = actual;
                oracle_incumbent = expected;
            }
        }
    }
    assert_eq!(
        p::active_bookmark(
            &BTreeMap::new(),
            Point::default(),
            (100, 100).into(),
            1.0,
            Point::new(50.0, 50.0),
            Some("missing")
        ),
        None
    );
}

#[test]
fn policy_zoom_deadzone_and_anchor_pipeline_match_upstream() {
    for zoom in [
        0.001,
        0.5,
        0.95,
        0.9500000000000001,
        1.0,
        1.0499999999999998,
        1.05,
        1.1,
        f64::NAN,
    ] {
        let actual = p::snap_zoom(zoom);
        let expected = upstream::snap_zoom(zoom);
        assert_eq!(actual.to_bits(), expected.to_bits());
        if actual.is_finite() {
            let anchor = Point::new(-130.5, 213.25);
            let screen = Point::new(811.0, 512.0);
            equal_point(
                p::zoom_anchor_camera(anchor, screen, actual),
                upstream::zoom_anchor_camera(upoint(anchor), upoint(screen), expected),
            );
        }
    }
}

#[test]
fn policy_event_timestamps_momentum_launch_decay_stop_and_relaunch_match_upstream() {
    for drift in [0.0, 0.1, p::DEFAULT_DRIFT, 1.0, 2.0] {
        let mut actual = p::MomentumState::new(drift);
        let mut oracle = upstream::MomentumState::new(drift);
        for (stamp, delta) in [
            (u32::MAX - 40, Point::new(2.0, 1.0)),
            (u32::MAX - 20, Point::new(10.0, -2.0)),
            (10, Point::new(40.0, 8.0)),
            (10, Point::new(3.0, 1.0)),
            (60, Point::new(30.0, 0.0)),
        ] {
            actual.accumulate(delta, stamp);
            oracle.accumulate(upoint(delta), stamp);
            equal_point(
                actual.tracker.launch_velocity(),
                oracle.tracker.launch_velocity(),
            );
            assert_eq!(actual.coasting, oracle.coasting);
        }
        actual.launch();
        oracle.launch();
        for tick in 0..1200 {
            let dt = Duration::from_micros([0, 8333, 16667, 40000][tick % 4]);
            let a = actual.tick(dt);
            let b = oracle.tick(dt);
            match (a, b) {
                (Some(a), Some(b)) => equal_point(a, b),
                (None, None) => (),
                _ => panic!("coasting mismatch"),
            }
            equal_point(actual.velocity, oracle.velocity);
            assert_eq!(actual.coasting, oracle.coasting);
        }
        actual.accumulate(Point::new(1.0, 0.0), 200);
        oracle.accumulate((1.0, 0.0).into(), 200);
        actual.accumulate(Point::new(1.0, 0.0), 200);
        oracle.accumulate((1.0, 0.0).into(), 200);
        actual.launch();
        oracle.launch();
        assert_eq!(actual.tick(Duration::from_millis(16)), None);
        assert!(oracle.tick(Duration::from_millis(16)).is_none());
        for speed in [14.999, 15.0, 2500.0, 5000.0] {
            actual.velocity = Point::new(speed, 0.0);
            oracle.velocity = (speed, 0.0).into();
            actual.coasting = true;
            oracle.coasting = true;
            match (
                actual.tick(Duration::from_millis(16)),
                oracle.tick(Duration::from_millis(16)),
            ) {
                (Some(a), Some(b)) => equal_point(a, b),
                (None, None) => (),
                _ => panic!("stop boundary mismatch"),
            }
            actual.stop();
            oracle.stop();
            equal_point(actual.velocity, oracle.velocity);
            equal_point(
                actual.tracker.launch_velocity(),
                oracle.tracker.launch_velocity(),
            );
            assert_eq!(actual.coasting, oracle.coasting);
        }
    }
    assert_eq!(p::MomentumState::default().drift, 0.5);
}

#[test]
fn policy_exact_bookmark_and_velocity_window_boundaries_match_upstream() {
    let mut bookmarks: BTreeMap<_, _> = [
        ("a".to_owned(), [40.0, -50.0]),
        ("b".to_owned(), [59.0, -50.0]),
    ]
    .into();
    for (rival_x, winner) in [(59.0, "a"), (58.999, "b"), (60.0, "a")] {
        bookmarks.insert("b".to_owned(), [rival_x, -50.0]);
        let actual = p::active_bookmark(
            &bookmarks,
            Point::default(),
            (100, 100).into(),
            1.0,
            Point::new(50.0, 50.0),
            Some("a"),
        );
        assert_eq!(actual.as_deref(), Some(winner));
        assert_eq!(
            actual,
            upstream::active_bookmark(
                &bookmarks,
                (0.0, 0.0).into(),
                (100, 100).into(),
                1.0,
                (50.0, 50.0).into(),
                Some("a")
            )
        );
    }
    let mut tracker = p::VelocityTracker::new();
    let mut oracle = upstream::VelocityTracker::new();
    for stamp in [0, 80, 81, 161, 162, 243] {
        tracker.push(stamp, Point::new(8.0, -4.0));
        oracle.push(stamp, (8.0, -4.0).into());
        equal_point(tracker.launch_velocity(), oracle.launch_velocity());
        if stamp == 80 {
            assert_eq!(tracker.launch_velocity(), Point::new(200.0, -100.0));
        }
        if stamp == 243 {
            assert_eq!(tracker.launch_velocity(), Point::default());
        }
    }
    tracker.clear();
    oracle.clear();
    equal_point(tracker.launch_velocity(), oracle.launch_velocity());
}
