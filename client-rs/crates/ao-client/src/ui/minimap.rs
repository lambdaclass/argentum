//! The minimap, in the world's upper right.
//!
//! It replaces a black rectangle with the word "unavailable" in it — which was honest
//! while there was nothing to draw, and stops being honest the moment there is.
//!
//! What it draws is deliberately what the *server disclosed*: a window of tiles around
//! the player and the markers inside it. Nothing here reads the downloaded map assets to
//! find entities the server did not mention. A minimap that showed hostiles the server
//! was withholding would be a wall-hack built out of presentation code, and the roadmap
//! forbids exactly that.
//!
//! Every marker has a shape as well as a colour, because a player who cannot distinguish
//! two of the colours still has to be able to tell a party member from a wolf.

use super::state::UiState;
use super::tokens::{ink, space, status, type_scale};
use ao_core::view::{MapAvailability, MapMarker, MarkerKind, MinimapState};
use bevy::prelude::*;

/// Content of the minimap, rebuilt when what it shows changes.
#[derive(Component)]
struct MinimapContent;

pub struct MinimapPlugin;

impl Plugin for MinimapPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            present_minimap
                .after(super::shell::spawn_shell)
                .in_set(super::controls::ControlSet::Rebuild),
        );
    }
}

/// Where a marker sits inside the minimap, as a fraction of its width and height.
///
/// `None` when the marker is outside the window the minimap covers. Returning a clamped
/// position instead would pin every distant hostile to the edge, which reads as a crowd at
/// the border rather than as nothing being there.
pub fn marker_fraction(marker: &MapMarker, state: &MinimapState) -> Option<Vec2> {
    let radius = state.radius;
    // A radius of zero covers one tile and cannot be divided by. The malformed fixture
    // sends one, and dividing produced infinities that laid the marker out at the edge of
    // the world.
    if radius <= 0 {
        return (marker.x == state.centre.0 && marker.y == state.centre.1)
            .then_some(Vec2::splat(0.5));
    }

    let (cx, cy) = state.centre;
    let dx = marker.x - cx;
    let dy = marker.y - cy;
    if dx.abs() > radius || dy.abs() > radius {
        return None;
    }

    let span = (radius * 2) as f32;
    Some(Vec2::new(
        (dx + radius) as f32 / span,
        // Map y grows south, and so does the screen: no flip, unlike the world view.
        (dy + radius) as f32 / span,
    ))
}

/// The word for what the minimap is showing, when it is not a map.
///
/// Idle and loading are different from unavailable, and both are different from an empty
/// map: "nothing yet" and "nothing here" send a player to different places.
pub fn state_key(availability: MapAvailability) -> Option<&'static str> {
    match availability {
        MapAvailability::Ready => None,
        MapAvailability::Idle => Some("map.idle"),
        MapAvailability::Loading => Some("map.loading"),
        MapAvailability::Unavailable(reason) => Some(reason.name_key()),
    }
}

/// How big a marker is drawn, in logical pixels.
const MARKER: f32 = 6.0;

pub fn marker_ink(kind: MarkerKind) -> Color {
    match kind {
        MarkerKind::Player => ink::PRIMARY,
        MarkerKind::Party => status::THIRST,
        MarkerKind::Hostile => status::DANGER,
        MarkerKind::Landmark => ink::GOLD,
        // The three world-map categories. They can appear on the minimap too — a shop two
        // streets away is worth seeing — and each keeps its own colour there.
        MarkerKind::Merchant => status::EXPERIENCE,
        MarkerKind::Quest => status::STAMINA,
        MarkerKind::Dungeon => status::HUNGER,
    }
}

/// A marker's shape, expressed as the node that draws it.
///
/// Four shapes rather than four colours: a round dot for the player, a square for a party
/// member, a hollow ring for a hostile and a small hollow square for a landmark. Shape is
/// the signal that survives a colour-blind player and a bad monitor.
pub fn marker_node(kind: MarkerKind) -> impl Bundle {
    let colour = marker_ink(kind);
    let shape = marker_shape(kind);
    (
        Node {
            position_type: PositionType::Absolute,
            width: Val::Px(shape.size),
            height: Val::Px(shape.size),
            border: UiRect::all(Val::Px(shape.border)),
            border_radius: BorderRadius::all(Val::Px(shape.radius)),
            // Centred on its position rather than hanging off it to the south-east.
            margin: UiRect::axes(Val::Px(-shape.size / 2.0), Val::Px(-shape.size / 2.0)),
            ..default()
        },
        BackgroundColor(if shape.filled { colour } else { Color::NONE }),
        BorderColor::all(colour),
        Pickable::IGNORE,
        MinimapMarker(kind),
    )
}

/// Marks a drawn marker with the kind it stands for, so a test can count them and say
/// which is which.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct MinimapMarker(pub MarkerKind);

/// How a kind of marker is drawn.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MarkerShape {
    pub size: f32,
    pub radius: f32,
    pub filled: bool,
    pub border: f32,
}

/// Four shapes rather than four colours: a round dot for the player, a square for a party
/// member, a hollow ring for a hostile and a small hollow square for a landmark.
pub fn marker_shape(kind: MarkerKind) -> MarkerShape {
    match kind {
        MarkerKind::Player => {
            MarkerShape { size: MARKER, radius: MARKER / 2.0, filled: true, border: 0.0 }
        }
        MarkerKind::Party => MarkerShape { size: MARKER, radius: 0.0, filled: true, border: 0.0 },
        MarkerKind::Hostile => MarkerShape {
            size: MARKER + 2.0,
            radius: (MARKER + 2.0) / 2.0,
            filled: false,
            border: 2.0,
        },
        MarkerKind::Landmark => {
            MarkerShape { size: MARKER, radius: 0.0, filled: false, border: 1.0 }
        }
        // Every category is a different size as well as a different fill, so a screenshot
        // in grey still distinguishes them: a large hollow square, a small filled square
        // with a wide border, and a large filled round one.
        MarkerKind::Merchant => {
            MarkerShape { size: MARKER + 3.0, radius: 0.0, filled: false, border: 1.0 }
        }
        MarkerKind::Quest => {
            MarkerShape { size: MARKER - 2.0, radius: 0.0, filled: true, border: 2.0 }
        }
        MarkerKind::Dungeon => MarkerShape {
            size: MARKER + 3.0,
            radius: (MARKER + 3.0) / 2.0,
            filled: true,
            border: 0.0,
        },
    }
}

fn present_minimap(
    state: Res<UiState>,
    minimaps: Query<Entity, With<super::shell::Minimap>>,
    existing: Query<Entity, With<MinimapContent>>,
    mut commands: Commands,
    mut last: Local<Option<MinimapState>>,
) {
    let minimap: MinimapState = state.get().minimap.clone();
    // By value: the snapshot changes for reasons that are not the map's, and a minimap
    // rebuilt every frame is a minimap that cannot hold a tooltip.
    if last.as_ref() == Some(&minimap) {
        return;
    }
    // Every rebuild starts from nothing, which is also how state from the previous map is
    // prevented from leaking: there is no incremental path that could keep a marker whose
    // map has changed.
    *last = Some(minimap.clone());

    for entity in &existing {
        commands.entity(entity).despawn();
    }
    let Some(well) = minimaps.iter().next() else {
        return;
    };

    let unavailable = state_key(minimap.availability).map(|key| super::fallback_label(key));
    let markers: Vec<(Vec2, MarkerKind)> = if unavailable.is_some() {
        Vec::new()
    } else {
        minimap
            .visible_markers()
            .filter_map(|marker| marker_fraction(marker, &minimap).map(|at| (at, marker.kind)))
            .collect()
    };
    let coordinates = format!("{}:{},{}", minimap.map_number, minimap.centre.0, minimap.centre.1);

    commands.entity(well).with_children(|parent| {
        parent.spawn((
            MinimapContent,
            Node {
                position_type: PositionType::Absolute,
                left: Val::Px(0.0),
                top: Val::Px(0.0),
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                // Clipped, so no marker and no label can escape the well however wrong the
                // data is.
                overflow: Overflow::clip(),
                ..default()
            },
            Pickable::IGNORE,
            Children::spawn((
                // The state, when there is no map: a label rather than a black rectangle.
                SpawnIter(
                    unavailable
                        .clone()
                        .map(|text| {
                            (
                                Node {
                                    position_type: PositionType::Absolute,
                                    left: Val::Px(space::SNUG),
                                    top: Val::Percent(45.0),
                                    max_width: Val::Percent(90.0),
                                    ..default()
                                },
                                Text::new(text),
                                TextFont { font_size: type_scale::MICRO, ..default() },
                                TextColor(ink::MUTED),
                                Pickable::IGNORE,
                            )
                        })
                        .into_iter(),
                ),
                // North, so the map has an orientation rather than an implied one.
                SpawnIter(
                    unavailable
                        .is_none()
                        .then(|| {
                            (
                                Node {
                                    position_type: PositionType::Absolute,
                                    top: Val::Px(space::HAIR),
                                    left: Val::Percent(50.0),
                                    margin: UiRect::left(Val::Px(-4.0)),
                                    ..default()
                                },
                                Text::new("N".to_string()),
                                TextFont { font_size: type_scale::MICRO, ..default() },
                                TextColor(ink::MUTED),
                                Pickable::IGNORE,
                            )
                        })
                        .into_iter(),
                ),
                SpawnIter(markers.into_iter().map(|(at, kind)| {
                    (
                        Node {
                            position_type: PositionType::Absolute,
                            left: Val::Percent(at.x * 100.0),
                            top: Val::Percent(at.y * 100.0),
                            ..default()
                        },
                        Pickable::IGNORE,
                        children![marker_node(kind)],
                    )
                })),
                // Where the player is, in words. A map without coordinates cannot be used
                // to tell anyone where you are, which is most of what a player uses one
                // for.
                Spawn((
                    Node {
                        position_type: PositionType::Absolute,
                        left: Val::Px(space::HAIR),
                        bottom: Val::Px(space::HAIR),
                        ..default()
                    },
                    Text::new(coordinates),
                    TextFont { font_size: type_scale::MICRO, ..default() },
                    TextColor(ink::MUTED),
                    Pickable::IGNORE,
                )),
            )),
        ));
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures::{self, Scenario};
    use ao_core::view::MapUnavailable;

    fn state(radius: i32, centre: (i32, i32), markers: Vec<MapMarker>) -> MinimapState {
        MinimapState {
            availability: MapAvailability::Ready,
            map_number: 1,
            centre,
            radius,
            markers,
        }
    }

    fn marker(x: i32, y: i32, kind: MarkerKind) -> MapMarker {
        MapMarker { x, y, kind }
    }

    #[test]
    fn the_player_at_the_centre_is_drawn_at_the_centre() {
        let minimap = state(10, (50, 50), vec![marker(50, 50, MarkerKind::Player)]);
        let at = marker_fraction(&minimap.markers[0], &minimap).expect("inside the view");
        assert_eq!(at, Vec2::splat(0.5));
    }

    #[test]
    fn north_is_up_and_east_is_right() {
        // Map y grows south and so does the screen, so this is the one place in the client
        // where there is deliberately no flip. Getting it wrong mirrors the map, which a
        // player only discovers by walking the wrong way.
        let minimap = state(
            10,
            (50, 50),
            vec![marker(50, 40, MarkerKind::Landmark), marker(60, 50, MarkerKind::Landmark)],
        );
        let north = marker_fraction(&minimap.markers[0], &minimap).expect("inside");
        let east = marker_fraction(&minimap.markers[1], &minimap).expect("inside");

        assert!(north.y < 0.5, "north is not up: {north:?}");
        assert_eq!(north.x, 0.5, "north drifted sideways: {north:?}");
        assert!(east.x > 0.5, "east is not right: {east:?}");
        assert_eq!(east.y, 0.5, "east drifted vertically: {east:?}");
    }

    #[test]
    fn a_marker_beyond_the_radius_is_not_drawn_at_the_edge() {
        // Clamping instead would pin every distant hostile to the border, which reads as a
        // crowd gathering at the edge of the map rather than as nothing being there.
        let minimap = state(5, (50, 50), vec![marker(80, 50, MarkerKind::Hostile)]);
        assert_eq!(marker_fraction(&minimap.markers[0], &minimap), None);
    }

    #[test]
    fn a_radius_of_zero_covers_one_tile_and_divides_by_nothing() {
        // The malformed fixture sends one. Dividing by it produced infinities, which laid
        // the marker out somewhere off the edge of the world.
        let minimap = state(0, (50, 50), vec![marker(50, 50, MarkerKind::Player)]);
        let at = marker_fraction(&minimap.markers[0], &minimap).expect("the centre tile");
        assert!(at.is_finite(), "a zero radius produced {at:?}");
        assert_eq!(at, Vec2::splat(0.5));

        let elsewhere = state(0, (50, 50), vec![marker(51, 50, MarkerKind::Party)]);
        assert_eq!(marker_fraction(&elsewhere.markers[0], &elsewhere), None);
    }

    #[test]
    fn every_marker_of_every_fixture_lands_inside_the_map() {
        // Including the malformed one, whose coordinates are deliberately absurd.
        for scenario in Scenario::ALL {
            let minimap = fixtures::snapshot(scenario).minimap;
            for marker in minimap.visible_markers() {
                if let Some(at) = marker_fraction(marker, &minimap) {
                    assert!(
                        at.x >= 0.0 && at.x <= 1.0 && at.y >= 0.0 && at.y <= 1.0,
                        "{scenario:?} places {marker:?} at {at:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn each_state_that_is_not_a_map_says_which_one_it_is() {
        // "Nothing yet" and "nothing here" send a player to different places, so they are
        // not allowed to collapse into one black rectangle.
        assert_eq!(state_key(MapAvailability::Ready), None);
        let mut seen: Vec<&str> = Vec::new();
        for availability in [
            MapAvailability::Idle,
            MapAvailability::Loading,
            MapAvailability::Unavailable(MapUnavailable::Disabled),
            MapAvailability::Unavailable(MapUnavailable::Offline),
            MapAvailability::Unavailable(MapUnavailable::Failed),
            MapAvailability::Unavailable(MapUnavailable::NoData),
        ] {
            let key = state_key(availability).expect("a state without a map has a word for it");
            assert!(!seen.contains(&key), "{availability:?} reuses {key}");
            let readable = super::super::fallback_label(key);
            assert!(!readable.contains('.'), "{availability:?} would show a key: {readable}");
            seen.push(key);
        }
    }

    #[test]
    fn every_marker_kind_is_a_different_shape_as_well_as_a_different_colour() {
        // Shape is the signal that survives a colour-blind player and a bad monitor, and
        // this phase forbids status carried by colour alone.
        let kinds = [
            MarkerKind::Player,
            MarkerKind::Party,
            MarkerKind::Hostile,
            MarkerKind::Landmark,
            MarkerKind::Merchant,
            MarkerKind::Quest,
            MarkerKind::Dungeon,
        ];
        let mut shapes: Vec<MarkerShape> = Vec::new();
        let mut colours: Vec<[u8; 4]> = Vec::new();
        for kind in kinds {
            let shape = marker_shape(kind);
            assert!(!shapes.contains(&shape), "{kind:?} is drawn the same shape as another");
            shapes.push(shape);

            let colour = marker_ink(kind).to_srgba().to_u8_array();
            assert!(!colours.contains(&colour), "{kind:?} reuses another kind's colour");
            colours.push(colour);
        }
    }

    #[test]
    fn the_minimap_draws_the_fixture_and_says_where_the_player_is() {
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }

        let well = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::Minimap>>()
            .iter(app.world())
            .next()
            .expect("the shell has a minimap");
        let children = testing::descendants(&app, well);
        let texts: Vec<String> = children
            .iter()
            .filter_map(|entity| app.world().get::<Text>(*entity).map(|text| text.0.clone()))
            .collect();

        assert!(
            texts.iter().any(|text| text.contains("50,50")),
            "the minimap does not say where the player is: {texts:?}"
        );
        assert!(texts.iter().any(|text| text == "N"), "the minimap has no orientation: {texts:?}");
        assert!(
            !texts.iter().any(|text| text.contains("unavailable")),
            "a ready minimap claims to be unavailable: {texts:?}"
        );

        let drawn = children
            .iter()
            .filter(|entity| app.world().get::<MinimapMarker>(**entity).is_some())
            .count();
        let expected = fixtures::snapshot(Scenario::Populated).minimap.visible_markers().count();
        assert_eq!(drawn, expected, "the minimap drew {drawn} markers for {expected}");
    }

    #[test]
    fn no_window_stretches_the_map_or_pushes_it_out_of_the_world() {
        // Including the compact rail and the smallest supported window. A minimap that
        // stretched would be lying about direction, which is the one thing it is for.
        use super::super::testing;

        for window in [
            Vec2::new(1280.0, 832.0),
            Vec2::new(2560.0, 1440.0),
            Vec2::new(1024.0, 768.0),
            // Narrow enough for the compact rail.
            Vec2::new(900.0, 700.0),
            Vec2::new(792.0, 638.0),
        ] {
            let mut app = testing::shell_app(window);
            for _ in 0..4 {
                app.update();
            }

            let well = app
                .world_mut()
                .query_filtered::<Entity, With<super::super::shell::Minimap>>()
                .iter(app.world())
                .next()
                .expect("the shell has a minimap");
            let rect = testing::solved_rect(&app, well).expect("laid out");
            let world = testing::settled(&app).world;

            assert!(
                (rect.width() - rect.height()).abs() <= 1.0,
                "the minimap is not square at {window:?}: {rect:?}"
            );
            assert!(
                rect.min.x >= world.min.x - 1.0
                    && rect.max.x <= world.max.x + 1.0
                    && rect.min.y >= world.min.y - 1.0
                    && rect.max.y <= world.max.y + 1.0,
                "the minimap at {rect:?} is outside the world at {world:?} for {window:?}"
            );

            // And every marker stayed inside it.
            for entity in testing::descendants(&app, well) {
                if app.world().get::<MinimapMarker>(entity).is_none() {
                    continue;
                }
                let marker = testing::solved_rect(&app, entity).expect("laid out");
                assert!(
                    marker.min.x >= rect.min.x - 1.0
                        && marker.max.x <= rect.max.x + 1.0
                        && marker.min.y >= rect.min.y - 1.0
                        && marker.max.y <= rect.max.y + 1.0,
                    "a marker at {marker:?} escaped the minimap at {rect:?} for {window:?}"
                );
            }
        }
    }

    #[test]
    fn an_unavailable_minimap_says_so_and_draws_no_markers() {
        // The state it replaced was an unexplained black rectangle, which is
        // indistinguishable from a rendering fault.
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }
        let mut offline = app.world().resource::<UiState>().get().clone();
        offline.minimap.availability = MapAvailability::Unavailable(MapUnavailable::Offline);
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), offline);
        for _ in 0..3 {
            app.update();
        }

        let well = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::Minimap>>()
            .iter(app.world())
            .next()
            .expect("the shell has a minimap");
        let children = testing::descendants(&app, well);
        let texts: Vec<String> = children
            .iter()
            .filter_map(|entity| app.world().get::<Text>(*entity).map(|text| text.0.clone()))
            .collect();

        assert!(
            texts.iter().any(|text| text.to_lowercase().contains("offline")),
            "an offline minimap does not say why: {texts:?}"
        );
        let drawn = children
            .iter()
            .filter(|entity| app.world().get::<MinimapMarker>(**entity).is_some())
            .count();
        assert_eq!(drawn, 0, "an unavailable minimap still drew markers");
    }

    #[test]
    fn a_map_change_does_not_leave_the_last_maps_markers_behind() {
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }
        let well = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::Minimap>>()
            .iter(app.world())
            .next()
            .expect("the shell has a minimap");
        let before = testing::descendants(&app, well).len();
        assert!(before > 1, "nothing was drawn to leak");

        let mut elsewhere = app.world().resource::<UiState>().get().clone();
        elsewhere.minimap.map_number = 34;
        elsewhere.minimap.centre = (12, 90);
        elsewhere.minimap.markers = vec![marker(12, 90, MarkerKind::Player)];
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), elsewhere);
        for _ in 0..3 {
            app.update();
        }

        let children = testing::descendants(&app, well);
        let texts: Vec<String> = children
            .iter()
            .filter_map(|entity| app.world().get::<Text>(*entity).map(|text| text.0.clone()))
            .collect();
        assert!(
            texts.iter().any(|text| text.contains("34:12,90")),
            "the minimap still names the map the player left: {texts:?}"
        );
        let drawn = children
            .iter()
            .filter(|entity| app.world().get::<MinimapMarker>(**entity).is_some())
            .count();
        assert_eq!(drawn, 1, "the new map kept the old map's markers: {drawn}");
    }
}
