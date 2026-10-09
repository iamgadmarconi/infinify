// SPDX-License-Identifier: GPL-3.0-or-later
// Time-based decay adapted from malbiruk/driftwm src/canvas.rs at 352333a8fa1b22171492d4b71a54102045c9a19d.
// Exact exponential integration replaces frame-Euler displacement for stable dt.
use crate::{Error, Point};
use std::time::Duration;

/// Independent inertial pan. Feed returned screen deltas to [`crate::Scene::pan`].
/// Native gesture code owns velocity estimation and must avoid applying OS
/// momentum events and this integrator to the same gesture.
#[derive(Debug, Clone)]
pub struct Momentum {
    velocity: Point,
    half_life: f64,
}
impl Momentum {
    /// Launch using screen points/second and a positive velocity half-life.
    pub fn new(velocity: Point, half_life: Duration) -> Result<Self, Error> {
        let half_life = half_life.as_secs_f64();
        if !velocity.valid() || half_life <= 0.0 || half_life > 60.0 {
            return Err(Error::Invalid("momentum parameters"));
        }
        Ok(Self {
            velocity,
            half_life,
        })
    }
    /// Advance by elapsed time; returns no movement once speed falls below 1 point/s.
    pub fn tick(&mut self, elapsed: Duration) -> Option<Point> {
        if self.velocity.x.hypot(self.velocity.y) < 1.0 {
            self.stop();
            return None;
        }
        let rate = std::f64::consts::LN_2 / self.half_life;
        let decay = (-rate * elapsed.as_secs_f64()).exp();
        let delta = self.velocity * ((1.0 - decay) / rate);
        self.velocity = self.velocity * decay;
        Some(delta)
    }
    /// Stop immediately, for a new gesture or focus transition.
    pub fn stop(&mut self) {
        self.velocity = Point::default();
    }
    /// Current screen-space velocity in points/second.
    pub fn velocity(&self) -> Point {
        self.velocity
    }
}
