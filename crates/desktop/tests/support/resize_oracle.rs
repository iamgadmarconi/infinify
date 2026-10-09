// SPDX-License-Identifier: GPL-3.0-or-later
// Types/IO only; tagged original blocks are extracted verbatim with byte hashes.
#![allow(dead_code)]
use std::io::{self, BufRead};
#[path = "GEOMETRY_PATH"] mod geometry;
use geometry::utils::{Logical, Point, Size};
mod xdg_toplevel { pub type ResizeEdge = u32; }
/*EDGES*/
struct SizeConstraints { min: Size<i32, Logical>, max: Size<i32, Logical> }
impl SizeConstraints {
/*CLAMP*/
}
struct Grab { edges: u32, start_zoom:f64, initial_window_size:Size<i32, Logical>, constraints:SizeConstraints }
impl Grab {
    // Disabled optional aspect-ratio feature; not an implementation of it.
    fn bend_to_locked_ratio(&self, w:i32,h:i32)->(i32,i32) {(w,h)}
    fn request(&self, screen_delta:Point<f64,Logical>)->(i32,i32) {
/*REQUEST*/
        (new_w,new_h)
    }
}
struct Geo {size:Size<i32,Logical>}
fn settle(edges:u32,current_pos:Point<i32,Logical>,last_committed_size:Size<i32,Logical>,current_geo:Geo)->Point<i32,Logical> {
    let placement_owns_size=false;
/*SETTLE*/
    new_loc
}
fn main() {
    for line in io::stdin().lock().lines() {
        let line=line.unwrap();
        let p:Vec<f64>=line.split_whitespace().map(|s|s.parse().unwrap()).collect();
        let g=Grab {edges:p[0] as u32,start_zoom:p[3],initial_window_size:(p[4] as i32,p[5] as i32).into(),constraints:SizeConstraints{min:(0,0).into(),max:(0,0).into()}};
        let r=g.request((p[1],p[2]).into());
        let pos=settle(g.edges,(p[10] as i32,p[11] as i32).into(),(p[6] as i32,p[7] as i32).into(),Geo{size:(p[8] as i32,p[9] as i32).into()});
        println!("{} {} {} {}",r.0,r.1,pos.x,pos.y);
    }
}
