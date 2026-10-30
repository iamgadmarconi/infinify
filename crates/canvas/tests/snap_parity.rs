// SPDX-License-Identifier: GPL-3.0-or-later
//! Public Scene traces against driftwm-core's upstream layout::{snap, cluster}.
//! These tests establish canvas geometry parity, not native app behavior.
use driftwm_canvas::{Point, Rect, ResizeEdges, Scene, SnapOptions, Window, WindowId};
use driftwm_core::layout::cluster::{
    ResizeClassification, Side, cluster_of, resolve_cluster_shifts,
};
use driftwm_core::layout::snap::{self, SnapParams, SnapRect, SnapState};

fn add(scene: &mut Scene, id: u64, rect: Rect) {
    scene
        .add_window(Window {
            id: WindowId(id),
            world_rect: rect,
        })
        .unwrap();
}
fn snap_rect(r: Rect) -> SnapRect {
    SnapRect {
        x_low: r.origin.x,
        x_high: r.right(),
        y_low: r.origin.y,
        y_high: r.bottom(),
    }
}
fn assert_rect(actual: Rect, expected: Rect, context: &str) {
    for (a, b) in [
        (actual.origin.x, expected.origin.x),
        (actual.origin.y, expected.origin.y),
        (actual.size.width, expected.size.width),
        (actual.size.height, expected.size.height),
    ] {
        assert!(
            (a - b).abs() < 1e-9,
            "{context}: {actual:?} != {expected:?}"
        );
    }
}

// Wrapper follows state/cluster_snapshot.rs::snap_position lines 328-367,
// with zero added chrome because Scene's rectangles already include it.
fn upstream_drag(
    state: &mut SnapState,
    natural: Rect,
    others: &[SnapRect],
    zoom: f64,
    same: bool,
    center: bool,
) -> Rect {
    let y = state.y.as_ref().map_or(natural.origin.y, |s| s.snapped_pos);
    let x = snap::update_axis(
        &mut state.x,
        &mut state.cooldown_x,
        natural.origin.x,
        &SnapParams {
            extent: natural.size.width,
            perp_low: y,
            perp_high: y + natural.size.height,
            horizontal: true,
            others,
            gap: 12.0,
            threshold: 24.0 / zoom,
            break_force: 32.0 / zoom,
            same_edge: same,
            edge_center: center,
        },
    );
    let y = snap::update_axis(
        &mut state.y,
        &mut state.cooldown_y,
        natural.origin.y,
        &SnapParams {
            extent: natural.size.height,
            perp_low: x,
            perp_high: x + natural.size.width,
            horizontal: false,
            others,
            gap: 12.0,
            threshold: 24.0 / zoom,
            break_force: 32.0 / zoom,
            same_edge: same,
            edge_center: center,
        },
    );
    Rect::new(x, y, natural.size.width, natural.size.height)
}

#[test]
fn parity_drag_candidate_families_thresholds_ties_and_hysteresis() {
    let primary = Rect::new(-37.0, 19.0, 100.0, 80.0);
    let targets = [
        Rect::new(130.0, 19.0, 100.0, 80.0),  // opposite edge
        Rect::new(-37.0, 131.0, 140.0, 80.0), // parallel edges and center
        Rect::new(130.0, 130.0, 100.0, 80.0), // perpendicular adjacency boundary
        Rect::new(-200.0, -100.0, 75.0, 60.0),
    ];
    for zoom in [1.0, 0.5, 0.125] {
        for (same, center) in [(false, false), (true, false), (false, true), (true, true)] {
            for order in [false, true] {
                let mut scene = Scene::new();
                add(&mut scene, 1, primary);
                let mut others: Vec<_> = targets.into_iter().map(snap_rect).collect();
                if order {
                    others.reverse();
                }
                for (i, r) in others.iter().enumerate() {
                    add(
                        &mut scene,
                        i as u64 + 2,
                        Rect::new(r.x_low, r.y_low, r.x_high - r.x_low, r.y_high - r.y_low),
                    );
                }
                let options = SnapOptions {
                    threshold: 24.0 / zoom,
                    ..SnapOptions::default()
                };
                let mut drag = scene
                    .begin_drag(WindowId(1), options, 32.0 / zoom, false)
                    .unwrap()
                    .with_alignment(same, center);
                let mut oracle = SnapState::default();
                // Continuous forward/reverse traces cross engage, exact break,
                // cooldown, same-edge and center eligibility boundaries.
                for y in [-100.0, -17.0, 0.0, 32.0, 68.0, 80.0, 112.0] {
                    for x in (-230..260).step_by(3).chain((-230..260).rev().step_by(3)) {
                        let delta = Point::new(f64::from(x), y);
                        let expected = upstream_drag(
                            &mut oracle,
                            primary.translated(delta),
                            &others,
                            zoom,
                            same,
                            center,
                        );
                        scene.drag_to(&mut drag, delta).unwrap();
                        assert_rect(
                            scene.window(WindowId(1)).unwrap().world_rect,
                            expected,
                            &format!(
                                "drag zoom={zoom} same={same} center={center} delta={delta:?}"
                            ),
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn parity_drag_exact_distance_and_release_boundaries() {
    let initial = Rect::new(0.0, 0.0, 100.0, 100.0);
    let target = Rect::new(150.0, 0.0, 100.0, 100.0);
    let mut scene = Scene::new();
    add(&mut scene, 1, initial);
    add(&mut scene, 2, target);
    let mut drag = scene
        .begin_drag(WindowId(1), SnapOptions::default(), 32.0, false)
        .unwrap();
    let mut oracle = SnapState::default();
    for delta in [
        26.0, 26.001, -5.998, -5.999, 38.0, 14.0, 13.999, 27.0, 69.999, 70.0, 38.0,
    ] {
        let delta = Point::new(delta, 0.0);
        let expected = upstream_drag(
            &mut oracle,
            initial.translated(delta),
            &[snap_rect(target)],
            1.0,
            false,
            false,
        );
        scene.drag_to(&mut drag, delta).unwrap();
        assert_rect(
            scene.window(WindowId(1)).unwrap().world_rect,
            expected,
            "exact boundary",
        );
    }
}

#[test]
fn parity_resize_all_edges_and_corner_held_perpendicular_ranges() {
    let initial = Rect::new(0.0, 0.0, 100.0, 80.0);
    let targets = [
        Rect::new(155.0, 30.0, 100.0, 100.0),
        Rect::new(20.0, 135.0, 100.0, 90.0),
        Rect::new(-160.0, -130.0, 100.0, 100.0),
    ];
    let others: Vec<_> = targets.into_iter().map(snap_rect).collect();
    for (edges, mask) in [
        (ResizeEdges::Top, 1),
        (ResizeEdges::Bottom, 2),
        (ResizeEdges::Left, 4),
        (ResizeEdges::Right, 8),
        (ResizeEdges::TopLeft, 5),
        (ResizeEdges::TopRight, 9),
        (ResizeEdges::BottomLeft, 6),
        (ResizeEdges::BottomRight, 10),
    ] {
        for zoom in [1.0, 0.5] {
            for same in [false, true] {
                let mut scene = Scene::new();
                add(&mut scene, 1, initial);
                for (i, rect) in targets.into_iter().enumerate() {
                    add(&mut scene, i as u64 + 2, rect);
                }
                let mut gesture = scene
                    .begin_resize(
                        WindowId(1),
                        edges,
                        SnapOptions {
                            threshold: 24.0 / zoom,
                            ..SnapOptions::default()
                        },
                        false,
                    )
                    .unwrap()
                    .with_same_edge(same)
                    .with_break_force(32.0 / zoom)
                    .unwrap();
                let mut oracle = SnapState::default();
                for y in [-60, -20, 0, 30, 60, 100] {
                    for x in (-180..180).step_by(2).chain((-180..180).rev().step_by(2)) {
                        let mut width = (100
                            + if mask & 4 != 0 {
                                -x
                            } else if mask & 8 != 0 {
                                x
                            } else {
                                0
                            })
                        .max(1);
                        let mut height = (80
                            + if mask & 1 != 0 {
                                -y
                            } else if mask & 2 != 0 {
                                y
                            } else {
                                0
                            })
                        .max(1);
                        snap::snap_resize_edges(
                            &mut oracle,
                            mask,
                            (0, 0),
                            (100, 80),
                            0,
                            0,
                            &mut width,
                            &mut height,
                            &others,
                            zoom,
                            12.0,
                            24.0,
                            32.0,
                            same,
                        );
                        let expected = Rect::new(
                            if mask & 4 != 0 {
                                f64::from(100 - width)
                            } else {
                                0.0
                            },
                            if mask & 1 != 0 {
                                f64::from(80 - height)
                            } else {
                                0.0
                            },
                            f64::from(width),
                            f64::from(height),
                        );
                        let actual = scene
                            .resize_to(&mut gesture, Point::new(f64::from(x), f64::from(y)))
                            .unwrap();
                        assert_rect(
                            actual,
                            expected,
                            &format!("resize mask={mask} zoom={zoom} same={same} x={x} y={y}"),
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn parity_resize_group_member_stays_while_the_primary_edge_moves() {
    // A left-edge resize moves nothing downstream: the right neighbour captured
    // with the group keeps its frame, and the primary floors at one point.
    let mut scene = Scene::new();
    add(&mut scene, 1, Rect::new(0.0, 0.0, 100.0, 100.0));
    add(&mut scene, 2, Rect::new(112.0, 0.0, 100.0, 100.0));
    let mut resize = scene
        .begin_resize(WindowId(1), ResizeEdges::Left, SnapOptions::default(), true)
        .unwrap();
    for (delta, expected_x, expected_width) in [
        (200.0, 99.0, 1.0),
        (-200.0, -200.0, 300.0),
        (0.0, 0.0, 100.0),
    ] {
        assert_rect(
            scene
                .resize_to(&mut resize, Point::new(delta, 0.0))
                .unwrap(),
            Rect::new(expected_x, 0.0, expected_width, 100.0),
            "left edge",
        );
        assert_eq!(
            scene.window(WindowId(2)).unwrap().world_rect.origin.x,
            112.0
        );
    }
}

#[test]
fn parity_cluster_components_and_integer_bond_reversal() {
    let rects = [
        Rect::new(0.0, 0.0, 100.0, 100.0),
        Rect::new(112.0, 0.0, 100.0, 100.0),
        Rect::new(112.0, 112.0, 100.0, 100.0),
        Rect::new(0.0, 112.0, 100.0, 100.0),
    ];
    let mut scene = Scene::new();
    for (i, r) in rects.into_iter().enumerate() {
        add(&mut scene, i as u64 + 1, r);
    }
    let upstream_rects: Vec<_> = rects
        .into_iter()
        .enumerate()
        .map(|(i, r)| (WindowId(i as u64 + 1), snap_rect(r)))
        .collect();
    let mut expected: Vec<_> = cluster_of(&WindowId(1), &upstream_rects, 12.0)
        .into_iter()
        .collect();
    expected.sort();
    assert_eq!(
        scene.cluster(WindowId(1), SnapOptions::default()).unwrap(),
        expected
    );
    // Source-cited static classifications from cluster_snapshot_for_resize_with_rects:
    // direct right neighbor and downstream lower-right carry X; lower-left stays.
    let members: Vec<_> = rects[1..]
        .iter()
        .enumerate()
        .map(|(i, &r)| ResizeClassification {
            axis_x: if i < 2 { Some(Side::Right) } else { None },
            axis_y: None,
            initial_rect: snap_rect(r),
        })
        .collect();
    // Disable attraction here to isolate the existing cluster resolver contract.
    let mut resize = scene
        .begin_resize(
            WindowId(1),
            ResizeEdges::Right,
            SnapOptions {
                threshold: 0.0,
                ..SnapOptions::default()
            },
            true,
        )
        .unwrap();
    let mut bonds = Vec::new();
    for delta in [-30, 20, 0, 35, -45, 60, 0] {
        let primary = Rect::new(0.0, 0.0, f64::from(100 + delta), 100.0);
        let (shifts, new_bonds) = resolve_cluster_shifts(
            &members,
            delta,
            0,
            12.0,
            &bonds,
            Some((snap_rect(rects[0]), snap_rect(primary))),
        );
        for bond in new_bonds {
            if !bonds.contains(&bond) {
                bonds.push(bond);
            }
        }
        scene
            .resize_to(&mut resize, Point::new(f64::from(delta), 0.0))
            .unwrap();
        for (i, &r) in rects[1..].iter().enumerate() {
            let (x, y) = shifts.get(&i).copied().unwrap_or_default();
            assert_rect(
                scene.window(WindowId(i as u64 + 2)).unwrap().world_rect,
                r.translated(Point::new(f64::from(x), f64::from(y))),
                "cluster reversal",
            );
        }
    }
}

#[test]
fn parity_resize_excludes_shifted_members_but_attracts_stationary_members() {
    let primary = Rect::new(0.0, 0.0, 100.0, 100.0);
    let stationary = Rect::new(0.0, 112.0, 200.0, 100.0);
    let mut scene = Scene::new();
    add(&mut scene, 1, primary);
    add(&mut scene, 2, Rect::new(112.0, 0.0, 100.0, 100.0));
    add(&mut scene, 3, stationary);
    let mut resize = scene
        .begin_resize(
            WindowId(1),
            ResizeEdges::Right,
            SnapOptions::default(),
            true,
        )
        .unwrap()
        .with_same_edge(true);
    let mut oracle = SnapState::default();
    // Upstream's exclude_set filters only is_shifted members, so the oracle
    // target set contains the unclassified, stationary lower neighbor.
    for delta in [20, 80, 100, 133, 80] {
        let mut width = 100 + delta;
        let mut height = 100;
        snap::snap_resize_edges(
            &mut oracle,
            8,
            (0, 0),
            (100, 100),
            0,
            0,
            &mut width,
            &mut height,
            &[snap_rect(stationary)],
            1.0,
            12.0,
            24.0,
            32.0,
            true,
        );
        let actual = scene
            .resize_to(&mut resize, Point::new(f64::from(delta), 0.0))
            .unwrap();
        assert_eq!(actual.size.width, f64::from(width));
        assert_eq!(
            scene.window(WindowId(2)).unwrap().world_rect.origin.x,
            f64::from(width) + 12.0
        );
        assert_eq!(scene.window(WindowId(3)).unwrap().world_rect, stationary);
    }
}

#[test]
fn parity_equal_candidates_keep_target_order_and_group_attraction_uses_primary() {
    let primary = Rect::new(0.0, 0.0, 100.0, 100.0);
    for reverse in [false, true] {
        let mut targets = [
            Rect::new(-110.0, 0.0, 100.0, 100.0),
            Rect::new(110.0, 0.0, 100.0, 100.0),
        ];
        if reverse {
            targets.reverse();
        }
        let others: Vec<_> = targets.into_iter().map(snap_rect).collect();
        let expected = upstream_drag(
            &mut SnapState::default(),
            primary,
            &others,
            1.0,
            false,
            false,
        );
        assert_eq!(expected.origin.x, if reverse { -2.0 } else { 2.0 });
        let mut scene = Scene::new();
        add(&mut scene, 1, primary);
        for (i, target) in targets.into_iter().enumerate() {
            add(&mut scene, i as u64 + 2, target);
        }
        let mut drag = scene
            .begin_drag(WindowId(1), SnapOptions::default(), 32.0, false)
            .unwrap();
        scene.drag_to(&mut drag, Point::default()).unwrap();
        assert_rect(
            scene.window(WindowId(1)).unwrap().world_rect,
            expected,
            "gesture candidate tie",
        );
    }

    let target = Rect::new(230.0, 0.0, 100.0, 100.0);
    let mut scene = Scene::new();
    add(&mut scene, 1, primary);
    add(&mut scene, 2, Rect::new(112.0, 0.0, 100.0, 100.0));
    add(&mut scene, 3, target);
    let expected = upstream_drag(
        &mut SnapState::default(),
        primary,
        &[snap_rect(target)],
        1.0,
        false,
        false,
    );
    let mut drag = scene
        .begin_drag(WindowId(1), SnapOptions::default(), 32.0, true)
        .unwrap();
    scene.drag_to(&mut drag, Point::default()).unwrap();
    assert_rect(
        scene.window(WindowId(1)).unwrap().world_rect,
        expected,
        "group primary attraction",
    );
    assert_eq!(
        scene.window(WindowId(2)).unwrap().world_rect.origin.x,
        112.0
    );
}
