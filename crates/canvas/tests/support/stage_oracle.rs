// SPDX-License-Identifier: GPL-3.0-or-later
// Compiled without cfg(test): executes the full original Stage, not its unrelated tests.
#![allow(dead_code)]
extern crate self as smithay;
#[path = "canvas_shim.rs"]
mod shim;
pub use shim::utils;
impl<T: Default, S> Default for utils::Point<T, S> {
    fn default() -> Self {
        (T::default(), T::default()).into()
    }
}
mod layout {
    pub mod snap {
        // As upstream's: v0.21's `FitPush` derives Clone, Copy and Debug over it.
        #[derive(Clone, Copy, Debug)]
        pub struct SnapRect {
            pub x_low: f64,
            pub x_high: f64,
            pub y_low: f64,
            pub y_high: f64,
        }
    }
}
#[path = "../upstream/stage/mod.rs"]
mod stage;
use std::io::{self, BufRead};
fn main() {
    let mut stage = stage::Stage::<u64>::new();
    let mut focused = None;
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let mut parts = line.split_whitespace();
        let op = parts.next().unwrap();
        let id: u64 = parts.next().unwrap_or("0").parse().unwrap();
        let mut selected = None;
        match op {
            "map" => stage.map(id, (id as i32, 0).into()),
            "focus" => {
                stage.raise(&id);
                focused = Some(id);
            }
            "confirm" => {
                if stage.cycle_state().is_none() {
                    stage.push_focus(&id);
                }
            }
            "step" => {
                selected = stage.cycle_step(id != 0, focused.as_ref());
                if let Some(id) = selected {
                    stage.raise(&id);
                    focused = Some(id);
                }
            }
            "end" => stage.end_cycle(),
            "cancel" => stage.cancel_cycle(),
            "drop" => stage.drop_from_focus_history(&id),
            "remove" => {
                stage.remove(&id);
                if focused == Some(id) {
                    focused = stage.windows().next_back().copied();
                }
            }
            _ => panic!("unknown trace operation"),
        }
        stage.verify_invariants();
        println!(
            "{{\"z\":{:?},\"history\":{:?},\"cycle\":{},\"selected\":{}}}",
            stage.windows().copied().collect::<Vec<_>>(),
            stage.focus_history(),
            stage
                .cycle_state()
                .map_or("null".to_string(), |i| i.to_string()),
            selected.map_or("null".to_string(), |i| i.to_string())
        );
    }
}
