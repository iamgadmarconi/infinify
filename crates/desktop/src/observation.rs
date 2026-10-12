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
        from_rect: Rect,
        to_rect: Rect,
        delta: Point,
    ) -> Result<Value, Error> {
        self.guard_resize_structure(Some(window))?;
        self.check_generation(window, identity, generation)?;
        if !rect_valid(from_rect)
            || !rect_valid(to_rect)
            || from_rect.size != to_rect.size
            || !point_valid(delta)
        {
            return Err(Error::Invalid("invalid source displacement"));
        }
        if self.fresh(window, identity)?.observed_rect != from_rect {
            return Err(Error::Invalid("stale source displacement"));
        }
        // Owner movement cannot interfere with a compositor grab or a size
        // restoration. Observe still adopts the latest source metadata.
        if self.gesture.is_some()
            || self.trackpad_gesture.is_some()
            || self.is_fullscreen(window)
            || !self.sizes.observation_idle()
            || !self.fullscreen.observation_idle()
        {
            return Ok(json!({"moved":false}));
        }
        let mut rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        if rect.size != from_rect.size || delta == Point::default() {
            return Ok(json!({"moved":false}));
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
        // Consume the source transition in the same transaction: replaying a
        // displaced observation cannot move the world window a second time.
        self.sources
            .get_mut(&window)
            .ok_or(Error::Invalid("unbound source"))?
            .observed_rect = to_rect;
        Ok(json!({"moved":true}))
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
}
