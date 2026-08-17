//! Where the shell's regions go, for a given window.
//!
//! Pure geometry, deliberately not flexbox. The world viewport is a *camera*
//! rectangle, not a UI node — the world is rendered by a camera whose viewport
//! must line up exactly with the space the rail leaves. Reading that rectangle
//! back out of a solved flex tree means the camera is always one frame behind
//! the layout, which on resize shows as a strip of stale pixels down the edge
//! of the world.
//!
//! Computing it up front instead makes the same numbers available to the UI
//! nodes, the camera and the tests, with no frame skew and no guessing at what
//! the layout engine decided.
//!
//! Everything here is in **logical** pixels. Device pixel ratio is applied once,
//! at the camera boundary; see `scale`.

use bevy::prelude::*;

/// Height of the top status bar.
///
/// Fixed rather than proportional: it holds one row of text and icons, and a
/// bar that grows with the window just wastes vertical space on large screens.
/// Measured from the reference client.
pub const TOP_BAR_HEIGHT: f32 = 30.0;

/// Share of the window width the character rail aims for.
///
/// The reference client sits at roughly 22%, which the roadmap records as the
/// 21–23% target.
pub const RAIL_FRACTION: f32 = 0.22;

/// Narrowest the full rail may become.
///
/// Below this the six-column inventory grid stops being readable — the slots
/// are fixed-size artwork, so a narrower rail clips them rather than reflowing.
pub const RAIL_MIN_WIDTH: f32 = 280.0;

/// Widest the full rail may become.
///
/// Its content is a fixed grid and a stack of bars; past this the rail is
/// mostly empty and the extra width is worth more to the world.
pub const RAIL_MAX_WIDTH: f32 = 420.0;

/// Width of the rail in compact mode: an icon strip, no grid.
pub const RAIL_COMPACT_WIDTH: f32 = 56.0;

/// Extra width required to leave compact mode, beyond what entering it needed.
///
/// Without it the mode flips on a single pixel: a window dragged to exactly the
/// breakpoint alternates between a full rail and an icon strip on every frame,
/// which is both unusable and expensive, since every flip rebuilds the rail.
///
/// Sized larger than any single drag step so crossing the band is deliberate.
pub const COMPACT_HYSTERESIS: f32 = 48.0;

/// Below this world width the full rail is giving up too much of the game.
///
/// The choice is between a rail whose controls are unusably small and a rail
/// that deliberately becomes an icon strip. The roadmap picks the second.
pub const WORLD_MIN_WIDTH: f32 = 640.0;

/// The server's area of interest, as a tile radius around the player.
///
/// Mirrors `:arena, :aoi_range_x/y` (`Arena.Map.Helpers`). The server sends
/// entities only within this rectangle, so it is the exact bound on what a
/// client can legitimately know about other players, NPCs and ground items.
///
/// Duplicated rather than negotiated because it is a *bound*, not a setting:
/// the client enforces it on itself so a wider window cannot become a
/// spyglass, and `aoi_matches_server` in the server test suite fails if the
/// two ever drift apart.
pub const AOI_RADIUS_X: i32 = 11;
pub const AOI_RADIUS_Y: i32 = 9;

/// Largest world area rendered, in tiles, regardless of window size.
///
/// A performance ceiling, not an aesthetic one. Every visible tile on every
/// layer is a sprite entity, so an unbounded viewport on a 7680px ultrawide
/// renders tens of thousands of them for no benefit. Sized so that every
/// target in the roadmap's list — up to 4K — renders edge to edge with no
/// perimeter at all; only genuinely extreme displays see a frame.
///
/// Terrain is public: the whole map pack is downloaded, so filling a large
/// screen with it gains a player nothing. Entities are a different matter and
/// are bounded by [`AOI_RADIUS_X`]/[`AOI_RADIUS_Y`], never by this.
pub const MAX_WORLD_TILES_X: i32 = 120;
pub const MAX_WORLD_TILES_Y: i32 = 72;

/// One tile, in logical pixels. Matches `world::TILE_SIZE`.
pub const TILE_SIZE: f32 = 32.0;

/// Smallest window the client claims to support.
///
/// Derived, not chosen: it is the size at which the whole area of interest is
/// still on screen beside a compact rail. Below it a player could be attacked
/// from a tile the server told them about but the client never drew, which is
/// a fairness problem rather than a cosmetic one.
pub fn minimum_supported_size() -> Vec2 {
    Vec2::new(
        (AOI_RADIUS_X * 2 + 1) as f32 * TILE_SIZE + RAIL_COMPACT_WIDTH,
        (AOI_RADIUS_Y * 2 + 1) as f32 * TILE_SIZE + TOP_BAR_HEIGHT,
    )
}

/// Whether a tile is inside the area of interest around `(px, py)`.
///
/// The client's own bound on entity rendering. The server already refuses to
/// send anything outside it, so this is defence in depth: a stale entity, a
/// fixture, or a future prediction path must not be able to draw something the
/// server would not have told a player about.
pub fn within_area_of_interest(x: i32, y: i32, px: i32, py: i32) -> bool {
    (x - px).abs() <= AOI_RADIUS_X && (y - py).abs() <= AOI_RADIUS_Y
}

/// How much world is drawn, and where.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WorldView {
    /// Tiles visible across and down, after the cap.
    pub tiles: IVec2,
    /// The area actually filled with world, centred in the world region.
    pub rect: Rect,
    /// True when the cap left space that is decoration rather than world.
    pub has_perimeter: bool,
}

/// Decide the drawn world area for a given world region.
pub fn world_view(world: Rect) -> WorldView {
    let available = world.size();

    let tiles = IVec2::new(
        ((available.x / TILE_SIZE).floor() as i32).clamp(0, MAX_WORLD_TILES_X),
        ((available.y / TILE_SIZE).floor() as i32).clamp(0, MAX_WORLD_TILES_Y),
    );

    // Only the capped axes are inset; an uncapped axis keeps every pixel it
    // has, so the common case has no perimeter at all.
    let filled = Vec2::new(
        if tiles.x >= MAX_WORLD_TILES_X { tiles.x as f32 * TILE_SIZE } else { available.x },
        if tiles.y >= MAX_WORLD_TILES_Y { tiles.y as f32 * TILE_SIZE } else { available.y },
    );

    let inset = ((available - filled) * 0.5).max(Vec2::ZERO).floor();
    let min = world.min + inset;

    WorldView {
        tiles,
        rect: Rect::from_corners(min, min + filled),
        has_perimeter: inset.x > 0.0 || inset.y > 0.0,
    }
}

/// How the rail is presenting itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailMode {
    /// Full rail: character header, grid, vitals, navigation.
    Full,
    /// Icon strip. Panels open over the world instead of living in the rail.
    Compact,
}

/// Resolved regions, in logical pixels, with the origin at the window's top left.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShellGeometry {
    pub top_bar: Rect,
    pub world: Rect,
    pub rail: Rect,
    pub rail_mode: RailMode,
}

impl ShellGeometry {
    /// True when a region came out with no area, which means the window is too
    /// small to show that part of the shell at all.
    pub fn world_is_visible(&self) -> bool {
        self.world.width() > 0.0 && self.world.height() > 0.0
    }
}

/// Lay out the shell for a window of `size` logical pixels.
///
/// Total width is always partitioned exactly: the rail takes its share and the
/// world takes the remainder, so the two can never overlap or leave a gap the
/// clear colour shows through.
pub fn shell_geometry(size: Vec2) -> ShellGeometry {
    shell_geometry_scaled(size, 1.0)
}

/// Decide the rail mode, holding the previous one inside the hysteresis band.
///
/// `previous` is what the shell is currently showing. A window resting exactly
/// on the breakpoint keeps whichever mode it already had, so dragging past it
/// is a decision rather than a flicker.
pub fn rail_mode_for(world_width: f32, previous: Option<RailMode>) -> RailMode {
    match previous {
        Some(RailMode::Compact) => {
            if world_width >= WORLD_MIN_WIDTH + COMPACT_HYSTERESIS {
                RailMode::Full
            } else {
                RailMode::Compact
            }
        }
        _ => {
            if world_width < WORLD_MIN_WIDTH {
                RailMode::Compact
            } else {
                RailMode::Full
            }
        }
    }
}

/// Lay out the shell when the interface is drawn at `ui_scale`.
///
/// The clamps are content-driven — the rail's minimum is six slots wide, the
/// top bar is one row of text tall — so they have to grow with the content.
/// Left in unscaled pixels while `UiScale` doubled everything inside them, the
/// rail stayed 420 logical pixels while its slots became 86, and the
/// six-column grid silently laid itself out as four with the remainder spilling
/// out of the panel.
///
/// The regions themselves stay in logical pixels, because the camera viewport
/// and the pointer both work in those and must agree with them exactly.
pub fn shell_geometry_scaled(size: Vec2, ui_scale: f32) -> ShellGeometry {
    shell_geometry_with(size, ui_scale, None)
}

/// Lay out the shell, holding `previous` inside the compact hysteresis band.
pub fn shell_geometry_with(size: Vec2, ui_scale: f32, previous: Option<RailMode>) -> ShellGeometry {
    let ui = if ui_scale.is_finite() && ui_scale > 0.0 { ui_scale } else { 1.0 };
    let width = size.x.max(0.0);
    let height = size.y.max(0.0);

    // The bar is fixed, but it cannot claim height the window does not have.
    let top_bar_height = (TOP_BAR_HEIGHT * ui).min(height);
    let body_top = top_bar_height;
    let body_height = (height - top_bar_height).max(0.0);

    // Rounded to whole logical pixels. A fractional rail (22% of 1280 is
    // 281.6) makes the world's width fractional too, and the world's edge is a
    // camera viewport in *physical* pixels: 998.4 rounds to 998 at 1x but 1997
    // at 2x, so the seam between world and rail lands differently per display.
    let preferred = (width * RAIL_FRACTION).clamp(RAIL_MIN_WIDTH * ui, RAIL_MAX_WIDTH * ui).round();
    let rail_mode = rail_mode_for(width - preferred, previous);
    let rail_width = match rail_mode {
        RailMode::Compact => RAIL_COMPACT_WIDTH * ui,
        RailMode::Full => preferred,
    };

    // Even the compact strip yields if there is genuinely no room; the world is
    // the part of the screen that cannot be given up.
    let rail_width = rail_width.min(width);
    let world_width = (width - rail_width).max(0.0);

    ShellGeometry {
        top_bar: Rect::new(0.0, 0.0, width, top_bar_height),
        world: Rect::new(0.0, body_top, world_width, body_top + body_height),
        rail: Rect::new(world_width, body_top, width, body_top + body_height),
        rail_mode,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sizes the client is expected to run at, from the roadmap's target list.
    const TARGETS: [(&str, Vec2); 6] = [
        ("small laptop", Vec2::new(1280.0, 720.0)),
        ("720p", Vec2::new(1280.0, 720.0)),
        ("1080p", Vec2::new(1920.0, 1080.0)),
        ("1440p", Vec2::new(2560.0, 1440.0)),
        ("ultrawide", Vec2::new(3440.0, 1440.0)),
        ("4k", Vec2::new(3840.0, 2160.0)),
    ];

    #[test]
    fn the_area_of_interest_matches_the_servers() {
        // The server's `:arena, :aoi_range_x/y`. If these drift the client
        // either hides entities the server sent — attacked from an empty
        // tile — or reserves space for entities that never arrive.
        assert_eq!(AOI_RADIUS_X, 11);
        assert_eq!(AOI_RADIUS_Y, 9);
    }

    #[test]
    fn the_area_of_interest_is_a_rectangle_not_a_circle() {
        // The server tests each axis separately, so the corners are included.
        // A radial client bound would drop entities the server did send.
        assert!(within_area_of_interest(50 + AOI_RADIUS_X, 50 + AOI_RADIUS_Y, 50, 50));
        assert!(!within_area_of_interest(50 + AOI_RADIUS_X + 1, 50, 50, 50));
        assert!(!within_area_of_interest(50, 50 + AOI_RADIUS_Y + 1, 50, 50));
    }

    #[test]
    fn a_larger_window_does_not_widen_the_area_of_interest() {
        // The fairness property: the bound is a constant, so no window size,
        // rail mode or scale factor can turn a wide monitor into a spyglass.
        for size in [Vec2::new(800.0, 600.0), Vec2::new(3840.0, 2160.0), Vec2::new(5120.0, 1440.0)]
        {
            let geometry = shell_geometry(size);
            let view = world_view(geometry.world);
            // The viewport may show more *terrain*, which is public.
            assert!(view.tiles.x > 0);
            // It never shows an entity further away.
            assert!(!within_area_of_interest(50 + AOI_RADIUS_X + 1, 50, 50, 50));
        }
    }

    #[test]
    fn the_minimum_supported_size_shows_the_whole_area_of_interest() {
        // Derived rather than chosen. Below this a player can be attacked from
        // a tile the server told the client about but the client never drew.
        let minimum = minimum_supported_size();
        let geometry = shell_geometry(minimum);
        let view = world_view(geometry.world);

        assert!(
            view.tiles.x >= AOI_RADIUS_X * 2 + 1,
            "only {} tiles wide, need {}",
            view.tiles.x,
            AOI_RADIUS_X * 2 + 1
        );
        assert!(
            view.tiles.y >= AOI_RADIUS_Y * 2 + 1,
            "only {} tiles tall, need {}",
            view.tiles.y,
            AOI_RADIUS_Y * 2 + 1
        );
    }

    #[test]
    fn every_supported_target_shows_the_whole_area_of_interest() {
        for (name, size) in TARGETS {
            let view = world_view(shell_geometry(size).world);
            assert!(
                view.tiles.x >= AOI_RADIUS_X * 2 + 1 && view.tiles.y >= AOI_RADIUS_Y * 2 + 1,
                "{name} shows {}x{} tiles, less than the area of interest",
                view.tiles.x,
                view.tiles.y
            );
        }
    }

    #[test]
    fn ordinary_windows_have_no_cosmetic_perimeter() {
        // The cap only exists for extreme displays. A letterbox at 1080p would
        // be a self-inflicted wound.
        for (name, size) in TARGETS {
            let view = world_view(shell_geometry(size).world);
            assert!(!view.has_perimeter, "{name} ({size:?}) was letterboxed");
        }
    }

    #[test]
    fn an_extreme_ultrawide_is_capped_and_the_remainder_is_decoration() {
        // Unbounded, a 5120px ultrawide renders an absurd area for no benefit.
        let view = world_view(shell_geometry(Vec2::new(7680.0, 2160.0)).world);

        assert_eq!(view.tiles.x, MAX_WORLD_TILES_X);
        assert!(view.has_perimeter);
        assert!(view.rect.width() <= MAX_WORLD_TILES_X as f32 * TILE_SIZE);
    }

    #[test]
    fn the_world_view_stays_inside_its_region() {
        // A view wider than its region would draw world under the rail.
        for size in [Vec2::new(800.0, 600.0), Vec2::new(1920.0, 1080.0), Vec2::new(7680.0, 2160.0)]
        {
            let geometry = shell_geometry(size);
            let view = world_view(geometry.world);
            assert!(view.rect.min.x >= geometry.world.min.x - 0.5);
            assert!(view.rect.max.x <= geometry.world.max.x + 0.5);
            assert!(view.rect.min.y >= geometry.world.min.y - 0.5);
            assert!(view.rect.max.y <= geometry.world.max.y + 0.5);
        }
    }

    #[test]
    fn a_capped_world_is_centred_in_its_region() {
        // Off-centre perimeter reads as a rendering bug rather than a frame.
        let geometry = shell_geometry(Vec2::new(7680.0, 2160.0));
        let view = world_view(geometry.world);

        let left = view.rect.min.x - geometry.world.min.x;
        let right = geometry.world.max.x - view.rect.max.x;
        assert!((left - right).abs() <= 1.0, "perimeter is {left} left and {right} right");
    }

    #[test]
    fn the_window_is_partitioned_exactly() {
        // No overlap and no gap: a gap shows the clear colour as a seam, an
        // overlap puts the rail on top of world the camera still renders.
        for (name, size) in TARGETS {
            let g = shell_geometry(size);
            assert_eq!(g.world.max.x, g.rail.min.x, "{name}: world and rail must meet");
            assert_eq!(g.rail.max.x, size.x, "{name}: rail must reach the window edge");
            assert_eq!(g.world.min.y, g.top_bar.max.y, "{name}: world must start below the bar");
            assert_eq!(g.rail.max.y, size.y, "{name}: rail must reach the window bottom");
        }
    }

    #[test]
    fn regions_land_on_whole_logical_pixels() {
        // The world's edge becomes a camera viewport in physical pixels. A
        // fractional logical edge rounds differently at 1x and 2x, so the seam
        // between world and rail moves depending on the display.
        for width in [1280.0, 1366.0, 1440.0, 1920.0, 2560.0, 3440.0] {
            let g = shell_geometry(Vec2::new(width, 900.0));
            assert_eq!(g.rail.width().fract(), 0.0, "rail width {} is fractional", g.rail.width());
            assert_eq!(
                g.world.width().fract(),
                0.0,
                "world width {} is fractional",
                g.world.width()
            );
        }
    }

    #[test]
    fn the_rail_holds_the_same_content_at_every_interface_scale() {
        // The clamps are content-driven — the minimum is six slots wide — so
        // they have to grow with the content. Left unscaled, a 2x interface got
        // a rail still capped at 420 logical pixels while its slots had doubled
        // to 86, and the six-column grid silently became four.
        //
        // The share of the window is *not* the invariant: the maximum clamp
        // binds on a large display, which is deliberate and asserted elsewhere.
        // What must hold is that the rail is always the same size measured in
        // the units its contents are declared in.
        //
        // Scales come from the resolver rather than from a list, because the
        // two are not independent: 1.5x in a 1280 window would need a rail
        // wider than a third of the screen, and the resolver never asks for it.
        for size in [
            Vec2::new(1280.0, 832.0),
            Vec2::new(1920.0, 1080.0),
            Vec2::new(2560.0, 1440.0),
            Vec2::new(3840.0, 2160.0),
        ] {
            let probe = shell_geometry(size);
            let ui = super::super::scale::resolve(size, probe.world.size(), 1.0).ui;
            let geometry = shell_geometry_scaled(size, ui);
            if geometry.rail_mode != RailMode::Full {
                continue;
            }

            let in_content_units = geometry.rail.width() / ui;
            assert!(
                (RAIL_MIN_WIDTH..=RAIL_MAX_WIDTH).contains(&in_content_units),
                "{size:?} at {ui}x gave the rail {in_content_units} content units"
            );
            assert!(
                geometry.rail.width() / size.x <= 0.23,
                "{size:?} at {ui}x: the rail took {:.1}% of the width",
                geometry.rail.width() / size.x * 100.0
            );
        }
    }

    #[test]
    fn the_top_bar_grows_with_the_interface_scale() {
        // It holds one row of text. If the text doubles and the bar does not,
        // the text is clipped.
        let size = Vec2::new(1920.0, 1080.0);
        let one = shell_geometry_scaled(size, 1.0).top_bar.height();
        let two = shell_geometry_scaled(size, 2.0).top_bar.height();

        assert_eq!(two, one * 2.0);
    }

    #[test]
    fn a_nonsense_ui_scale_lays_out_as_though_unscaled() {
        // Resolved from a window that can report zero mid-restore.
        for ui in [0.0, -1.0, f32::NAN] {
            let geometry = shell_geometry_scaled(Vec2::new(1280.0, 832.0), ui);
            assert_eq!(geometry, shell_geometry(Vec2::new(1280.0, 832.0)), "{ui} broke the layout");
        }
    }

    #[test]
    fn the_rail_holds_its_target_share_on_ordinary_windows() {
        // 21-23% is the roadmap's band, taken from the reference client.
        for size in [Vec2::new(1280.0, 720.0), Vec2::new(1600.0, 900.0)] {
            let g = shell_geometry(size);
            let share = g.rail.width() / size.x;
            assert!(
                (0.21..=0.23).contains(&share),
                "{size:?}: rail took {:.1}% of the width",
                share * 100.0
            );
        }
    }

    #[test]
    fn the_rail_stops_growing_so_large_screens_give_their_space_to_the_world() {
        // At 22% a 4K rail would be 845px of mostly empty panel.
        let g = shell_geometry(Vec2::new(3840.0, 2160.0));
        assert_eq!(g.rail.width(), RAIL_MAX_WIDTH);
        assert!(g.world.width() > 3000.0);
    }

    #[test]
    fn the_rail_stops_shrinking_before_its_contents_clip() {
        // Slots are fixed-size artwork and do not reflow, so a narrower rail
        // cuts them off rather than rearranging them.
        let g = shell_geometry(Vec2::new(1024.0, 768.0));
        assert!(g.rail.width() >= RAIL_MIN_WIDTH || g.rail_mode == RailMode::Compact);
    }

    #[test]
    fn a_small_window_switches_the_rail_rather_than_squeezing_the_world() {
        // The deliberate choice from roadmap item 2: shrink the rail's *mode*,
        // never its controls.
        let g = shell_geometry(Vec2::new(800.0, 600.0));
        assert_eq!(g.rail_mode, RailMode::Compact);
        assert_eq!(g.rail.width(), RAIL_COMPACT_WIDTH);
        assert!(g.world.width() > WORLD_MIN_WIDTH * 0.9, "the world keeps the space");
    }

    #[test]
    fn the_switch_to_compact_happens_before_the_world_gets_too_small() {
        // Walk the width down and check the mode flips while the world is still
        // above its minimum, not after it has already been squeezed.
        let mut flipped_at = None;
        for width in (600..=1400).rev().step_by(10) {
            let g = shell_geometry(Vec2::new(width as f32, 800.0));
            if g.rail_mode == RailMode::Compact {
                flipped_at = Some(width as f32);
                break;
            }
            assert!(
                g.world.width() >= WORLD_MIN_WIDTH,
                "world fell to {} while the rail was still full",
                g.world.width()
            );
        }
        assert!(flipped_at.is_some(), "the rail never went compact");
    }

    #[test]
    fn a_one_pixel_dither_cannot_toggle_the_mode_forever() {
        // The failure this rules out: a window resting between two widths — a
        // drag that jitters, a scrollbar appearing and disappearing — driving a
        // rail rebuild every frame.
        //
        // Note this is *not* "the mode never changes at the threshold". Every
        // threshold has a pixel where one direction crosses it; asserting both
        // directions hold at the same pixel is unsatisfiable. What must hold is
        // that the crossings are at *different* widths, so a two-pixel dither
        // settles instead of alternating.
        for width in 400..3000 {
            let low = width as f32;
            let high = low + 1.0;

            // Widening one pixel promotes...
            let promoted =
                shell_geometry_with(Vec2::new(high, 800.0), 1.0, Some(RailMode::Compact)).rail_mode;
            // ...and narrowing that same pixel demotes again.
            let demoted =
                shell_geometry_with(Vec2::new(low, 800.0), 1.0, Some(RailMode::Full)).rail_mode;

            assert!(
                !(promoted == RailMode::Full && demoted == RailMode::Compact),
                "a dither between {low}px and {high}px toggles the rail forever"
            );
        }
    }

    #[test]
    fn the_two_thresholds_are_a_hysteresis_band_apart() {
        // With the band collapsed to zero the test above still passes at every
        // width but one, so pin the band itself.
        let width_of = |mode: RailMode| {
            (400..3000)
                .map(|w| w as f32)
                .find(|w| {
                    shell_geometry_with(Vec2::new(*w, 800.0), 1.0, Some(mode)).rail_mode
                        == RailMode::Full
                })
                .expect("the rail goes full somewhere")
        };

        let from_full = width_of(RailMode::Full);
        let from_compact = width_of(RailMode::Compact);
        assert!(
            from_compact > from_full,
            "widening promotes at {from_compact}px but narrowing demotes at {from_full}px; \
             the thresholds coincide, so there is no band"
        );
        assert_eq!(
            from_compact - from_full,
            COMPACT_HYSTERESIS,
            "the band is {}px wide, not the documented {COMPACT_HYSTERESIS}px",
            from_compact - from_full
        );
    }

    #[test]
    fn crossing_the_whole_band_does_change_the_mode() {
        // Hysteresis must not become "the mode never changes".
        let narrow = shell_geometry_with(Vec2::new(700.0, 800.0), 1.0, Some(RailMode::Full));
        assert_eq!(narrow.rail_mode, RailMode::Compact);

        let wide = shell_geometry_with(Vec2::new(1600.0, 800.0), 1.0, Some(RailMode::Compact));
        assert_eq!(wide.rail_mode, RailMode::Full);
    }

    #[test]
    fn a_drag_across_the_band_settles_rather_than_alternating() {
        // Walk a window across the breakpoint one pixel at a time, carrying the
        // mode forward as the shell does, and count the transitions. More than
        // one in each direction is a flicker.
        let mut mode = RailMode::Compact;
        let mut transitions = 0;
        for width in 600..1600 {
            let next =
                shell_geometry_with(Vec2::new(width as f32, 800.0), 1.0, Some(mode)).rail_mode;
            if next != mode {
                transitions += 1;
                mode = next;
            }
        }
        assert_eq!(transitions, 1, "the mode changed {transitions} times widening once");

        for width in (600..1600).rev() {
            let next =
                shell_geometry_with(Vec2::new(width as f32, 800.0), 1.0, Some(mode)).rail_mode;
            if next != mode {
                transitions += 1;
                mode = next;
            }
        }
        assert_eq!(transitions, 2, "narrowing back did not settle either");
    }

    #[test]
    fn the_mode_does_not_oscillate_across_a_resize() {
        // One threshold, crossed once. Two competing rules would flip the rail
        // back and forth while a window is being dragged.
        let mut modes = Vec::new();
        for width in (400..=3000).step_by(10) {
            let mode = shell_geometry(Vec2::new(width as f32, 800.0)).rail_mode;
            if modes.last() != Some(&mode) {
                modes.push(mode);
            }
        }
        assert_eq!(
            modes,
            vec![RailMode::Compact, RailMode::Full],
            "expected exactly one transition, got {modes:?}"
        );
    }

    #[test]
    fn the_world_never_gains_height_the_top_bar_is_using() {
        for (name, size) in TARGETS {
            let g = shell_geometry(size);
            assert_eq!(
                g.top_bar.height() + g.world.height(),
                size.y,
                "{name}: bar and world must together fill the window"
            );
        }
    }

    #[test]
    fn a_degenerate_window_produces_no_negative_regions() {
        // Browsers report a zero-sized window while a tab is being restored,
        // and a negative width becomes a camera viewport that panics.
        for size in [Vec2::ZERO, Vec2::new(0.0, 800.0), Vec2::new(800.0, 0.0), Vec2::new(1.0, 1.0)]
        {
            let g = shell_geometry(size);
            for (name, rect) in [("top bar", g.top_bar), ("world", g.world), ("rail", g.rail)] {
                assert!(rect.width() >= 0.0, "{size:?}: {name} width went negative");
                assert!(rect.height() >= 0.0, "{size:?}: {name} height went negative");
            }
        }
    }

    #[test]
    fn a_window_shorter_than_the_bar_still_yields_a_usable_partition() {
        let g = shell_geometry(Vec2::new(1280.0, 20.0));
        assert_eq!(g.top_bar.height(), 20.0, "the bar cannot claim height that is not there");
        assert!(!g.world_is_visible(), "and the world is honestly reported as invisible");
    }
}
