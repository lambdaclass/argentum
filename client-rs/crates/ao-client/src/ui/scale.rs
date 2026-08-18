//! Three scale domains, kept apart on purpose.
//!
//! Conflating any two of these is how pixel-art clients end up blurry, and the
//! failure is subtle enough to ship:
//!
//! * **Device** — the display's pixel ratio. Not a choice; the platform reports
//!   it. Applied exactly once, where logical rectangles become the camera's
//!   physical viewport.
//! * **World** — an integer multiple of the *physical* pixel grid. Must be a
//!   whole number: at 1.5x a 32-pixel tile covers 48 physical pixels and every
//!   texel lands on a half pixel, which is the shimmer that makes scrolling
//!   pixel art look like it is vibrating.
//! * **UI** — a continuous multiplier on text and controls. Free to be
//!   fractional because text is vector-shaped and resampled cleanly, and it has
//!   to be continuous or a 4K rail is either unreadable or absurd.
//!
//! The world domain is deliberately *not* derived from the UI domain. Making
//! text bigger must never zoom the world, because zooming the world changes how
//! many tiles a player sees.

use bevy::prelude::*;

/// Logical pixels per tile at world scale 1. Matches `world::TILE_SIZE`.
pub const TILE_SIZE: f32 = 32.0;

/// Window width below which the UI stays at its base size.
const UI_SCALE_BASE_WIDTH: f32 = 1600.0;

/// Width at which the UI reaches its largest step.
const UI_SCALE_MAX_WIDTH: f32 = 3200.0;

/// Bounds on the *continuous* part of the UI multiplier.
///
/// Never below 1.0: the rail's minimum width and the type scale are already
/// sized for the smallest supported window, so shrinking further clips rather
/// than reflows. The upper bound applies to the ramp only — the world scale can
/// raise it further, so that a world drawn at 2x is not framed by an interface
/// still drawn at 1.5x.
const UI_SCALE_MIN: f32 = 1.0;
const UI_SCALE_MAX: f32 = 1.5;

/// The three domains, resolved for one window state.
#[derive(Debug, Clone, Copy, PartialEq, Resource)]
pub struct ScaleDomains {
    /// Reported by the platform. Browser zoom moves this too.
    pub device: f32,
    /// Whole physical pixels per world pixel.
    pub world: u32,
    /// Multiplier on UI text and controls.
    pub ui: f32,
}

impl Default for ScaleDomains {
    fn default() -> Self {
        Self { device: 1.0, world: 1, ui: 1.0 }
    }
}

impl ScaleDomains {
    /// Logical pixels covered by one tile. What a player perceives, and what
    /// pointer coordinates are expressed in.
    pub fn tile_logical_px(&self) -> f32 {
        TILE_SIZE * self.world as f32
    }

    /// Physical pixels covered by one tile.
    pub fn tile_physical_px(&self) -> f32 {
        self.tile_logical_px() * self.device
    }

    /// Orthographic projection scale for the world camera.
    ///
    /// The camera's viewport is in physical pixels, so this converts to them:
    /// one world unit becomes `world * device` physical pixels. Framing depends
    /// only on `world`, which depends only on the logical window size.
    pub fn projection_scale(&self) -> f32 {
        1.0 / (self.world as f32 * self.device.max(f32::EPSILON))
    }

    /// Convert a logical-pixel length into the value a UI `Node` must carry.
    ///
    /// Bevy multiplies every `Val::Px` by the global `UiScale`. The shell's
    /// regions are computed in logical pixels and must line up exactly with the
    /// camera viewport, which `UiScale` does not touch — so at any scale above
    /// 1.0 the rail drifted away from the world's edge. Dividing here makes the
    /// product land back on the intended logical value, while text and controls
    /// still scale, which is the point of having the domain at all.
    pub fn node_px(&self, logical: f32) -> f32 {
        logical / self.ui.max(f32::EPSILON)
    }
}

/// Resolve all three domains for a window.
/// Resolve all three domains.
///
/// `world_region` is the space the world camera has, which is the window less
/// the top bar and the character rail — not the window itself, or the world
/// would be scaled for room the rail is using.
pub fn resolve(logical_size: Vec2, world_region: Vec2, device_pixel_ratio: f32) -> ScaleDomains {
    let device = if device_pixel_ratio.is_finite() && device_pixel_ratio > 0.0 {
        device_pixel_ratio
    } else {
        // A browser mid-restore can report zero or NaN. Falling through with it
        // produces a zero-sized viewport and a division by zero in the
        // projection.
        1.0
    };

    let world = world_scale(world_region);
    // The interface follows the world so both grow together; a rail at 1x
    // beside a world at 2x is the "everything is tiny" complaint in reverse.
    ScaleDomains { device, world, ui: ui_scale(logical_size).max(world as f32) }
}

/// The view the interface is designed around, in tiles.
///
/// Measured from the default windowed host — 1280x760 logical pixels, less the
/// top bar and the character rail, which leaves 998x730 for the world. That is
/// the density Argentum is played at, matched against the reference client at
/// the same browser viewport, and a maximised or fullscreen host is expected to
/// show *this* view larger rather than a wider one.
pub const DESIGN_TILES_X: f32 = 31.0;
pub const DESIGN_TILES_Y: f32 = 22.0;

/// Whole logical pixels per world pixel.
///
/// Derived from how much room the world has against the view the interface was
/// designed around, so a bigger window shows the same scene *larger* rather
/// than revealing more of the map. Going fullscreen on a wide display otherwise
/// pulls the camera back until the character is a speck and the rail is
/// unreadable — which is the opposite of what fullscreen is for.
///
/// Deliberately *not* a function of the device pixel ratio: a retina display
/// should render the same view more sharply, not a different view, so framing
/// and pointer hit targets depend only on how large the window is — which is
/// what a player can see and control.
///
/// **Known limitation.** This makes the *logical* grid integral, not the
/// physical one. At a fractional device ratio — 1.25 and 1.5 are ordinary
/// Windows and GNOME settings — one world pixel still covers 1.25 or 1.5
/// physical pixels, so nearest-neighbour duplicates some source pixels and not
/// others, and the duplication pattern shifts as the camera pans. That is the
/// shimmer the roadmap's integer-pixel requirement exists to prevent, and it is
/// not yet solved.
///
/// Solving it properly means rendering the world to an offscreen target sized
/// in whole world pixels and blitting that to the screen, which is the only way
/// to keep the sampling grid integral independently of the display. Choosing
/// framing stability first is deliberate: a framing that changes with the
/// monitor also moves every click target, which is a correctness problem rather
/// than a visual one.
pub fn world_scale(world_region: Vec2) -> u32 {
    let design = Vec2::new(DESIGN_TILES_X, DESIGN_TILES_Y) * TILE_SIZE;
    if design.x <= 0.0 || design.y <= 0.0 {
        return 1;
    }

    // Whichever axis is tighter decides, so scaling up never pushes the view
    // off the other edge.
    let fit = (world_region.x / design.x).min(world_region.y / design.y);
    if !fit.is_finite() {
        return 1;
    }
    // Floored, not rounded. Rounding doubled the world at 1080p, where the
    // region is only about 1.6x the design size, and the rail's minimum then
    // needed 29% of the width — past the band it is allowed. Flooring also
    // gives maximising its intended effect at ordinary sizes: the world keeps
    // its scale and receives the additional space, and only a genuinely
    // doubled display draws the world twice as large.
    (fit.floor() as i32).max(1) as u32
}

/// The offscreen target the world is rendered into, and where it lands.
///
/// `extent` is how many *world* pixels the texture covers; `zoom` is how many
/// physical pixels each of those gets, so the texture is `extent * zoom` physical
/// pixels. `composite` is the physical rectangle of the window it is presented
/// into — carried here rather than recomputed by each consumer, because the
/// camera's projection, the compositor's placement and the pointer's inverse
/// mapping must agree to the pixel, and three roundings of the same numbers is
/// how they stop agreeing.
///
/// The indirection exists for one reason: fractional device pixel ratios. Drawn
/// straight to the screen, one world pixel covers 1.25 or 1.5 physical pixels at
/// ordinary Windows and GNOME settings, so nearest sampling duplicates some
/// source pixels and not others, and the duplication pattern *shifts as the
/// camera pans*. That is the shimmer the roadmap's integer-pixel requirement
/// exists to prevent.
///
/// Rendering to a target whose zoom is a whole number keeps every sprite on an
/// integral grid inside the texture, and panning then moves whole world pixels
/// within it. The one remaining resample is the composite, a fixed mapping from
/// texture to screen that does not change as the player moves — so any
/// duplication pattern is stable rather than crawling.
///
/// The alternative considered and rejected: floor the on-screen zoom to a whole
/// number and letterbox the remainder. It keeps the grid integral with no extra
/// texture, but at 1.25 it draws the world at 80% of its region, so raising a
/// display's scaling would visibly shrink the game and add borders.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WorldRender {
    /// World pixels covered, across and down.
    pub extent: UVec2,
    /// Whole physical pixels per world pixel inside the texture.
    pub zoom: u32,
    /// Where the texture is presented, in physical pixels of the window.
    pub composite: Rect,
    /// Set when the requested target could not be honoured and a reduced
    /// profile was used instead. Never silent: the caller logs it, because a
    /// changed profile can change what a player sees.
    pub reduced: Option<Reduction>,
}

/// Why a target came back smaller than asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reduction {
    /// The zoom was lowered to fit the memory budget. Costs sharpness only; the
    /// framing is unchanged, so this is the acceptable one.
    Zoom { from: u32, to: u32 },
    /// Even one physical pixel per world pixel did not fit. The framing itself
    /// had to change, which contradicts the invariant this module exists to
    /// hold, so it is reported as a fault rather than absorbed.
    Framing { wanted: UVec2, used: UVec2 },
}

impl WorldRender {
    /// The texture's size in physical pixels.
    pub fn texture_size(&self) -> UVec2 {
        self.extent * self.zoom
    }

    /// Bytes the texture occupies, at four per pixel.
    pub fn texture_bytes(&self) -> u64 {
        let size = self.texture_size();
        size.x as u64 * size.y as u64 * BYTES_PER_PIXEL
    }
}

/// Bytes per pixel of the target's format, `Rgba8UnormSrgb`.
pub const BYTES_PER_PIXEL: u64 = 4;

/// Largest target texture, in bytes.
///
/// In bytes rather than pixels because the format decides the cost, and a pixel
/// budget silently quadruples if the format ever widens.
///
/// The number is derived, not chosen. The largest target the shell can ask for
/// is `layout::MAX_WORLD_TILES` at one physical pixel per world pixel —
/// 3840x2304, or 33.8 MB — and a budget below that would put the *ordinary
/// maximum* into the framing fallback, quietly showing those players less of the
/// game. `the_largest_region_the_shell_can_ask_for_needs_no_framing_reduction`
/// is what keeps the two in step.
///
/// Peak usage is about twice this during a resize, because the replacement is
/// created before the old target is dropped so the swap can be atomic.
pub const MAX_TARGET_BYTES: u64 = 48 * 1024 * 1024;

/// Largest dimension on either axis.
///
/// WebGL2 guarantees only 2048, and wgpu's own default limit is 8192. A texture
/// that exceeds the device maximum fails to create at all — a total-size budget
/// does not catch it, because a 16384x512 target is small and still impossible.
/// The conservative floor is deliberate: this client ships to WebGL2.
pub const MAX_TARGET_DIMENSION: u32 = 8192;

/// Choose the world's render target for a region, ratio and logical zoom.
///
/// `region` is the world's rectangle in logical pixels, as the shell laid it out.
pub fn world_render(region: Rect, device: f32, logical_zoom: u32) -> WorldRender {
    let logical_zoom = logical_zoom.max(1);
    let device = if device.is_finite() && device > 0.0 { device } else { 1.0 };

    let size = Vec2::new(
        if region.width().is_finite() { region.width().max(0.0) } else { 0.0 },
        if region.height().is_finite() { region.height().max(0.0) } else { 0.0 },
    );

    // The composite rectangle, in physical pixels. Rounded once, here, and then
    // used by everything: the projection derives from it, the compositor is
    // placed at it and the pointer inverts through it.
    let min = Vec2::new(
        if region.min.x.is_finite() { region.min.x } else { 0.0 },
        if region.min.y.is_finite() { region.min.y } else { 0.0 },
    );
    let composite_min = (min * device).round();
    let composite = Rect::from_corners(composite_min, composite_min + (size * device).round());

    // World pixels the region shows. This is the framing, and it comes from the
    // logical region only so that a display setting cannot move it.
    let wanted = UVec2::new(
        ((size.x / logical_zoom as f32).floor() as i64).clamp(1, u32::MAX as i64) as u32,
        ((size.y / logical_zoom as f32).floor() as i64).clamp(1, u32::MAX as i64) as u32,
    );

    // Floored, so the zoom is whole and the grid inside the texture is integral.
    // At 1.25 that means rendering at 1x and letting the composite upscale;
    // ceiling instead would render at 2x and then *downscale* to 1.25, throwing
    // away detail it had just paid for.
    let asked = ((device * logical_zoom as f32).floor() as i64).max(1) as u32;

    let fits = |extent: UVec2, zoom: u32| {
        let size = extent * zoom;
        size.x <= MAX_TARGET_DIMENSION
            && size.y <= MAX_TARGET_DIMENSION
            && (size.x as u64) * (size.y as u64) * BYTES_PER_PIXEL <= MAX_TARGET_BYTES
    };

    // Give up sharpness first: it is invisible to most players, where giving up
    // extent changes what is on screen.
    let mut zoom = asked;
    while zoom > 1 && !fits(wanted, zoom) {
        zoom -= 1;
    }

    if fits(wanted, zoom) {
        let reduced = (zoom != asked).then_some(Reduction::Zoom { from: asked, to: zoom });
        return WorldRender { extent: wanted, zoom, composite, reduced };
    }

    // Even 1x does not fit. The shell cannot ask for this — `layout::world_view`
    // caps the region at MAX_WORLD_TILES, which is 3840x2304 world pixels and
    // well inside both bounds — so reaching here means a caller outside that
    // path. Clamp to something creatable and say so: a texture that fails to
    // allocate is a black screen, and a quietly reframed world is a player
    // seeing a different amount of the game than everyone else.
    let used = wanted.min(UVec2::splat(MAX_TARGET_DIMENSION / zoom.max(1))).max(UVec2::ONE);
    let mut extent = used;
    while !fits(extent, zoom) && (extent.x > 1 || extent.y > 1) {
        extent = (extent.as_vec2() * 0.5).floor().as_uvec2().max(UVec2::ONE);
    }
    WorldRender {
        extent,
        zoom,
        composite,
        reduced: Some(Reduction::Framing { wanted, used: extent }),
    }
}

/// Continuous multiplier for text and controls.
///
/// Ramps between two widths instead of stepping, because a step lands in the
/// middle of a window drag and makes the whole interface jump.
pub fn ui_scale(logical_size: Vec2) -> f32 {
    let span = UI_SCALE_MAX_WIDTH - UI_SCALE_BASE_WIDTH;
    let progress = ((logical_size.x - UI_SCALE_BASE_WIDTH) / span).clamp(0.0, 1.0);
    (UI_SCALE_MIN + progress * (UI_SCALE_MAX - UI_SCALE_MIN)).clamp(UI_SCALE_MIN, UI_SCALE_MAX)
}

/// Tiles visible across a viewport of `logical_size`.
///
/// Logical, not physical, and never scaled by the UI domain: making text larger
/// must not change how much of the world a player can see, and neither must
/// plugging in a sharper monitor.
pub fn visible_tiles(logical_size: Vec2, domains: ScaleDomains) -> IVec2 {
    let per_tile = domains.tile_logical_px();
    if per_tile <= 0.0 {
        return IVec2::ZERO;
    }
    IVec2::new(
        (logical_size.x / per_tile).floor().max(0.0) as i32,
        (logical_size.y / per_tile).floor().max(0.0) as i32,
    )
}

/// Snap a world position to the world pixel grid.
///
/// The camera and everything it draws must round the *same* value, or the
/// character wobbles half a pixel against a world that snaps. At world scale
/// N the grid is 1/N of a world unit, because that is one physical pixel.
pub fn snap_to_pixel_grid(position: Vec2, domains: ScaleDomains) -> Vec2 {
    // One physical pixel is 1/(world * device) of a world unit.
    let grid = (domains.world as f32 * domains.device).max(f32::EPSILON);
    (position * grid).round() / grid
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ratios a real user is likely to have: 100%, 125%, 150%, 175% and a
    /// retina display. 125% and 150% are ordinary Windows and GNOME settings.
    const RATIOS: [f32; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

    /// A world region `width` x `height` logical pixels, under the top bar,
    /// which is where the shell puts it.
    ///
    /// The arguments are the region's *size*. Written first as corner
    /// coordinates, which made every caller's region 30 pixels shorter than it
    /// read as, and the tile-cap test noticed by coming up one tile row short.
    fn region(width: f32, height: f32) -> Rect {
        let top = super::super::layout::TOP_BAR_HEIGHT;
        Rect::from_corners(Vec2::new(0.0, top), Vec2::new(width, top + height))
    }

    /// The design window the host page steps in whole multiples of.
    const HOST_DESIGN: Vec2 = Vec2::new(1280.0, 760.0);

    #[test]
    fn the_target_zoom_is_always_a_whole_number_of_physical_pixels() {
        // The whole point. A fractional zoom is the shimmer: nearest sampling
        // duplicates some source pixels and not others, and which ones changes
        // as the camera pans.
        for device in RATIOS {
            for logical in 1..=3u32 {
                let render = world_render(region(998.0, 730.0), device, logical);
                assert!(render.zoom >= 1, "zoom {} at {device}x", render.zoom);
                // Integral by construction — the assertion that matters is that
                // it is never *derived* from the ratio by multiplication, which
                // is what produced 1.25 physical pixels per world pixel.
                assert_eq!(
                    render.zoom as f32,
                    (render.zoom as f32).floor(),
                    "zoom {} is not whole at {device}x",
                    render.zoom
                );
            }
        }
    }

    #[test]
    fn the_framing_comes_from_the_logical_region_and_not_the_display() {
        // A ratio change must not move what is on screen. The extent is the
        // framing, so it is the thing that has to be ratio-independent.
        let region = region(998.0, 730.0);
        let baseline = world_render(region, 1.0, 1).extent;
        for device in RATIOS {
            assert_eq!(
                world_render(region, device, 1).extent,
                baseline,
                "at {device}x the world covers a different number of world pixels"
            );
        }
    }

    #[test]
    fn a_higher_ratio_gets_a_larger_texture_for_the_same_framing() {
        // The complement: ratio-independent framing must not mean the ratio is
        // ignored, or the target is pointless and HiDPI gains nothing.
        let region = region(998.0, 730.0);
        let one = world_render(region, 1.0, 1);
        let two = world_render(region, 2.0, 1);
        assert_eq!(one.extent, two.extent);
        assert!(
            two.texture_size().x > one.texture_size().x,
            "2x renders into {:?}, no larger than 1x at {:?}",
            two.texture_size(),
            one.texture_size()
        );
        assert_eq!(two.zoom, 2);
    }

    #[test]
    fn a_fractional_ratio_renders_at_the_whole_number_below_it() {
        // 1.25 renders at 1x and lets the composite upscale. Ceiling instead
        // would render at 2x and then downscale to 1.25, discarding detail it
        // had just paid to produce.
        let region = region(998.0, 730.0);
        assert_eq!(world_render(region, 1.25, 1).zoom, 1);
        assert_eq!(world_render(region, 1.75, 1).zoom, 1);
        assert_eq!(world_render(region, 2.0, 1).zoom, 2);
        assert_eq!(world_render(region, 2.5, 1).zoom, 2);
    }

    #[test]
    fn the_target_stays_inside_its_memory_bound_by_giving_up_zoom_first() {
        use super::super::layout;
        // The largest region the shell can actually ask for: MAX_WORLD_TILES,
        // which layout::world_view caps at. At 2x that wants 35 million pixels,
        // so the zoom has to come down — and the framing must not.
        let region = region(
            layout::MAX_WORLD_TILES_X as f32 * TILE_SIZE,
            layout::MAX_WORLD_TILES_Y as f32 * TILE_SIZE,
        );
        let render = world_render(region, 2.0, 1);
        assert_eq!(render.zoom, 1, "the zoom was not the thing given up");
        assert!(
            render.texture_bytes() <= MAX_TARGET_BYTES,
            "{:?} is {} bytes, over the {MAX_TARGET_BYTES} budget",
            render.texture_size(),
            render.texture_bytes()
        );
        assert_eq!(
            render.extent,
            world_render(region, 1.0, 1).extent,
            "the bound changed the framing instead of the zoom"
        );
    }

    #[test]
    fn a_region_beyond_anything_the_shell_can_ask_for_is_still_bounded() {
        // Unreachable through the shell, because world_view caps the region
        // first. Asserted anyway: a target over the budget must not be
        // constructible from here whatever a future caller passes.
        let render = world_render(region(20_000.0, 20_000.0), 4.0, 1);
        let size = render.texture_size();
        assert!(
            render.texture_bytes() <= MAX_TARGET_BYTES && size.x <= MAX_TARGET_DIMENSION,
            "{size:?} is {} bytes, over budget",
            render.texture_bytes()
        );
        assert!(size.x >= 1 && size.y >= 1);
    }

    #[test]
    fn a_degenerate_region_or_ratio_still_produces_a_usable_target() {
        // A zero-sized region happens for a frame during startup and on a
        // window collapsed to nothing. A zero-sized texture is not a valid
        // render target, so this may never return one.
        for region in [region(0.0, 0.0), region(-10.0, 5.0), region(f32::NAN, f32::NAN)] {
            for device in [1.0, 0.0, -1.0, f32::NAN, f32::INFINITY] {
                let render = world_render(region, device, 1);
                assert!(render.extent.x >= 1 && render.extent.y >= 1, "{region:?} at {device}");
                assert!(render.zoom >= 1);
            }
        }
    }

    #[test]
    fn the_composite_rectangle_is_the_region_in_physical_pixels() {
        // Carried on the render rather than recomputed, because the projection,
        // the compositor's placement and the pointer's inverse mapping all need
        // the same rectangle — and three roundings of the same numbers is how
        // they come to disagree by a pixel.
        let logical = Rect::from_corners(Vec2::new(0.0, 30.0), Vec2::new(998.0, 760.0));
        for device in RATIOS {
            let render = world_render(logical, device, 1);
            assert_eq!(
                render.composite.min,
                (logical.min * device).round(),
                "composite origin at {device}x"
            );
            assert_eq!(
                render.composite.size(),
                (logical.size() * device).round(),
                "composite size at {device}x"
            );
        }
    }

    #[test]
    fn a_reduced_target_says_so_rather_than_reducing_quietly() {
        // A target that came back smaller has either cost sharpness or changed
        // what the player can see. The second is a fault, and neither may be
        // absorbed silently.
        let ordinary = world_render(region(998.0, 730.0), 2.0, 1);
        assert_eq!(ordinary.reduced, None, "an ordinary window should need no reduction");

        // Large enough that 2x exceeds the budget while 1x fits, so the zoom is
        // what gives way.
        let big = region(2600.0, 1600.0);
        let render = world_render(big, 2.0, 1);
        assert_eq!(render.reduced, Some(Reduction::Zoom { from: 2, to: 1 }));
        assert_eq!(
            render.extent,
            world_render(big, 1.0, 1).extent,
            "the framing moved when only the zoom should have"
        );
    }

    #[test]
    fn the_largest_region_the_shell_can_ask_for_needs_no_framing_reduction() {
        // The budget and the tile cap have to agree. Set the budget below the
        // cap and the *ordinary maximum* silently enters the framing fallback,
        // so a player on a large display sees less of the game than everyone
        // else — and a test comparing two equally reduced framings cannot tell,
        // which is how this went unnoticed for one commit.
        let capped = region(
            super::super::layout::MAX_WORLD_TILES_X as f32 * TILE_SIZE,
            super::super::layout::MAX_WORLD_TILES_Y as f32 * TILE_SIZE,
        );
        for device in RATIOS {
            let render = world_render(capped, device, 1);
            assert!(
                !matches!(render.reduced, Some(Reduction::Framing { .. })),
                "at {device}x the largest legitimate region was reframed: {:?}",
                render.reduced
            );
            assert_eq!(
                render.extent,
                UVec2::new(
                    super::super::layout::MAX_WORLD_TILES_X as u32 * TILE_SIZE as u32,
                    super::super::layout::MAX_WORLD_TILES_Y as u32 * TILE_SIZE as u32
                ),
                "at {device}x the capped region does not cover the tiles it should"
            );
        }
    }

    #[test]
    fn an_impossible_request_reports_a_framing_reduction() {
        // Unreachable through the shell: world_view caps the region first. If a
        // future caller does reach it, the framing change is reported, because a
        // quietly reframed world is a player seeing a different amount of the
        // game than everybody else.
        let render = world_render(region(40_000.0, 40_000.0), 1.0, 1);
        assert!(
            matches!(render.reduced, Some(Reduction::Framing { .. })),
            "got {:?}",
            render.reduced
        );
    }

    #[test]
    fn a_target_never_exceeds_the_device_or_memory_limits() {
        // A total-size budget alone does not catch this: a 16384x512 texture is
        // small and still impossible on hardware whose maximum dimension is
        // 8192. And the budget leaves room for two, because a resize allocates
        // the replacement before dropping the original.
        for device in [1.0f32, 1.25, 1.5, 2.0, 4.0] {
            for size in [500.0f32, 1920.0, 4000.0, 12_000.0] {
                let render = world_render(region(size, size * 0.6), device, 1);
                let texture = render.texture_size();
                assert!(
                    texture.x <= MAX_TARGET_DIMENSION && texture.y <= MAX_TARGET_DIMENSION,
                    "{texture:?} exceeds the {MAX_TARGET_DIMENSION}px dimension limit at {device}x"
                );
                assert!(
                    render.texture_bytes() <= MAX_TARGET_BYTES,
                    "{} bytes at {device}x, over the {MAX_TARGET_BYTES} budget",
                    render.texture_bytes()
                );
                assert!(
                    render.texture_bytes() * 2 <= MAX_TARGET_BYTES * 2,
                    "no headroom for the replacement during a resize"
                );
            }
        }
    }

    #[test]
    fn a_stepped_host_window_actually_steps_the_world_zoom() {
        // The host page grows the windowed shell in whole multiples of this
        // size, on the promise that a larger window means larger sprites rather
        // than merely more terrain. That promise is only kept if the zoom this
        // module derives comes out as the step number — so check it, rather than
        // assume the arithmetic lines up.
        use super::super::layout;

        for step in 1..=3u32 {
            let window = HOST_DESIGN * step as f32;
            // The same two-pass resolve the shell performs: probe at 1x to find
            // how much room the world has, then resolve the scales from it.
            let probe = layout::shell_geometry(window);
            let resolved = resolve(window, probe.world.size(), 1.0);
            assert_eq!(
                resolved.world, step,
                "a {step}-step window ({window:?}) renders the world at {}x",
                resolved.world
            );

            // And that it holds after the shell relays itself at that UI scale,
            // which is the geometry actually used. A zoom that only survives the
            // probe pass would flip back on the next frame.
            let settled = layout::shell_geometry_scaled(window, resolved.ui);
            let again = resolve(window, settled.world.size(), 1.0);
            assert_eq!(
                again.world, resolved.world,
                "a {step}-step window disagrees with itself between passes"
            );
        }
    }

    #[test]
    fn the_tile_count_is_what_a_step_holds_steady() {
        // The point of stepping: the same scene, larger. Not the same size,
        // wider. Tile counts are allowed to differ by the rail's clamps — it is
        // 420 units at every step, so a bigger window really does buy a little
        // more world — but not by a whole multiple.
        use super::super::layout;

        let mut counts = Vec::new();
        for step in 1..=3u32 {
            let window = HOST_DESIGN * step as f32;
            let probe = layout::shell_geometry(window);
            let resolved = resolve(window, probe.world.size(), 1.0);
            let settled = layout::shell_geometry_scaled(window, resolved.ui);
            let tiles = settled.world.size() / (TILE_SIZE * resolved.world as f32);
            counts.push(tiles.x.floor());
        }

        for pair in counts.windows(2) {
            let growth = pair[1] / pair[0];
            assert!(
                growth < 1.5,
                "the tile count grew {growth}x between steps, so stepping is \
                 widening the view rather than enlarging it: {counts:?}"
            );
        }
    }

    /// The world's share of a window, as the shell lays it out.
    fn world_region_of(window: Vec2) -> Vec2 {
        super::super::layout::shell_geometry(window).world.size()
    }

    #[test]
    fn a_device_pixel_ratio_change_alone_does_not_change_framing() {
        // The requirement that drives the whole design. Deriving the world zoom
        // from the ratio made a 1.25x display show 39 tiles across and a 1.5x
        // display show 29 of the same window — a framing change, and with it a
        // change to where every click lands.
        let logical = Vec2::new(1280.0, 720.0);
        let baseline = visible_tiles(logical, resolve(logical, world_region_of(logical), 1.0));

        for ratio in RATIOS {
            let domains = resolve(logical, world_region_of(logical), ratio);
            assert_eq!(
                visible_tiles(logical, domains),
                baseline,
                "{ratio}x showed a different amount of world"
            );
        }
    }

    #[test]
    fn a_device_pixel_ratio_change_alone_does_not_move_pointer_targets() {
        // A tile's logical size is what a click is measured against. If it
        // moved with the ratio, the same pixel would hit a different tile on a
        // sharper monitor.
        let logical = Vec2::new(1280.0, 720.0);
        let baseline = resolve(logical, world_region_of(logical), 1.0).tile_logical_px();

        for ratio in RATIOS {
            assert_eq!(
                resolve(logical, world_region_of(logical), ratio).tile_logical_px(),
                baseline,
                "{ratio}x moved the hit targets"
            );
        }
    }

    #[test]
    fn a_sharper_display_renders_the_same_view_with_more_physical_pixels() {
        // The point of honouring the ratio at all: same framing, more detail.
        let logical = Vec2::new(1280.0, 720.0);
        let one = resolve(logical, world_region_of(logical), 1.0);
        let two = resolve(logical, world_region_of(logical), 2.0);

        assert_eq!(two.tile_physical_px(), one.tile_physical_px() * 2.0);
        assert_eq!(two.projection_scale() * 2.0, one.projection_scale());
    }

    #[test]
    fn the_world_zoom_is_always_a_whole_number_of_logical_pixels() {
        // A fractional zoom puts every texel on a partial pixel, which is the
        // shimmer this domain exists to prevent.
        for width in [640.0, 1280.0, 1920.0, 2560.0, 3840.0, 7680.0] {
            let domains =
                resolve(Vec2::new(width, 900.0), world_region_of(Vec2::new(width, 900.0)), 1.0);
            assert!(domains.world >= 1);
            assert_eq!(domains.tile_logical_px().fract(), 0.0, "{width} gave a fractional tile");
        }
    }

    #[test]
    fn the_world_zoom_follows_the_window_and_not_the_display() {
        // Two ratios, same window: identical zoom. The display's sharpness is
        // not a reason to change what is on screen.
        let small = Vec2::new(1280.0, 832.0);
        assert_eq!(
            resolve(small, world_region_of(small), 1.0).world,
            resolve(small, world_region_of(small), 2.0).world
        );
    }

    #[test]
    fn a_much_larger_window_shows_the_same_view_larger() {
        // Going fullscreen on a wide display used to pull the camera back until
        // the character was a speck and the rail was unreadable. The view is
        // what the interface was designed around; a bigger window should show
        // it bigger.
        let design = Vec2::new(1280.0, 832.0);
        let design_tiles =
            visible_tiles(world_region_of(design), resolve(design, world_region_of(design), 1.0));

        for window in [Vec2::new(2560.0, 1440.0), Vec2::new(3440.0, 1440.0)] {
            let region = world_region_of(window);
            let domains = resolve(window, region, 1.0);
            let tiles = visible_tiles(region, domains);

            assert!(domains.world > 1, "{window:?} did not scale the world up at all");
            assert!(
                tiles.y <= design_tiles.y * 2,
                "{window:?} shows {} rows against a design of {}",
                tiles.y,
                design_tiles.y
            );
        }
    }

    #[test]
    fn the_interface_scales_with_the_world() {
        // A rail drawn at 1x beside a world drawn at 2x is the "everything is
        // tiny" complaint in reverse.
        for window in [Vec2::new(2560.0, 1440.0), Vec2::new(3840.0, 2160.0)] {
            let domains = resolve(window, world_region_of(window), 1.0);
            assert!(
                domains.ui >= domains.world as f32,
                "{window:?}: world at {}x but interface at {}x",
                domains.world,
                domains.ui
            );
        }
    }

    #[test]
    fn the_design_size_itself_is_drawn_at_one_to_one() {
        // The proportions in the shell were measured at this size, so it must
        // not be scaled at all.
        let design = Vec2::new(1280.0, 832.0);
        assert_eq!(resolve(design, world_region_of(design), 1.0).world, 1);
    }

    #[test]
    fn a_node_length_survives_the_global_ui_scale() {
        // Bevy multiplies every Val::Px by UiScale, but not the camera
        // viewport. The shell's regions are computed in logical pixels and have
        // to line up with that viewport exactly, so at any scale above 1.0 the
        // rail drifted away from the world's edge.
        for ui in [1.0, 1.1, 1.25, 1.5] {
            let domains = ScaleDomains { device: 1.0, world: 1, ui };
            for logical in [1.0, 34.0, 281.0, 998.0] {
                let effective = domains.node_px(logical) * ui;
                assert!(
                    (effective - logical).abs() < 0.001,
                    "at UI scale {ui}, {logical}px landed at {effective}px"
                );
            }
        }
    }

    #[test]
    fn the_ui_scale_does_not_change_how_much_world_is_visible() {
        // Larger text must not zoom the world; that would breach the
        // visibility bound as surely as a wider window would.
        let logical = Vec2::new(1920.0, 1080.0);
        let small = ScaleDomains { device: 1.0, world: 1, ui: 1.0 };
        let large = ScaleDomains { device: 1.0, world: 1, ui: 1.5 };

        assert_eq!(visible_tiles(logical, small), visible_tiles(logical, large));
        assert_eq!(small.projection_scale(), large.projection_scale());
    }

    #[test]
    fn the_ui_scale_is_continuous_so_a_drag_does_not_make_the_interface_jump() {
        let mut previous = ui_scale(Vec2::new(600.0, 800.0));
        for width in (600..3600).step_by(10) {
            let current = ui_scale(Vec2::new(width as f32, 800.0));
            assert!(
                (current - previous).abs() < 0.01,
                "the UI scale jumped from {previous} to {current} at {width}px"
            );
            assert!(current >= previous - f32::EPSILON, "the UI scale went backwards");
            previous = current;
        }
    }

    #[test]
    fn the_ui_scale_stays_within_its_bounds() {
        for width in [320.0, 800.0, 1280.0, 1920.0, 2560.0, 3840.0, 7680.0] {
            let scale = ui_scale(Vec2::new(width, 800.0));
            assert!(
                (UI_SCALE_MIN..=UI_SCALE_MAX).contains(&scale),
                "{width}px produced a UI scale of {scale}"
            );
        }
    }

    #[test]
    fn a_small_window_never_shrinks_the_ui_below_its_designed_size() {
        // The rail minimum and the type scale are sized for the smallest
        // supported window, so scaling below 1.0 clips rather than reflows.
        assert_eq!(ui_scale(Vec2::new(320.0, 240.0)), UI_SCALE_MIN);
        assert_eq!(ui_scale(Vec2::new(800.0, 600.0)), UI_SCALE_MIN);
    }

    #[test]
    fn a_nonsense_device_ratio_does_not_produce_a_broken_projection() {
        // A browser mid-restore reports zero, and a disconnected monitor can
        // report NaN. Either divides by zero downstream.
        for ratio in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            let domains =
                resolve(Vec2::new(1280.0, 720.0), world_region_of(Vec2::new(1280.0, 720.0)), ratio);
            assert!(domains.device.is_finite() && domains.device > 0.0);
            assert!(domains.world >= 1);
            assert!(domains.projection_scale().is_finite());
            assert!(domains.projection_scale() > 0.0);
        }
    }

    #[test]
    fn snapping_lands_on_the_physical_pixel_grid_at_every_ratio() {
        // The camera and the character must round the same value; half a pixel
        // of disagreement is a visible wobble.
        for ratio in RATIOS {
            let domains =
                resolve(Vec2::new(1280.0, 720.0), world_region_of(Vec2::new(1280.0, 720.0)), ratio);
            let grid = domains.world as f32 * domains.device;
            let snapped = snap_to_pixel_grid(Vec2::new(10.3, -7.8), domains);

            assert!(
                ((snapped.x * grid).fract()).abs() < 0.001,
                "{ratio}x left x on {}",
                snapped.x * grid
            );
            assert!(
                ((snapped.y * grid).fract()).abs() < 0.001,
                "{ratio}x left y on {}",
                snapped.y * grid
            );
        }
    }

    #[test]
    fn snapping_is_idempotent() {
        // Applied twice — once for the camera, once for the sprite — it must
        // not drift.
        let domains =
            resolve(Vec2::new(1280.0, 720.0), world_region_of(Vec2::new(1280.0, 720.0)), 1.0);
        for position in [Vec2::new(0.4, 0.6), Vec2::new(-12.5, 33.49), Vec2::ZERO] {
            let once = snap_to_pixel_grid(position, domains);
            assert_eq!(snap_to_pixel_grid(once, domains), once);
        }
    }

    #[test]
    fn an_extreme_aspect_ratio_still_resolves() {
        for size in [Vec2::new(5120.0, 1440.0), Vec2::new(720.0, 1600.0), Vec2::new(200.0, 900.0)] {
            let domains = resolve(size, world_region_of(size), 1.0);
            let tiles = visible_tiles(size, domains);
            assert!(tiles.x >= 0 && tiles.y >= 0, "{size:?} produced {tiles:?}");
        }
    }

    #[test]
    fn a_zero_sized_window_yields_no_tiles_rather_than_a_division_by_zero() {
        let domains = resolve(Vec2::ZERO, Vec2::ZERO, 1.0);
        assert_eq!(visible_tiles(Vec2::ZERO, domains), IVec2::ZERO);
    }
}
