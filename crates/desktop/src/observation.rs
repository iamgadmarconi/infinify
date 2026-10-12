// SPDX-License-Identifier: GPL-3.0-or-later
// Source geometry transactions and the unchanged-observation fast path.
// Geometry never establishes current native authority.
use super::*;

impl Controller {
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
            .map(|pin| {
                self.screen_pin_arrival(
                    &SourceScreenPin {
                        output: pin.output,
                        screen_pos: Point::new(
                            f64::from(pin.screen_pos[0]) + delta.x,
                            f64::from(pin.screen_pos[1]) + delta.y,
                        ),
                    },
                    rect.size,
                )
            })
            .transpose()?;
        let pin = match pin {
            Some(Arrival::Pin {
                rect: placement,
                pin,
            }) => {
                rect = placement;
                Some(pin)
            }
            None => {
                rect.origin = rect.origin + delta;
                None
            }
            _ => return Err(Error::Invalid("invalid pin relocation")),
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
        // A repeated physical observation may still adopt the world size after
        // a gesture, or settle pending structure. Leave every such case on the
        // ordinary transactional path, including runs without native resize capability.
        if !self.sizes.observation_idle()
            || !self.fullscreen.observation_idle()
            || self.gesture.is_some()
            || self.trackpad_gesture.is_some()
            || self.guard_resize_structure(None).is_err()
            || !self.policy.pins.is_empty()
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
            && self
                .scene
                .window(window)
                .is_some_and(|window| window.world_rect.size == source_rect.size)
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
    fn changed_world_size_requires_observation_after_gesture_ends() {
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
        assert!(!current(&controller, window, &identity));
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
        assert_eq!(result["resized"], true);
        assert!(current(&controller, window, &identity));
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
}
