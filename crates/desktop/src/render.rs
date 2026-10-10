// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/ipc/mod.rs (cmd_screenshot, resolve_screenshot_region,
// window_visual_rect, snap_rect_to_rect, union_rect, element_by_selector),
// src/render/screenshot.rs (capture_region_to_png's checks: the scale, the
// empty region, the pixel size and its MAX_DIM ceiling), src/state/mod.rs
// (output_viewport_rect), src/state/window_frame.rs (suspended_chrome,
// default_border_width), src/state/fit.rs (snap_rect_at),
// src/state/suspended.rs (standin_body_rect) and src/render/mod.rs
// (compose_capture_elements: a stand-in is composed at alpha 1.0, and a window
// captured alone at its rule's opacity or 1.0). What an element is drawn with is
// not adapted: it is driftwm-core's `config::effective_*` helpers over its
// `DecorationConfig`, and the background, outline and effects tables are its
// `BackgroundConfig`, `OutputOutlineSettings` and `EffectsConfig`, upstream's
// own code. The rule those helpers are given is the one the window mapped with,
// kept in rules.rs with any IPC `Opacity` write: nothing here matches a rule.
// Nothing is drawn here: the snapshot describes a frame and the
// shell's compositor draws it; a screenshot is an effect the shell performs
// and reports back. A native Mac window carries its own title bar, so its
// frame is its content and it is decorated as upstream decorates a
// client-side-decorated window unless the config says otherwise.
use super::actions::Outcome;
use super::ipc::{Reply, Response, ScreenshotTarget, frame, rule_to_internal};
use super::rules::decoration_name;
use super::view_actions::pixel_size;
use super::*;
use driftwm_core::config::{
    BackgroundKind, Config, DecorationConfig, DecorationMode, FontWeight, TitleAlign,
    effective_blur, effective_border_color, effective_border_color_focused, effective_border_width,
    effective_corner_radius, effective_decoration_mode, effective_shadow_enabled,
};

/// Upstream MAX_DIM: the ceiling per side of one capture, in pixels.
const MAX_DIM: i32 = 16384;
/// How many screenshot effects may wait for the shell's answer. One that is
/// never answered is forgotten once this many newer ones are waiting.
const MAX_PENDING: usize = 64;

/// A colour as the snapshot carries it: straight-alpha sRGB, each channel 0..1.
fn rgba(color: [u8; 4]) -> [f64; 4] {
    color.map(|channel| f64::from(channel) / 255.0)
}
/// The first spelling upstream's `font_weight` parser accepts for each weight.
fn weight_name(weight: FontWeight) -> &'static str {
    match weight {
        FontWeight::Thin => "thin",
        FontWeight::ExtraLight => "extralight",
        FontWeight::Light => "light",
        FontWeight::Normal => "normal",
        FontWeight::Medium => "medium",
        FontWeight::SemiBold => "semibold",
        FontWeight::Bold => "bold",
        FontWeight::ExtraBold => "extrabold",
        FontWeight::Black => "black",
    }
}
/// Does `new` differ from `old` in a table the shell builds its drawing state
/// from? Asked of the launch load only: every accepted reload after it
/// rebuilds that state whatever changed.
pub(crate) fn sections_differ(old: &Config, new: &Config) -> bool {
    old.background != new.background
        || old.decorations != new.decorations
        || old.output_outline != new.output_outline
        || old.effects != new.effects
}

/// The decoration one element is drawn with, as upstream's helpers resolve it.
struct Decoration {
    mode: DecorationMode,
    border_width: i32,
    border_color: [u8; 4],
    border_color_focused: [u8; 4],
    corner_radius: i32,
    shadow: bool,
    opacity: f64,
    blur: bool,
}
/// A canvas rectangle at upstream's integer boundary: top-left origin, Y down.
#[derive(Clone, Copy)]
struct Region {
    x: i64,
    y: i64,
    w: i64,
    h: i64,
}
impl Region {
    /// Upstream union_rect.
    fn union(self, other: Self) -> Self {
        let (x, y) = (self.x.min(other.x), self.y.min(other.y));
        Self {
            x,
            y,
            w: (self.x + self.w).max(other.x + other.w) - x,
            h: (self.y + self.h).max(other.y + other.h) - y,
        }
    }
    fn rect(self) -> Rect {
        Rect::new(self.x as f64, self.y as f64, self.w as f64, self.h as f64)
    }
}
/// A canvas coordinate that fits upstream's `i32`, or the refusal.
fn whole(value: f64, refusal: &str) -> Result<i64, String> {
    if (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&value) {
        Ok(value as i64)
    } else {
        Err(refusal.to_string())
    }
}
const WINDOW_RANGE: &str = "window geometry exceeds integer range";
const VIEW_RANGE: &str = "view geometry exceeds integer range";

impl Controller {
    /// What the shell builds once per configuration: upstream's `[background]`
    /// table, the part of `[decorations]` compositor-drawn chrome is rasterised
    /// from, and `[output.outline]`. Paths are upstream's parsed values, a
    /// leading `~/` already expanded from `$HOME` where that is set.
    pub(crate) fn render_block(&self) -> Value {
        let config = self.config();
        let (background, decorations, outline) = (
            &config.background,
            &config.decorations,
            &config.output_outline,
        );
        let (kind, path, texture) = match &background.kind {
            BackgroundKind::Default => ("default", None, None),
            BackgroundKind::Shader { path, texture } => ("shader", Some(path), texture.as_ref()),
            BackgroundKind::Tile(path) => ("tile", Some(path), None),
            BackgroundKind::Wallpaper(path) => ("wallpaper", Some(path), None),
            BackgroundKind::None => ("none", None, None),
        };
        let align = match decorations.title_align {
            TitleAlign::Left => "left",
            TitleAlign::Center => "center",
        };
        json!({
            "background":{"type":kind,"path":path,"texture":texture,"mirror_tile":background.mirror_tile,"transparent_shader":background.transparent_shader,"animate_fps":background.animate_fps,"cache_shader":background.cache_shader},
            "chrome":{"background":rgba(decorations.bg_color),"foreground":rgba(decorations.fg_color),"corner_radius":decorations.corner_radius,"title_bar_height":decorations.title_bar_height,"font":Some(&decorations.font).filter(|font| !font.is_empty()),"font_size":decorations.font_size,"font_weight":weight_name(decorations.font_weight),"title_align":align},
            "outline":{"color":rgba(outline.color),"thickness":outline.thickness,"opacity":outline.opacity},
            "revision":self.render_revision,
        })
    }
    /// Upstream's `effective_*` helpers for one element, called with the rule
    /// the window mapped with (`drawn_rule` in rules.rs): never resolved
    /// again here, so a retitle or a config reload re-applies none, and an
    /// IPC `Opacity` write is part of it. A stand-in carries no rule and
    /// takes the global table alone, as upstream's does, and it is opaque.
    /// The opacity is `opacity_of`, the placement's own `opacity`. Never
    /// fullscreen: there is none here.
    fn decoration(&self, window: WindowId) -> Decoration {
        let decorations = &self.config().decorations;
        let applied = self.drawn_rule(window);
        let mode = effective_decoration_mode(
            applied.and_then(|rule| rule.decoration.as_ref()),
            &decorations.default_mode,
        );
        Decoration {
            border_width: effective_border_width(applied, mode, decorations),
            border_color: effective_border_color(applied, decorations),
            border_color_focused: effective_border_color_focused(applied, decorations),
            corner_radius: effective_corner_radius(applied, mode, decorations),
            shadow: effective_shadow_enabled(applied, mode, decorations),
            opacity: self.opacity_of(window),
            blur: effective_blur(applied, decorations, false),
            mode: mode.clone(),
        }
    }
    /// What the compositor draws one window from, beyond its rectangles:
    /// whether it is a live window or a stand-in, its label, and its
    /// decoration. The coverage rule (upstream's DrawnChrome) is left to the
    /// shell, which knows the output's usable area at the moment it draws.
    pub(crate) fn drawn(&self, window: WindowId) -> Value {
        let focused = self.scene.focused() == Some(window);
        let metadata = self.metadata.get(&window);
        let decoration = self.decoration(window);
        json!({
            "kind":if self.sources.contains_key(&window) { "window" } else { "standin" },
            "focused":focused,
            "title":metadata.map_or("", |m| m.title.as_str()),
            // Upstream labels a stand-in with its desktop entry's name and
            // falls back to the desktop id; the bundle identifier is that id.
            "app_name":metadata.map_or("", |m| m.bundle_id.as_str()),
            "launching":self.lifecycle.relaunching.contains(&window),
            "world_rect":self.scene.window(window).map(|w| w.world_rect),
            "decoration":{"mode":decoration_name(&decoration.mode),"border_width":decoration.border_width,"border_color":rgba(decoration.border_color),"border_color_focused":rgba(decoration.border_color_focused),"corner_radius":decoration.corner_radius,"shadow":decoration.shadow,"shadow_radius":DecorationConfig::SHADOW_RADIUS,"shadow_color":rgba(DecorationConfig::SHADOW_COLOR),"opacity":decoration.opacity,"blur":decoration.blur},
        })
    }

    /// What a capture of one element frames, or `None` for a window with no
    /// area. A bound window is upstream's window_visual_rect: its frame at the
    /// integer boundary, padded by the border and, when it casts one, the
    /// shadow radius, with a compositor title bar above it only in `server`
    /// mode. A stand-in is upstream's visual_frame_rect through
    /// snap_rect_to_rect: its bar and body, which together take the window's
    /// rectangle here (standin_body_rect for a client-decorated origin), padded
    /// by the global border and by no shadow, rounded outward.
    fn capture_rect(&self, window: WindowId) -> Result<Option<Region>, String> {
        let rect = self
            .scene
            .window(window)
            .ok_or_else(|| "unknown window".to_string())?
            .world_rect;
        let decoration = self.decoration(window);
        let bar = self.config().decorations.title_bar_height;
        let border = decoration.border_width;
        if !self.sources.contains_key(&window) {
            let (bar, border) = (f64::from(bar), f64::from(border));
            let body = (rect.size.height - bar).max(1.0);
            let x = whole((rect.origin.x - border).floor(), WINDOW_RANGE)?;
            let y = whole((rect.origin.y - border).floor(), WINDOW_RANGE)?;
            let right = whole((rect.right() + border).ceil(), WINDOW_RANGE)?;
            let bottom = whole((rect.origin.y + bar + body + border).ceil(), WINDOW_RANGE)?;
            return Ok(Some(Region {
                x,
                y,
                w: (right - x).max(1),
                h: (bottom - y).max(1),
            }));
        }
        let (loc, size) = frame(rect)?;
        if size[0] <= 0 || size[1] <= 0 {
            return Ok(None);
        }
        let bar = match decoration.mode {
            DecorationMode::Server => i64::from(bar),
            _ => 0,
        };
        let pad = match decoration.shadow {
            true => DecorationConfig::SHADOW_RADIUS.ceil() as i64,
            false => 0,
        };
        let edge = i64::from(border) + pad;
        Ok(Some(Region {
            x: loc[0] - edge,
            y: loc[1] - bar - edge,
            w: size[0] + 2 * edge,
            h: size[1] + bar + 2 * edge,
        }))
    }
    /// Upstream resolve_screenshot_region: the canvas rectangle a target
    /// frames, the target as the effect names it, and the output it was read
    /// through. A selector is resolved as every window verb resolves one, a
    /// bound window before a stand-in. `from_screen` coordinates are global
    /// screen points, upstream's output layout space.
    fn screenshot_region(
        &self,
        output: Option<OutputId>,
        target: &ScreenshotTarget,
    ) -> Result<(Region, Value, Option<OutputId>), String> {
        let active = match output {
            Some(id) => Some(
                self.scene
                    .output(id)
                    .ok_or_else(|| "unknown output".to_string())?,
            ),
            None => None,
        };
        let named = serde_json::to_value(target).map_err(|e| e.to_string())?;
        match target {
            // Upstream output_viewport_rect, over the whole output.
            ScreenshotTarget::Viewport => {
                let viewport = active.ok_or_else(|| "no active output to capture".to_string())?;
                let size = pixel_size(viewport.screen_bounds.size).map_err(|e| e.to_string())?;
                let region = Region {
                    x: whole(viewport.camera.x.round(), VIEW_RANGE)?,
                    y: whole(viewport.camera.y.round(), VIEW_RANGE)?,
                    w: (f64::from(size.w) / viewport.zoom).round() as i64,
                    h: (f64::from(size.h) / viewport.zoom).round() as i64,
                };
                Ok((region, named, output))
            }
            ScreenshotTarget::Window { window } => {
                let id = self.select(window.as_ref())?;
                let region = self.capture_rect(id)?.ok_or_else(|| {
                    match self.sources.contains_key(&id) {
                        true => "window has no capturable area",
                        false => "suspended window has no capturable area",
                    }
                    .to_string()
                })?;
                let world = self.scene.window(id).map(|w| w.world_rect);
                // Upstream compose_capture_elements: an isolated window is
                // captured as itself, not as the unfocused window it is while
                // the command runs, so at its rule's opacity, else opaque. The
                // rule is the one it mapped with, where upstream's cmd_opacity
                // writes too. A pinned window or a widget is captured like any
                // other, at its canvas frame, which follows its pin.
                let opacity = self
                    .drawn_rule(id)
                    .and_then(|rule| rule.opacity)
                    .unwrap_or(1.0);
                let named = json!({"Window":{"window":id,"world_rect":world,"opacity":opacity}});
                Ok((region, named, output))
            }
            ScreenshotTarget::All => {
                // Upstream frames its canvas windows (is_canvas_window: no
                // widget, no pinned window) and every stand-in. A slot that
                // still holds a pin is drawn in screen space and has no place
                // on the canvas to frame either.
                let mut all: Option<Region> = None;
                for window in self.scene.windows() {
                    if !self.on_canvas(window.id) {
                        continue;
                    }
                    if let Some(region) = self.capture_rect(window.id)? {
                        all = Some(all.map_or(region, |all| all.union(region)));
                    }
                }
                let all = all.ok_or_else(|| "no windows to capture".to_string())?;
                // `fit_padding` canvas units of margin, as upstream frames it.
                let pad = self
                    .config()
                    .zoom_fit_padding
                    .clamp(0.0, f64::from(i32::MAX))
                    .round() as i64;
                let region = Region {
                    x: all.x - pad,
                    y: all.y - pad,
                    w: all.w + 2 * pad,
                    h: all.h + 2 * pad,
                };
                Ok((region, named, output))
            }
            ScreenshotTarget::Region {
                x,
                y,
                w,
                h,
                from_screen,
            } => {
                if *w <= 0 || *h <= 0 {
                    return Err("region width and height must be positive".to_string());
                }
                if !*from_screen {
                    let size = [i64::from(*w), i64::from(*h)];
                    let loc = rule_to_internal(*x, *y, size);
                    let region = Region {
                        x: loc.x as i64,
                        y: loc.y as i64,
                        w: size[0],
                        h: size[1],
                    };
                    return Ok((region, named, output));
                }
                // The output under the rectangle's corner, else the active one.
                let corner = Point::new(f64::from(*x), f64::from(*y));
                let viewport = self
                    .scene
                    .outputs()
                    .iter()
                    .find(|o| o.screen_bounds.contains(corner))
                    .or(active)
                    .ok_or_else(|| "no output for the screen region".to_string())?;
                let local = corner - viewport.screen_bounds.origin;
                let (camera, zoom) = (viewport.camera, viewport.zoom);
                let region = Region {
                    x: whole((camera.x + local.x / zoom).round(), VIEW_RANGE)?,
                    y: whole((camera.y + local.y / zoom).round(), VIEW_RANGE)?,
                    w: (f64::from(*w) / zoom).round() as i64,
                    h: (f64::from(*h) / zoom).round() as i64,
                };
                Ok((region, named, Some(viewport.id)))
            }
        }
    }
    /// Upstream cmd_screenshot up to the render: every refusal it or
    /// capture_region_to_png makes before a pixel is drawn, in their order,
    /// then the request to the shell. Upstream renders at zoom 1 into a
    /// transparent target, a `window` target alone and without the background;
    /// the shell does the same from `target`, `region` and the pixel size, and
    /// answers with `screenshot_result`.
    pub(crate) fn cmd_screenshot(
        &mut self,
        output: Option<OutputId>,
        target: &ScreenshotTarget,
        scale: f64,
        path: &str,
        outcome: &mut Outcome,
    ) -> Result<(), String> {
        if !std::path::Path::new(path).is_absolute() {
            return Err("screenshot path must be absolute".to_string());
        }
        // Upstream's write fails on such a path; the shell must not be handed
        // one it could shorten into another file's name.
        if !text_valid(path, 4096) {
            return Err("screenshot path is not a usable file path".to_string());
        }
        let (region, target, output) = self.screenshot_region(output, target)?;
        if !(scale.is_finite() && scale > 0.0) {
            return Err("scale must be a positive number".to_string());
        }
        if region.w <= 0 || region.h <= 0 {
            return Err("capture region is empty".to_string());
        }
        let total_w = (region.w as f64 * scale).round() as i32;
        let total_h = (region.h as f64 * scale).round() as i32;
        if total_w <= 0 || total_h <= 0 {
            return Err("capture resolves to zero pixels".to_string());
        }
        if total_w > MAX_DIM || total_h > MAX_DIM {
            return Err(format!(
                "capture {total_w}x{total_h}px exceeds the {MAX_DIM}px per-side limit — \
                 lower --scale or shrink the region"
            ));
        }
        outcome.effects.push(json!({"op":"screenshot","target":target,"scale":scale,"path":path,"output":output,"region":region.rect(),"width":total_w,"height":total_h}));
        if self.pending_screenshots.len() >= MAX_PENDING {
            self.pending_screenshots.remove(0);
        }
        self.pending_screenshots.push(path.to_owned());
        Ok(())
    }
    /// The shell has performed a screenshot effect, or failed to: upstream's
    /// reply for the client that asked. A capture is answered by the path it
    /// was asked to write, which must be one that is waiting; a failure
    /// answers the oldest one waiting. The pixel size is what the shell wrote.
    pub(crate) fn screenshot_result(
        &mut self,
        path: Option<String>,
        width: Option<u32>,
        height: Option<u32>,
        error: Option<String>,
    ) -> Result<Value, Error> {
        let reply: Reply = match (path, width, height, error) {
            (Some(path), Some(width), Some(height), None) => {
                let waiting = self
                    .pending_screenshots
                    .iter()
                    .position(|pending| *pending == path)
                    .ok_or(Error::Invalid("no screenshot is pending for this path"))?;
                let limit = 1..=MAX_DIM as u32;
                if !limit.contains(&width) || !limit.contains(&height) {
                    return Err(Error::Invalid("invalid screenshot dimensions"));
                }
                self.pending_screenshots.remove(waiting);
                Ok(Response::Screenshot {
                    path,
                    width,
                    height,
                })
            }
            (None, None, None, Some(error)) => {
                if !text_valid(&error, 16384) {
                    return Err(Error::Invalid("invalid screenshot error text"));
                }
                if self.pending_screenshots.is_empty() {
                    return Err(Error::Invalid("no screenshot is pending"));
                }
                self.pending_screenshots.remove(0);
                Err(error)
            }
            _ => {
                return Err(Error::Invalid(
                    "a screenshot result is a path with its pixel size, or an error",
                ));
            }
        };
        Ok(json!({"reply":reply}))
    }
}
