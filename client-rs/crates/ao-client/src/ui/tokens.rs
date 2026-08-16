//! Design tokens: the shared vocabulary every control draws from.
//!
//! Values live here rather than at their use sites so a change lands
//! everywhere at once, and so the golden screenshot tests have something
//! specific to be a regression against.
//!
//! The palette is the AO visual heritage — dark wood, gold trim, the stat-bar
//! stack — which is common to every Argentum client including ours. It is
//! derived from that tradition, not sampled from another client's artwork.
//!
//! Two constraints the roadmap sets, which the tests here enforce: every token
//! must stay legible over both bright and dark maps, and status colours must
//! not be the only thing distinguishing a state.

use bevy::prelude::*;

/// Surfaces, from furthest back to nearest.
pub mod surface {
    use super::*;

    // Sampled from the reference client rather than invented. An earlier
    // version of this palette was roughly twice as bright, because a test here
    // demanded that every pair of surfaces differ by 1.25:1 — a threshold that
    // belongs to *text*, not to panels. The reference separates its surfaces by
    // only 1.03 to 1.28 and carries structure through borders and type instead,
    // which is why lightening everything moved away from the target rather than
    // toward it.

    /// The page behind the client window, and the perimeter on capped displays.
    pub const VOID: Color = Color::srgb(0.027, 0.027, 0.055);
    /// The top bar and rail body.
    pub const PANEL: Color = Color::srgb(0.090, 0.071, 0.051);
    /// Inset areas inside a panel: slot grids, list backgrounds, bar tracks.
    pub const WELL: Color = Color::srgb(0.059, 0.047, 0.027);
    /// A raised element inside a panel: a slot face, a button, a selected tab.
    pub const RAISED: Color = Color::srgb(0.114, 0.094, 0.059);
    /// Panel edges and separators.
    ///
    /// A little brighter than the reference's slot border, which is the same
    /// tone as its raised faces. Left equal, a border drawn *on* a raised face
    /// disappears, and the structure the whole palette depends on goes with it.
    pub const EDGE: Color = Color::srgb(0.212, 0.172, 0.108);
}

/// Text and iconography.
pub mod ink {
    use super::*;

    /// Body text on a panel.
    pub const PRIMARY: Color = Color::srgb(0.910, 0.863, 0.769);
    /// Labels and secondary values.
    pub const MUTED: Color = Color::srgb(0.553, 0.565, 0.600);
    /// Headings, the character name, emphasis.
    pub const GOLD: Color = Color::srgb(0.878, 0.663, 0.290);
    /// Disabled or locked.
    pub const DISABLED: Color = Color::srgb(0.353, 0.333, 0.302);
}

/// Vitals and status. Each pairs with a label, never colour alone.
pub mod status {
    use super::*;

    pub const HEALTH: Color = Color::srgb(0.773, 0.110, 0.110);
    pub const MANA: Color = Color::srgb(0.243, 0.365, 0.816);
    pub const STAMINA: Color = Color::srgb(0.851, 0.706, 0.208);
    /// A food brown, not a green. It was a green, and measured only 0.12 from
    /// EXPERIENCE in linear RGB — the hunger bar and the XP bar would have read
    /// as the same colour at a glance.
    pub const HUNGER: Color = Color::srgb(0.550, 0.380, 0.200);
    pub const THIRST: Color = Color::srgb(0.243, 0.612, 0.729);
    pub const EXPERIENCE: Color = Color::srgb(0.239, 0.624, 0.239);
    /// A rejected action, and error text in the world message area.
    pub const DANGER: Color = Color::srgb(0.918, 0.353, 0.286);
    /// A server notice in the world message area.
    pub const NOTICE: Color = Color::srgb(0.400, 0.898, 0.400);

    /// Mandatory shadow behind text drawn straight onto the world.
    ///
    /// World messages have no panel behind them and AO maps run from
    /// snowfields to dungeons, so no single ink colour is legible on all of
    /// them — bright green over snow measures 1.1:1, which is invisible. The
    /// shadow makes the immediate surround of every glyph deterministic, which
    /// is what the contrast test below can then hold to a real threshold. Text
    /// in the world message area must never be drawn without it.
    pub const WORLD_TEXT_SHADOW: Color = Color::srgb(0.031, 0.024, 0.020);
}

/// Focus and selection, which must read on any surface.
pub mod focus {
    use super::*;

    /// Keyboard focus ring. Deliberately not gold: focus must be
    /// distinguishable from ordinary gold trim.
    pub const RING: Color = Color::srgb(0.996, 0.835, 0.412);
    /// The currently selected slot or tab.
    pub const SELECTED: Color = Color::srgb(0.878, 0.663, 0.290);
    pub const RING_WIDTH: f32 = 2.0;
}

/// Spacing scale. One unit is 4 logical pixels.
pub mod space {
    /// Gap between slots in a grid.
    ///
    /// Measured from the reference client: its six columns span 263 logical
    /// pixels, which is 43-pixel slots separated by a single pixel. Anything
    /// wider and six no longer fit a 280-pixel rail.
    pub const GRID_GAP: f32 = 1.0;

    pub const HAIR: f32 = 2.0;
    pub const TIGHT: f32 = 4.0;
    pub const SNUG: f32 = 6.0;
    pub const BASE: f32 = 8.0;
    pub const WIDE: f32 = 12.0;
    pub const LOOSE: f32 = 16.0;
}

/// Type scale, in logical pixels.
pub mod type_scale {
    /// Slot quantities and other in-artwork numerals.
    pub const MICRO: f32 = 10.0;
    /// Labels, the status bar.
    pub const SMALL: f32 = 12.0;
    /// Body text and values.
    pub const BODY: f32 = 13.0;
    /// Panel headings. Below the character name, which is the only text in the
    /// rail that outranks them.
    pub const HEADING: f32 = 14.0;
    /// The character name. Sized from the reference client, where it is the
    /// largest text in the interface but still only a little above body size —
    /// a rail is not a poster.
    pub const TITLE: f32 = 16.0;
}

/// Fixed sizes shared by controls.
pub mod size {
    /// An inventory or spell slot, including its border.
    ///
    /// Measured: six columns and five one-pixel gaps across the 263 logical
    /// pixels the reference rail gives its grid.
    pub const SLOT: f32 = 43.0;
    /// A hotbar slot.
    pub const HOTBAR_SLOT: f32 = 46.0;
    /// A status bar's height, chosen so a numeral fits inside it. Measured
    /// from the reference client's HP bar.
    pub const STATUS_BAR_HEIGHT: f32 = 16.0;
    /// An icon button in the top bar or rail footer.
    pub const ICON_BUTTON: f32 = 26.0;
    /// Border thickness on panels and slots.
    pub const BORDER: f32 = 1.0;
}

/// Relative luminance, for the contrast checks below.
///
/// WCAG's definition, which is what its contrast ratio is defined against.
fn luminance(color: Color) -> f32 {
    let c = color.to_linear();
    0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
}

/// WCAG contrast ratio between two colours, from 1.0 to 21.0.
pub fn contrast_ratio(a: Color, b: Color) -> f32 {
    let (la, lb) = (luminance(a), luminance(b));
    let (lighter, darker) = if la > lb { (la, lb) } else { (lb, la) };
    (lighter + 0.05) / (darker + 0.05)
}

/// Straight-line distance between two colours in linear RGB.
///
/// Crude perceptually, but it answers the question contrast cannot: whether two
/// colours *look different*. Two colours can share a luminance — and so score
/// 1.0 contrast — while being red and blue.
pub fn channel_distance(a: Color, b: Color) -> f32 {
    let (a, b) = (a.to_linear(), b.to_linear());
    ((a.red - b.red).powi(2) + (a.green - b.green).powi(2) + (a.blue - b.blue).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// WCAG AA for text at these sizes.
    const AA_TEXT: f32 = 4.5;
    /// WCAG AA for large text and for meaningful non-text elements.
    const AA_LARGE: f32 = 3.0;

    #[test]
    fn a_border_is_visible_against_every_surface_it_separates() {
        // This is what actually carries the structure. The reference client's
        // surfaces differ by as little as 1.03:1 and its interface still reads,
        // because the borders and the type do the work. A border that
        // disappears against a slot face is what makes a grid look like one
        // continuous well.
        for (name, against) in
            [("panel", surface::PANEL), ("well", surface::WELL), ("raised", surface::RAISED)]
        {
            let ratio = contrast_ratio(surface::EDGE, against);
            assert!(ratio >= 1.15, "the edge is only {ratio:.3}:1 against {name}");
        }
    }

    #[test]
    fn no_two_surfaces_are_the_same_colour() {
        // They are allowed to be close — the reference's are — but two that are
        // identical mean one of the five tokens is not doing anything.
        let surfaces = [
            ("void", surface::VOID),
            ("panel", surface::PANEL),
            ("well", surface::WELL),
            ("raised", surface::RAISED),
            ("edge", surface::EDGE),
        ];
        for (i, (a_name, a)) in surfaces.iter().enumerate() {
            for (b_name, b) in &surfaces[i + 1..] {
                assert_ne!(a, b, "{a_name} and {b_name} are the same colour");
            }
        }
    }

    #[test]
    fn the_client_window_is_visible_against_the_page_behind_it() {
        // The client presents as a window on a dark page. Its own border is
        // what separates the two, so that is what is measured.
        assert!(contrast_ratio(surface::EDGE, surface::VOID) >= 1.2);
    }

    #[test]
    fn body_text_is_legible_on_every_surface_it_is_drawn_on() {
        for (name, surface) in
            [("panel", surface::PANEL), ("well", surface::WELL), ("raised", surface::RAISED)]
        {
            let ratio = contrast_ratio(ink::PRIMARY, surface);
            assert!(ratio >= AA_TEXT, "primary ink on {name} is only {ratio:.2}:1");
        }
    }

    #[test]
    fn muted_text_stays_readable_rather_than_merely_dimmer() {
        // Muted is for labels that still have to be read. Disabled is the token
        // for text that does not.
        for (name, surface) in [("panel", surface::PANEL), ("well", surface::WELL)] {
            let ratio = contrast_ratio(ink::MUTED, surface);
            assert!(ratio >= AA_LARGE, "muted ink on {name} is only {ratio:.2}:1");
        }
    }

    #[test]
    fn headings_are_legible_on_panels() {
        let ratio = contrast_ratio(ink::GOLD, surface::PANEL);
        assert!(ratio >= AA_LARGE, "gold on panel is only {ratio:.2}:1");
    }

    #[test]
    fn world_text_is_legible_against_its_mandatory_shadow() {
        // Measured against the shadow, not the map, because the map is not
        // knowable: these render straight onto the world, and AO maps run from
        // snowfields to dungeons. Bright green over snow is 1.1:1 — invisible.
        // The shadow is what makes each glyph's immediate surround
        // deterministic, so this is the contrast that actually governs.
        for (name, color) in [("notice", status::NOTICE), ("danger", status::DANGER)] {
            let ratio = contrast_ratio(color, status::WORLD_TEXT_SHADOW);
            assert!(ratio >= AA_TEXT, "{name} against its shadow is only {ratio:.2}:1");
        }
    }

    #[test]
    fn the_world_text_shadow_is_dark_enough_to_survive_a_bright_map() {
        // A shadow that a snowfield washes out provides no surround at all.
        let bright_map = Color::srgb(0.85, 0.85, 0.80);
        let ratio = contrast_ratio(status::WORLD_TEXT_SHADOW, bright_map);
        assert!(ratio >= AA_TEXT, "the shadow is only {ratio:.2}:1 against snow");
    }

    #[test]
    fn the_focus_ring_is_distinguishable_from_ordinary_gold_trim() {
        // If focus looks like decoration, keyboard users cannot tell where they
        // are. It has to differ from both the trim and the panel behind it.
        assert!(contrast_ratio(focus::RING, surface::PANEL) >= AA_LARGE);
        assert_ne!(focus::RING, ink::GOLD);
        assert!(
            contrast_ratio(focus::RING, surface::EDGE) >= 2.0,
            "the focus ring must not disappear into a panel border"
        );
    }

    #[test]
    fn disabled_reads_as_disabled_without_becoming_invisible() {
        // Locked inventory slots are shown rather than hidden, so their content
        // must be perceivable while clearly not usable.
        let ratio = contrast_ratio(ink::DISABLED, surface::WELL);
        assert!(ratio >= 1.4, "disabled ink is only {ratio:.2}:1 — indistinguishable from empty");
        assert!(
            ratio < contrast_ratio(ink::PRIMARY, surface::WELL),
            "disabled must be visibly weaker than enabled"
        );
    }

    #[test]
    fn every_vital_is_visibly_different_from_every_other() {
        // Separation is measured as distance in linear RGB, not as a contrast
        // ratio. Contrast is a luminance comparison, and health red and mana
        // blue are near-identical in luminance while being impossible to
        // confuse — an earlier version of this test failed them for it.
        //
        // Colour is never the sole cue regardless: every bar carries its own
        // label, which is what carries the meaning for colour-blind players.
        // This only guards against two bars looking accidentally alike.
        let vitals = [
            ("health", status::HEALTH),
            ("mana", status::MANA),
            ("stamina", status::STAMINA),
            ("hunger", status::HUNGER),
            ("thirst", status::THIRST),
            ("experience", status::EXPERIENCE),
        ];

        for (i, (a_name, a)) in vitals.iter().enumerate() {
            for (b_name, b) in &vitals[i + 1..] {
                let separation = channel_distance(*a, *b);
                assert!(
                    separation >= 0.25,
                    "{a_name} and {b_name} are only {separation:.3} apart in linear RGB"
                );
            }
        }
    }

    #[test]
    fn every_vital_fill_is_visible_against_the_well_behind_it() {
        // A bar's fill has to be distinguishable from its empty track, or a
        // nearly-empty bar looks the same as a full one.
        for (name, color) in [
            ("health", status::HEALTH),
            ("mana", status::MANA),
            ("stamina", status::STAMINA),
            ("hunger", status::HUNGER),
            ("thirst", status::THIRST),
            ("experience", status::EXPERIENCE),
        ] {
            let ratio = contrast_ratio(color, surface::WELL);
            assert!(ratio >= 1.6, "{name} fill is only {ratio:.2}:1 against an empty track");
        }
    }

    #[test]
    fn numbers_fit_inside_a_status_bar() {
        // The reference client draws the value inside the bar rather than
        // beside it, which is one of the ideas the roadmap calls out as worth
        // taking. That only works if the bar is taller than the glyphs.
        assert!(
            size::STATUS_BAR_HEIGHT >= type_scale::SMALL + space::HAIR * 2.0,
            "a {}px bar cannot contain {}px text",
            size::STATUS_BAR_HEIGHT,
            type_scale::SMALL
        );
    }

    #[test]
    fn the_type_scale_ascends() {
        let scale = [
            type_scale::MICRO,
            type_scale::SMALL,
            type_scale::BODY,
            type_scale::HEADING,
            type_scale::TITLE,
        ];
        assert!(scale.windows(2).all(|w| w[0] < w[1]), "type scale is not ordered: {scale:?}");
    }

    #[test]
    fn the_spacing_scale_ascends() {
        let scale =
            [space::HAIR, space::TIGHT, space::SNUG, space::BASE, space::WIDE, space::LOOSE];
        assert!(scale.windows(2).all(|w| w[0] < w[1]), "spacing scale is not ordered: {scale:?}");
    }

    #[test]
    fn contrast_ratio_matches_its_definition_at_the_extremes() {
        // Guards the checks above: a broken ratio would let every other test
        // here pass while proving nothing.
        let extreme = contrast_ratio(Color::WHITE, Color::BLACK);
        assert!((extreme - 21.0).abs() < 0.1, "white on black should be 21:1, got {extreme:.2}");
        assert!((contrast_ratio(Color::WHITE, Color::WHITE) - 1.0).abs() < 0.01);
        // Symmetric in its arguments.
        assert_eq!(
            contrast_ratio(ink::PRIMARY, surface::PANEL),
            contrast_ratio(surface::PANEL, ink::PRIMARY)
        );
    }
}
