//! The interface's view of the world, and the way it asks for things.
//!
//! One resource in, one event out. Presentation systems read [`UiState`] and
//! write [`Intent`] events; nothing in `ui` may touch a socket, a packet or a
//! session. That is what lets the same screens run against a fixture in a test
//! and a live session in production without knowing which they have.
//!
//! The adapter that fills this from a real session arrives in Phase 3. Until
//! then it is filled from `ao_core::fixtures`, which is a deliberate choice
//! rather than a stub: the fixtures are built through the same constructors the
//! live adapter will use, so no widget can come to depend on a shape that only
//! exists in tests.

use ao_core::fixtures::{self, Scenario};
use ao_core::view::{Intent, UiSnapshot};
use bevy::prelude::*;

/// What the interface currently believes.
#[derive(Resource, Debug, Clone, Default)]
pub struct UiState {
    snapshot: UiSnapshot,
    /// How many snapshots have been published into this resource.
    ///
    /// Zero means the interface is showing its own default and nothing has told it
    /// anything. That distinction cannot be recovered from the contents: the first-scene
    /// barrier previously inferred it from "the clock is not midnight or there is chat",
    /// which blocks forever on a legitimate midnight snapshot with a quiet channel and
    /// passes on anything that happens to look populated. A count is the fact itself.
    revision: u64,
}

impl UiState {
    pub fn get(&self) -> &UiSnapshot {
        &self.snapshot
    }

    /// Whether anything has ever been published into this resource.
    pub fn has_snapshot(&self) -> bool {
        self.revision > 0
    }

    /// How many snapshots have been published. Monotonic.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Replace the snapshot. The only way it changes.
    ///
    /// Bevy's change detection fires on any call that takes `ResMut`, including
    /// one that writes an identical value. Filtering here rather than at each
    /// reader means a live adapter polling at 20Hz does not rebuild the whole
    /// rail twenty times a second for nothing.
    ///
    /// `same_state_as` rather than `PartialEq`, because a snapshot carrying a
    /// NaN — which malformed server data produces — is never equal to itself
    /// and would defeat the filter exactly when it matters most. It formerly
    /// compared `Debug` output, which worked but allocated two full renderings
    /// of the entire interface state on every poll.
    /// Test-only. Production writes go through [`UiState::publish`], which is
    /// the only path that avoids ticking change detection on a no-op — leaving
    /// this reachable is how a future adapter quietly reintroduces a rail that
    /// rebuilds twenty times a second.
    #[cfg(test)]
    pub fn set(&mut self, snapshot: UiSnapshot) {
        // The revision counts publications, not changes: a snapshot identical to the
        // default is still something the server said, and the barrier is waiting to be
        // told anything at all.
        self.revision += 1;
        if snapshot.same_state_as(&self.snapshot) {
            return;
        }
        self.snapshot = snapshot;
    }

    /// Write through a `ResMut`, ticking change detection only on a real change.
    ///
    /// Taking a `ResMut` at all marks the resource changed the moment it is
    /// dereferenced, whatever the write turns out to be — so guarding inside
    /// `set` stops the *value* changing but not the tick, and the rail rebuilds
    /// anyway. The write therefore bypasses detection and the tick is raised
    /// explicitly, which is the only way to make "nothing happened" cost
    /// nothing.
    pub fn publish(state: &mut ResMut<'_, UiState>, snapshot: UiSnapshot) {
        // Counted even when the value is unchanged, and without ticking detection for it:
        // "a snapshot arrived" and "the interface must be rebuilt" are different facts,
        // and the barrier needs the first one.
        state.bypass_change_detection().revision += 1;

        if snapshot.same_state_as(&state.bypass_change_detection().snapshot) {
            return;
        }
        state.bypass_change_detection().snapshot = snapshot;
        state.set_changed();
    }
}

/// Which fixture is driving the interface.
///
/// Cycled from the component gallery, and settable from the query string so a
/// screenshot run can ask for one state and get exactly it.
#[derive(Resource, Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActiveScenario(pub Scenario);

impl Default for ActiveScenario {
    fn default() -> Self {
        Self(Scenario::Populated)
    }
}

/// A player request, emitted by presentation and consumed by the session layer.
///
/// A buffered message rather than an observer event: intents are a queue the
/// session drains once a frame, not something that needs to run code the
/// instant a button is pressed.
#[derive(Message, Debug, Clone, PartialEq, Eq)]
pub struct IntentMessage(pub Intent);

/// System ordering label for the intent pipeline.
///
/// Filtering has to happen before anything consumes intents, or a ghost's
/// forbidden action reaches the session in the same frame it was refused. An
/// explicit set makes that orderable rather than accidental.
#[derive(SystemSet, Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IntentSet {
    /// Drops intents the player is not allowed to make.
    Filter,
    /// Anything that acts on what survives.
    Consume,
}

pub struct UiStatePlugin;

impl Plugin for UiStatePlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<UiState>()
            .init_resource::<ActiveScenario>()
            .add_message::<IntentMessage>()
            .configure_sets(Update, IntentSet::Filter.before(IntentSet::Consume))
            .add_systems(Startup, (adopt_configured_scenario, apply_scenario).chain())
            .add_systems(
                Update,
                (
                    apply_scenario.run_if(scenario_changed),
                    refuse_dead_intents.in_set(IntentSet::Filter),
                ),
            );
    }
}

fn scenario_changed(scenario: Res<ActiveScenario>) -> bool {
    scenario.is_changed()
}

/// Start in the fixture state the configuration asked for, if it named one.
///
/// Configuration rather than a hook a page can call: a capture harness has to photograph
/// an unavailable map and a dead ghost, and asking at boot keeps the running client's
/// state its own. An unknown name is ignored rather than fatal — a query string is not a
/// contract, and the populated fixture is a safe place to land.
fn adopt_configured_scenario(
    config: Option<Res<crate::config::ClientConfig>>,
    mut scenario: ResMut<ActiveScenario>,
) {
    let Some(named) = config.as_ref().and_then(|config| config.scenario.as_deref()) else {
        return;
    };
    if let Some(wanted) = Scenario::from_key(named) {
        *scenario = ActiveScenario(wanted);
    }
}

fn apply_scenario(scenario: Res<ActiveScenario>, mut state: ResMut<UiState>) {
    UiState::publish(&mut state, fixtures::snapshot(scenario.0));
}

/// Drop intents a ghost cannot act on.
///
/// Enforced centrally rather than at each control: a button added later cannot
/// forget the rule, and the session layer never has to re-derive whether the
/// player was alive when they clicked.
fn refuse_dead_intents(state: Res<UiState>, mut intents: ResMut<Messages<IntentMessage>>) {
    if !state.get().is_dead() {
        return;
    }

    let surviving: Vec<IntentMessage> =
        intents.drain().filter(|message| message.0.allowed_while_dead()).collect();
    intents.write_batch(surviving);
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::view::ChatChannel;

    fn app() -> App {
        let mut app = App::new();
        app.add_plugins(UiStatePlugin);
        app
    }

    #[test]
    fn the_interface_starts_from_a_fixture_rather_than_an_empty_snapshot() {
        // An empty default would let every screen be developed against a blank
        // state that production never produces.
        let mut app = app();
        app.update();

        let state = app.world().resource::<UiState>();
        assert!(!state.get().progression.name.is_empty());
        assert!(state.get().inventory.used_slots() > 0);
    }

    #[test]
    fn changing_the_scenario_replaces_the_snapshot() {
        let mut app = app();
        app.update();

        *app.world_mut().resource_mut::<ActiveScenario>() = ActiveScenario(Scenario::DeadGhost);
        app.update();

        assert!(app.world().resource::<UiState>().get().is_dead());
    }

    /// Counts how many frames a reader saw the state as changed.
    #[derive(Resource, Default)]
    struct Rebuilds(usize);

    /// Publish `scenarios` one per frame and count the rebuilds a reader sees.
    ///
    /// Counted from inside a system, because that is where it matters and
    /// because `is_changed()` read from outside compares against a tick that
    /// `update()` has already advanced — it answers a different question.
    fn rebuilds(scenarios: &[Scenario]) -> usize {
        let script: Vec<Scenario> = scenarios.to_vec();
        let mut app = App::new();
        app.init_resource::<UiState>().init_resource::<Rebuilds>();

        let mut frame = 0usize;
        app.add_systems(
            Update,
            (
                move |mut state: ResMut<UiState>| {
                    if let Some(scenario) = script.get(frame) {
                        UiState::publish(&mut state, fixtures::snapshot(*scenario));
                    }
                    frame += 1;
                },
                |state: Res<UiState>, mut count: ResMut<Rebuilds>| {
                    if state.is_changed() {
                        count.0 += 1;
                    }
                },
            )
                .chain(),
        );

        for _ in 0..scenarios.len() {
            app.update();
        }
        app.world().resource::<Rebuilds>().0
    }

    #[test]
    fn an_identical_snapshot_does_not_rebuild_the_interface() {
        // The contract's numbers exactly: the first snapshot rebuilds once and
        // twenty identical writes after it rebuild zero times. Twenty because a
        // live adapter polling at 20Hz publishes that many in a second, and a
        // rail that rebuilds twenty times a second is the failure being ruled
        // out — not a rail that rebuilds five times.
        for scenario in [Scenario::Populated, Scenario::Empty, Scenario::DeadGhost] {
            let mut script = vec![scenario];
            script.extend(std::iter::repeat_n(scenario, 20));
            let count = rebuilds(&script);
            assert_eq!(
                count,
                1,
                "{} rebuilt {count} times across one value written 21 times",
                scenario.key()
            );
        }
    }

    #[test]
    fn one_changed_field_rebuilds_exactly_once() {
        // The other half of the contract's numbers. `a_genuine_change_does_rebuild`
        // changes whole scenarios; this changes a single field, which is the case
        // a coarse comparison would miss and an over-eager one would double.
        let base = fixtures::snapshot(Scenario::Populated);
        let mut changed = base.clone();
        changed.vitals.health = ao_core::view::Gauge::new(1, 220);

        let script = vec![base.clone(), base.clone(), changed.clone(), changed.clone()];
        let mut app = App::new();
        app.init_resource::<UiState>().init_resource::<Rebuilds>();

        let mut frame = 0usize;
        app.add_systems(
            Update,
            (
                move |mut state: ResMut<UiState>| {
                    if let Some(snapshot) = script.get(frame) {
                        UiState::publish(&mut state, snapshot.clone());
                    }
                    frame += 1;
                },
                |state: Res<UiState>, mut count: ResMut<Rebuilds>| {
                    if state.is_changed() {
                        count.0 += 1;
                    }
                },
            )
                .chain(),
        );
        for _ in 0..4 {
            app.update();
        }

        assert_eq!(
            app.world().resource::<Rebuilds>().0,
            2,
            "one field changing should rebuild once, on top of the first value"
        );
    }

    #[test]
    fn a_malformed_snapshot_settles_rather_than_rebuilding_forever() {
        // It carries a NaN, so PartialEq reports it as different from itself.
        // Without the NaN-aware comparison this is an unbounded rebuild loop,
        // and it happens exactly when the client is already struggling.
        assert_eq!(rebuilds(&[Scenario::Malformed; 5]), 1);
    }

    #[test]
    fn a_genuine_change_does_rebuild() {
        // The filter must not be so eager that a real update is dropped.
        assert_eq!(
            rebuilds(&[
                Scenario::Populated,
                Scenario::Populated,
                Scenario::Empty,
                Scenario::Empty,
                Scenario::DeadGhost,
            ]),
            3
        );
    }

    #[test]
    fn intents_are_filtered_before_anything_consumes_them() {
        // Ordering, not luck. A consumer scheduled before the filter would act
        // on a ghost's forbidden intent in the frame it was supposedly refused.
        use std::sync::atomic::{AtomicUsize, Ordering};
        static SEEN: AtomicUsize = AtomicUsize::new(0);

        fn consume(mut intents: MessageReader<IntentMessage>) {
            SEEN.fetch_add(intents.read().count(), Ordering::SeqCst);
        }

        SEEN.store(0, Ordering::SeqCst);
        let mut app = App::new();
        app.add_plugins(UiStatePlugin).add_systems(Update, consume.in_set(IntentSet::Consume));
        *app.world_mut().resource_mut::<ActiveScenario>() = ActiveScenario(Scenario::DeadGhost);
        app.update();

        app.world_mut().write_message(IntentMessage(Intent::UseInventorySlot { slot: 0 }));
        app.update();

        assert_eq!(SEEN.load(Ordering::SeqCst), 0, "a consumer saw a refused intent");
    }

    #[test]
    fn a_ghost_cannot_emit_an_action_intent() {
        // Enforced centrally so a control added later cannot forget the rule.
        let mut app = app();
        *app.world_mut().resource_mut::<ActiveScenario>() = ActiveScenario(Scenario::DeadGhost);
        app.update();

        app.world_mut().write_message(IntentMessage(Intent::UseInventorySlot { slot: 0 }));
        app.update();

        let messages = app.world().resource::<Messages<IntentMessage>>();
        let mut cursor = messages.get_cursor();
        assert_eq!(cursor.read(messages).count(), 0, "a ghost used an item");
    }

    #[test]
    fn a_ghost_may_still_talk() {
        // Death restricts acting, not communicating. Filtering everything
        // would strand a dead player with no way to ask for a resurrection.
        let mut app = app();
        *app.world_mut().resource_mut::<ActiveScenario>() = ActiveScenario(Scenario::DeadGhost);
        app.update();

        app.world_mut().write_message(IntentMessage(Intent::SendChat {
            channel: ChatChannel::Say,
            body: "help".into(),
        }));
        app.update();

        let messages = app.world().resource::<Messages<IntentMessage>>();
        let mut cursor = messages.get_cursor();
        assert_eq!(cursor.read(messages).count(), 1, "a ghost was silenced");
    }

    #[test]
    fn a_living_player_keeps_every_intent() {
        let mut app = app();
        app.update();

        app.world_mut().write_message(IntentMessage(Intent::UseInventorySlot { slot: 0 }));
        app.update();

        let messages = app.world().resource::<Messages<IntentMessage>>();
        let mut cursor = messages.get_cursor();
        assert_eq!(cursor.read(messages).count(), 1);
    }
}
