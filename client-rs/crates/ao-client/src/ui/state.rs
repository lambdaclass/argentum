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
}

impl UiState {
    pub fn get(&self) -> &UiSnapshot {
        &self.snapshot
    }

    /// Replace the snapshot. The only way it changes.
    ///
    /// Bevy's change detection fires on any call, including one that writes an
    /// identical value. Filtering here rather than at each reader means a
    /// future live adapter polling at 20Hz does not rebuild the whole rail 20
    /// times a second for nothing.
    ///
    /// The comparison is on the formatted value, not `PartialEq`: a snapshot
    /// carrying a NaN — which malformed server data can produce — is never
    /// equal to itself and would defeat the filter entirely.
    pub fn set(&mut self, snapshot: UiSnapshot) {
        if format!("{:?}", snapshot) == format!("{:?}", self.snapshot) {
            return;
        }
        self.snapshot = snapshot;
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

pub struct UiStatePlugin;

impl Plugin for UiStatePlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<UiState>()
            .init_resource::<ActiveScenario>()
            .add_message::<IntentMessage>()
            .add_systems(Startup, apply_scenario)
            .add_systems(Update, (apply_scenario.run_if(scenario_changed), refuse_dead_intents));
    }
}

fn scenario_changed(scenario: Res<ActiveScenario>) -> bool {
    scenario.is_changed()
}

fn apply_scenario(scenario: Res<ActiveScenario>, mut state: ResMut<UiState>) {
    state.set(fixtures::snapshot(scenario.0));
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

    #[test]
    fn writing_an_identical_snapshot_does_not_report_a_change() {
        // A live adapter polling at 20Hz would otherwise rebuild the whole rail
        // twenty times a second for nothing.
        let mut state = UiState::default();
        state.set(fixtures::snapshot(Scenario::Populated));
        let before = format!("{:?}", state.get());

        state.set(fixtures::snapshot(Scenario::Populated));
        assert_eq!(format!("{:?}", state.get()), before);
    }

    #[test]
    fn a_malformed_snapshot_still_settles_rather_than_changing_forever() {
        // It carries a NaN, so `PartialEq` reports it as different from
        // itself. Comparing the formatted value is what stops the filter from
        // being defeated by exactly the data it most needs to handle.
        let mut state = UiState::default();
        state.set(fixtures::snapshot(Scenario::Malformed));
        let first = format!("{:?}", state.get());

        state.set(fixtures::snapshot(Scenario::Malformed));
        assert_eq!(format!("{:?}", state.get()), first);
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
