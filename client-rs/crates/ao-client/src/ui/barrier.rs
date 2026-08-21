//! The screen in front of the world until there is a world worth showing.
//!
//! `crate::reveal` decides *when*; this draws *what*, and covers everything until that
//! decision is made. It is Bevy-owned rather than a page element for the reason the page
//! element failed: `index.html` can only know that the wasm module started, so it lifted
//! two frames after `init()` and a player watched the world assemble behind it — a
//! placeholder grid, then sheets arriving one at a time, then item icons replacing their
//! own names. Anything that knows what a complete first frame requires has to live where
//! the loading does.
//!
//! Three properties this has to hold, each of which has a test:
//!
//! - **Opaque, and over everything.** Not a scrim: a scrim proves the world is behind it.
//!   The task's rule is that no world pixel appears before the first complete frame.
//! - **Modal.** It carries `controls::Modal`, the same marker the world map uses, so
//!   movement, casting and targeting are suppressed by the rule that already exists
//!   rather than by a second one written here.
//! - **Truthful.** The lines it shows come from the reveal set, so the screen cannot
//!   claim a stage the set has not reached. A failure replaces the bar instead of sitting
//!   next to it, because "90%" beside a dead load says "nearly there" about something
//!   that will never finish.

use bevy::prelude::*;

use super::tokens::{ink, size, space, surface, type_scale};
use crate::reveal::{barrier_for, Barrier, Failure, Member, Reveal, Stage, StageProgress};

pub struct BarrierPlugin;

impl Plugin for BarrierPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            // In the presentation set, like every other panel: it is drawn from the
            // reveal set after the frame's interactions have been consumed.
            (
                // Before the rebuild, like every other activation consumer: a retry that
                // ran after the barrier was rebuilt would act on an entity that no longer
                // exists.
                retry_on_activation.in_set(super::controls::ControlSet::Consume),
                present_barrier.in_set(super::controls::ControlSet::Present),
            ),
        );
    }
}

/// Marks the barrier's root, so it can be found and removed in one place.
#[derive(Component)]
pub struct BarrierRoot;

/// What the barrier last drew, so it is rebuilt when that changes and not every frame.
#[derive(Component, Debug, Clone, PartialEq)]
pub struct BarrierShown {
    fraction: f32,
    stages: Vec<(Stage, StageProgress)>,
    failure: Option<(Member, Failure)>,
}

fn present_barrier(
    reveal: Res<Reveal>,
    existing: Query<(Entity, &BarrierShown), With<BarrierRoot>>,
    mut commands: Commands,
) {
    let barrier = barrier_for(&reveal.0);

    let wanted = match &barrier {
        Barrier::Revealed => None,
        Barrier::Loading { fraction, stages } => {
            Some(BarrierShown { fraction: *fraction, stages: stages.clone(), failure: None })
        }
        Barrier::Failed { member, failure, .. } => Some(BarrierShown {
            fraction: 0.0,
            stages: Vec::new(),
            failure: Some((*member, failure.clone())),
        }),
    };

    let Some(wanted) = wanted else {
        // Revealed. The barrier goes away exactly once; there is nothing to rebuild
        // afterwards, and re-adding it would be a black frame in the middle of play.
        for (entity, _) in &existing {
            commands.entity(entity).despawn();
        }
        return;
    };

    match existing.single() {
        Ok((entity, shown)) if *shown == wanted => return,
        Ok((entity, _)) => commands.entity(entity).despawn(),
        Err(_) => {}
    }

    let may_retry = matches!(&barrier, Barrier::Failed { may_retry: true, .. });
    commands.spawn(barrier_root(wanted, may_retry));
}

fn barrier_root(shown: BarrierShown, may_retry: bool) -> impl Bundle {
    let failure = shown.failure.clone();
    let note = shown.failure.clone();
    let stages = shown.stages.clone();
    let fraction = shown.fraction;

    (
        BarrierRoot,
        shown,
        // The keyboard belongs to this while it is up, by the same marker a dialog uses:
        // one rule for "the world does not act", not a second one written here.
        super::controls::Modal,
        Node {
            position_type: PositionType::Absolute,
            left: Val::Px(0.0),
            top: Val::Px(0.0),
            width: Val::Percent(100.0),
            height: Val::Percent(100.0),
            flex_direction: FlexDirection::Column,
            align_items: AlignItems::Center,
            justify_content: JustifyContent::Center,
            row_gap: Val::Px(space::WIDE),
            ..default()
        },
        // Opaque, and above every panel. A scrim would prove the world is behind it,
        // which is the thing this task forbids.
        BackgroundColor(surface::VOID),
        GlobalZIndex(100),
        Children::spawn((
            Spawn((
                Text::new(super::fallback_label("reveal.title")),
                TextFont { font_size: type_scale::HEADING, ..default() },
                TextColor(ink::GOLD),
            )),
            // No stages and no bar when the load has failed. A bar frozen at 86% beside a
            // dead load says "nearly there" about something that will never finish, and a
            // bar at 0% says the opposite of what happened.
            SpawnIter(failure.is_none().then(|| stage_list(stages, fraction)).into_iter()),
            Spawn(failure_note(note, may_retry)),
            Spawn(retry_button(may_retry)),
        )),
    )
}

/// One line per stage, and a bar counted from completions.
fn stage_list(stages: Vec<(Stage, StageProgress)>, fraction: f32) -> impl Bundle {
    let rows: Vec<(Stage, StageProgress)> = stages;

    (
        Node {
            flex_direction: FlexDirection::Column,
            row_gap: Val::Px(space::TIGHT),
            min_width: Val::Px(260.0),
            ..default()
        },
        Children::spawn((
            SpawnIter(rows.into_iter().map(|(stage, progress)| {
                (
                    Node {
                        flex_direction: FlexDirection::Row,
                        justify_content: JustifyContent::SpaceBetween,
                        column_gap: Val::Px(space::WIDE),
                        ..default()
                    },
                    Children::spawn((
                        Spawn((
                            Text::new(super::fallback_label(stage.name_key())),
                            TextFont { font_size: type_scale::SMALL, ..default() },
                            TextColor(if progress.is_complete() {
                                ink::PRIMARY
                            } else {
                                ink::MUTED
                            }),
                        )),
                        Spawn((
                            // Counted, not guessed: the loader that this replaces treated
                            // dispatching a request as progress, so its bar reached the
                            // end before a single decode had finished.
                            Text::new(format!("{}/{}", progress.ready, progress.total)),
                            TextFont { font_size: type_scale::SMALL, ..default() },
                            TextColor(if progress.failed { ink::PRIMARY } else { ink::MUTED }),
                        )),
                    )),
                )
            })),
            Spawn((
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Px(size::BORDER * 3.0),
                    margin: UiRect::top(Val::Px(space::SNUG)),
                    ..default()
                },
                BackgroundColor(surface::WELL),
                children![(
                    Node {
                        width: Val::Percent((fraction * 100.0).clamp(0.0, 100.0)),
                        height: Val::Percent(100.0),
                        ..default()
                    },
                    BackgroundColor(ink::GOLD),
                    BarrierBar,
                )],
            )),
        )),
    )
}

/// Marks the progress bar's filled part, so a test can read how far it claims to be.
#[derive(Component)]
pub struct BarrierBar;

/// What went wrong, and whether trying again is honest.
fn failure_note(failure: Option<(Member, Failure)>, may_retry: bool) -> impl Bundle {
    (
        Node {
            flex_direction: FlexDirection::Column,
            align_items: AlignItems::Center,
            row_gap: Val::Px(space::SNUG),
            ..default()
        },
        Children::spawn(SpawnIter(failure.into_iter().flat_map(move |(member, failure)| {
            let mut parts: Vec<(Node, Text, TextFont, TextColor)> = Vec::new();

            // Which part, and what happened to it: a screen that says only "loading
            // failed" leaves a player with nothing to report and nothing to try.
            parts.push((
                Node::default(),
                Text::new(super::fallback_label(failure.explanation_key())),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::PRIMARY),
            ));
            parts.push((
                Node::default(),
                Text::new(super::fallback_label(member.name_key())),
                TextFont { font_size: type_scale::MICRO, ..default() },
                TextColor(ink::MUTED),
            ));
            parts
        }))),
    )
}

/// Marks the retry button, so activating it can be recognised.
#[derive(Component)]
pub struct BarrierRetry;

/// Try again, as a control rather than a word.
///
/// Reviewed and found: this said "retry" and did nothing, so the only way out of a failed
/// load was to reload the page. A screen that names an action it cannot perform is worse
/// than one that names none.
fn retry_button(may_retry: bool) -> impl Bundle {
    (
        Node { flex_direction: FlexDirection::Row, ..default() },
        Children::spawn(SpawnIter(
            may_retry
                .then(|| {
                    (
                        super::controls::button(
                            &super::fallback_label("reveal.retry"),
                            super::controls::ControlState::Normal,
                            0,
                        ),
                        super::controls::ControlKey::new("reveal.retry"),
                        BarrierRetry,
                    )
                })
                .into_iter(),
        )),
    )
}

/// Start a fresh load when the retry is activated.
///
/// A new generation, not a reset of this one: the work already dispatched cannot be
/// recalled, and its answers must not be able to complete the scene the player just asked
/// to be rebuilt. Reviewed and found missing — generations existed in the model and
/// nothing in production ever created a second one, so the isolation they provide was
/// theoretical.
fn retry_on_activation(
    mut activations: MessageReader<super::controls::Activated>,
    retries: Query<(), With<BarrierRetry>>,
    mut reveal: ResMut<Reveal>,
    mut reload: MessageWriter<crate::world::ReloadWorld>,
) {
    for activation in activations.read() {
        if retries.get(activation.entity).is_err() {
            continue;
        }

        let next = crate::reveal::Generation(reveal.0.generation().0 + 1);
        reveal.0 = crate::reveal::RevealSet::new(next, crate::reveal::REQUIRED);

        // And the work starts again. A new set on its own is a barrier that waits forever
        // for a fetch nobody re-issued — a worse failure than the one the player was
        // trying to escape, because it looks like progress.
        reload.write(crate::world::ReloadWorld);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reveal::{Generation, MemberState, RevealSet, REQUIRED};

    fn barrier_app() -> App {
        let mut app = App::new();
        app.add_plugins((MinimalPlugins, bevy::asset::AssetPlugin::default()))
            .init_asset::<Font>()
            .init_resource::<Reveal>()
            .add_systems(Update, present_barrier);
        app
    }

    fn roots(app: &mut App) -> usize {
        app.world_mut().query_filtered::<Entity, With<BarrierRoot>>().iter(app.world()).count()
    }

    fn ready_all(app: &mut App) {
        let mut reveal = app.world_mut().resource_mut::<Reveal>();
        let generation = reveal.0.generation();
        for member in REQUIRED {
            reveal.0.report(generation, member, MemberState::Ready);
        }
    }

    #[test]
    fn the_barrier_is_up_before_anything_has_loaded() {
        let mut app = barrier_app();
        app.update();

        assert_eq!(roots(&mut app), 1, "the world was exposed with nothing loaded");

        // Opaque and over everything: a scrim would prove the world is behind it.
        let (colour, z) = app
            .world_mut()
            .query_filtered::<(&BackgroundColor, &GlobalZIndex), With<BarrierRoot>>()
            .iter(app.world())
            .map(|(colour, z)| (colour.0, z.0))
            .next()
            .expect("a barrier");
        assert_eq!(colour.alpha(), 1.0, "the barrier is see-through");
        assert!(z >= 100, "the barrier is not above the panels: {z}");

        // And modal, so the world does not act behind it.
        let modals = app
            .world_mut()
            .query_filtered::<Entity, (With<BarrierRoot>, With<super::super::controls::Modal>)>()
            .iter(app.world())
            .count();
        assert_eq!(modals, 1, "the barrier does not own the keyboard");
    }

    #[test]
    fn the_barrier_stays_up_while_one_member_is_missing() {
        // The two-second texture from the contract, at the layer that draws.
        let mut app = barrier_app();
        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            for member in REQUIRED.iter().filter(|m| **m != Member::Sheets) {
                reveal.0.report(generation, *member, MemberState::Ready);
            }
        }
        app.update();

        assert_eq!(roots(&mut app), 1, "revealed with a sheet outstanding");

        // The bar says how far, and it is not the end.
        let width = app
            .world_mut()
            .query_filtered::<&Node, With<BarrierBar>>()
            .iter(app.world())
            .map(|node| node.width)
            .next()
            .expect("a bar");
        assert!(matches!(width, Val::Percent(p) if p > 50.0 && p < 100.0), "{width:?}");
    }

    #[test]
    fn the_barrier_goes_away_exactly_once_and_stays_away() {
        let mut app = barrier_app();
        app.update();
        assert_eq!(roots(&mut app), 1);

        ready_all(&mut app);
        // Ready is not revealed: something has to commit.
        app.update();
        assert_eq!(roots(&mut app), 1, "the barrier lifted before the scene was committed");

        assert!(app.world_mut().resource_mut::<Reveal>().0.commit());
        app.update();
        assert_eq!(roots(&mut app), 0, "the barrier stayed up after commit");

        // A later failure cannot bring it back: that would be a black frame mid-play.
        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            reveal.0.report(generation, Member::Sheets, MemberState::Failed(Failure::TimedOut));
        }
        app.update();
        assert_eq!(roots(&mut app), 0, "a committed scene was covered again");
    }

    #[test]
    fn a_failure_replaces_the_bar_rather_than_sitting_beside_it() {
        let mut app = barrier_app();
        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            for member in REQUIRED.iter().filter(|m| **m != Member::MapData) {
                reveal.0.report(generation, *member, MemberState::Ready);
            }
            reveal.0.report(
                generation,
                Member::MapData,
                MemberState::Failed(Failure::TooLarge { needed: 2, allowed: 1 }),
            );
        }
        app.update();

        assert_eq!(roots(&mut app), 1);
        let bars =
            app.world_mut().query_filtered::<Entity, With<BarrierBar>>().iter(app.world()).count();
        assert_eq!(bars, 0, "a bar at 86% was shown next to a load that will never finish");

        // And it says what happened, without offering a retry that cannot work.
        let text: Vec<String> =
            app.world_mut().query::<&Text>().iter(app.world()).map(|text| text.0.clone()).collect();
        assert!(
            text.iter().any(|line| line.to_lowercase().contains("large")),
            "the failure is not on screen: {text:?}"
        );
        assert!(
            !text.iter().any(|line| line.to_lowercase().contains("retry")
                || line.to_lowercase().contains("again")),
            "offered a retry for a device limit: {text:?}"
        );
    }

    #[test]
    fn the_retry_starts_a_fresh_load_rather_than_reusing_the_failed_one() {
        // Reviewed and found: "retry" was a word with nothing behind it, so a failed load
        // could only be escaped by reloading the page — and generations existed in the
        // model with nothing in production ever creating a second one, which made their
        // isolation theoretical.
        let mut app = App::new();
        app.add_plugins((MinimalPlugins, bevy::asset::AssetPlugin::default()))
            .init_asset::<Font>()
            .init_resource::<Reveal>()
            .add_message::<super::super::controls::Activated>()
            .add_message::<crate::world::ReloadWorld>()
            .add_systems(Update, (retry_on_activation, present_barrier).chain());

        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            reveal.0.report(
                generation,
                Member::MapData,
                MemberState::Failed(Failure::Unreachable("origin unreachable".into())),
            );
        }
        app.update();

        let before = app.world().resource::<Reveal>().0.generation();
        let button = app
            .world_mut()
            .query_filtered::<Entity, With<BarrierRetry>>()
            .iter(app.world())
            .next()
            .expect("a retry button, not a label");

        app.world_mut().write_message(super::super::controls::Activated {
            entity: button,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();

        let after = app.world().resource::<Reveal>().0.generation();
        assert!(after > before, "the retry did not start a new load: {before:?} -> {after:?}");

        // And it asked for the world again. A new set with no fetch behind it is a barrier
        // that waits forever, which looks like progress and is worse than the failure the
        // player was escaping.
        let reloads =
            app.world_mut().resource_mut::<Messages<crate::world::ReloadWorld>>().drain().count();
        assert_eq!(reloads, 1, "the retry did not re-issue the fetch");

        // A fresh candidate: nothing carried over from the failed one, and an answer from
        // it can no longer complete this scene.
        let mut reveal = app.world_mut().resource_mut::<Reveal>();
        assert!(reveal.0.failure().is_none(), "the new load inherited the old failure");
        assert!(
            !reveal.0.report(before, Member::MapData, MemberState::Ready),
            "an answer from the abandoned load was accepted"
        );
        assert!(matches!(barrier_for(&reveal.0), Barrier::Loading { .. }));
    }

    #[test]
    fn a_failure_that_cannot_be_retried_offers_no_button() {
        // A device limit will not change on a second attempt, and a button that cannot
        // work is worse than none.
        let mut app = barrier_app();
        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            reveal.0.report(
                generation,
                Member::Sheets,
                MemberState::Failed(Failure::TooLarge { needed: 2, allowed: 1 }),
            );
        }
        app.update();

        let buttons = app
            .world_mut()
            .query_filtered::<Entity, With<BarrierRetry>>()
            .iter(app.world())
            .count();
        assert_eq!(buttons, 0);
    }

    #[test]
    fn a_retryable_failure_offers_the_retry() {
        let mut app = barrier_app();
        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            reveal.0.report(
                generation,
                Member::MapData,
                MemberState::Failed(Failure::Unreachable("socket closed".into())),
            );
        }
        app.update();

        let text: Vec<String> =
            app.world_mut().query::<&Text>().iter(app.world()).map(|text| text.0.clone()).collect();
        assert!(
            text.iter().any(|line| line.to_lowercase().contains("retry")),
            "a retryable failure did not offer one: {text:?}"
        );
    }

    #[test]
    fn a_new_generation_puts_the_barrier_back_without_reusing_the_old_one() {
        // Retry, character switch, reconnect: a new candidate is a new generation, and it
        // starts behind a barrier again rather than editing the scene already shown.
        let mut app = barrier_app();
        ready_all(&mut app);
        assert!(app.world_mut().resource_mut::<Reveal>().0.commit());
        app.update();
        assert_eq!(roots(&mut app), 0);

        app.world_mut().resource_mut::<Reveal>().0 = RevealSet::new(Generation(2), REQUIRED);
        app.update();
        assert_eq!(roots(&mut app), 1, "a fresh load did not raise the barrier");
    }

    #[test]
    fn the_barrier_is_rebuilt_only_when_what_it_says_changes() {
        // It is drawn every frame from the set, so without this it despawns and respawns
        // sixty times a second — which flickers, loses focus and makes any pointer test
        // against it meaningless.
        let mut app = barrier_app();
        app.update();
        let first = app
            .world_mut()
            .query_filtered::<Entity, With<BarrierRoot>>()
            .iter(app.world())
            .next()
            .expect("a barrier");

        app.update();
        app.update();
        let same = app
            .world_mut()
            .query_filtered::<Entity, With<BarrierRoot>>()
            .iter(app.world())
            .next()
            .expect("a barrier");
        assert_eq!(first, same, "the barrier was rebuilt with nothing changed");

        {
            let mut reveal = app.world_mut().resource_mut::<Reveal>();
            let generation = reveal.0.generation();
            reveal.0.report(generation, Member::Font, MemberState::Ready);
        }
        app.update();
        let after = app
            .world_mut()
            .query_filtered::<Entity, With<BarrierRoot>>()
            .iter(app.world())
            .next()
            .expect("a barrier");
        assert_ne!(first, after, "progress changed and the screen did not");
    }
}
