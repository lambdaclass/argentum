//! A stand-in for the server, so the prototype is operable without claiming to be
//! live gameplay.
//!
//! The task this exists for is explicit about the order: the snapshot changes only
//! *after* an authority accepts an intent, and a rejection leaves the item where it
//! was and says why. That order is the whole point. An interface that decrements a
//! stack the moment the player clicks looks identical to one that works, right up
//! until the server refuses — and then it has to put something back, which is how
//! items appear to duplicate and vanish.
//!
//! So this consumes [`IntentMessage`] and produces the next snapshot, exactly as the
//! real adapter will. It is not gameplay: nothing here talks to a socket, and every
//! decision is a fixture's. When the real adapter lands it replaces this system and
//! nothing else changes, because the panels already read the snapshot and write
//! intents.

use bevy::prelude::*;

use super::state::{ActiveScenario, IntentMessage, IntentSet, UiState};
use ao_core::fixtures::Scenario;
use ao_core::view::{Feedback, FeedbackKey, Intent, SlotState, UiSnapshot};

/// The hotbar pages this stand-in remembers.
///
/// The snapshot carries one page at a time, because that is what a server sends. Which
/// slots the *other* pages hold is server state, so a stand-in that wants page changes
/// and assignment to persist has to keep it somewhere — here, explicitly, rather than by
/// inventing bindings when a page is asked for.
///
/// Seeded lazily from the first snapshot: page one is whatever the fixture carries, and
/// the rest start empty, which is truthful. A fixture with two pages of bindings would
/// be describing a character nobody set up.
#[derive(Resource, Debug, Clone, Default)]
pub struct HotbarPages {
    pages: Vec<Vec<ao_core::view::HotbarSlotState>>,
}

impl HotbarPages {
    fn seed(&mut self, hotbar: &ao_core::view::HotbarState) {
        if !self.pages.is_empty() {
            return;
        }
        let width = hotbar.slots.len().max(1);
        let count = hotbar.page_count.max(1);
        self.pages = (0..count)
            .map(|page| {
                if page == hotbar.page {
                    hotbar.slots.clone()
                } else {
                    vec![ao_core::view::HotbarSlotState::default(); width]
                }
            })
            .collect();
    }

    fn page_mut(&mut self, page: usize) -> Option<&mut Vec<ao_core::view::HotbarSlotState>> {
        self.pages.get_mut(page)
    }
}

pub struct SimulatedAuthorityPlugin;

impl Plugin for SimulatedAuthorityPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<HotbarPages>();
        // A consumer, in the same set as any other: intents reach it only after the
        // filter has had its say, so a ghost's forbidden action never gets applied.
        app.add_systems(Update, apply_accepted_intents.in_set(IntentSet::Consume));
    }
}

/// Whether the active scenario is one where the authority refuses.
///
/// Refusal is a property of the fixture rather than of the intent: the point is to
/// exercise the interface's behaviour when an action is declined, and the scenarios
/// named "rejected" and "disabled" are where that is being demonstrated.
fn refuses(scenario: Scenario) -> bool {
    matches!(scenario, Scenario::Rejected | Scenario::Disabled | Scenario::Disconnected)
}

fn apply_accepted_intents(
    mut intents: MessageReader<IntentMessage>,
    scenario: Res<ActiveScenario>,
    mut state: ResMut<UiState>,
    mut pages: ResMut<HotbarPages>,
) {
    pages.seed(&state.get().hotbar);

    for message in intents.read() {
        let mut next = state.get().clone();

        if refuses(scenario.0) {
            // The item stays exactly where it was. Only the feedback changes, and it
            // is a key rather than prose so it can be translated and so a test can
            // assert on it without matching a sentence.
            next.feedback = vec![Feedback::new(rejection_for(&message.0))];
            UiState::publish(&mut state, next);
            continue;
        }

        if apply(&mut next, &message.0, &mut pages) {
            UiState::publish(&mut state, next);
        }
    }
}

/// Why an action was refused, as a semantic key.
fn rejection_for(intent: &Intent) -> FeedbackKey {
    match intent {
        Intent::CastSpell { .. } => FeedbackKey::NotEnoughMana,
        Intent::UseInventorySlot { .. } | Intent::EquipInventorySlot { .. } => FeedbackKey::Blocked,
        _ => FeedbackKey::Blocked,
    }
}

/// Apply an accepted intent to a snapshot, returning whether anything changed.
///
/// Only the inventory actions are modelled. The rest are accepted silently: an
/// unmodelled intent that quietly reverted the snapshot would be indistinguishable
/// from a rejection, and this stand-in must not invent refusals the real server
/// would not send.
fn apply(snapshot: &mut UiSnapshot, intent: &Intent, pages: &mut HotbarPages) -> bool {
    match intent {
        Intent::UseInventorySlot { slot } => consume(snapshot, *slot, 1),
        Intent::DropInventorySlot { slot, amount } => consume(snapshot, *slot, (*amount).max(1)),
        Intent::EquipInventorySlot { slot } => equip(snapshot, *slot),
        Intent::MoveInventorySlot { from, to } => move_slot(snapshot, *from, *to),
        Intent::BindHotbarSlot { index, binding } => {
            bind_hotbar(snapshot, pages, *index, Some(*binding))
        }
        Intent::ClearHotbarSlot { index } => bind_hotbar(snapshot, pages, *index, None),
        Intent::ChangeHotbarPage { page } => change_page(snapshot, pages, *page),
        Intent::SendChat { channel, body } => say(snapshot, *channel, body),
        Intent::SetSafeMode(on) => {
            if snapshot.safety.safe_mode == *on {
                return false;
            }
            snapshot.safety.safe_mode = *on;
            true
        }
        Intent::SetPartySafe(on) => {
            if snapshot.safety.party_safe == *on {
                return false;
            }
            snapshot.safety.party_safe = *on;
            true
        }
        Intent::SetActiveChannel { channel } => {
            if snapshot.chat.active_channel == *channel {
                return false;
            }
            snapshot.chat.active_channel = *channel;
            true
        }
        _ => false,
    }
}

/// Put something in a hotbar slot, or take it out.
///
/// Written to the page the player is looking at, and kept there: a binding that
/// disappeared when the page changed would look like the server refusing an assignment
/// it had already accepted.
fn bind_hotbar(
    snapshot: &mut UiSnapshot,
    pages: &mut HotbarPages,
    index: usize,
    binding: Option<ao_core::view::HotbarBinding>,
) -> bool {
    let page = snapshot.hotbar.page;
    let Some(slots) = pages.page_mut(page) else {
        return false;
    };
    let Some(slot) = slots.get_mut(index) else {
        return false;
    };
    if slot.binding == binding {
        return false;
    }

    slot.binding = binding;
    // A slot that has just been rebound is not on the cooldown of whatever used to be
    // in it.
    slot.cooldown = 0.0;
    snapshot.hotbar.slots = slots.clone();
    true
}

/// Show a different page of the hotbar.
fn change_page(snapshot: &mut UiSnapshot, pages: &mut HotbarPages, page: usize) -> bool {
    if page == snapshot.hotbar.page {
        return false;
    }
    let Some(slots) = pages.page_mut(page) else {
        return false;
    };

    snapshot.hotbar.slots = slots.clone();
    snapshot.hotbar.page = page;
    true
}

/// Add the player's own line to the log.
///
/// A real server echoes what it accepted, and the player has to see their own words in
/// the same place as everyone else's — a composer that clears with nothing appearing
/// looks exactly like a message that was swallowed.
fn say(snapshot: &mut UiSnapshot, channel: ao_core::view::ChatChannel, body: &str) -> bool {
    if body.trim().is_empty() {
        return false;
    }
    let speaker = snapshot.progression.name.clone();
    snapshot.chat.lines.push(ao_core::view::ChatLine {
        channel,
        speaker,
        body: body.to_string(),
    });
    // Bounded, because this stand-in has no other pruning and a session's worth of lines
    // in a snapshot that is cloned on every intent is a leak with a long fuse.
    const KEPT: usize = 200;
    if snapshot.chat.lines.len() > KEPT {
        let excess = snapshot.chat.lines.len() - KEPT;
        snapshot.chat.lines.drain(0..excess);
    }
    true
}

/// Remove `amount` from a stack, emptying the slot when it runs out.
fn consume(snapshot: &mut UiSnapshot, index: usize, amount: i32) -> bool {
    let Some(SlotState::Filled(item)) = snapshot.inventory.slots.get_mut(index) else {
        return false;
    };
    // A worn item is not consumed by using it. Without this, double-clicking an
    // equipped staff would eat it.
    if item.equipped {
        return false;
    }

    item.quantity -= amount;
    if item.quantity <= 0 {
        snapshot.inventory.slots[index] = SlotState::Empty;
    }
    true
}

/// Exchange the contents of two inventory slots.
///
/// A swap rather than an overwrite, because the destination may hold something and
/// destroying it would be the one outcome the player can never undo. Dropping onto an
/// empty slot is the same operation with nothing coming back.
///
/// Refuses rather than reorders when either index is out of range or the destination
/// will not take a drop: an index arrives from a gesture, and a locked slot is locked.
fn move_slot(snapshot: &mut UiSnapshot, from: usize, to: usize) -> bool {
    if from == to {
        return false;
    }
    let slots = &mut snapshot.inventory.slots;
    if from >= slots.len() || to >= slots.len() {
        return false;
    }
    if !slots[from].accepts_drop() || !slots[to].accepts_drop() {
        return false;
    }
    slots.swap(from, to);
    true
}

/// Toggle whether the item in a slot is worn.
fn equip(snapshot: &mut UiSnapshot, index: usize) -> bool {
    let Some(SlotState::Filled(item)) = snapshot.inventory.slots.get_mut(index) else {
        return false;
    };
    item.equipped = !item.equipped;
    let worn = item.equipped;
    let item = item.clone();

    // The equipment summary is a second view of the same fact, so it has to move
    // with it — otherwise the rail shows a staff in hand that the inventory says is
    // stowed.
    if worn {
        snapshot.equipment.worn.retain(|(_, existing)| existing.item_id != item.item_id);
        if let Some(slot) = slot_for(&item) {
            snapshot.equipment.worn.retain(|(existing, _)| *existing != slot);
            snapshot.equipment.worn.push((slot, item));
        }
    } else {
        snapshot.equipment.worn.retain(|(_, existing)| existing.item_id != item.item_id);
    }
    true
}

/// Which equipment slot an item belongs in.
///
/// Guessed from the name key, because the view model does not carry it yet. A
/// stand-in inside a stand-in, and deliberately narrow: an item it cannot place is
/// left unplaced rather than put somewhere plausible, so the guess cannot be
/// mistaken for knowledge.
fn slot_for(item: &ao_core::view::ItemView) -> Option<ao_core::view::EquipSlot> {
    use ao_core::view::EquipSlot;
    let key = item.name_key.as_str();
    if key.contains("staff") || key.contains("sword") || key.contains("axe") {
        Some(EquipSlot::Weapon)
    } else if key.contains("robe") || key.contains("armour") || key.contains("armor") {
        Some(EquipSlot::Armour)
    } else if key.contains("helmet") {
        Some(EquipSlot::Helmet)
    } else if key.contains("shield") {
        Some(EquipSlot::Shield)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures;

    fn authority_app(scenario: Scenario) -> App {
        let mut app = App::new();
        app.add_plugins(super::super::state::UiStatePlugin).add_plugins(SimulatedAuthorityPlugin);
        *app.world_mut().resource_mut::<ActiveScenario>() = ActiveScenario(scenario);
        app.update();
        app
    }

    fn quantity(app: &App, index: usize) -> Option<i32> {
        match app.world().resource::<UiState>().get().inventory.slots.get(index) {
            Some(SlotState::Filled(item)) => Some(item.quantity),
            _ => None,
        }
    }

    fn send(app: &mut App, intent: Intent) {
        app.world_mut().write_message(IntentMessage(intent));
        app.update();
    }

    #[test]
    fn using_an_item_changes_the_snapshot_only_through_the_authority() {
        // The order the task insists on. An interface that decremented on click
        // would look identical until the server refused, and then it would have to
        // put something back.
        let mut app = authority_app(Scenario::Populated);
        let before = quantity(&app, 0).expect("a stack");

        send(&mut app, Intent::UseInventorySlot { slot: 0 });

        assert_eq!(
            quantity(&app, 0),
            Some(before - 1),
            "the authority accepted but the snapshot did not change"
        );
    }

    #[test]
    fn a_refused_action_leaves_the_item_exactly_where_it_was() {
        let mut app = authority_app(Scenario::Rejected);
        let before = quantity(&app, 0);

        send(&mut app, Intent::UseInventorySlot { slot: 0 });

        assert_eq!(quantity(&app, 0), before, "a refused action still consumed the item");
    }

    #[test]
    fn a_refusal_says_why_in_a_key_rather_than_a_sentence() {
        let mut app = authority_app(Scenario::Rejected);
        send(&mut app, Intent::UseInventorySlot { slot: 0 });

        let feedback = app.world().resource::<UiState>().get().feedback.clone();
        assert!(!feedback.is_empty(), "a refusal said nothing at all");
        assert!(
            feedback.iter().all(|entry| entry.key != FeedbackKey::Untranslated),
            "a refusal arrived as prose rather than a key: {feedback:?}"
        );
    }

    #[test]
    fn the_last_of_a_stack_empties_its_slot() {
        // Not a stack of zero, which would draw "0" in a slot that still looks full.
        let mut app = authority_app(Scenario::Populated);
        let mut remaining = quantity(&app, 0).expect("a stack");
        // Two at a time, so the loop is bounded well below the stack size.
        while remaining > 1 {
            send(&mut app, Intent::DropInventorySlot { slot: 0, amount: remaining - 1 });
            remaining = quantity(&app, 0).unwrap_or(0);
        }

        send(&mut app, Intent::UseInventorySlot { slot: 0 });
        assert_eq!(quantity(&app, 0), None, "the slot still holds an empty stack");
        assert!(matches!(
            app.world().resource::<UiState>().get().inventory.slots[0],
            SlotState::Empty
        ));
    }

    #[test]
    fn equipping_moves_the_equipment_summary_too() {
        // The rail shows the same fact twice. If they disagree, one of them is lying
        // about what is in the player's hand.
        let mut app = authority_app(Scenario::Populated);
        let staff = fixtures::snapshot(Scenario::Populated)
            .inventory
            .slots
            .iter()
            .position(|slot| slot.item().is_some_and(|item| item.name_key.contains("staff")))
            .expect("the fixture carries a staff");

        // It starts worn in this fixture, so the first toggle takes it off.
        send(&mut app, Intent::EquipInventorySlot { slot: staff });
        let worn_after_first = app
            .world()
            .resource::<UiState>()
            .get()
            .equipment
            .worn
            .iter()
            .any(|(_, item)| item.name_key.contains("staff"));

        send(&mut app, Intent::EquipInventorySlot { slot: staff });
        let worn_after_second = app
            .world()
            .resource::<UiState>()
            .get()
            .equipment
            .worn
            .iter()
            .any(|(_, item)| item.name_key.contains("staff"));

        assert_ne!(
            worn_after_first, worn_after_second,
            "equipping did not move the equipment summary"
        );
    }

    #[test]
    fn using_a_worn_item_does_not_eat_it() {
        let mut app = authority_app(Scenario::Populated);
        let staff = fixtures::snapshot(Scenario::Populated)
            .inventory
            .slots
            .iter()
            .position(|slot| slot.item().is_some_and(|item| item.equipped))
            .expect("the fixture wears something");
        let before = quantity(&app, staff);

        send(&mut app, Intent::UseInventorySlot { slot: staff });
        assert_eq!(quantity(&app, staff), before, "using a worn item consumed it");
    }

    #[test]
    fn dragging_an_item_onto_an_occupied_slot_swaps_rather_than_destroys() {
        // Overwriting is the one outcome the player cannot undo, so a drop onto
        // something exchanges the two.
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().inventory.slots.clone();
        let (from, to) = (0usize, 1usize);
        assert!(
            before[from].item().is_some() && before[to].item().is_some(),
            "this test needs two occupied slots"
        );

        send(&mut app, Intent::MoveInventorySlot { from, to });

        let after = app.world().resource::<UiState>().get().inventory.slots.clone();
        assert_eq!(after[to], before[from], "the dragged item did not arrive");
        assert_eq!(after[from], before[to], "the displaced item was destroyed");
    }

    #[test]
    fn dragging_an_item_onto_an_empty_slot_leaves_the_origin_empty() {
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().inventory.slots.clone();
        let from = before.iter().position(|slot| slot.item().is_some()).expect("an item");
        let to = before
            .iter()
            .position(|slot| matches!(slot, SlotState::Empty))
            .expect("an empty slot");

        send(&mut app, Intent::MoveInventorySlot { from, to });

        let after = app.world().resource::<UiState>().get().inventory.slots.clone();
        assert_eq!(after[to], before[from], "the item did not move");
        assert_eq!(after[from], SlotState::Empty, "the item was left behind as well");
    }

    #[test]
    fn a_move_to_a_slot_that_refuses_drops_changes_nothing() {
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().inventory.slots.clone();
        let locked = before
            .iter()
            .position(|slot| matches!(slot, SlotState::Locked))
            .expect("the fixture carries a locked slot");

        send(&mut app, Intent::MoveInventorySlot { from: 0, to: locked });

        assert_eq!(
            app.world().resource::<UiState>().get().inventory.slots,
            before,
            "a locked slot took a drop"
        );
    }

    #[test]
    fn an_out_of_range_move_is_refused_rather_than_panicking() {
        // The indices come from a gesture, and a stale rebuild can outlive a slot.
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().inventory.slots.clone();

        send(&mut app, Intent::MoveInventorySlot { from: 0, to: 9_999 });

        assert_eq!(app.world().resource::<UiState>().get().inventory.slots, before);
    }

    #[test]
    fn binding_a_hotbar_slot_survives_a_trip_to_another_page_and_back() {
        // The point of keeping the pages here: an assignment that vanished when the
        // player looked at page two would read as the server refusing something it had
        // already accepted.
        let mut app = authority_app(Scenario::Populated);
        let binding = ao_core::view::HotbarBinding::Spell { spell_id: 42, icon_grh: 2042 };

        send(&mut app, Intent::BindHotbarSlot { index: 5, binding });
        assert_eq!(
            app.world().resource::<UiState>().get().hotbar.slot(5).binding,
            Some(binding),
            "the binding was not applied"
        );

        send(&mut app, Intent::ChangeHotbarPage { page: 1 });
        assert_eq!(
            app.world().resource::<UiState>().get().hotbar.page,
            1,
            "the page did not change"
        );
        assert_eq!(
            app.world().resource::<UiState>().get().hotbar.slot(5).binding,
            None,
            "the second page shows the first page's bindings"
        );

        send(&mut app, Intent::ChangeHotbarPage { page: 0 });
        assert_eq!(
            app.world().resource::<UiState>().get().hotbar.slot(5).binding,
            Some(binding),
            "the binding did not survive a page change"
        );
    }

    #[test]
    fn binding_over_an_occupied_slot_replaces_what_was_there() {
        // Replacement, which the contract names alongside assignment: a bar where the
        // second binding silently does nothing is worse than one that cannot be edited.
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().hotbar.slot(0).binding;
        assert!(before.is_some(), "this test needs an occupied slot");
        let replacement = ao_core::view::HotbarBinding::Item { item_id: 461, icon_grh: 505 };

        send(&mut app, Intent::BindHotbarSlot { index: 0, binding: replacement });

        assert_eq!(
            app.world().resource::<UiState>().get().hotbar.slot(0).binding,
            Some(replacement),
            "binding over an occupied slot changed nothing"
        );
    }

    #[test]
    fn a_rebound_slot_does_not_inherit_the_cooldown_of_what_was_there() {
        let mut app = authority_app(Scenario::Populated);
        let mut cooling = app.world().resource::<UiState>().get().clone();
        cooling.hotbar.slots[0].cooldown = 0.8;
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), cooling);
        app.update();

        send(
            &mut app,
            Intent::BindHotbarSlot {
                index: 0,
                binding: ao_core::view::HotbarBinding::Spell { spell_id: 9, icon_grh: 2009 },
            },
        );

        assert_eq!(
            app.world().resource::<UiState>().get().hotbar.slot(0).cooldown_fraction(),
            0.0,
            "the new binding is waiting out the old one's cooldown"
        );
    }

    #[test]
    fn emptying_a_hotbar_slot_leaves_the_others_alone() {
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().hotbar.slot(1).binding;
        assert!(before.is_some(), "this test needs a bound neighbour");

        send(&mut app, Intent::ClearHotbarSlot { index: 0 });

        let hotbar = &app.world().resource::<UiState>().get().hotbar;
        assert_eq!(hotbar.slot(0).binding, None, "the slot was not emptied");
        assert_eq!(hotbar.slot(1).binding, before, "emptying one slot disturbed another");
    }

    #[test]
    fn a_page_that_does_not_exist_changes_nothing() {
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().hotbar.clone();

        send(&mut app, Intent::ChangeHotbarPage { page: 99 });

        assert_eq!(
            app.world().resource::<UiState>().get().hotbar,
            before,
            "a page beyond the end was accepted"
        );
    }

    #[test]
    fn an_unmodelled_intent_is_not_a_refusal() {
        // Reverting the snapshot for something this stand-in does not model would be
        // indistinguishable from the server saying no, and it must not invent
        // refusals the server would not send.
        let mut app = authority_app(Scenario::Populated);
        let before = app.world().resource::<UiState>().get().clone();

        send(&mut app, Intent::RequestReconnect);

        let after = app.world().resource::<UiState>().get();
        assert!(before.same_state_as(after), "an unmodelled intent changed the snapshot");
    }
}
