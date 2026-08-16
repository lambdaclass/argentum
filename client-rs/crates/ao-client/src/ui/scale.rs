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

/// Bounds on the UI multiplier.
///
/// Never below 1.0: the rail's minimum width and the type scale are already
/// sized for the smallest supported window, so shrinking further clips rather
/// than reflows. Capped because past this the rail is mostly padding.
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
    /// Physical pixels covered by one tile.
    pub fn tile_physical_px(&self) -> f32 {
        TILE_SIZE * self.world as f32
    }

    /// Logical pixels covered by one tile, which is what a player perceives.
    pub fn tile_logical_px(&self) -> f32 {
        self.tile_physical_px() / self.device.max(f32::EPSILON)
    }

    /// Orthographic projection scale for the world camera.
    ///
    /// The exact reciprocal of the world scale, so one world unit is exactly
    /// `world` physical pixels. Anything else resamples the tile atlas.
    pub fn projection_scale(&self) -> f32 {
        1.0 / self.world as f32
    }
}

/// Resolve all three domains for a window.
pub fn resolve(logical_size: Vec2, device_pixel_ratio: f32) -> ScaleDomains {
    let device = if device_pixel_ratio.is_finite() && device_pixel_ratio > 0.0 {
        device_pixel_ratio
    } else {
        // A browser mid-restore can report zero or NaN. Falling through with it
        // produces a zero-sized viewport and a division by zero in the
        // projection.
        1.0
    };

    ScaleDomains { device, world: world_scale(device), ui: ui_scale(logical_size) }
}

/// Whole physical pixels per world pixel.
///
/// Rounds the device ratio rather than truncating it: at 1.5x, scale 1 leaves
/// each world pixel covering one and a half physical pixels — the fractional
/// case this domain exists to avoid — while scale 2 keeps the grid exact and
/// makes tiles slightly larger, which is the better trade for pixel art.
pub fn world_scale(device_pixel_ratio: f32) -> u32 {
    (device_pixel_ratio.round() as i32).max(1) as u32
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

/// Tiles visible across a viewport of `physical_size`.
///
/// Derived from physical pixels and the world scale, never from the UI scale:
/// making text larger must not change how much of the world a player can see.
pub fn visible_tiles(physical_size: Vec2, domains: ScaleDomains) -> IVec2 {
    let per_tile = domains.tile_physical_px();
    if per_tile <= 0.0 {
        return IVec2::ZERO;
    }
    IVec2::new(
        (physical_size.x / per_tile).floor().max(0.0) as i32,
        (physical_size.y / per_tile).floor().max(0.0) as i32,
    )
}

/// Snap a world position to the world pixel grid.
///
/// The camera and everything it draws must round the *same* value, or the
/// character wobbles half a pixel against a world that snaps. At world scale
/// N the grid is 1/N of a world unit, because that is one physical pixel.
pub fn snap_to_pixel_grid(position: Vec2, domains: ScaleDomains) -> Vec2 {
    let grid = domains.world as f32;
    (position * grid).round() / grid
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_world_scale_is_always_a_whole_number() {
        // The entire point of this domain. At a fractional scale each texel
        // lands on a partial physical pixel and scrolling pixel art shimmers.
        for ratio in [0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0] {
            let scale = world_scale(ratio);
            assert!(scale >= 1, "{ratio}x produced scale {scale}");
            let domains = ScaleDomains { device: ratio, world: scale, ui: 1.0 };
            assert_eq!(
                domains.tile_physical_px().fract(),
                0.0,
                "{ratio}x puts a tile on a fractional physical pixel"
            );
        }
    }

    #[test]
    fn a_fractional_device_ratio_rounds_up_rather_than_down() {
        // At 1.5x, scale 1 is the fractional case this domain exists to avoid.
        // Scale 2 keeps the grid exact; tiles come out slightly larger, which
        // is the better trade for pixel art.
        assert_eq!(world_scale(1.5), 2);
        assert_eq!(world_scale(1.25), 1);
        assert_eq!(world_scale(1.75), 2);
    }

    #[test]
    fn the_projection_is_the_exact_reciprocal_of_the_world_scale() {
        // Anything else resamples the atlas. Checked as an exact product
        // because "close enough" is precisely what blurs a tile edge.
        for world in 1..=4u32 {
            let domains = ScaleDomains { device: world as f32, world, ui: 1.0 };
            assert_eq!(domains.projection_scale() * world as f32, 1.0);
        }
    }

    #[test]
    fn the_projection_follows_the_world_scale_and_not_the_device_ratio() {
        // Deliberately separated: the device ratio is fractional and the world
        // scale is not, so binding the projection to the device ratio puts
        // every texel back on a half pixel. An earlier version of the test
        // above happened to set device equal to world, which made both
        // formulas agree and let exactly this mistake through.
        for ratio in [1.5, 1.75, 2.5, 3.4] {
            let domains = resolve(Vec2::new(1280.0, 720.0), ratio);
            assert_ne!(
                domains.device, domains.world as f32,
                "{ratio}x must exercise the case where the two differ"
            );
            assert_eq!(
                domains.projection_scale(),
                1.0 / domains.world as f32,
                "{ratio}x bound the projection to the device ratio"
            );
        }
    }

    #[test]
    fn a_high_dpi_display_shows_the_same_amount_of_world() {
        // A retina display should render the same view more sharply, not zoom
        // out. If tiles stayed 32 physical pixels the player would see twice
        // as much world, which is the visibility bound from W-0002.
        let logical = Vec2::new(1280.0, 720.0);
        let at_1x = resolve(logical, 1.0);
        let at_2x = resolve(logical, 2.0);

        assert_eq!(
            visible_tiles(logical, at_1x),
            visible_tiles(logical * 2.0, at_2x),
            "a 2x display must show the same tiles, not more"
        );
        assert_eq!(at_1x.tile_logical_px(), at_2x.tile_logical_px());
    }

    #[test]
    fn browser_zoom_changes_apparent_size_without_changing_crispness() {
        // Browser zoom arrives as a device pixel ratio change. The world scale
        // follows it, so the grid stays exact at every zoom step.
        for zoom in [0.67, 0.8, 1.0, 1.1, 1.25, 1.5, 2.0] {
            let domains = resolve(Vec2::new(1280.0, 720.0), zoom);
            assert_eq!(domains.tile_physical_px().fract(), 0.0, "zoom {zoom} broke the grid");
        }
    }

    #[test]
    fn the_ui_scale_is_continuous_so_a_drag_does_not_make_the_interface_jump() {
        // A step lands mid-drag and the whole interface snaps a size.
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
        // The rail minimum and the type scale are already sized for the
        // smallest supported window, so scaling below 1.0 clips rather than
        // reflows.
        assert_eq!(ui_scale(Vec2::new(320.0, 240.0)), UI_SCALE_MIN);
        assert_eq!(ui_scale(Vec2::new(800.0, 600.0)), UI_SCALE_MIN);
    }

    #[test]
    fn making_the_ui_larger_does_not_zoom_the_world() {
        // The domains are separate specifically so this cannot happen: a
        // larger rail must not reveal or hide tiles.
        let physical = Vec2::new(1920.0, 1080.0);
        let small_ui = ScaleDomains { device: 1.0, world: 1, ui: 1.0 };
        let large_ui = ScaleDomains { device: 1.0, world: 1, ui: UI_SCALE_MAX };

        assert_eq!(visible_tiles(physical, small_ui), visible_tiles(physical, large_ui));
    }

    #[test]
    fn a_nonsense_device_ratio_does_not_produce_a_broken_projection() {
        // A browser mid-restore reports zero, and a disconnected monitor can
        // report NaN. Either divides by zero downstream.
        for ratio in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            let domains = resolve(Vec2::new(1280.0, 720.0), ratio);
            assert!(domains.device.is_finite() && domains.device > 0.0);
            assert!(domains.world >= 1);
            assert!(domains.projection_scale().is_finite());
        }
    }

    #[test]
    fn snapping_lands_on_the_physical_pixel_grid() {
        // The camera and the character must round the same value; half a pixel
        // of disagreement is a visible wobble.
        let domains = ScaleDomains { device: 2.0, world: 2, ui: 1.0 };
        let snapped = snap_to_pixel_grid(Vec2::new(10.3, -7.8), domains);

        assert_eq!((snapped.x * 2.0).fract(), 0.0);
        assert_eq!((snapped.y * 2.0).fract(), 0.0);
    }

    #[test]
    fn snapping_is_idempotent() {
        // Applied twice — once for the camera, once for the sprite — it must
        // not drift.
        let domains = ScaleDomains { device: 1.0, world: 1, ui: 1.0 };
        for position in [Vec2::new(0.4, 0.6), Vec2::new(-12.5, 33.49), Vec2::ZERO] {
            let once = snap_to_pixel_grid(position, domains);
            assert_eq!(snap_to_pixel_grid(once, domains), once);
        }
    }

    #[test]
    fn an_extreme_aspect_ratio_still_resolves() {
        // Ultrawide, a portrait phone and a sliver of a window.
        for size in [Vec2::new(5120.0, 1440.0), Vec2::new(720.0, 1600.0), Vec2::new(200.0, 900.0)] {
            let domains = resolve(size, 1.0);
            let tiles = visible_tiles(size, domains);
            assert!(tiles.x >= 0 && tiles.y >= 0, "{size:?} produced {tiles:?}");
        }
    }

    #[test]
    fn a_zero_sized_window_yields_no_tiles_rather_than_a_division_by_zero() {
        let domains = resolve(Vec2::ZERO, 1.0);
        assert_eq!(visible_tiles(Vec2::ZERO, domains), IVec2::ZERO);
    }
}
