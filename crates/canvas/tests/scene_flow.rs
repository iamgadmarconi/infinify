// SPDX-License-Identifier: GPL-3.0-or-later
// New end-to-end public Scene API scenarios for the macOS canvas port.
use driftwm_canvas::{
    Direction, Error, Momentum, NativeIdentity, OutputId, Point, Rect, Scene, SnapOptions,
    Viewport, Window, WindowId,
};
use std::{fs, time::Duration};

fn window(id: u64, rect: Rect) -> Window {
    Window {
        id: WindowId(id),
        world_rect: rect,
        native: None,
        title: format!("Window {id}"),
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
fn camera_render_hit_focus_and_bookmark_flow() {
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
    let hit = scene
        .hit_test(OutputId(2), Point::new(110.0, 30.0))
        .unwrap();
    assert_eq!(hit.window, WindowId(1));
    close(hit.local, Point::new(50.0, 20.0));
    assert!(
        scene
            .hit_test(OutputId(2), Point::new(90.0, 30.0))
            .is_none()
    );

    let other = scene.output(OutputId(2)).unwrap().clone();
    scene.save_bookmark("start", OutputId(1)).unwrap();
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
    scene.restore_bookmark("start", OutputId(1)).unwrap();
    assert_eq!(scene.output(OutputId(1)).unwrap().camera, Point::default());
    assert_eq!(scene.output(OutputId(1)).unwrap().zoom, 1.0);
    scene.focus(WindowId(1)).unwrap();
    assert_eq!(
        scene
            .directional_focus(OutputId(1), Direction::Right)
            .unwrap(),
        Some(WindowId(2))
    );
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
    let displacement = scene
        .snap_move(WindowId(1), Point::new(25.0, 0.0), options, false)
        .unwrap();
    assert_eq!(displacement, Point::new(30.0, 0.0));
    assert_eq!(
        scene.cluster(WindowId(1), options).unwrap(),
        vec![WindowId(1), WindowId(2)]
    );
    let corner_before = scene.window(WindowId(3)).unwrap().world_rect;
    let moved = scene
        .move_cluster(WindowId(1), Point::new(-50.0, 70.0), options)
        .unwrap();
    assert_eq!(moved, vec![WindowId(1), WindowId(2)]);
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
    assert!(
        scene
            .move_cluster(WindowId(1), Point::new(1e12, 0.0), options)
            .is_err()
    );
    assert_eq!(scene, before);
}

#[test]
fn durable_roundtrip_detaches_native_binding_and_rejects_malformed_sessions() {
    let mut scene = Scene::new();
    let mut native = window(17, Rect::new(-500.0, 300.0, 900.0, 600.0));
    native.native = Some(NativeIdentity {
        pid: 123,
        window_id: 45,
    });
    scene.add_window(native).unwrap();
    scene
        .add_output(output(
            8,
            Point::new(-600.0, 100.0),
            0.5,
            Rect::new(-1920.0, 0.0, 1920.0, 1080.0),
        ))
        .unwrap();
    scene.focus(WindowId(17)).unwrap();
    scene.save_bookmark("work", OutputId(8)).unwrap();
    let json = scene.to_json().unwrap();
    assert!(!json.contains("native"));
    let mut restored = Scene::from_json(&json).unwrap();
    assert_eq!(restored.window(WindowId(17)).unwrap().native, None);
    assert_eq!(
        restored.window(WindowId(17)).unwrap().world_rect,
        scene.window(WindowId(17)).unwrap().world_rect
    );
    assert_eq!(restored.outputs(), scene.outputs());
    assert_eq!(restored.bookmarks(), scene.bookmarks());
    assert_eq!(restored.focused(), scene.focused());
    let binding = NativeIdentity {
        pid: 234,
        window_id: 56,
    };
    restored.bind_native(WindowId(17), Some(binding)).unwrap();
    assert_eq!(restored.window(WindowId(17)).unwrap().native, Some(binding));
    restored
        .add_window(window(18, Rect::new(700.0, 0.0, 100.0, 100.0)))
        .unwrap();
    assert!(restored.bind_native(WindowId(18), Some(binding)).is_err());
    assert_eq!(restored.window(WindowId(18)).unwrap().native, None);
    restored.remove_window(WindowId(18)).unwrap();
    restored.bind_native(WindowId(17), None).unwrap();
    let path = std::env::temp_dir().join(format!(
        "driftwm-scene-{}-{}.json",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    scene.save_atomic(&path).unwrap();
    assert_eq!(Scene::load(&path).unwrap(), restored);
    scene.pan(OutputId(8), Point::new(25.0, 0.0)).unwrap();
    scene.save_atomic(&path).unwrap();
    assert_eq!(Scene::load(&path).unwrap().outputs(), scene.outputs());

    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    let mut unknown = value.clone();
    unknown["version"] = 99.into();
    assert!(matches!(
        Scene::from_json(&unknown.to_string()),
        Err(Error::UnsupportedVersion(99))
    ));
    let mut duplicate = value.clone();
    duplicate["scene"]["windows"]
        .as_array_mut()
        .unwrap()
        .push(value["scene"]["windows"][0].clone());
    let mut invalid_zoom = value.clone();
    invalid_zoom["scene"]["outputs"][0]["zoom"] = 0.into();
    let mut invalid_rect = value.clone();
    invalid_rect["scene"]["windows"][0]["world_rect"]["size"]["width"] = (-1).into();
    let mut bad_focus = value.clone();
    bad_focus["scene"]["focused"] = 999.into();
    let mut bad_field = value;
    bad_field["scene"]["unexpected"] = true.into();
    for malformed in [duplicate, invalid_zoom, invalid_rect, bad_focus, bad_field] {
        let bytes = malformed.to_string();
        fs::write(&path, &bytes).unwrap();
        assert!(Scene::load(&path).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), bytes);
        assert!(serde_json::from_value::<Scene>(malformed["scene"].clone()).is_err());
    }
    assert!(Scene::from_json("{truncated").is_err());
    fs::remove_file(path).unwrap();
}

#[test]
fn momentum_drives_camera_without_changing_world() {
    let mut scene = Scene::new();
    scene
        .add_output(output(
            1,
            Point::default(),
            0.5,
            Rect::new(0.0, 0.0, 800.0, 600.0),
        ))
        .unwrap();
    scene
        .add_window(window(1, Rect::new(0.0, 0.0, 200.0, 100.0)))
        .unwrap();
    let rect = scene.window(WindowId(1)).unwrap().world_rect;
    let mut coast = Momentum::new(Point::new(500.0, 0.0), Duration::from_millis(150)).unwrap();
    for _ in 0..100 {
        if let Some(delta) = coast.tick(Duration::from_millis(16)) {
            scene.pan(OutputId(1), delta).unwrap();
        }
    }
    assert!(scene.output(OutputId(1)).unwrap().camera.x > 200.0);
    assert_eq!(scene.window(WindowId(1)).unwrap().world_rect, rect);
    assert_eq!(coast.velocity(), Point::default());
}
