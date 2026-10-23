// SPDX-License-Identifier: GPL-3.0-or-later
// Source geometry transactions and the unchanged-observation fast path.
// Geometry never establishes current native authority.
use super::*;

impl Controller {
    pub(crate) fn observe_source(
        &mut self,
        window: WindowId,
        identity: &SourceIdentity,
        source_rect: Rect,
        buffer: BufferSize,
        adopt_size: bool,
    ) -> Result<Value, Error> {
        self.guard_resize_structure(Some(window))?;
        let native_size_changed =
            self.fresh(window, identity)?.observed_rect.size != source_rect.size;
        buffer.validate()?;
        if !rect_valid(source_rect) {
            return Err(Error::Invalid("invalid observed source rectangle"));
        }
        let source = self
            .sources
            .get_mut(&window)
            .ok_or(Error::Invalid("unbound source"))?;
        if source.buffer.width != buffer.width || source.buffer.height != buffer.height {
            source.content_rect = buffer.full_rect();
        }
        source.observed_rect = source_rect;
        source.buffer = buffer;
        // A presentation handoff can change native geometry without changing
        // the canvas frame. Repeating that basis is not a new application resize.
        if adopt_size && native_size_changed && self.sizes.capability && self.gesture.is_none() {
            let mut rect = self
                .scene
                .window(window)
                .ok_or(Error::Invalid("unknown window"))?
                .world_rect;
            if rect.size != source_rect.size {
                rect.size = source_rect.size;
                self.scene.set_window_rect(window, rect)?;
                return Ok(json!({"resized": true}));
            }
        }
        Ok(json!({}))
    }

    pub(crate) fn relocate_source(
        &mut self,
        window: WindowId,
        identity: &SourceIdentity,
        generation: u64,
        observed_rect: Rect,
        expected_world_rect: Rect,
        delta: Point,
    ) -> Result<Value, Error> {
        self.guard_resize_structure(Some(window))?;
        self.check_generation(window, identity, generation)?;
        if !rect_valid(observed_rect) || !rect_valid(expected_world_rect) || !point_valid(delta) {
            return Err(Error::Invalid("invalid source displacement"));
        }
        if self.fresh(window, identity)?.observed_rect != observed_rect {
            return Err(Error::Invalid("stale source displacement"));
        }
        let mut rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        if rect != expected_world_rect
            || rect.size != observed_rect.size
            || delta == Point::default()
            || !self.sizes.capability
        {
            return Ok(json!({"moved":false,"deferred":false}));
        }
        // Fullscreen and size restoration reserve their own window only.
        // DriftWM 352333a8's fullscreen.rs locks its target output, not an
        // unrelated ordinary window on another output. Live canvas gestures
        // still reserve their anchors; the adapter retries after they end.
        if self.gesture.is_some()
            || self.trackpad_gesture.is_some()
            || self.sizes.observation_blocked(window)
            || self.fullscreen.observation_blocked(window)
        {
            return Ok(json!({"moved":false,"deferred":true}));
        }
        let pin = self
            .policy
            .pins
            .get(&window)
            .map(|pin| self.screen_pin_relocation(*pin, delta, rect.size))
            .transpose()?;
        let pin = match pin {
            Some((placement, pin)) => {
                rect = placement;
                Some(pin)
            }
            None => {
                rect.origin = rect.origin + delta;
                None
            }
        };
        self.scene.set_window_rect(window, rect)?;
        if let Some(pin) = pin {
            self.policy.pins.insert(window, pin);
        }
        // Native observation has already advanced independently. Changing the
        // expected world frame makes a repeated receipt harmless.
        Ok(json!({"moved":true,"deferred":false}))
    }
    pub(crate) fn observation_current(
        &self,
        window: WindowId,
        identity: &SourceIdentity,
        source_rect: Rect,
        buffer: BufferSize,
    ) -> bool {
        // Pending structure still needs the ordinary transactional path,
        // including runs without native resize capability. A stable native
        // basis may intentionally differ from its canvas size after a handoff.
        // Pins alone are already settled by every successful scene mutation;
        // unchanged native metadata cannot move or resize them. Keeping one
        // screen pin must not invalidate this shortcut for the whole desktop.
        if !self.sizes.observation_idle()
            || !self.fullscreen_observation_idle()
            || self.gesture.is_some()
            || self.trackpad_gesture.is_some()
            || self.guard_resize_structure(None).is_err()
            || !self.policy.sizing.is_empty()
            || !self.lifecycle.standins.is_empty()
            || !self.lifecycle.relaunching.is_empty()
            || !self.lifecycle.marks.is_empty()
            || !self.lifecycle.held.is_empty()
            || buffer.validate().is_err()
            || !rect_valid(source_rect)
        {
            return false;
        }
        let Ok(source) = self.fresh(window, identity) else {
            return false;
        };
        source.observed_rect == source_rect
            && source.buffer.width == buffer.width
            && source.buffer.height == buffer.height
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (Controller, WindowId, SourceIdentity) {
        let mut controller = Controller::new();
        let mut call = |command| {
            controller
                .request(&serde_json::to_vec(&json!({"version": 1, "command": command})).unwrap())
                .unwrap()
        };
        call(
            json!({"op":"register_output","stable_id":"observation-test","screen_bounds":Rect::new(0.,0.,1000.,800.)}),
        );
        call(json!({"op":"native_resize_capability","enabled":true}));
        let identity = SourceIdentity {
            pid: 123,
            birth_sec: 1800000000,
            birth_usec: 5,
            wid: 456,
            owner: None,
        };
        let reply = call(
            json!({"op":"attach","identity":identity,"bundle_id":"test","title":"window","buffer":{"width":400,"height":300},"source_rect":Rect::new(10.,20.,200.,150.),"world_rect":Rect::new(100.,100.,200.,150.)}),
        );
        (
            controller,
            WindowId(reply["window"].as_u64().unwrap()),
            identity,
        )
    }

    fn current(controller: &Controller, window: WindowId, identity: &SourceIdentity) -> bool {
        controller.observation_current(
            window,
            identity,
            Rect::new(10., 20., 200., 150.),
            BufferSize {
                width: 400,
                height: 300,
            },
        )
    }

    #[test]
    fn identical_native_observation_is_current() {
        let (controller, window, identity) = setup();
        assert!(current(&controller, window, &identity));
    }

    #[test]
    fn unchanged_native_size_does_not_undo_completed_canvas_gesture() {
        let (mut controller, window, identity) = setup();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::BeginResize {
                    window,
                    output: OutputId(1),
                    edges: Edges::BottomRight,
                    group: false,
                },
            })
            .unwrap();
        assert!(!current(&controller, window, &identity));
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::GestureTo {
                    screen_delta: Point::new(40., 30.),
                    pointer: None,
                },
            })
            .unwrap();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::EndGesture {},
            })
            .unwrap();
        assert!(current(&controller, window, &identity));
        let placed = controller.scene.window(window).unwrap().world_rect;
        assert_ne!(placed.size, Size::new(200., 150.));
        let result = controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::Observe {
                    window,
                    identity: identity.clone(),
                    source_rect: Rect::new(10., 20., 200., 150.),
                    buffer: BufferSize {
                        width: 400,
                        height: 300,
                    },
                },
            })
            .unwrap();
        // The former rule re-adopted any world/native mismatch. A fresh native
        // size change is now required; an unchanged poll preserves the gesture.
        assert!(result.get("resized").is_none());
        assert_eq!(controller.scene.window(window).unwrap().world_rect, placed);
        assert!(current(&controller, window, &identity));
    }

    #[test]
    fn presentation_basis_preserves_world_until_a_new_native_size_change() {
        let (mut controller, window, identity) = setup();
        let original = controller.scene.window(window).unwrap().world_rect;
        let basis = Rect::new(30., 45., 320., 240.);
        let buffer = BufferSize {
            width: 640,
            height: 480,
        };
        let reply = controller
            .request(
                &serde_json::to_vec(&json!({"version":1,"command":{
                    "op":"observe_presentation","window":window,"identity":identity,
                    "source_rect":basis,"buffer":buffer
                }}))
                .unwrap(),
            )
            .unwrap();
        assert!(reply.get("resized").is_none());
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            original
        );
        assert_eq!(controller.sources[&window].observed_rect, basis);
        assert_eq!(controller.sources[&window].content_rect, buffer.full_rect());
        assert!(controller.observation_current(window, &identity, basis, buffer));

        for observed in [basis, Rect::new(31., 46., 320., 240.)] {
            let reply = controller
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::Observe {
                        window,
                        identity: identity.clone(),
                        source_rect: observed,
                        buffer,
                    },
                })
                .unwrap();
            assert!(reply.get("resized").is_none());
            assert_eq!(
                controller.scene.window(window).unwrap().world_rect,
                original
            );
        }

        let changed = Rect::new(31., 46., 330., 250.);
        let reply = controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::Observe {
                    window,
                    identity: identity.clone(),
                    source_rect: changed,
                    buffer,
                },
            })
            .unwrap();
        assert_eq!(reply["resized"], true);
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            Rect {
                origin: original.origin,
                size: changed.size
            }
        );
    }

    #[test]
    fn presentation_observation_rejects_invalid_or_stale_basis_atomically() {
        let (mut controller, window, identity) = setup();
        let original = controller.sources[&window].clone();
        let world = controller.scene.window(window).unwrap().world_rect;
        let mut stale = identity.clone();
        stale.birth_sec += 1;
        for (candidate, rect, buffer) in [
            (
                stale,
                Rect::new(30., 45., 320., 240.),
                BufferSize {
                    width: 640,
                    height: 480,
                },
            ),
            (
                identity.clone(),
                Rect::new(30., 45., 0., 240.),
                BufferSize {
                    width: 640,
                    height: 480,
                },
            ),
            (
                identity,
                Rect::new(30., 45., 320., 240.),
                BufferSize {
                    width: 0,
                    height: 480,
                },
            ),
        ] {
            assert!(
                controller
                    .execute(Request {
                        version: ABI_VERSION,
                        command: Command::ObservePresentation {
                            window,
                            identity: candidate,
                            source_rect: rect,
                            buffer
                        }
                    })
                    .is_err()
            );
            assert_eq!(
                controller.sources[&window].observed_rect,
                original.observed_rect
            );
            assert_eq!(
                controller.sources[&window].buffer.width,
                original.buffer.width
            );
            assert_eq!(
                controller.sources[&window].content_rect,
                original.content_rect
            );
            assert_eq!(controller.scene.window(window).unwrap().world_rect, world);
        }
    }

    #[test]
    fn rebind_and_changed_capture_metadata_require_observation() {
        let (mut controller, window, identity) = setup();
        let mut replaced = identity.clone();
        replaced.birth_sec += 1;
        controller.sources.get_mut(&window).unwrap().identity = replaced;
        assert!(!current(&controller, window, &identity));
        controller.sources.get_mut(&window).unwrap().identity = identity.clone();
        controller.sources.get_mut(&window).unwrap().buffer.width += 1;
        assert!(!current(&controller, window, &identity));
    }

    #[test]
    fn disabled_native_resize_never_skips_observation() {
        let (mut controller, window, identity) = setup();
        controller.sizes.capability = false;
        assert!(!current(&controller, window, &identity));
    }

    fn observe_move(
        controller: &mut Controller,
        window: WindowId,
        identity: &SourceIdentity,
    ) -> Rect {
        let observed = Rect::new(30., 35., 200., 150.);
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::Observe {
                    window,
                    identity: identity.clone(),
                    source_rect: observed,
                    buffer: BufferSize {
                        width: 400,
                        height: 300,
                    },
                },
            })
            .unwrap();
        observed
    }

    fn relocate(
        controller: &mut Controller,
        window: WindowId,
        identity: &SourceIdentity,
        observed_rect: Rect,
        expected_world_rect: Rect,
        delta: Point,
    ) -> Result<Value, Error> {
        controller.execute(Request {
            version: ABI_VERSION,
            command: Command::RelocateSource {
                window,
                identity: identity.clone(),
                generation: controller.sources[&window].generation,
                observed_rect,
                expected_world_rect,
                delta,
            },
        })
    }

    #[test]
    fn native_owner_relocation_keeps_a_pin_partly_outside_its_output() {
        for (at, pointer, delta) in [
            (
                Point::new(-50., 100.),
                Point::new(50., 150.),
                Point::new(5., 0.),
            ),
            (
                Point::new(900., 100.),
                Point::new(950., 150.),
                Point::new(5., 0.),
            ),
            (
                Point::new(100., -50.),
                Point::new(150., 50.),
                Point::new(0., 5.),
            ),
            (
                Point::new(100., 750.),
                Point::new(150., 775.),
                Point::new(0., 5.),
            ),
        ] {
            let (mut controller, window, identity) = setup();
            controller
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::Zoom {
                        output: OutputId(1),
                        zoom: 0.5,
                        anchor: Point::default(),
                    },
                })
                .unwrap();
            controller.pin_window(window, Some(OutputId(1))).unwrap();
            let pin = controller.policy.pins[&window];
            let start = Point::new(f64::from(pin.screen_pos[0]), f64::from(pin.screen_pos[1]));
            for command in [
                Command::BeginDrag {
                    window,
                    output: OutputId(1),
                    group: false,
                },
                Command::GestureTo {
                    screen_delta: at - start,
                    pointer: Some(pointer),
                },
                Command::EndGesture {},
            ] {
                controller
                    .execute(Request {
                        version: ABI_VERSION,
                        command,
                    })
                    .unwrap();
            }
            assert_eq!(
                controller.policy.pins[&window].screen_pos,
                [at.x as i32, at.y as i32]
            );
            // A native-owned pair subsequently settles five screen points
            // farther along the edge. Adoption must preserve its release site,
            // just as the managed pin drag does, regardless of camera zoom.
            let observed = observe_move(&mut controller, window, &identity);
            let expected = controller.scene.window(window).unwrap().world_rect;
            let camera = controller.scene.output(OutputId(1)).unwrap().camera;
            assert_eq!(
                relocate(
                    &mut controller,
                    window,
                    &identity,
                    observed,
                    expected,
                    delta
                )
                .unwrap(),
                json!({"moved":true,"deferred":false})
            );
            let released = at + delta;
            assert_eq!(
                controller.policy.pins[&window].screen_pos,
                [released.x as i32, released.y as i32]
            );
            let placed = controller.scene.window(window).unwrap().world_rect;
            assert_eq!(placed.origin, expected.origin + delta / 0.5);
            assert_eq!(placed.size, expected.size);
            assert_eq!(controller.scene.output(OutputId(1)).unwrap().camera, camera);
            assert_eq!(
                relocate(
                    &mut controller,
                    window,
                    &identity,
                    observed,
                    expected,
                    delta
                )
                .unwrap(),
                json!({"moved":false,"deferred":false})
            );
            assert_eq!(controller.scene.window(window).unwrap().world_rect, placed);
        }
    }

    #[test]
    fn native_screen_pin_arrival_still_clamps_the_whole_frame() {
        let (controller, _, _) = setup();
        let Arrival::Pin { rect, pin } = controller
            .screen_pin_arrival(
                &SourceScreenPin {
                    output: OutputId(1),
                    screen_pos: Point::new(-50., 900.),
                },
                Size::new(200., 150.),
            )
            .unwrap()
        else {
            panic!("expected screen pin arrival");
        };
        assert_eq!(pin.screen_pos, [0, 650]);
        assert_eq!(rect, Rect::new(0., 650., 200., 150.));
    }

    #[test]
    fn native_owner_pin_relocation_refuses_unrepresentable_positions_atomically() {
        let (mut controller, window, identity) = setup();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::Zoom {
                    output: OutputId(1),
                    zoom: 0.5,
                    anchor: Point::default(),
                },
            })
            .unwrap();
        controller.pin_window(window, Some(OutputId(1))).unwrap();
        let observed = observe_move(&mut controller, window, &identity);
        let expected = controller.scene.window(window).unwrap().world_rect;
        let pin = controller.policy.pins[&window];
        for delta in [
            Point::new(f64::from(i32::MAX) + 1., 0.),
            Point::new(f64::NAN, 0.),
            // Screen coordinates still fit, but the corresponding canvas
            // origin at zoom .5 cannot be represented by later IPC requests.
            Point::new(f64::from(i32::MAX) / 2. + 1., 0.),
        ] {
            assert!(
                relocate(
                    &mut controller,
                    window,
                    &identity,
                    observed,
                    expected,
                    delta
                )
                .is_err()
            );
            assert_eq!(controller.policy.pins[&window], pin);
            assert_eq!(
                controller.scene.window(window).unwrap().world_rect,
                expected
            );
            assert_eq!(controller.sources[&window].observed_rect, observed);
        }
    }

    #[test]
    fn deferred_owner_move_retries_after_gesture_without_replaying_native_observation() {
        let (mut controller, window, identity) = setup();
        let expected = controller.scene.window(window).unwrap().world_rect;
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::BeginDrag {
                    window,
                    output: OutputId(1),
                    group: false,
                },
            })
            .unwrap();
        let observed = observe_move(&mut controller, window, &identity);
        let delta = Point::new(20., 15.);
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                delta
            )
            .unwrap(),
            json!({"moved":false,"deferred":true})
        );
        assert_eq!(controller.sources[&window].observed_rect, observed);
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::EndGesture {},
            })
            .unwrap();
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                delta
            )
            .unwrap(),
            json!({"moved":true,"deferred":false})
        );
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            Rect::new(120., 115., 200., 150.)
        );
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                delta
            )
            .unwrap(),
            json!({"moved":false,"deferred":false})
        );
    }

    #[test]
    fn independent_canvas_move_supersedes_deferred_owner_move() {
        let (mut controller, window, identity) = setup();
        let expected = controller.scene.window(window).unwrap().world_rect;
        let observed = observe_move(&mut controller, window, &identity);
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::BeginDrag {
                    window,
                    output: OutputId(1),
                    group: false,
                },
            })
            .unwrap();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::GestureTo {
                    screen_delta: Point::new(50., 0.),
                    pointer: None,
                },
            })
            .unwrap();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::EndGesture {},
            })
            .unwrap();
        let placed = controller.scene.window(window).unwrap().world_rect;
        assert_ne!(placed, expected);
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                Point::new(20., 15.)
            )
            .unwrap(),
            json!({"moved":false,"deferred":false})
        );
        assert_eq!(controller.scene.window(window).unwrap().world_rect, placed);
    }

    #[test]
    fn unrelated_fullscreen_and_its_resize_do_not_discard_ordinary_owner_move() {
        let (mut controller, fullscreen, _) = setup();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::RegisterOutput {
                    stable_id: "other".to_owned(),
                    screen_bounds: Rect::new(1000., 0., 1000., 800.),
                    usable_rect_local: None,
                },
            })
            .unwrap();
        let identity = SourceIdentity {
            pid: 124,
            birth_sec: 1800000000,
            birth_usec: 6,
            wid: 457,
            owner: None,
        };
        let attached = controller.request(&serde_json::to_vec(&json!({"version":1,"command":{"op":"attach","identity":identity,"bundle_id":"other","title":"ordinary","buffer":{"width":400,"height":300},"source_rect":Rect::new(10.,20.,200.,150.),"world_rect":Rect::new(1200.,100.,200.,150.)}})).unwrap()).unwrap();
        let window = WindowId(attached["window"].as_u64().unwrap());
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::Focus { window: fullscreen },
            })
            .unwrap();
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::Action {
                    output: Some(OutputId(1)),
                    action: "toggle-fullscreen".to_owned(),
                    pointer: None,
                    held: false,
                },
            })
            .unwrap();
        assert!(controller.is_fullscreen(fullscreen));
        assert!(controller.resize_slot().unwrap().live);
        let expected = controller.scene.window(window).unwrap().world_rect;
        let observed = observe_move(&mut controller, window, &identity);
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                Point::new(20., 15.)
            )
            .unwrap(),
            json!({"moved":true,"deferred":false})
        );
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            Rect::new(1220., 115., 200., 150.)
        );
    }

    #[test]
    fn own_native_resize_keeps_owner_movement_out_of_its_ax_result() {
        let (mut controller, window, identity) = setup();
        let expected = controller.scene.window(window).unwrap().world_rect;
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::BeginNativeResize {
                    window,
                    output: OutputId(1),
                    edges: Some(Edges::Right),
                    start_screen: Point::new(300., 175.),
                    group: false,
                },
            })
            .unwrap();
        assert!(
            controller
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::ObservePresentation {
                        window,
                        identity: identity.clone(),
                        source_rect: Rect::new(30., 45., 320., 240.),
                        buffer: BufferSize {
                            width: 640,
                            height: 480
                        },
                    },
                })
                .is_err()
        );
        assert_eq!(
            controller.sources[&window].observed_rect,
            Rect::new(10., 20., 200., 150.)
        );
        assert!(
            relocate(
                &mut controller,
                window,
                &identity,
                Rect::new(10., 20., 200., 150.),
                expected,
                Point::new(20., 15.)
            )
            .is_err()
        );
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            expected
        );
    }

    #[test]
    fn net_zero_owner_move_has_nothing_to_defer() {
        let (mut controller, window, identity) = setup();
        let expected = controller.scene.window(window).unwrap().world_rect;
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                Rect::new(10., 20., 200., 150.),
                expected,
                Point::default()
            )
            .unwrap(),
            json!({"moved":false,"deferred":false})
        );
    }

    #[test]
    fn unsupported_owner_move_is_a_terminal_refusal() {
        let (mut controller, window, identity) = setup();
        let expected = controller.scene.window(window).unwrap().world_rect;
        let observed = observe_move(&mut controller, window, &identity);
        controller.sizes.capability = false;
        assert_eq!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                Point::new(20., 15.)
            )
            .unwrap(),
            json!({"moved":false,"deferred":false})
        );
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            expected
        );
    }

    #[test]
    fn deferred_owner_move_rejects_stale_native_metadata_and_rebound_identity() {
        let (mut controller, window, identity) = setup();
        let expected = controller.scene.window(window).unwrap().world_rect;
        let observed = observe_move(&mut controller, window, &identity);
        assert!(
            relocate(
                &mut controller,
                window,
                &identity,
                Rect::new(10., 20., 200., 150.),
                expected,
                Point::new(20., 15.)
            )
            .is_err()
        );
        controller
            .sources
            .get_mut(&window)
            .unwrap()
            .identity
            .birth_sec += 1;
        assert!(
            relocate(
                &mut controller,
                window,
                &identity,
                observed,
                expected,
                Point::new(20., 15.)
            )
            .is_err()
        );
        assert_eq!(
            controller.scene.window(window).unwrap().world_rect,
            expected
        );
    }
    // Compare the no-op shortcut with the complete Observe transaction,
    // including fields absent from Snapshot. Real native authority is still
    // checked by the adapter before this controller-only decision.
    fn assert_settled_observations_are_noops(controller: &Controller) {
        for (&window, source) in &controller.sources {
            let before = format!("{controller:?}");
            let mut reference = controller.clone();
            reference
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::Observe {
                        window,
                        identity: source.identity.clone(),
                        source_rect: source.observed_rect,
                        buffer: source.buffer,
                    },
                })
                .unwrap();
            assert_eq!(format!("{reference:?}"), before);
            assert!(controller.observation_current(
                window,
                &source.identity,
                source.observed_rect,
                source.buffer,
            ));
        }
    }

    fn pinned_observation_scene() -> (Controller, WindowId, SourceIdentity) {
        let (mut controller, window, identity) = setup();
        controller
            .request(
                &serde_json::to_vec(&json!({"version":1,"command":{
                    "op":"ipc","output":1,"request":{"Pin":{"window":window,"value":true}}
                }}))
                .unwrap(),
            )
            .unwrap();
        let mut ordinary = identity.clone();
        ordinary.wid += 1;
        controller
            .request(
                &serde_json::to_vec(&json!({"version":1,"command":{
                    "op":"attach","identity":ordinary,"bundle_id":"test","title":"ordinary",
                    "buffer":{"width":400,"height":300},
                    "source_rect":Rect::new(10.,20.,200.,150.),
                    "world_rect":Rect::new(500.,100.,200.,150.)
                }}))
                .unwrap(),
            )
            .unwrap();
        (controller, window, identity)
    }

    #[test]
    fn settled_pin_does_not_force_unchanged_observations_through_transactions() {
        let (mut controller, _, _) = pinned_observation_scene();
        assert_settled_observations_are_noops(&controller);
        for zoom in [0.5, 0.8, 1.0] {
            controller
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::Zoom {
                        output: OutputId(1),
                        zoom,
                        anchor: Point::new(187., 263.),
                    },
                })
                .unwrap();
            controller
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::Pan {
                        output: OutputId(1),
                        screen_delta: Point::new(37.25, -19.5),
                        time_ms: None,
                        source: None,
                    },
                })
                .unwrap();
            assert_settled_observations_are_noops(&controller);
        }
    }

    #[test]
    fn unchanged_pin_observation_preserves_partial_offscreen_drag_and_native_basis_restore() {
        let (mut controller, window, identity) = pinned_observation_scene();
        for (target, pointer) in [
            (Point::new(-50., 100.), Point::new(50., 150.)),
            (Point::new(900., 100.), Point::new(950., 150.)),
            (Point::new(100., -50.), Point::new(150., 50.)),
            (Point::new(100., 750.), Point::new(150., 775.)),
        ] {
            let pin = controller.policy.pins[&window];
            let start = Point::new(f64::from(pin.screen_pos[0]), f64::from(pin.screen_pos[1]));
            for command in [
                Command::BeginDrag {
                    window,
                    output: OutputId(1),
                    group: false,
                },
                Command::GestureTo {
                    screen_delta: target - start,
                    pointer: Some(pointer),
                },
                Command::EndGesture {},
            ] {
                controller
                    .execute(Request {
                        version: ABI_VERSION,
                        command,
                    })
                    .unwrap();
            }
            assert_eq!(
                controller.policy.pins[&window].screen_pos,
                [target.x as i32, target.y as i32]
            );
            assert_settled_observations_are_noops(&controller);
        }
        for source_rect in [
            Rect::new(30., 45., 320., 240.),
            Rect::new(10., 20., 200., 150.),
        ] {
            controller
                .execute(Request {
                    version: ABI_VERSION,
                    command: Command::ObservePresentation {
                        window,
                        identity: identity.clone(),
                        source_rect,
                        buffer: BufferSize {
                            width: 400,
                            height: 300,
                        },
                    },
                })
                .unwrap();
            assert_settled_observations_are_noops(&controller);
        }
    }

    #[test]
    fn pinned_observation_still_rejects_changed_geometry_identity_buffer_and_live_gesture() {
        let (mut controller, window, identity) = pinned_observation_scene();
        let source = controller.sources[&window].clone();
        let mut stale = identity.clone();
        stale.birth_sec += 1;
        for (owner, rect, buffer) in [
            (stale, source.observed_rect, source.buffer),
            (
                identity.clone(),
                Rect::new(11., 20., 200., 150.),
                source.buffer,
            ),
            (
                identity.clone(),
                Rect::new(10., 20., 201., 150.),
                source.buffer,
            ),
            (
                identity.clone(),
                source.observed_rect,
                BufferSize {
                    width: 401,
                    height: 300,
                },
            ),
        ] {
            assert!(!controller.observation_current(window, &owner, rect, buffer));
        }
        controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::BeginDrag {
                    window,
                    output: OutputId(1),
                    group: false,
                },
            })
            .unwrap();
        for (&id, source) in &controller.sources {
            assert!(!controller.observation_current(
                id,
                &source.identity,
                source.observed_rect,
                source.buffer
            ));
        }
    }
}
