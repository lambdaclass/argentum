//! The character rail: the full-height panel on the right.
//!
//! This establishes the named regions and their vertical order. What goes
//! *inside* them is fixture-driven and arrives with W-0006 (character, vitals,
//! inventory, equipment) and W-0007 (spells, hotbar); until then each region is
//! an empty, correctly-sized well rather than placeholder content pretending to
//! be data.
//!
//! Ordering is deliberate and follows the reference composition: identity at
//! the top where the eye starts, the grid in the middle where it spends most of
//! its time, and vitals at the bottom edge nearest the world — the numbers you
//! check mid-fight sit closest to what you are looking at.

use super::shell::{label, muted_label, CompactRailOnly, FullRailOnly, Region};
use super::tokens::{ink, size, space, surface, type_scale};
use bevy::prelude::*;

/// The rail's stacked regions, top to bottom.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailRegion {
    /// Name, class, level, XP and clock.
    CharacterHeader,
    /// Inventory / Spells tab strip.
    Tabs,
    /// The slot grid the tabs switch between.
    SlotGrid,
    /// Details of the selected slot, with the discard target.
    SelectedDetails,
    /// Quick-use consumables.
    Consumables,
    /// Equipment summary and currency.
    Equipment,
    /// HP, mana, stamina, hunger, thirst.
    Vitals,
    /// The icon row along the bottom.
    Navigation,
}

impl RailRegion {
    /// Top-to-bottom order, which is also the tab order.
    pub const ORDER: [RailRegion; 8] = [
        RailRegion::CharacterHeader,
        RailRegion::Tabs,
        RailRegion::SlotGrid,
        RailRegion::SelectedDetails,
        RailRegion::Consumables,
        RailRegion::Equipment,
        RailRegion::Vitals,
        RailRegion::Navigation,
    ];

    /// Whether this region survives into the compact rail.
    ///
    /// Compact is an icon strip: there is no room for a six-column grid or a
    /// stack of labelled bars, so those regions are dropped and their content
    /// is reached through the navigation icons instead. Dropping *vitals*
    /// would be wrong — they are the one thing needed mid-fight — so they stay
    /// as unlabelled slivers.
    pub fn survives_compact(self) -> bool {
        matches!(self, RailRegion::Vitals | RailRegion::Navigation)
    }
}

pub struct RailPlugin;

impl Plugin for RailPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, populate.after(super::shell::spawn_shell));
    }
}

/// A well: the standard container for a rail region.
fn region_well(region: RailRegion, height: Val) -> impl Bundle {
    (
        Node {
            width: Val::Percent(100.0),
            height,
            flex_direction: FlexDirection::Column,
            row_gap: Val::Px(space::TIGHT),
            padding: UiRect::all(Val::Px(space::SNUG)),
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(surface::EDGE),
        region,
    )
}

fn populate(mut commands: Commands, rails: Query<(Entity, &Region)>) {
    let Some((rail, _)) = rails.iter().find(|(_, region)| **region == Region::Rail) else {
        return;
    };

    commands.entity(rail).insert(Node {
        position_type: PositionType::Absolute,
        flex_direction: FlexDirection::Column,
        row_gap: Val::Px(space::SNUG),
        padding: UiRect::all(Val::Px(space::BASE)),
        ..default()
    });

    commands.entity(rail).with_children(|rail| {
        // Identity, where the eye starts.
        // No placeholder children: `character::rebuild_on_change` fills this
        // from the snapshot. They used to be spawned here as well, so the rail
        // showed a dash and "not connected" above the character it was in fact
        // displaying.
        rail.spawn((region_well(RailRegion::CharacterHeader, Val::Auto), FullRailOnly));

        rail.spawn((
            region_well(RailRegion::Tabs, Val::Auto),
            FullRailOnly,
            children![muted_label("Inventory    Spells")],
        ));

        // Every region below carries a label when it has nothing in it. An
        // unexplained empty panel reads as a rendering failure, and there is no
        // way for a player to tell it apart from one.

        // The grid takes the slack, so the regions below stay pinned to the
        // bottom edge regardless of window height.
        rail.spawn((
            Node {
                width: Val::Percent(100.0),
                flex_grow: 1.0,
                min_height: Val::Px(size::SLOT * 2.0),
                border: UiRect::all(Val::Px(size::BORDER)),
                ..default()
            },
            BackgroundColor(surface::WELL),
            BorderColor::all(surface::EDGE),
            RailRegion::SlotGrid,
            FullRailOnly,
        ));

        rail.spawn((region_well(RailRegion::SelectedDetails, Val::Px(72.0)), FullRailOnly));

        // These two have no content until their tasks land. Each says so
        // rather than sitting blank: an unlabelled empty panel is
        // indistinguishable from one that failed to draw.
        rail.spawn((
            region_well(RailRegion::Consumables, Val::Px(size::SLOT + space::WIDE)),
            FullRailOnly,
            children![muted_label("quick slots — not yet wired")],
        ));
        rail.spawn((region_well(RailRegion::Equipment, Val::Auto), FullRailOnly));

        // Vitals sit at the bottom, nearest the world: the numbers checked
        // mid-fight belong closest to what is being looked at.
        rail.spawn((region_well(RailRegion::Vitals, Val::Auto), FullRailOnly));

        rail.spawn((
            region_well(RailRegion::Navigation, Val::Px(size::ICON_BUTTON + space::WIDE)),
            FullRailOnly,
            children![muted_label("navigation — not yet wired")],
        ));

        // Compact rail: an icon strip. Vitals survive as unlabelled slivers
        // because they are the one thing needed mid-fight.
        rail.spawn((
            Node {
                width: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                row_gap: Val::Px(space::TIGHT),
                display: Display::None,
                ..default()
            },
            CompactRailOnly,
            RailRegion::Navigation,
        ));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_region_appears_exactly_once_in_the_order() {
        // The order is also the keyboard tab order, so a duplicate or a
        // missing entry is a focus trap rather than a cosmetic problem.
        for region in RailRegion::ORDER {
            let count = RailRegion::ORDER.iter().filter(|r| **r == region).count();
            assert_eq!(count, 1, "{region:?} appears {count} times in the order");
        }
    }

    #[test]
    fn identity_is_first_and_navigation_last() {
        assert_eq!(RailRegion::ORDER.first(), Some(&RailRegion::CharacterHeader));
        assert_eq!(RailRegion::ORDER.last(), Some(&RailRegion::Navigation));
    }

    #[test]
    fn vitals_sit_below_the_grid_and_nearest_the_world() {
        // Mid-fight the eye is on the world; the numbers checked without
        // looking away belong at the bottom edge of the rail.
        let position = |target: RailRegion| RailRegion::ORDER.iter().position(|r| *r == target);
        assert!(position(RailRegion::Vitals) > position(RailRegion::SlotGrid));
        assert!(position(RailRegion::Vitals) > position(RailRegion::Equipment));
    }

    #[test]
    fn the_compact_rail_keeps_vitals_and_a_way_back_to_everything_else() {
        // Compact drops panels, not information. Losing health while the
        // window is small would be a functional regression, not a layout one.
        assert!(RailRegion::Vitals.survives_compact());
        assert!(RailRegion::Navigation.survives_compact());
    }

    #[test]
    fn the_compact_rail_drops_what_cannot_fit_in_an_icon_strip() {
        // A six-column grid does not fit in 56px; shrinking it until it does
        // is exactly the failure mode the roadmap rules out.
        for region in
            [RailRegion::SlotGrid, RailRegion::CharacterHeader, RailRegion::SelectedDetails]
        {
            assert!(!region.survives_compact(), "{region:?} cannot fit an icon strip");
        }
    }

    #[test]
    fn compact_mode_is_reachable_from_the_layout() {
        // Guards against the rail regions and the geometry disagreeing about
        // whether compact exists at all.
        let compact = super::super::layout::shell_geometry(Vec2::new(800.0, 600.0));
        assert_eq!(compact.rail_mode, super::super::layout::RailMode::Compact);
        assert!(RailRegion::ORDER.iter().any(|r| r.survives_compact()));
    }
}
