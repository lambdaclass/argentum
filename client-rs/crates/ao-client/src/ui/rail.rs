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

use super::controls::{Control, ControlKey};
use super::icons::{icon, AccessibleName, Icon, ShowsTooltip};
use super::shell::{muted_label, CompactRailOnly, FullRailOnly, Region};
use super::tokens::{ink, size, space, status, surface};
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
        // because they are the one thing needed mid-fight, and the navigation
        // icons remain because they are how everything the strip dropped is
        // reached. An empty node here would have been a claim, not a rail.
        rail.spawn((
            Node {
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                justify_content: JustifyContent::SpaceBetween,
                row_gap: Val::Px(space::TIGHT),
                display: Display::None,
                ..default()
            },
            CompactRailOnly,
            children![compact_vitals(), compact_navigation()],
        ));
    });
}

/// Vitals as unlabelled slivers.
///
/// No numbers and no names: at 56 logical pixels there is no room, and a
/// truncated "HP: 14..." is worse than a bar whose fill speaks for itself. The
/// order matches the full rail so the colours mean the same thing in both.
fn compact_vitals() -> impl Bundle {
    (
        Node {
            width: Val::Percent(100.0),
            flex_direction: FlexDirection::Column,
            row_gap: Val::Px(space::HAIR),
            padding: UiRect::all(Val::Px(space::TIGHT)),
            ..default()
        },
        RailRegion::Vitals,
        Children::spawn(SpawnIter(
            [status::HEALTH, status::MANA, status::STAMINA, status::HUNGER, status::THIRST]
                .into_iter()
                .map(compact_sliver),
        )),
    )
}

/// One sliver. Filled by `character::rebuild_on_change` from the snapshot; the
/// track is drawn here so the region is never an unexplained black well.
fn compact_sliver(fill: Color) -> impl Bundle {
    (
        Node {
            width: Val::Percent(100.0),
            height: Val::Px(COMPACT_SLIVER_HEIGHT),
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(surface::EDGE),
        CompactVital(fill),
        // The fill is created with the track, so the sliver is never an
        // unexplained empty well waiting for its first snapshot.
        children![(
            Node {
                position_type: PositionType::Absolute,
                left: Val::Px(0.0),
                top: Val::Px(0.0),
                bottom: Val::Px(0.0),
                width: Val::Percent(0.0),
                ..default()
            },
            BackgroundColor(fill),
            CompactVitalFill,
        )],
    )
}

/// The filled portion of a compact sliver.
#[derive(Component, Debug, Clone, Copy)]
pub struct CompactVitalFill;

/// Height of a compact vital sliver.
const COMPACT_SLIVER_HEIGHT: f32 = 6.0;

/// A vital drawn as a bare bar in the compact rail.
#[derive(Component, Debug, Clone, Copy)]
pub struct CompactVital(pub Color);

/// The navigation icons, stacked instead of in a row.
fn compact_navigation() -> impl Bundle {
    (
        Node {
            width: Val::Percent(100.0),
            flex_direction: FlexDirection::Column,
            align_items: AlignItems::Center,
            row_gap: Val::Px(space::TIGHT),
            padding: UiRect::all(Val::Px(space::TIGHT)),
            ..default()
        },
        RailRegion::Navigation,
        Children::spawn(SpawnIter(COMPACT_NAVIGATION.into_iter().enumerate().map(
            |(index, kind)| {
                (
                    Button,
                    Node {
                        width: Val::Px(size::ICON_BUTTON),
                        height: Val::Px(size::ICON_BUTTON),
                        justify_content: JustifyContent::Center,
                        align_items: AlignItems::Center,
                        ..default()
                    },
                    BackgroundColor(surface::RAISED),
                    AccessibleName::new(kind.name_key()),
                    ShowsTooltip,
                    ControlKey::indexed("rail.compact.nav", index),
                    Control { tab_index: 500 + index as u32, ..default() },
                    CompactNavigation,
                    children![icon(kind, size::ICON_BUTTON * 0.62, ink::PRIMARY)],
                )
            },
        ))),
    )
}

/// What the compact strip offers. Deliberately few: these are the ways back to
/// what the strip had to drop, not the whole interface in miniature.
const COMPACT_NAVIGATION: [Icon; 3] = [Icon::Settings, Icon::Support, Icon::Language];

/// A navigation control that exists only in the compact rail.
#[derive(Component, Debug, Clone, Copy)]
pub struct CompactNavigation;

#[cfg(test)]
mod tests {
    use super::*;

    /// Spawn the real rail tree and run the mode systems over it.
    fn rail_app(window: Vec2) -> App {
        use super::super::shell::{AppliedGeometry, ShellPlugin};

        let mut app = App::new();
        app.add_plugins(ShellPlugin)
            .init_resource::<super::super::scale::ScaleDomains>()
            .init_resource::<UiScale>()
            .init_resource::<crate::world::ViewRadius>()
            .add_plugins(RailPlugin);

        let mut win = Window::default();
        win.resolution.set(window.x, window.y);
        app.world_mut().spawn(win);

        // Two frames: one to spawn the tree, one for the mode systems to act on
        // the geometry the first produced.
        app.update();
        app.update();

        let _ = app.world().resource::<AppliedGeometry>();
        app
    }

    /// Whether an entity and all its ancestors are displayed.
    fn is_displayed(app: &App, entity: Entity) -> bool {
        let mut current = Some(entity);
        while let Some(id) = current {
            match app.world().get::<Node>(id) {
                Some(node) if node.display == Display::None => return false,
                _ => {}
            }
            current = app.world().get::<ChildOf>(id).map(|parent| parent.parent());
        }
        true
    }

    #[test]
    fn compact_mode_renders_a_visible_vital_and_a_usable_navigation_control() {
        // An enum saying these regions survive is not evidence. This spawns the
        // real tree at a window narrow enough to be compact and looks for the
        // nodes a player would actually see.
        let mut app = rail_app(Vec2::new(760.0, 700.0));
        assert_eq!(
            app.world().resource::<super::super::shell::AppliedGeometry>().0.rail_mode,
            super::super::layout::RailMode::Compact,
            "this window should be compact, or the test proves nothing"
        );

        let vitals: Vec<Entity> = app
            .world_mut()
            .query_filtered::<Entity, With<CompactVital>>()
            .iter(app.world())
            .collect();
        assert!(!vitals.is_empty(), "compact mode drew no vitals");
        assert!(
            vitals.iter().any(|entity| is_displayed(&app, *entity)),
            "every compact vital was hidden"
        );

        let navigation: Vec<Entity> = app
            .world_mut()
            .query_filtered::<Entity, With<CompactNavigation>>()
            .iter(app.world())
            .collect();
        assert!(!navigation.is_empty(), "compact mode drew no navigation controls");
        assert!(
            navigation.iter().any(|entity| is_displayed(&app, *entity)),
            "every compact navigation control was hidden"
        );
    }

    #[test]
    fn a_compact_navigation_control_is_focusable_rather_than_decorative() {
        // "Usable" means reachable: a strip of icons nothing can focus is a
        // picture of a rail.
        let mut app = rail_app(Vec2::new(760.0, 700.0));

        let mut query = app.world_mut().query_filtered::<&Control, With<CompactNavigation>>();
        let controls: Vec<bool> = query.iter(app.world()).map(|c| c.enabled).collect();

        assert!(!controls.is_empty(), "compact navigation has no controls");
        assert!(controls.iter().any(|enabled| *enabled), "no compact control is enabled");
    }

    #[test]
    fn the_full_rail_is_hidden_in_compact_mode_and_shown_otherwise() {
        let mut app = rail_app(Vec2::new(760.0, 700.0));
        let mut full = app.world_mut().query_filtered::<Entity, With<FullRailOnly>>();
        let hidden: Vec<Entity> = full.iter(app.world()).collect();
        assert!(!hidden.is_empty(), "there is no full-rail content to hide");
        assert!(
            hidden.iter().all(|entity| !is_displayed(&app, *entity)),
            "full-rail content is still displayed in compact mode"
        );

        let mut wide = rail_app(Vec2::new(1600.0, 900.0));
        assert_eq!(
            wide.world().resource::<super::super::shell::AppliedGeometry>().0.rail_mode,
            super::super::layout::RailMode::Full
        );
        let mut compact = wide.world_mut().query_filtered::<Entity, With<CompactRailOnly>>();
        let strip: Vec<Entity> = compact.iter(wide.world()).collect();
        assert!(
            strip.iter().all(|entity| !is_displayed(&wide, *entity)),
            "the compact strip is displayed beside a full rail"
        );
    }

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
