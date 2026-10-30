// SPDX-License-Identifier: GPL-3.0-or-later
// New end-to-end public Scene API scenarios for the macOS canvas port.
use driftwm_canvas::{OutputId, Point, Rect, Scene, SnapOptions, Viewport, Window, WindowId};

fn window(id: u64, rect: Rect) -> Window {
    Window {
        id: WindowId(id),
        world_rect: rect,
    }
}
fn output(id: u64, camera: Point, zoom: f64, bounds: Rect) -> Viewport {
    Viewport {
        id: OutputId(id),
        camera,
        zoom,
        screen_bounds: bounds,
    }
}
fn close(a: Point, b: Point) {
    assert!(
        (a.x - b.x).abs() < 1e-8 && (a.y - b.y).abs() < 1e-8,
        "{a:?} != {b:?}"
    );
}

#[test]
fn camera_render_zoom_and_focus_flow() {
    let mut scene = Scene::new();
    scene
        .add_output(output(
            1,
            Point::default(),
            1.0,
            Rect::new(0.0, 0.0, 400.0, 300.0),
        ))
        .unwrap();
    // The screens physically overlap; the same world window is projected through
    // two different cameras, not assigned exclusively to one output.
    scene
        .add_output(output(
            2,
            Point::new(50.0, 0.0),
            0.5,
            Rect::new(100.0, 0.0, 300.0, 300.0),
        ))
        .unwrap();
    scene
        .add_window(window(1, Rect::new(20.0, 40.0, 200.0, 100.0)))
        .unwrap();
    scene
        .add_window(window(2, Rect::new(250.0, 40.0, 100.0, 100.0)))
        .unwrap();
    let original = scene.windows().to_vec();
    let placements = scene.placements();
    assert_eq!(
        placements
            .iter()
            .filter(|p| p.window == WindowId(1))
            .count(),
        2
    );
    let second = placements
        .iter()
        .find(|p| p.window == WindowId(1) && p.output == OutputId(2))
        .unwrap();
    assert_eq!(second.screen_rect, Rect::new(85.0, 20.0, 100.0, 50.0));
    assert_eq!(second.clip_rect, Rect::new(100.0, 20.0, 85.0, 50.0));
    assert_eq!(second.source_rect, Rect::new(30.0, 0.0, 170.0, 100.0));
    let other = scene.output(OutputId(2)).unwrap().clone();
    scene.pan(OutputId(1), Point::new(100.0, -50.0)).unwrap();
    let anchor = Point::new(70.0, 80.0);
    let anchored_world = scene.output(OutputId(1)).unwrap().screen_to_world(anchor);
    scene.zoom_at(OutputId(1), 0.25, anchor).unwrap();
    close(
        scene.output(OutputId(1)).unwrap().screen_to_world(anchor),
        anchored_world,
    );
    assert_eq!(scene.windows(), original);
    assert_eq!(scene.output(OutputId(2)).unwrap(), &other);
    scene.focus(WindowId(1)).unwrap();
    assert_eq!(scene.focused(), Some(WindowId(1)));
    scene.focus(WindowId(2)).unwrap();
    assert_eq!(scene.focused(), Some(WindowId(2)));
    assert_eq!(scene.windows().last().unwrap().id, WindowId(2));

    let before = scene.clone();
    assert!(scene.zoom_at(OutputId(1), 0.0, anchor).is_err());
    assert!(scene.pan(OutputId(1), Point::new(f64::NAN, 0.0)).is_err());
    assert_eq!(scene, before);
}

#[test]
fn docking_then_moving_a_group_excludes_corner_contact() {
    let mut scene = Scene::new();
    scene
        .add_window(window(1, Rect::new(0.0, 0.0, 100.0, 100.0)))
        .unwrap();
    scene
        .add_window(window(2, Rect::new(130.0, 0.0, 100.0, 100.0)))
        .unwrap();
    scene
        .add_window(window(3, Rect::new(230.0, 100.0, 100.0, 100.0)))
        .unwrap();
    let options = SnapOptions {
        gap: 0.0,
        threshold: 8.0,
        adjacency_tolerance: 0.01,
    };
    let mut drag = scene.begin_drag(WindowId(1), options, 32.0, false).unwrap();
    let displacement = scene.drag_to(&mut drag, Point::new(25.0, 0.0)).unwrap();
    assert_eq!(displacement, Point::new(30.0, 0.0));
    assert_eq!(
        scene.cluster(WindowId(1), options).unwrap(),
        vec![WindowId(1), WindowId(2)]
    );
    let corner_before = scene.window(WindowId(3)).unwrap().world_rect;
    let mut group = scene
        .begin_drag(
            WindowId(1),
            SnapOptions {
                threshold: 0.0,
                ..options
            },
            32.0,
            true,
        )
        .unwrap();
    scene.drag_to(&mut group, Point::new(-50.0, 70.0)).unwrap();
    assert_eq!(
        scene.window(WindowId(1)).unwrap().world_rect,
        Rect::new(-20.0, 70.0, 100.0, 100.0)
    );
    assert_eq!(
        scene.window(WindowId(2)).unwrap().world_rect,
        Rect::new(80.0, 70.0, 100.0, 100.0)
    );
    assert_eq!(scene.window(WindowId(3)).unwrap().world_rect, corner_before);
    let before = scene.clone();
    let gesture_before = group.clone();
    assert!(scene.drag_to(&mut group, Point::new(1e12, 0.0)).is_err());
    assert_eq!(group, gesture_before);
    assert_eq!(scene, before);
}

#[test]
fn serialized_scene_roundtrips_and_rejects_invalid_data() {
    let mut scene = Scene::new();
    scene
        .add_window(window(17, Rect::new(-500.0, 300.0, 900.0, 600.0)))
        .unwrap();
    scene
        .add_output(output(
            8,
            Point::new(-600.0, 100.0),
            0.5,
            Rect::new(-1920.0, 0.0, 1920.0, 1080.0),
        ))
        .unwrap();
    scene.focus(WindowId(17)).unwrap();
    let value = serde_json::to_value(&scene).unwrap();
    assert_eq!(
        value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["focused", "outputs", "windows"]
    );
    assert_eq!(
        serde_json::from_value::<Scene>(value.clone()).unwrap(),
        scene
    );

    let mut duplicate = value.clone();
    let first = value["windows"][0].clone();
    duplicate["windows"].as_array_mut().unwrap().push(first);
    let mut invalid_zoom = value.clone();
    invalid_zoom["outputs"][0]["zoom"] = 0.into();
    let mut invalid_rect = value.clone();
    invalid_rect["windows"][0]["world_rect"]["size"]["width"] = (-1).into();
    let mut bad_focus = value.clone();
    bad_focus["focused"] = 999.into();
    let mut bad_field = value;
    bad_field["unexpected"] = true.into();
    for malformed in [duplicate, invalid_zoom, invalid_rect, bad_focus, bad_field] {
        assert!(serde_json::from_value::<Scene>(malformed).is_err());
    }
}
