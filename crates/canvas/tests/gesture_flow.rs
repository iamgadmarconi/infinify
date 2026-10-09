// SPDX-License-Identifier: GPL-3.0-or-later
// Public Scene API interactions; no native compositor behavior is asserted.
use driftwm_canvas::{
    OutputId, Point, Rect, ResizeEdges, Scene, SnapOptions, Viewport, Window, WindowId,
};

fn add(scene: &mut Scene, id: u64, rect: Rect) {
    scene
        .add_window(Window {
            id: WindowId(id),
            world_rect: rect,
            native: None,
            title: id.to_string(),
        })
        .unwrap();
}
fn frame(scene: &Scene, id: u64) -> Rect {
    scene.window(WindowId(id)).unwrap().world_rect
}
fn options() -> SnapOptions {
    SnapOptions {
        gap: 4.0,
        threshold: 8.0,
        adjacency_tolerance: 0.01,
    }
}
fn camera(scene: &mut Scene) {
    scene
        .add_output(Viewport {
            id: OutputId(1),
            camera: Point::new(50.0, -90.0),
            zoom: 0.5,
            screen_bounds: Rect::new(200.0, 100.0, 800.0, 600.0),
        })
        .unwrap();
}

#[test]
fn drag_latches_releases_cools_down_and_never_accumulates_motion() {
    let mut scene = Scene::new();
    camera(&mut scene);
    add(&mut scene, 1, Rect::new(0.0, 0.0, 100.0, 100.0));
    add(&mut scene, 2, Rect::new(134.0, 0.0, 100.0, 100.0));
    let outputs = scene.outputs().to_vec();
    // Caller's screen displacement and thresholds use the frozen start zoom.
    let zoom = scene.output(OutputId(1)).unwrap().zoom;
    let mut snap = options();
    snap.threshold = 4.0 / zoom;
    let mut drag = scene
        .begin_drag(WindowId(1), snap, 3.0 / zoom, false)
        .unwrap();
    for _ in 0..25 {
        assert_eq!(
            scene
                .drag_to(&mut drag, Point::new(13.0, 0.0) / zoom)
                .unwrap(),
            Point::new(30.0, 0.0)
        );
    }
    // Retreat breaks relative to engagement (26), even though target is 30.
    assert_eq!(
        scene.drag_to(&mut drag, Point::new(20.0, 0.0)).unwrap().x,
        20.0
    );
    // Still in cooldown band: no immediate snap back at the same 26 position.
    assert_eq!(
        scene.drag_to(&mut drag, Point::new(26.0, 0.0)).unwrap().x,
        26.0
    );
    scene.drag_to(&mut drag, Point::new(10.0, 0.0)).unwrap();
    assert_eq!(
        scene.drag_to(&mut drag, Point::new(26.0, 0.0)).unwrap().x,
        30.0
    );
    assert_eq!(
        scene.drag_to(&mut drag, Point::new(35.0, 0.0)).unwrap().x,
        30.0
    );
    assert_eq!(
        scene.drag_to(&mut drag, Point::new(36.0, 0.0)).unwrap().x,
        36.0
    );
    assert_eq!(frame(&scene, 2), Rect::new(134.0, 0.0, 100.0, 100.0));
    assert_eq!(scene.outputs(), outputs);
}

#[test]
fn drag_membership_is_frozen_and_errors_preserve_latch_state() {
    let mut scene = Scene::new();
    add(&mut scene, 1, Rect::new(0.0, 0.0, 100.0, 100.0));
    add(&mut scene, 2, Rect::new(-104.0, 0.0, 100.0, 100.0));
    add(&mut scene, 3, Rect::new(134.0, 0.0, 100.0, 100.0));
    let mut drag = scene.begin_drag(WindowId(1), options(), 6.0, true).unwrap();
    scene.drag_to(&mut drag, Point::new(26.0, 0.0)).unwrap();
    assert_eq!(frame(&scene, 2).origin.x, -74.0);
    // Window 3 became adjacent, but the next update must not recruit it.
    scene.drag_to(&mut drag, Point::new(100.0, 0.0)).unwrap();
    assert_eq!(frame(&scene, 3).origin.x, 134.0);
    assert_eq!(frame(&scene, 2).origin.x, -4.0);
    for delta in [Point::new(f64::NAN, 0.0), Point::new(1e12, 0.0)] {
        let before = scene.clone();
        let gesture_before = drag.clone();
        assert!(scene.drag_to(&mut drag, delta).is_err());
        assert_eq!(scene, before);
        assert_eq!(drag, gesture_before);
    }
    scene.remove_window(WindowId(2)).unwrap();
    let before = scene.clone();
    let gesture_before = drag.clone();
    assert!(scene.drag_to(&mut drag, Point::new(10.0, 0.0)).is_err());
    assert_eq!(scene, before);
    assert_eq!(drag, gesture_before);
}

#[test]
fn held_axis_uses_visible_overlap_for_the_other_snap_axis() {
    let mut scene = Scene::new();
    add(&mut scene, 1, Rect::new(0.0, 0.0, 100.0, 100.0));
    add(&mut scene, 2, Rect::new(0.0, 134.0, 100.0, 100.0));
    let mut drag = scene
        .begin_drag(WindowId(1), options(), 30.0, false)
        .unwrap();
    scene.drag_to(&mut drag, Point::new(0.0, 26.0)).unwrap();
    add(&mut scene, 3, Rect::new(134.0, 131.0, 100.0, 100.0));
    // Natural bottom is 145, but visible bottom is held at 130: no X snap to 3.
    assert_eq!(
        scene.drag_to(&mut drag, Point::new(26.0, 45.0)).unwrap(),
        Point::new(26.0, 30.0)
    );
}

fn rotate(rect: Rect) -> Rect {
    Rect::new(
        -rect.bottom(),
        rect.origin.x,
        rect.size.height,
        rect.size.width,
    )
}
fn rotate_n(mut rect: Rect, n: usize) -> Rect {
    for _ in 0..n {
        rect = rotate(rect);
    }
    rect
}
fn rotate_delta(mut delta: Point, n: usize) -> Point {
    for _ in 0..n {
        delta = Point::new(-delta.y, delta.x);
    }
    delta
}

#[test]
fn resizing_each_side_propagates_downstream_and_preserves_other_members() {
    for (rotation, edge) in [
        ResizeEdges::Right,
        ResizeEdges::Bottom,
        ResizeEdges::Left,
        ResizeEdges::Top,
    ]
    .into_iter()
    .enumerate()
    {
        let mut scene = Scene::new();
        camera(&mut scene);
        let initial = [
            Rect::new(0.0, 0.0, 100.0, 100.0),
            Rect::new(104.0, 0.0, 100.0, 100.0),
            Rect::new(208.0, 0.0, 100.0, 100.0),
            Rect::new(0.0, -104.0, 100.0, 100.0),
            Rect::new(500.0, 500.0, 100.0, 100.0),
        ];
        for (index, rect) in initial.into_iter().enumerate() {
            add(&mut scene, index as u64 + 1, rotate_n(rect, rotation));
        }
        let outputs = scene.outputs().to_vec();
        let mut resize = scene
            .begin_resize(WindowId(1), edge, options(), true)
            .unwrap();
        for _ in 0..25 {
            scene
                .resize_to(&mut resize, rotate_delta(Point::new(20.5, 0.0), rotation))
                .unwrap();
        }
        assert_eq!(
            frame(&scene, 1),
            rotate_n(Rect::new(0.0, 0.0, 120.5, 100.0), rotation)
        );
        for id in [2, 3] {
            assert_eq!(
                frame(&scene, id),
                rotate_n(
                    initial[id as usize - 1].translated(Point::new(20.5, 0.0)),
                    rotation
                )
            );
        }
        for id in [4, 5] {
            assert_eq!(
                frame(&scene, id),
                rotate_n(initial[id as usize - 1], rotation)
            );
        }
        // Shrink uses the same snapshot; returning to zero restores original frames.
        scene
            .resize_to(&mut resize, rotate_delta(Point::new(-20.0, 0.0), rotation))
            .unwrap();
        scene.resize_to(&mut resize, Point::default()).unwrap();
        for (index, rect) in initial.into_iter().enumerate() {
            assert_eq!(frame(&scene, index as u64 + 1), rotate_n(rect, rotation));
        }
        assert_eq!(scene.outputs(), outputs);
    }
}

#[test]
fn corner_resize_moves_both_downstream_axes_without_changing_member_sizes() {
    let mut scene = Scene::new();
    for (id, x, y) in [
        (1, 0.0, 0.0),
        (2, 104.0, 0.0),
        (3, 0.0, 104.0),
        (4, 104.0, 104.0),
    ] {
        add(&mut scene, id, Rect::new(x, y, 100.0, 100.0));
    }
    let mut resize = scene
        .begin_resize(WindowId(1), ResizeEdges::BottomRight, options(), true)
        .unwrap();
    scene
        .resize_to(&mut resize, Point::new(20.0, 30.0))
        .unwrap();
    assert_eq!(frame(&scene, 1), Rect::new(0.0, 0.0, 120.0, 130.0));
    assert_eq!(frame(&scene, 2), Rect::new(124.0, 0.0, 100.0, 100.0));
    assert_eq!(frame(&scene, 3), Rect::new(0.0, 134.0, 100.0, 100.0));
    assert_eq!(frame(&scene, 4), Rect::new(124.0, 134.0, 100.0, 100.0));
}

#[test]
fn resize_collision_bonds_follow_reversal_without_recruiting_new_members() {
    let mut scene = Scene::new();
    for (id, x, y) in [
        (1, 0.0, 0.0),
        (2, 104.0, 0.0),
        (3, 104.0, 104.0),
        (4, 0.0, 104.0),
    ] {
        add(&mut scene, id, Rect::new(x, y, 100.0, 100.0));
    }
    let mut resize = scene
        .begin_resize(WindowId(1), ResizeEdges::Right, options(), true)
        .unwrap();
    // A late-arriving adjacent window cannot join the captured component.
    add(&mut scene, 5, Rect::new(208.0, 0.0, 100.0, 100.0));
    scene
        .resize_to(&mut resize, Point::new(-30.0, 0.0))
        .unwrap();
    assert_eq!(frame(&scene, 4).origin.x, -30.0);
    // The lower-left member now follows its right-hand neighbor on reversal.
    for _ in 0..25 {
        scene.resize_to(&mut resize, Point::new(20.0, 0.0)).unwrap();
    }
    assert_eq!(frame(&scene, 4), Rect::new(20.0, 104.0, 100.0, 100.0));
    assert_eq!(frame(&scene, 5), Rect::new(208.0, 0.0, 100.0, 100.0));
}

#[test]
fn rejected_resizes_and_stale_members_are_atomic() {
    let mut scene = Scene::new();
    add(&mut scene, 1, Rect::new(0.0, 0.0, 100.0, 100.0));
    add(&mut scene, 2, Rect::new(104.0, 0.0, 1e12 - 104.0, 100.0));
    assert!(
        scene
            .begin_resize(WindowId(99), ResizeEdges::Right, options(), true)
            .is_err()
    );
    assert!(
        scene
            .begin_drag(WindowId(99), options(), 6.0, false)
            .is_err()
    );
    assert!(
        scene
            .begin_drag(WindowId(1), options(), f64::NAN, false)
            .is_err()
    );
    let mut invalid = options();
    invalid.gap = f64::INFINITY;
    assert!(
        scene
            .begin_resize(WindowId(1), ResizeEdges::Left, invalid, true)
            .is_err()
    );
    let mut resize = scene
        .begin_resize(WindowId(1), ResizeEdges::Right, options(), true)
        .unwrap();
    for delta in [
        Point::new(1.0, 0.0),
        Point::new(-100.0, 0.0),
        Point::new(0.0, f64::NAN),
    ] {
        let before = scene.clone();
        let gesture_before = resize.clone();
        assert!(scene.resize_to(&mut resize, delta).is_err());
        assert_eq!(scene, before);
        assert_eq!(resize, gesture_before);
    }
    // Even a valid primary frame cannot overwrite an externally moved member.
    scene
        .move_window(WindowId(2), Point::new(-1.0, 0.0))
        .unwrap();
    let before = scene.clone();
    let gesture_before = resize.clone();
    assert!(
        scene
            .resize_to(&mut resize, Point::new(-20.0, 0.0))
            .is_err()
    );
    assert_eq!(scene, before);
    assert_eq!(resize, gesture_before);
    scene.remove_window(WindowId(2)).unwrap();
    let before = scene.clone();
    assert!(
        scene
            .resize_to(&mut resize, Point::new(-20.0, 0.0))
            .is_err()
    );
    assert_eq!(scene, before);
    assert_eq!(resize, gesture_before);
}
