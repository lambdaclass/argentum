//! The selected target, and the notices the server sends about what just happened.
//!
//! Both live over the world rather than in the rail, because both are about the moment
//! rather than about the character: a player deciding whether to attack is looking at the
//! thing they are attacking, and a refusal that appears in a panel they are not watching
//! has not been delivered.
//!
//! Everything here is presentation of what the snapshot already says. The client does not
//! decide who is targetable, what a target's health is, or whether an action was allowed —
//! it decides what to *stop* showing when the answer can no longer be true, which is a
//! different and much smaller claim.

use super::state::UiState;
use super::tokens::{ink, size, space, status, surface, type_scale};
use ao_core::view::{ConnectionPhase, Feedback, FeedbackKey, TargetKind, TargetState, UiSnapshot};
use bevy::prelude::*;

/// Content of the target strip, rebuilt when the target changes.
#[derive(Component)]
struct TargetContent;

/// Content of the notice stack.
#[derive(Component)]
struct NoticeContent;

pub struct TargetPanelPlugin;

impl Plugin for TargetPanelPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            (present_target, present_notices)
                .after(super::shell::spawn_shell)
                // So a target or a notice spawned this frame is painted this frame.
                .before(super::controls::ControlSet::Present),
        );
    }
}

/// Whether the target the snapshot names can still be true.
///
/// The server owns targeting, and the honest client rule is narrow: there are states in
/// which a target it was told about certainly no longer applies, and showing one then is
/// worse than showing none. A dead player has no target; a disconnected client knows
/// nothing current; a client mid-load is between worlds, so a target from the last one is
/// a target on a map the player is no longer standing on.
pub fn shows_target(snapshot: &UiSnapshot) -> bool {
    if snapshot.loading {
        return false;
    }
    if snapshot.vitals.is_dead() {
        return false;
    }
    if !matches!(snapshot.service.phase, ConnectionPhase::Playing) {
        return false;
    }
    matches!(snapshot.target, TargetState::Selected { .. })
}

/// What kind of thing the target is, in words.
///
/// Said out loud rather than left to a colour: "hostile" and "player" are the difference
/// between a fight and a crime, and the safety rules act on exactly that distinction.
pub fn kind_label(kind: TargetKind) -> &'static str {
    match kind {
        TargetKind::Player => "citizen",
        TargetKind::Npc => "npc",
        TargetKind::Hostile => "hostile",
        TargetKind::Item => "object",
    }
}

fn kind_ink(kind: TargetKind) -> Color {
    match kind {
        TargetKind::Player => ink::PRIMARY,
        TargetKind::Npc => status::THIRST,
        TargetKind::Hostile => status::DANGER,
        TargetKind::Item => ink::MUTED,
    }
}

fn present_target(
    state: Res<UiState>,
    strips: Query<Entity, With<super::shell::TargetStrip>>,
    existing: Query<Entity, With<TargetContent>>,
    mut commands: Commands,
    mut last: Local<Option<TargetState>>,
    mut shown_last: Local<bool>,
) {
    let snapshot = state.get();
    let shows = shows_target(snapshot);
    // By value, because the snapshot changes constantly for reasons that are not the
    // target's, and respawning this strip on each of them would make its own controls
    // unclickable.
    if last.as_ref() == Some(&snapshot.target) && *shown_last == shows {
        return;
    }
    *last = Some(snapshot.target.clone());
    *shown_last = shows;

    for entity in &existing {
        commands.entity(entity).despawn();
    }

    let TargetState::Selected { name, kind, health } = snapshot.target.clone() else {
        return;
    };
    if !shows {
        return;
    }

    let Some(strip) = strips.iter().next() else {
        return;
    };
    commands.entity(strip).with_children(|parent| {
        parent.spawn((
            TargetContent,
            Node {
                flex_direction: FlexDirection::Column,
                row_gap: Val::Px(space::HAIR),
                padding: UiRect::axes(Val::Px(space::SNUG), Val::Px(space::HAIR)),
                border: UiRect::all(Val::Px(size::BORDER)),
                align_items: AlignItems::Center,
                ..default()
            },
            BackgroundColor(surface::PANEL),
            BorderColor::all(kind_ink(kind)),
            Pickable::IGNORE,
            Children::spawn((
                Spawn((
                    Node {
                        flex_direction: FlexDirection::Row,
                        column_gap: Val::Px(space::SNUG),
                        align_items: AlignItems::Center,
                        ..default()
                    },
                    Pickable::IGNORE,
                    Children::spawn((
                        Spawn((
                            // The name the server disclosed. An unnamed target is drawn as
                            // its kind rather than as an empty strip: the malformed
                            // fixture sends one, and a blank panel over the world is
                            // indistinguishable from a rendering fault.
                            Text::new(if name.trim().is_empty() {
                                kind_label(kind).to_string()
                            } else {
                                name.clone()
                            }),
                            TextFont { font_size: type_scale::SMALL, ..default() },
                            TextColor(ink::PRIMARY),
                        )),
                        Spawn((
                            Text::new(kind_label(kind).to_string()),
                            TextFont { font_size: type_scale::MICRO, ..default() },
                            TextColor(kind_ink(kind)),
                        )),
                    )),
                )),
                // Health only when the server disclosed it. `None` is not full: a bar
                // drawn for an undisclosed value tells the player something the server
                // deliberately withheld.
                SpawnIter(
                    health
                        .filter(|gauge| gauge.max > 0)
                        .map(|gauge| {
                            (
                                Node {
                                    width: Val::Px(96.0),
                                    height: Val::Px(size::BORDER * 4.0),
                                    ..default()
                                },
                                BackgroundColor(surface::WELL),
                                Pickable::IGNORE,
                                children![(
                                    Node {
                                        width: Val::Percent(gauge.fraction() * 100.0),
                                        height: Val::Percent(100.0),
                                        ..default()
                                    },
                                    BackgroundColor(status::HEALTH),
                                    Pickable::IGNORE,
                                )],
                            )
                        })
                        .into_iter(),
                ),
            )),
        ));
    });
}

/// What a notice says, as a key the catalogue will translate.
///
/// Keys rather than sentences, and one per outcome the player has to tell apart: "too
/// soon" and "you are silenced" lead to completely different next actions, and a client
/// that collapses them into "cannot do that" has thrown away the useful half.
pub fn notice_key(feedback: &Feedback) -> String {
    match feedback.key {
        FeedbackKey::NotEnoughMana => "notice.mana".into(),
        FeedbackKey::NotEnoughStamina => "notice.stamina".into(),
        FeedbackKey::NotEnoughGold => "notice.gold".into(),
        FeedbackKey::InventoryFull => "notice.inventory-full".into(),
        FeedbackKey::TooFarAway => "notice.too-far".into(),
        FeedbackKey::TargetInvalid => "notice.target-invalid".into(),
        FeedbackKey::ActionTooSoon => "notice.too-soon".into(),
        FeedbackKey::Muted => "notice.muted".into(),
        FeedbackKey::Blocked => "notice.blocked".into(),
        FeedbackKey::Died => "notice.died".into(),
        FeedbackKey::LevelUp => "notice.level-up".into(),
        // Prose the protocol could not classify is shown as it arrived. It is the one
        // case where the wire's own words reach the screen, and it is deliberate: the
        // alternative is telling the player nothing at all.
        FeedbackKey::Untranslated => feedback.literal.clone().unwrap_or_default(),
    }
}

/// How loudly a notice is drawn.
pub fn notice_level(key: FeedbackKey) -> super::controls::NoticeLevel {
    use super::controls::NoticeLevel;
    match key {
        // Something good, and the only two of these that are not a refusal.
        FeedbackKey::LevelUp => NoticeLevel::Info,
        // Death is not a warning.
        FeedbackKey::Died => NoticeLevel::Danger,
        FeedbackKey::Untranslated => NoticeLevel::Info,
        _ => NoticeLevel::Warning,
    }
}

/// The notices to show, newest last.
///
/// Bounded, because a server having a bad minute must not paper over the world. The
/// newest are kept: an old refusal is history, and the player is acting on the last one.
pub fn notices(snapshot: &UiSnapshot) -> Vec<&Feedback> {
    const SHOWN: usize = 4;
    let all: Vec<&Feedback> = snapshot.feedback.iter().collect();
    if all.len() <= SHOWN {
        all
    } else {
        all[all.len() - SHOWN..].to_vec()
    }
}

fn present_notices(
    state: Res<UiState>,
    stacks: Query<Entity, With<super::shell::NoticeStack>>,
    existing: Query<Entity, With<NoticeContent>>,
    mut commands: Commands,
    mut last: Local<Option<Vec<Feedback>>>,
) {
    let snapshot = state.get();
    if last.as_deref() == Some(snapshot.feedback.as_slice()) {
        return;
    }
    *last = Some(snapshot.feedback.clone());

    for entity in &existing {
        commands.entity(entity).despawn();
    }

    let lines: Vec<(String, super::controls::NoticeLevel)> = notices(snapshot)
        .into_iter()
        .map(|feedback| {
            let key = notice_key(feedback);
            let text = if feedback.key == FeedbackKey::Untranslated {
                key
            } else {
                super::fallback_label(&key)
            };
            (text, notice_level(feedback.key))
        })
        .filter(|(text, _)| !text.trim().is_empty())
        .collect();
    if lines.is_empty() {
        return;
    }

    let Some(stack) = stacks.iter().next() else {
        return;
    };
    commands.entity(stack).with_children(|parent| {
        parent.spawn((
            NoticeContent,
            Node {
                flex_direction: FlexDirection::Column,
                row_gap: Val::Px(space::HAIR),
                align_items: AlignItems::FlexEnd,
                ..default()
            },
            Pickable::IGNORE,
            Children::spawn(SpawnIter(
                lines
                    .into_iter()
                    .map(|(text, level)| (super::controls::notification(&text, level), Pickable::IGNORE)),
            )),
        ));
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures::{self, Scenario};
    use ao_core::view::Gauge;

    fn selected(name: &str, kind: TargetKind, health: Option<Gauge>) -> TargetState {
        TargetState::Selected { name: name.to_string(), kind, health }
    }

    /// Every text in the shell, for asking what is on screen.
    fn on_screen(app: &mut App) -> String {
        app.world_mut()
            .query::<&Text>()
            .iter(app.world())
            .map(|text| text.0.clone())
            .collect::<Vec<_>>()
            .join(" | ")
    }

    #[test]
    fn the_target_strip_names_the_target_and_says_what_kind_it_is() {
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }

        let shown = on_screen(&mut app);
        assert!(shown.contains("Wolf"), "the target strip does not name the target: {shown}");
        assert!(
            shown.contains("hostile"),
            "the strip does not say what kind of thing the target is: {shown}"
        );
    }

    #[test]
    fn a_target_whose_health_the_server_withheld_gets_no_bar() {
        // `None` is not full health. Drawing a bar for an undisclosed value tells the
        // player something the server deliberately did not.
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }
        let strip = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::TargetStrip>>()
            .iter(app.world())
            .next()
            .expect("the shell has a target strip");
        let with_health = testing::descendants(&app, strip).len();

        let mut withheld = app.world().resource::<UiState>().get().clone();
        withheld.target = selected("Wolf", TargetKind::Hostile, None);
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), withheld);
        for _ in 0..3 {
            app.update();
        }

        let without = testing::descendants(&app, strip).len();
        assert!(
            without < with_health,
            "an undisclosed health still drew a bar: {without} nodes against {with_health}"
        );
        assert!(on_screen(&mut app).contains("Wolf"), "the target itself disappeared");
    }

    #[test]
    fn the_strip_is_empty_once_the_target_can_no_longer_be_true() {
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }
        let strip = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::TargetStrip>>()
            .iter(app.world())
            .next()
            .expect("the shell has a target strip");
        assert!(!testing::descendants(&app, strip).is_empty(), "nothing was drawn to clear");

        let mut dead = app.world().resource::<UiState>().get().clone();
        dead.vitals.health = Gauge::new(0, 220);
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), dead);
        for _ in 0..3 {
            app.update();
        }

        assert!(
            testing::descendants(&app, strip).is_empty(),
            "a dead player is still looking at a target: {}",
            on_screen(&mut app)
        );
    }

    #[test]
    fn a_refusal_appears_over_the_world_with_a_marker_of_its_own() {
        // Not colour alone: the notification carries a marker glyph as well, because this
        // phase forbids status a player cannot see without distinguishing two browns.
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        for _ in 0..4 {
            app.update();
        }
        let mut refused = app.world().resource::<UiState>().get().clone();
        refused.feedback = vec![Feedback::new(FeedbackKey::ActionTooSoon)];
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), refused);
        for _ in 0..3 {
            app.update();
        }

        let stack = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::NoticeStack>>()
            .iter(app.world())
            .next()
            .expect("the shell has a notice stack");
        let texts: Vec<String> = testing::descendants(&app, stack)
            .into_iter()
            .filter_map(|entity| app.world().get::<Text>(entity).map(|text| text.0.clone()))
            .collect();

        assert!(
            texts.iter().any(|text| text.to_lowercase().contains("soon")),
            "the refusal did not say what it was: {texts:?}"
        );
        assert!(
            texts.iter().any(|text| text == "!" || text == "!!" || text == "\u{00b7}"),
            "the notice carries no marker, only colour: {texts:?}"
        );
        assert!(
            !texts.iter().any(|text| text.starts_with("notice.")),
            "a semantic key reached the screen: {texts:?}"
        );
    }

    #[test]
    fn a_target_is_shown_while_the_player_is_alive_and_connected() {
        let mut snapshot = fixtures::snapshot(Scenario::Populated);
        snapshot.target = selected("Wolf", TargetKind::Hostile, Some(Gauge::new(30, 60)));
        assert!(shows_target(&snapshot), "a live connected player cannot see their target");
    }

    #[test]
    fn death_a_disconnect_and_a_map_load_each_stop_showing_a_stale_target() {
        // Three states in which the target the server last named certainly no longer
        // applies. Showing one then is worse than showing none: it invites an attack on
        // something that is not there.
        let base = {
            let mut snapshot = fixtures::snapshot(Scenario::Populated);
            snapshot.target = selected("Wolf", TargetKind::Hostile, Some(Gauge::new(30, 60)));
            snapshot
        };

        let mut dead = base.clone();
        dead.vitals.health = Gauge::new(0, 220);
        assert!(!shows_target(&dead), "a dead player still has a target");

        let mut gone = base.clone();
        gone.service.phase = ConnectionPhase::Reconnecting;
        assert!(!shows_target(&gone), "a disconnected client still shows its last target");

        let mut loading = base.clone();
        loading.loading = true;
        assert!(!shows_target(&loading), "a target survived a map change");
    }

    #[test]
    fn no_target_shows_nothing() {
        let mut snapshot = fixtures::snapshot(Scenario::Populated);
        snapshot.target = TargetState::None;
        assert!(!shows_target(&snapshot));
    }

    #[test]
    fn every_kind_is_named_and_no_two_share_a_word() {
        let kinds =
            [TargetKind::Player, TargetKind::Npc, TargetKind::Hostile, TargetKind::Item];
        let mut seen: Vec<&str> = Vec::new();
        for kind in kinds {
            let label = kind_label(kind);
            assert!(!label.is_empty(), "{kind:?} has no name");
            assert!(!seen.contains(&label), "{kind:?} reuses the word {label}");
            seen.push(label);
        }
    }

    #[test]
    fn every_feedback_key_says_something_a_player_can_read() {
        let keys = [
            FeedbackKey::NotEnoughMana,
            FeedbackKey::NotEnoughStamina,
            FeedbackKey::NotEnoughGold,
            FeedbackKey::InventoryFull,
            FeedbackKey::TooFarAway,
            FeedbackKey::TargetInvalid,
            FeedbackKey::ActionTooSoon,
            FeedbackKey::Muted,
            FeedbackKey::Blocked,
            FeedbackKey::Died,
            FeedbackKey::LevelUp,
        ];
        let mut seen: Vec<String> = Vec::new();
        for key in keys {
            let notice = notice_key(&Feedback::new(key));
            assert!(notice.starts_with("notice."), "{key:?} is not a notice key: {notice}");
            assert!(!seen.contains(&notice), "{key:?} reuses {notice}");
            let readable = super::super::fallback_label(&notice);
            assert!(!readable.contains('.'), "{key:?} would show a key: {readable}");
            seen.push(notice);
        }
    }

    #[test]
    fn unclassified_prose_is_shown_as_it_arrived() {
        // The one case where the wire's own words reach the screen. The alternative is
        // telling the player nothing, which is worse than telling them something odd.
        let feedback = Feedback::untranslated("el hechizo falla");
        assert_eq!(notice_key(&feedback), "el hechizo falla");
    }

    #[test]
    fn a_refusal_is_not_drawn_as_quietly_as_a_level_up() {
        use super::super::controls::NoticeLevel;
        assert_eq!(notice_level(FeedbackKey::LevelUp), NoticeLevel::Info);
        assert_eq!(notice_level(FeedbackKey::Died), NoticeLevel::Danger);
        assert_eq!(notice_level(FeedbackKey::ActionTooSoon), NoticeLevel::Warning);
        assert_eq!(notice_level(FeedbackKey::Muted), NoticeLevel::Warning);
    }

    #[test]
    fn the_notice_stack_is_bounded_to_the_newest() {
        let mut snapshot = fixtures::snapshot(Scenario::Populated);
        snapshot.feedback = (0..9).map(|_| Feedback::new(FeedbackKey::Blocked)).collect();
        snapshot.feedback.push(Feedback::new(FeedbackKey::LevelUp));

        let shown = notices(&snapshot);
        assert!(shown.len() <= 4, "a bad minute papered over the world: {}", shown.len());
        assert_eq!(
            shown.last().map(|feedback| feedback.key),
            Some(FeedbackKey::LevelUp),
            "the newest notice was dropped in favour of older ones"
        );
    }
}
