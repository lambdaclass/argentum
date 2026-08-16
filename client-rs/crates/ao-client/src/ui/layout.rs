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
pub const TOP_BAR_HEIGHT: f32 = 34.0;

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

/// Below this world width the full rail is giving up too much of the game.
///
/// The choice is between a rail whose controls are unusably small and a rail
/// that deliberately becomes an icon strip. The roadmap picks the second.
pub const WORLD_MIN_WIDTH: f32 = 640.0;

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
    let width = size.x.max(0.0);
    let height = size.y.max(0.0);

    // The bar is fixed, but it cannot claim height the window does not have.
    let top_bar_height = TOP_BAR_HEIGHT.min(height);
    let body_top = top_bar_height;
    let body_height = (height - top_bar_height).max(0.0);

    // Rounded to whole logical pixels. A fractional rail (22% of 1280 is
    // 281.6) makes the world's width fractional too, and the world's edge is a
    // camera viewport in *physical* pixels: 998.4 rounds to 998 at 1x but 1997
    // at 2x, so the seam between world and rail lands differently per display.
    let preferred = (width * RAIL_FRACTION).clamp(RAIL_MIN_WIDTH, RAIL_MAX_WIDTH).round();
    let (rail_width, rail_mode) = if width - preferred < WORLD_MIN_WIDTH {
        (RAIL_COMPACT_WIDTH, RailMode::Compact)
    } else {
        (preferred, RailMode::Full)
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
