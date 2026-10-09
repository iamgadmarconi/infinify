// SPDX-License-Identifier: GPL-3.0-or-later
// Harness-only trait adapter. The complete Stage algorithm in mod.rs is unchanged.
pub trait StageElement: Clone + PartialEq {
    fn is_alive(&self) -> bool;
    fn is_child_of(&self, parent: &Self) -> bool;
    fn is_widget(&self) -> bool;
}
impl StageElement for u64 {
    fn is_alive(&self) -> bool {
        true
    }
    fn is_child_of(&self, _: &Self) -> bool {
        false
    }
    fn is_widget(&self) -> bool {
        false
    }
}
