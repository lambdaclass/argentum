//! Names, speech bubbles and combat text over the world.
//!
//! This is the part of the HUD that gets unreadable first. Argentum's screens are busy:
//! several characters on adjacent tiles, each with a name, some of them speaking, numbers
//! rising off every hit. Drawn naively that is a stack of overlapping text with the
//! important half underneath, so the placement rules here are deliberate and stated:
//!
//! - **Priority** is distance from the player. What is next to you matters more than what
//!   is across the street, and ties break on identity so the same crowd always resolves
//!   the same way — a label that flickers between two positions is worse than one that is
//!   missing.
//! - **Overlap** is resolved by dropping the lower-priority label rather than nudging it.
//!   A nudged label points at the wrong character, which is a lie about who said what.
//! - **Fade** is by distance, so the edge of the view reads as further away rather than as
//!   equally present.
//!
//! Text metrics are approximated for the overlap test. That is deliberate: the exact
//! width needs a laid-out font and the arbitration has to be decided *before* laying
//! anything out. The approximation is generous, so the rule errs towards dropping a label
//! rather than towards letting two collide.

use super::state::UiState;
use super::tokens::{ink, size, space, status, surface, type_scale};
use ao_core::view::{PresenceView, TargetKind};
use bevy::prelude::*;

/// Rough width of a character at the label font size.
///
/// Only for arbitration; nothing is positioned with it.
const CHAR_WIDTH: f32 = 5.5;

/// Height of one line of label text, including the gap the bubble leaves.
const LINE_HEIGHT: f32 = 12.0;

/// Distance, in tiles, within which a label is at full strength.
const NEAR_TILES: f32 = 6.0;

/// Distance beyond which a label is as faint as it gets.
const FAR_TILES: f32 = 14.0;

/// How faint the furthest label is drawn.
const FAR_ALPHA: f32 = 0.35;

/// What a presence is asking to have drawn over it.
#[derive(Debug, Clone, PartialEq)]
pub struct LabelRequest {
    pub id: i32,
    pub name: String,
    pub kind: TargetKind,
    pub tile: IVec2,
    pub bubble: Option<String>,
    pub combat: Option<i32>,
}

impl LabelRequest {
    /// The widest line this label will draw, in approximate pixels.
    fn width(&self) -> f32 {
        let longest = self
            .name
            .chars()
            .count()
            .max(self.bubble.as_ref().map(|text| text.chars().count()).unwrap_or(0))
            .max(self.combat.map(|amount| amount.to_string().chars().count()).unwrap_or(0));
        longest as f32 * CHAR_WIDTH + space::SNUG * 2.0
    }

    /// How many lines it occupies: the name, plus a bubble and a number if it has them.
    fn lines(&self) -> f32 {
        1.0 + self.bubble.is_some() as u8 as f32 + self.combat.is_some() as u8 as f32
    }
}

/// A label with a place on screen.
#[derive(Debug, Clone, PartialEq)]
pub struct PlacedLabel {
    pub request: LabelRequest,
    /// Where the label's own top-left goes, in the world region's coordinates.
    pub at: Vec2,
    pub alpha: f32,
}

/// How faint a label is, by how far away it is in tiles.
pub fn distance_alpha(tiles: f32) -> f32 {
    if tiles <= NEAR_TILES {
        return 1.0;
    }
    if tiles >= FAR_TILES {
        return FAR_ALPHA;
    }
    let across = (tiles - NEAR_TILES) / (FAR_TILES - NEAR_TILES);
    1.0 - across * (1.0 - FAR_ALPHA)
}

/// Chebyshev distance in tiles, which is how far away something *feels* on a grid.
fn tile_distance(a: IVec2, b: IVec2) -> f32 {
    (a.x - b.x).abs().max((a.y - b.y).abs()) as f32
}

/// Decide which labels are drawn and where.
///
/// `screen_of` maps a tile to a position in the world region's coordinates. Passed in
/// rather than computed here so this stays pure and the coordinate pipeline stays in one
/// place.
pub fn place(
    requests: &[LabelRequest],
    player_tile: IVec2,
    view: Rect,
    screen_of: impl Fn(IVec2) -> Vec2,
) -> Vec<PlacedLabel> {
    let mut ordered: Vec<&LabelRequest> = requests.iter().collect();
    // Nearest first, then by id: a crowd must resolve the same way every frame, or the
    // labels flicker between each other as the sort order wobbles.
    ordered.sort_by(|left, right| {
        let by_distance = tile_distance(left.tile, player_tile)
            .partial_cmp(&tile_distance(right.tile, player_tile))
            .unwrap_or(std::cmp::Ordering::Equal);
        by_distance.then(left.id.cmp(&right.id))
    });

    let mut placed: Vec<PlacedLabel> = Vec::new();
    let mut boxes: Vec<Rect> = Vec::new();
    for request in ordered {
        let anchor = screen_of(request.tile);
        let width = request.width();
        let height = request.lines() * LINE_HEIGHT;
        // Centred over the tile and lifted clear of the sprite's head.
        let top_left = Vec2::new(anchor.x - width / 2.0, anchor.y - height - LINE_HEIGHT);
        let area = Rect::from_corners(top_left, top_left + Vec2::new(width, height));

        // Outside the view is not drawn at all. The view is the world the player can see;
        // a label beyond it belongs to someone behind the rail.
        if area.max.x < view.min.x
            || area.min.x > view.max.x
            || area.max.y < view.min.y
            || area.min.y > view.max.y
        {
            continue;
        }

        // Overlapping a label that matters more is dropped, not moved.
        let collides = boxes.iter().any(|other| {
            area.min.x < other.max.x
                && area.max.x > other.min.x
                && area.min.y < other.max.y
                && area.max.y > other.min.y
        });
        if collides {
            continue;
        }

        boxes.push(area);
        placed.push(PlacedLabel {
            request: request.clone(),
            at: top_left,
            alpha: distance_alpha(tile_distance(request.tile, player_tile)),
        });
    }
    placed
}

/// What the interface asks to draw for each presence the snapshot reports.
pub fn requests(presences: &[PresenceView]) -> Vec<LabelRequest> {
    presences
        .iter()
        .filter(|presence| !presence.name.trim().is_empty())
        .map(|presence| LabelRequest {
            id: presence.id,
            name: presence.name.clone(),
            kind: presence.kind,
            tile: IVec2::new(presence.tile_x as i32, presence.tile_y as i32),
            bubble: presence
                .bubble
                .as_ref()
                .map(|text| text.trim().to_string())
                .filter(|text| !text.is_empty()),
            combat: presence.combat.filter(|amount| *amount != 0),
        })
        .collect()
}

/// The colour a name is drawn in, by what kind of thing it is.
fn name_ink(kind: TargetKind) -> Color {
    match kind {
        TargetKind::Player => ink::PRIMARY,
        TargetKind::Npc => status::THIRST,
        TargetKind::Hostile => status::DANGER,
        // Neither an object on the ground nor a bare tile is a character, and neither is
        // labelled prominently: they are what the world is made of, not who is in it.
        TargetKind::Item | TargetKind::Ground => ink::MUTED,
    }
}

/// A combat number as the player reads it: a sign and an amount.
pub fn combat_text(amount: i32) -> String {
    if amount < 0 {
        format!("-{}", amount.abs())
    } else {
        format!("+{amount}")
    }
}

/// Marks a label drawn over the world.
#[derive(Component)]
struct WorldLabel;

/// The node labels are spawned under, so they clip with the world.
#[derive(Component)]
pub struct LabelLayer;

pub struct LabelPlugin;

impl Plugin for LabelPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            present_labels
                .after(super::shell::spawn_shell)
                .before(super::controls::ControlSet::Present),
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn present_labels(
    state: Res<UiState>,
    geometry: Res<super::shell::AppliedGeometry>,
    domains: Res<super::scale::ScaleDomains>,
    cameras: Query<&Transform, With<super::shell::WorldCamera>>,
    player: Res<crate::world::LocalPlayer>,
    layers: Query<Entity, With<LabelLayer>>,
    existing: Query<Entity, With<WorldLabel>>,
    mut commands: Commands,
    mut last: Local<Option<(Vec<LabelRequest>, IVec2, Rect)>>,
) {
    let Some(shell) = geometry.0 else {
        return;
    };
    let view = super::layout::world_view(shell.world).rect;
    let player_tile = IVec2::new(player.x, player.y);
    let wanted = requests(&state.get().presences);

    // Rebuilt when what is being said changes or when the camera has moved a whole tile.
    // A label that respawned every frame would flicker and would cost a despawn per
    // presence per frame for a picture that had not changed.
    let signature = (wanted.clone(), player_tile, view);
    if last.as_ref() == Some(&signature) {
        return;
    }
    *last = Some(signature);

    for entity in &existing {
        commands.entity(entity).despawn();
    }
    let Some(layer) = layers.iter().next() else {
        return;
    };

    let camera_centre =
        cameras.iter().next().map(|transform| transform.translation.truncate()).unwrap_or_default();
    let origin = shell.world.min;
    let placed = place(&wanted, player_tile, view, |tile| {
        super::pointer::screen_of_world(
            super::pointer::tile_centre(tile),
            view,
            *domains,
            camera_centre,
        ) - origin
    });

    commands.entity(layer).with_children(|parent| {
        for label in placed {
            let mut name = name_ink(label.request.kind);
            name.set_alpha(label.alpha);
            let mut speech = ink::PRIMARY;
            speech.set_alpha(label.alpha);
            let combat = label.request.combat;

            parent.spawn((
                WorldLabel,
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(label.at.x),
                    top: Val::Px(label.at.y),
                    flex_direction: FlexDirection::Column,
                    align_items: AlignItems::Center,
                    row_gap: Val::Px(space::HAIR),
                    ..default()
                },
                // Labels are not controls: a click goes to the world under them, or a
                // crowded street would be unclickable.
                Pickable::IGNORE,
                Children::spawn((
                    SpawnIter(
                        combat
                            .map(|amount| {
                                let mut colour =
                                    if amount < 0 { status::DANGER } else { status::EXPERIENCE };
                                colour.set_alpha(label.alpha);
                                (
                                    Text::new(combat_text(amount)),
                                    TextFont { font_size: type_scale::SMALL, ..default() },
                                    TextColor(colour),
                                    Pickable::IGNORE,
                                )
                            })
                            .into_iter(),
                    ),
                    SpawnIter(
                        label
                            .request
                            .bubble
                            .clone()
                            .map(|text| {
                                (
                                    Node {
                                        max_width: Val::Px(160.0),
                                        padding: UiRect::axes(
                                            Val::Px(space::SNUG),
                                            Val::Px(space::HAIR),
                                        ),
                                        border: UiRect::all(Val::Px(size::BORDER)),
                                        ..default()
                                    },
                                    BackgroundColor(surface::PANEL.with_alpha(label.alpha)),
                                    BorderColor::all(surface::EDGE.with_alpha(label.alpha)),
                                    Pickable::IGNORE,
                                    children![(
                                        Text::new(text),
                                        TextFont {
                                            font_size: type_scale::MICRO,
                                            ..default()
                                        },
                                        TextColor(speech),
                                        Pickable::IGNORE,
                                    )],
                                )
                            })
                            .into_iter(),
                    ),
                    Spawn((
                        Text::new(label.request.name.clone()),
                        TextFont { font_size: type_scale::MICRO, ..default() },
                        TextColor(name),
                        Pickable::IGNORE,
                    )),
                )),
            ));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures::{self, Scenario};

    fn request(id: i32, tile: (i32, i32), name: &str) -> LabelRequest {
        LabelRequest {
            id,
            name: name.to_string(),
            kind: TargetKind::Player,
            tile: IVec2::new(tile.0, tile.1),
            bubble: None,
            combat: None,
        }
    }

    /// A view big enough that nothing is culled, and a mapping of ten pixels per tile.
    fn scene() -> (Rect, impl Fn(IVec2) -> Vec2) {
        let view = Rect::from_corners(Vec2::ZERO, Vec2::new(1000.0, 1000.0));
        (view, |tile: IVec2| Vec2::new(tile.x as f32 * 10.0, tile.y as f32 * 10.0))
    }

    #[test]
    fn the_crowd_is_drawn_over_the_world_and_stays_inside_it() {
        // The wiring, which the pure tests above cannot reach: the placement is computed
        // from the shell's own geometry and the camera the world actually uses, and a
        // label that escaped the world region would sit over the rail.
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }

        let layer = app
            .world_mut()
            .query_filtered::<Entity, With<LabelLayer>>()
            .iter(app.world())
            .next()
            .expect("the shell has a label layer");
        let children = testing::descendants(&app, layer);
        let texts: Vec<String> = children
            .iter()
            .filter_map(|entity| app.world().get::<Text>(*entity).map(|text| text.0.clone()))
            .collect();

        assert!(
            texts.iter().any(|text| text == "Borzug"),
            "nobody in the crowd is named on screen: {texts:?}"
        );
        assert!(
            texts.iter().any(|text| text.contains("lobo")),
            "nobody's speech reached the world: {texts:?}"
        );
        assert!(
            texts.iter().any(|text| text.starts_with('-')),
            "no combat number was drawn: {texts:?}"
        );

        let world = testing::settled(&app).world;
        let mut drawn = 0;
        for entity in children {
            let Some(rect) = testing::solved_rect(&app, entity) else {
                continue;
            };
            if rect.width() <= 0.0 || rect.height() <= 0.0 {
                continue;
            }
            drawn += 1;
            assert!(
                rect.min.x >= world.min.x - 1.0 && rect.max.x <= world.max.x + 1.0,
                "a label at {rect:?} is outside the world at {world:?}"
            );
        }
        assert!(drawn > 3, "almost nothing was drawn to check: {drawn}");
    }

    #[test]
    fn the_nearer_label_survives_a_collision() {
        // Two names on top of each other. The one next to the player is the one they need.
        let (view, screen_of) = scene();
        let near = request(1, (50, 50), "Borzug");
        let far = request(2, (50, 51), "Nithal");
        let player = IVec2::new(50, 50);

        let placed = place(&[far.clone(), near.clone()], player, view, &screen_of);

        assert_eq!(placed.len(), 1, "both labels were drawn on top of each other");
        assert_eq!(placed[0].request.id, near.id, "the distant label won the collision");
    }

    #[test]
    fn the_same_crowd_resolves_the_same_way_every_time() {
        // Deterministic, because a label that flickers between two positions as the sort
        // order wobbles is worse than one that is simply missing.
        let (view, screen_of) = scene();
        let crowd: Vec<LabelRequest> = (0..8)
            .map(|index| request(index, (50 + index % 2, 50 + index / 2), "Someone"))
            .collect();
        let player = IVec2::new(50, 50);

        let first = place(&crowd, player, view, &screen_of);
        let mut shuffled = crowd.clone();
        shuffled.reverse();
        let second = place(&shuffled, player, view, &screen_of);

        assert_eq!(first, second, "the same crowd placed differently depending on input order");
    }

    #[test]
    fn a_label_outside_the_view_is_not_drawn() {
        let (view, _) = scene();
        let far_away = request(1, (500, 500), "Somebody");
        let placed = place(&[far_away], IVec2::new(50, 50), view, |tile| {
            // A mapping that puts this presence well off the right of the view.
            Vec2::new(tile.x as f32 * 10.0, tile.y as f32 * 10.0)
        });
        assert!(placed.is_empty(), "a label off the edge of the world was drawn anyway");
    }

    #[test]
    fn distance_fades_but_never_disappears() {
        assert_eq!(distance_alpha(0.0), 1.0);
        assert_eq!(distance_alpha(NEAR_TILES), 1.0);
        assert_eq!(distance_alpha(FAR_TILES), FAR_ALPHA);
        assert_eq!(distance_alpha(FAR_TILES + 40.0), FAR_ALPHA);
        let middle = distance_alpha((NEAR_TILES + FAR_TILES) / 2.0);
        assert!(middle < 1.0 && middle > FAR_ALPHA, "the ramp is not a ramp: {middle}");
    }

    #[test]
    fn a_label_is_lifted_clear_of_the_thing_it_names() {
        // Drawn *at* the tile it would cover the sprite's head, which is the one part of a
        // character a player uses to tell them apart.
        let (view, screen_of) = scene();
        let placed = place(&[request(1, (50, 50), "Borzug")], IVec2::new(50, 50), view, &screen_of);
        let anchor = screen_of(IVec2::new(50, 50));
        assert!(
            placed[0].at.y < anchor.y,
            "the label is not above its tile: {} against {}",
            placed[0].at.y,
            anchor.y
        );
    }

    #[test]
    fn a_bubble_and_a_number_make_the_label_taller_and_still_fit_above_the_tile() {
        let (view, screen_of) = scene();
        let mut talking = request(1, (50, 50), "Borzug");
        talking.bubble = Some("cuidado".to_string());
        talking.combat = Some(-12);

        let placed = place(&[talking], IVec2::new(50, 50), view, &screen_of);
        let plain = place(&[request(1, (50, 50), "Borzug")], IVec2::new(50, 50), view, &screen_of);

        assert!(
            placed[0].at.y < plain[0].at.y,
            "a bubble and a number did not make room for themselves"
        );
    }

    #[test]
    fn a_number_is_drawn_with_its_sign() {
        assert_eq!(combat_text(-34), "-34");
        assert_eq!(combat_text(18), "+18");
    }

    #[test]
    fn a_presence_with_no_name_asks_for_nothing_and_a_zero_hit_is_not_a_number() {
        let mut nameless = fixtures::snapshot(Scenario::Populated).presences;
        nameless.push(PresenceView {
            id: 99,
            name: "   ".to_string(),
            kind: TargetKind::Npc,
            tile_x: 50,
            tile_y: 50,
            bubble: Some("  ".to_string()),
            combat: Some(0),
        });

        let asked = requests(&nameless);
        assert!(
            !asked.iter().any(|request| request.id == 99),
            "a nameless presence asked for a label"
        );
        assert!(
            asked.iter().all(|request| request.combat != Some(0)),
            "a hit for no damage was drawn as a number"
        );
    }

    #[test]
    fn the_populated_fixture_puts_a_crowd_on_the_map() {
        // The task asks for the HUD to be judged under real density rather than on an
        // empty map, and that is a property of the fixture.
        let snapshot = fixtures::snapshot(Scenario::Populated);
        let asked = requests(&snapshot.presences);
        assert!(asked.len() >= 4, "the fixture is too empty to judge a HUD: {}", asked.len());
        assert!(
            asked.iter().any(|request| request.bubble.is_some()),
            "nobody in the fixture is speaking"
        );
        assert!(
            asked.iter().any(|request| request.combat.is_some()),
            "nothing in the fixture is taking a hit"
        );
        assert!(
            asked.iter().any(|request| request.kind == TargetKind::Hostile),
            "the fixture has nothing hostile in it"
        );
    }
}
