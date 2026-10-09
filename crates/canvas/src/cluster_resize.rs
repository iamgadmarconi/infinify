// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm src/layout/cluster.rs::resolve_cluster_shifts
// and src/state/cluster_snapshot.rs::cluster_snapshot_for_resize_with_rects at
// 352333a8fa1b22171492d4b71a54102045c9a19d, GPL-3.0-or-later.
// Uses fractional world points instead of i32 pixel rounding. Unsettled cascades
// return an error rather than applying the upstream iteration-limit result.
use std::collections::BTreeSet;

use crate::layout::adjacent;
use crate::{Error, Point, Rect, ResizeEdges, SnapOptions, WindowId};

#[derive(Debug, Clone, Copy, PartialEq)]
enum Side {
    Left,
    Right,
    Top,
    Bottom,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ResizeMember {
    pub id: WindowId,
    pub initial: Rect,
    x: Option<Side>,
    y: Option<Side>,
}

pub(crate) fn classify(
    primary: (WindowId, Rect),
    cluster: &[(WindowId, Rect)],
    edges: ResizeEdges,
    options: SnapOptions,
) -> Vec<ResizeMember> {
    let mut members: Vec<_> = cluster
        .iter()
        .filter(|(id, _)| *id != primary.0)
        .map(|&(id, initial)| ResizeMember {
            id,
            initial,
            x: None,
            y: None,
        })
        .collect();
    for (active, side) in [
        (edges.left(), Side::Left),
        (edges.right(), Side::Right),
        (edges.top(), Side::Top),
        (edges.bottom(), Side::Bottom),
    ] {
        if !active {
            continue;
        }
        let mut selected = BTreeSet::new();
        let mut pending = Vec::new();
        for (i, member) in members.iter().enumerate() {
            if touches_side(primary.1, member.initial, side, options) {
                selected.insert(i);
                pending.push(i);
            }
        }
        while let Some(i) = pending.pop() {
            for (j, member) in members.iter().enumerate() {
                if !selected.contains(&j)
                    && downstream(primary.1, member.initial, side)
                    && adjacent(members[i].initial, member.initial, options)
                {
                    selected.insert(j);
                    pending.push(j);
                }
            }
        }
        for i in selected {
            match side {
                Side::Left | Side::Right => members[i].x = Some(side),
                Side::Top | Side::Bottom => members[i].y = Some(side),
            }
        }
    }
    members
}

fn downstream(primary: Rect, other: Rect, side: Side) -> bool {
    match side {
        Side::Left => other.right() <= primary.origin.x,
        Side::Right => other.origin.x >= primary.right(),
        Side::Top => other.bottom() <= primary.origin.y,
        Side::Bottom => other.origin.y >= primary.bottom(),
    }
}

fn touches_side(a: Rect, b: Rect, side: Side, options: SnapOptions) -> bool {
    let (distance, overlap) = match side {
        Side::Right => (b.origin.x - a.right() - options.gap, y_overlap(a, b)),
        Side::Left => (a.origin.x - b.right() - options.gap, y_overlap(a, b)),
        Side::Bottom => (b.origin.y - a.bottom() - options.gap, x_overlap(a, b)),
        Side::Top => (a.origin.y - b.bottom() - options.gap, x_overlap(a, b)),
    };
    overlap && distance.abs() <= options.adjacency_tolerance
}

type Resolved = (Vec<Point>, Vec<(usize, usize)>);

pub(crate) fn resolve(
    members: &[ResizeMember],
    primary_initial: Rect,
    primary_current: Rect,
    gap: f64,
    existing_bonds: &[(usize, usize)],
) -> Result<Resolved, Error> {
    let mut shifts: Vec<_> = members
        .iter()
        .map(|member| {
            Point::new(
                match member.x {
                    Some(Side::Right) => primary_current.right() - primary_initial.right(),
                    Some(Side::Left) => primary_current.origin.x - primary_initial.origin.x,
                    _ => 0.0,
                },
                match member.y {
                    Some(Side::Bottom) => primary_current.bottom() - primary_initial.bottom(),
                    Some(Side::Top) => primary_current.origin.y - primary_initial.origin.y,
                    _ => 0.0,
                },
            )
        })
        .collect();
    let mut bonds = existing_bonds.to_vec();
    // Bonds keep a pushed follower flush even after reversing past its start.
    // Initial relative positions prevent tracking on an unintended axis.
    for &(i, j) in existing_bonds {
        let m_init = members[i].initial;
        let m_cur = m_init.translated(shifts[i]);
        let n_init = members[j].initial;
        let n_cur = n_init.translated(shifts[j]);
        if y_overlap(m_cur, n_cur) {
            if n_init.origin.x >= m_init.right() {
                shifts[j].x = m_cur.right() + gap - n_init.origin.x;
            } else if n_init.right() <= m_init.origin.x {
                shifts[j].x = m_cur.origin.x - gap - n_init.right();
            }
        }
        if x_overlap(m_cur, n_cur) {
            if n_init.origin.y >= m_init.bottom() {
                shifts[j].y = m_cur.bottom() + gap - n_init.origin.y;
            } else if n_init.bottom() <= m_init.origin.y {
                shifts[j].y = m_cur.origin.y - gap - n_init.bottom();
            }
        }
    }
    // One extra pass checks convergence after the upstream 2N propagation bound.
    for _ in 0..=members.len() * 2 {
        let mut changed = false;
        for (j, member) in members.iter().enumerate() {
            let current = member.initial.translated(shifts[j]);
            // Static primary edges must block a reversing bond/cascade too.
            let push = push_between(
                primary_initial,
                primary_current,
                member.initial,
                current,
                None,
                gap,
            );
            changed |= add_push(&mut shifts[j], push);
        }
        for (i, member) in members.iter().enumerate() {
            let movement = shifts[i];
            if movement == Point::default() {
                continue;
            }
            let current = member.initial.translated(movement);
            for (j, other) in members.iter().enumerate() {
                if i == j {
                    continue;
                }
                let other_current = other.initial.translated(shifts[j]);
                let push = push_between(
                    member.initial,
                    current,
                    other.initial,
                    other_current,
                    Some(movement),
                    gap,
                );
                if add_push(&mut shifts[j], push) {
                    changed = true;
                    if !bonds.contains(&(i, j)) {
                        bonds.push((i, j));
                    }
                }
            }
        }
        if shifts.iter().any(|shift| !shift.valid()) {
            return Err(Error::Invalid("resize cascade geometry"));
        }
        if !changed {
            return Ok((shifts, bonds));
        }
    }
    Err(Error::Invalid("resize cascade did not settle"))
}

fn add_push(shift: &mut Point, push: Point) -> bool {
    // Fractional coordinates need a tiny arithmetic tolerance in place of the
    // original integer rounding, or cancellation can prevent convergence.
    let previous = *shift;
    if push.x.abs() > 1e-9 {
        shift.x += push.x;
    }
    if push.y.abs() > 1e-9 {
        shift.y += push.y;
    }
    *shift != previous
}

fn x_overlap(a: Rect, b: Rect) -> bool {
    a.origin.x < b.right() && b.origin.x < a.right()
}
fn y_overlap(a: Rect, b: Rect) -> bool {
    a.origin.y < b.bottom() && b.origin.y < a.bottom()
}

fn push_between(
    m_init: Rect,
    m_cur: Rect,
    n_init: Rect,
    n_cur: Rect,
    movement: Option<Point>,
    gap: f64,
) -> Point {
    let mut push = Point::default();
    if y_overlap(m_cur, n_cur) {
        if n_init.origin.x >= m_init.right() && movement.is_none_or(|d| d.x > 0.0) {
            push.x = (m_cur.right() + gap - n_cur.origin.x).max(0.0);
        } else if n_init.right() <= m_init.origin.x && movement.is_none_or(|d| d.x < 0.0) {
            push.x = (m_cur.origin.x - gap - n_cur.right()).min(0.0);
        }
    }
    if x_overlap(m_cur, n_cur) {
        if n_init.origin.y >= m_init.bottom() && movement.is_none_or(|d| d.y > 0.0) {
            push.y = (m_cur.bottom() + gap - n_cur.origin.y).max(0.0);
        } else if n_init.bottom() <= m_init.origin.y && movement.is_none_or(|d| d.y < 0.0) {
            push.y = (m_cur.origin.y - gap - n_cur.bottom()).min(0.0);
        }
    }
    push
}
