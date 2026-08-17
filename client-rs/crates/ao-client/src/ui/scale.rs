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
