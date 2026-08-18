//! The spellbook tab and the numbered hotbar.
//!
//! Every restriction shown here is presentation only. The server re-checks all
//! of them and its answer is final; a client that treats its own judgement as
//! authoritative desynchronises the moment a rule changes on one side. What the
//! client owes the player is an accurate *prediction* and, when it is wrong, a
//! rollback that does not look like a bug.

use super::state::{IntentMessage, UiState};
use super::tokens::{focus, ink, size, space, surface, type_scale};
use ao_core::view::{
    HotbarSlotState, Intent, SpellBlocker, SpellView, TargetMode, TargetState, UiSnapshot,
};
use bevy::prelude::*;

/// Slots on one hotbar page. Ten, keyed 1-9 then 0.
pub const SLOTS_PER_PAGE: usize = 10;

/// A spell chosen and waiting for a target.
///
/// Armed rather than cast immediately: an entity- or ground-targeted spell
/// needs a second click, and firing on the first one would cast at whatever
/// happened to be selected.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ArmedSpell(pub Option<i32>);

impl ArmedSpell {
    /// Disarm. Escape, a cast, a death and a disconnect all end here.
    pub fn clear(&mut self) {
        self.0 = None;
    }
}

pub struct SpellPanelPlugin;

impl Plugin for SpellPanelPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<ArmedSpell>()
            // Ownership of the keyboard is decided before these read it, so a
            // keystroke cannot be taken as a hotbar activation in the same frame
            // a text field gains focus.
            .init_resource::<super::controls::TextInputActive>()
            .add_systems(
                Update,
                (trigger_hotbar_keys, disarm_on_escape, disarm_when_unusable)
                    .chain()
                    .in_set(super::controls::GameplayInput),
            );
    }
}

/// What choosing a spell should do.
///
/// Split out because the interesting decision — cast now, or arm and wait for a
/// target — is invisible in a screenshot and easy to get backwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpellActivation {
    /// Cast immediately.
    Cast(i32),
    /// Wait for the player to pick a target.
    Arm(i32),
    /// Do nothing, and say why.
    Blocked(SpellBlocker),
}

/// Decide what activating `spell` means, given the current target.
pub fn activate_spell(spell: &SpellView, target: &TargetState) -> SpellActivation {
    if let Some(blocker) = spell.primary_blocker() {
        return SpellActivation::Blocked(blocker);
    }

    match spell.target_mode {
        // Self and area spells have nothing to point at.
        TargetMode::SelfCast | TargetMode::Area => SpellActivation::Cast(spell.spell_id),
        // A target already selected is good enough; re-arming would make the
        // player click the same enemy twice.
        TargetMode::Entity if matches!(target, TargetState::Selected { .. }) => {
            SpellActivation::Cast(spell.spell_id)
        }
        _ => SpellActivation::Arm(spell.spell_id),
    }
}

/// What pressing a hotbar key should do.
///
/// `None` covers an unbound slot and one still cooling down — neither is worth
/// a round trip, and a request the server refuses on cooldown is
/// indistinguishable from lag.
pub fn hotbar_intent(slot: HotbarSlotState, index: usize) -> Option<Intent> {
    if slot.binding.is_none() {
        return None;
    }
    if slot.cooldown_fraction() > 0.0 {
        return None;
    }
    Some(Intent::TriggerHotbarSlot { index })
}

/// The key that fires a slot: 1-9 then 0.
pub fn slot_key_code(index: usize) -> Option<KeyCode> {
    Some(match index {
        0 => KeyCode::Digit1,
        1 => KeyCode::Digit2,
        2 => KeyCode::Digit3,
        3 => KeyCode::Digit4,
        4 => KeyCode::Digit5,
        5 => KeyCode::Digit6,
        6 => KeyCode::Digit7,
        7 => KeyCode::Digit8,
        8 => KeyCode::Digit9,
        9 => KeyCode::Digit0,
        _ => return None,
    })
}

/// Fire hotbar slots from the number row.
///
/// Suppressed entirely while a text field owns the keyboard: typing "1" in
/// chat must not cast a spell, and that rule belongs here rather than in every
/// key handler.
fn trigger_hotbar_keys(
    text_input: Res<super::controls::TextInputActive>,
    keys: Res<ButtonInput<KeyCode>>,
    state: Res<UiState>,
    mut intents: MessageWriter<IntentMessage>,
) {
    // `TextInputActive`, not the snapshot directly. This read the snapshot while
    // the control layer maintained its own answer, which is two rules for one
    // question — and they disagreed the moment a Bevy field held focus without
    // the snapshot knowing.
    if text_input.0 {
        return;
    }

    for index in 0..SLOTS_PER_PAGE {
        let Some(key) = slot_key_code(index) else {
            continue;
        };
        if !keys.just_pressed(key) {
            continue;
        }
        if let Some(intent) = hotbar_intent(state.get().hotbar.slot(index), index) {
            intents.write(IntentMessage(intent));
        }
    }
}

fn disarm_on_escape(
    text_input: Res<super::controls::TextInputActive>,
    keys: Res<ButtonInput<KeyCode>>,
    mut armed: ResMut<ArmedSpell>,
) {
    // While typing, Escape belongs to the composition it is cancelling.
    if text_input.0 {
        return;
    }
    if armed.0.is_some() && keys.just_pressed(KeyCode::Escape) {
        armed.clear();
    }
}

/// Disarm when the spell stops being castable.
///
/// Dying with a spell armed and then clicking would otherwise fire a cast the
/// server refuses, and the refusal arrives with no obvious cause.
fn disarm_when_unusable(state: Res<UiState>, mut armed: ResMut<ArmedSpell>) {
    if !state.is_changed() {
        return;
    }
    let Some(spell_id) = armed.0 else {
        return;
    };

    let still_usable = state
        .get()
        .spellbook
        .spells
        .iter()
        .any(|spell| spell.spell_id == spell_id && spell.is_castable());

    if !still_usable {
        armed.clear();
    }
}

/// A short label for why a spell cannot be cast.
///
/// A key, not a sentence: the catalogue turns it into text. Returning the key
/// keeps the decision about wording out of the panel.
pub fn blocker_key(blocker: SpellBlocker) -> &'static str {
    match blocker {
        SpellBlocker::Dead => "spell.blocked.dead",
        SpellBlocker::InsufficientMana => "spell.blocked.mana",
        SpellBlocker::InsufficientStamina => "spell.blocked.stamina",
        SpellBlocker::InsufficientSkill => "spell.blocked.skill",
        SpellBlocker::OnCooldown => "spell.blocked.cooldown",
        SpellBlocker::NoTarget => "spell.blocked.no-target",
        SpellBlocker::TargetDead => "spell.blocked.target-dead",
        SpellBlocker::TargetLevelTooLow => "spell.blocked.target-level",
        SpellBlocker::EquipmentMask => "spell.blocked.equipment",
        SpellBlocker::WrongTerrain => "spell.blocked.terrain",
        SpellBlocker::ForbiddenHere => "spell.blocked.area",
    }
}

/// One spellbook row.
pub fn spell_row(spell: &SpellView, armed: bool) -> impl Bundle {
    let castable = spell.is_castable();
    let name = spell.name_key.rsplit('.').next().unwrap_or_default().to_string();
    let detail = match spell.primary_blocker() {
        Some(blocker) => blocker_key(blocker).to_string(),
        None => format!("{} mana", spell.mana_cost.max(0)),
    };

    (
        Node {
            width: Val::Percent(100.0),
            flex_direction: FlexDirection::Column,
            padding: UiRect::all(Val::Px(space::TIGHT)),
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(if armed { focus::RING } else { surface::EDGE }),
        children![
            (
                Text::new(name),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(if castable { ink::PRIMARY } else { ink::DISABLED }),
            ),
            (
                Text::new(detail),
                TextFont { font_size: type_scale::MICRO, ..default() },
                TextColor(ink::MUTED),
            ),
        ],
    )
}

/// Whether the hotbar should show its page control.
pub fn shows_page_control(snapshot: &UiSnapshot) -> bool {
    snapshot.hotbar.page_count > 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures::{self, Scenario};
    use ao_core::view::{ChatState, Gauge, HotbarBinding, TargetKind};

    fn spell(target_mode: TargetMode, blockers: Vec<SpellBlocker>) -> SpellView {
        SpellView {
            spell_id: 7,
            name_key: "spell.missile".into(),
            mana_cost: 10,
            stamina_cost: 0,
            required_skill: 5,
            icon_grh: 1,
            target_mode,
            blockers,
        }
    }

    fn selected() -> TargetState {
        TargetState::Selected {
            name: "Wolf".into(),
            kind: TargetKind::Hostile,
            health: Some(Gauge::new(30, 60)),
        }
    }

    #[test]
    fn the_most_actionable_blocker_is_the_one_shown() {
        // Showing the wrong one sends a player to train a skill when they only
        // had to sheathe a shield.
        let blockers =
            [SpellBlocker::InsufficientSkill, SpellBlocker::OnCooldown, SpellBlocker::Dead];
        assert_eq!(SpellBlocker::most_actionable(&blockers), Some(SpellBlocker::Dead));

        let blockers = [SpellBlocker::InsufficientSkill, SpellBlocker::InsufficientMana];
        assert_eq!(SpellBlocker::most_actionable(&blockers), Some(SpellBlocker::InsufficientMana));
    }

    #[test]
    fn a_repeated_blocker_still_reports_one_reason() {
        // The malformed fixture carries the same blocker twice.
        let blockers = [SpellBlocker::OnCooldown, SpellBlocker::OnCooldown];
        assert_eq!(SpellBlocker::most_actionable(&blockers), Some(SpellBlocker::OnCooldown));
    }

    #[test]
    fn a_ready_spell_has_no_blocker_to_report() {
        assert_eq!(SpellBlocker::most_actionable(&[]), None);
    }

    #[test]
    fn a_self_cast_spell_fires_immediately() {
        // There is nothing to point at, so arming would make the player click
        // twice for no reason.
        assert_eq!(
            activate_spell(&spell(TargetMode::SelfCast, vec![]), &TargetState::None),
            SpellActivation::Cast(7)
        );
        assert_eq!(
            activate_spell(&spell(TargetMode::Area, vec![]), &TargetState::None),
            SpellActivation::Cast(7)
        );
    }

    #[test]
    fn a_targeted_spell_arms_when_nothing_is_selected() {
        assert_eq!(
            activate_spell(&spell(TargetMode::Entity, vec![]), &TargetState::None),
            SpellActivation::Arm(7)
        );
        assert_eq!(
            activate_spell(&spell(TargetMode::Ground, vec![]), &selected()),
            SpellActivation::Arm(7),
            "a ground spell needs a tile even when an entity is selected"
        );
    }

    #[test]
    fn a_targeted_spell_uses_the_selection_it_already_has() {
        // Re-arming would make the player click the same enemy twice.
        assert_eq!(
            activate_spell(&spell(TargetMode::Entity, vec![]), &selected()),
            SpellActivation::Cast(7)
        );
    }

    #[test]
    fn a_blocked_spell_neither_casts_nor_arms() {
        // Arming a spell that cannot be cast leaves a targeting cursor the
        // player has to dismiss for nothing.
        let blocked = spell(TargetMode::Entity, vec![SpellBlocker::InsufficientMana]);
        assert_eq!(
            activate_spell(&blocked, &selected()),
            SpellActivation::Blocked(SpellBlocker::InsufficientMana)
        );
    }

    #[test]
    fn every_target_mode_agrees_about_whether_it_needs_a_selection() {
        assert!(!TargetMode::SelfCast.needs_selection());
        assert!(!TargetMode::Area.needs_selection());
        assert!(TargetMode::Entity.needs_selection());
        assert!(TargetMode::Ground.needs_selection());
    }

    #[test]
    fn an_unbound_hotbar_slot_does_nothing() {
        assert_eq!(hotbar_intent(HotbarSlotState::default(), 0), None);
    }

    #[test]
    fn a_cooling_hotbar_slot_does_not_ask_the_server() {
        // A request refused on cooldown is indistinguishable from lag.
        let cooling = HotbarSlotState {
            binding: Some(HotbarBinding::Spell { spell_id: 1, icon_grh: 1 }),
            cooldown: 0.5,
        };
        assert_eq!(hotbar_intent(cooling, 3), None);
    }

    #[test]
    fn a_ready_hotbar_slot_asks_to_be_triggered() {
        let ready = HotbarSlotState {
            binding: Some(HotbarBinding::Spell { spell_id: 1, icon_grh: 1 }),
            cooldown: 0.0,
        };
        assert_eq!(hotbar_intent(ready, 3), Some(Intent::TriggerHotbarSlot { index: 3 }));
    }

    #[test]
    fn a_nan_cooldown_does_not_make_a_slot_permanently_dead() {
        // It clamps to zero, so a malformed cooldown leaves the slot usable
        // rather than silently unusable forever.
        let odd = HotbarSlotState {
            binding: Some(HotbarBinding::Spell { spell_id: 1, icon_grh: 1 }),
            cooldown: f32::NAN,
        };
        assert_eq!(hotbar_intent(odd, 0), Some(Intent::TriggerHotbarSlot { index: 0 }));
    }

    #[test]
    fn slots_are_bound_to_the_number_row_in_order() {
        let keys: Vec<KeyCode> = (0..SLOTS_PER_PAGE).filter_map(slot_key_code).collect();
        assert_eq!(keys.len(), SLOTS_PER_PAGE);
        assert_eq!(keys[0], KeyCode::Digit1);
        assert_eq!(keys[9], KeyCode::Digit0);
        assert_eq!(slot_key_code(SLOTS_PER_PAGE), None);
    }

    fn app_with(scenario: Scenario) -> App {
        let mut app = App::new();
        // The real interaction pipeline, so `TextInputActive` is maintained by
        // `track_text_input` exactly as in production. Setting the resource by
        // hand here would test the gate while leaving the thing that decides it
        // unexercised — and the snapshot path is precisely what regressed when
        // this moved off the snapshot.
        app.add_plugins(super::super::controls::ControlsPlugin)
            .init_resource::<UiState>()
            .init_resource::<ArmedSpell>()
            .insert_resource(ButtonInput::<KeyCode>::default())
            .add_message::<IntentMessage>()
            .add_systems(
                Update,
                (trigger_hotbar_keys, disarm_on_escape, disarm_when_unusable)
                    .chain()
                    .in_set(super::super::controls::GameplayInput),
            );
        app.world_mut().resource_mut::<UiState>().set(fixtures::snapshot(scenario));
        app
    }

    #[test]
    fn a_focused_text_field_stops_a_number_key_firing_a_hotbar_slot() {
        // The complement of `typing_in_chat_does_not_cast_spells`, which drives
        // the snapshot. This drives the *control* path: a Bevy field holding focus
        // with the snapshot knowing nothing about it, which is exactly the case
        // where the two rules disagreed and the hotbar fired anyway.
        use super::super::controls::{text_field, FocusOwner, TextField};

        let mut app = app_with(Scenario::Populated);
        let field = app.world_mut().spawn(text_field(TextField::new(), 1)).id();
        app.update();
        app.world_mut().resource_mut::<FocusOwner>().focus(field, None);

        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::Digit1);
        app.update();

        assert_eq!(
            intent_count(&app),
            0,
            "a hotbar slot fired while a text field held the keyboard"
        );

        // And the key works again once the field lets go, or suppression would be
        // a way to disable the hotbar permanently.
        app.world_mut().resource_mut::<FocusOwner>().clear();
        // Released, not merely cleared: `clear` drops the just-pressed edge but
        // leaves the key held, and pressing a held key produces no new edge.
        {
            let mut keys = app.world_mut().resource_mut::<ButtonInput<KeyCode>>();
            keys.release(KeyCode::Digit1);
            keys.clear();
        }
        app.update();
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::Digit1);
        app.update();
        assert!(intent_count(&app) > 0, "the hotbar never recovered");
    }

    fn intent_count(app: &App) -> usize {
        let messages = app.world().resource::<Messages<IntentMessage>>();
        let mut cursor = messages.get_cursor();
        cursor.read(messages).count()
    }

    #[test]
    fn a_number_key_fires_its_hotbar_slot() {
        let mut app = app_with(Scenario::Populated);
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::Digit1);
        app.update();

        assert_eq!(intent_count(&app), 1);
    }

    #[test]
    fn typing_in_chat_does_not_cast_spells() {
        // The reason focus ownership is modelled at all: "1" in a chat line
        // must be a character, not a fireball.
        let mut app = app_with(Scenario::Populated);
        {
            let mut state = app.world_mut().resource_mut::<UiState>();
            let mut snapshot = state.get().clone();
            snapshot.chat = ChatState { composing: true, ..snapshot.chat };
            state.set(snapshot);
        }
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::Digit1);
        app.update();

        assert_eq!(intent_count(&app), 0, "a hotbar key fired while typing");
    }

    #[test]
    fn escape_disarms_a_pending_spell() {
        let mut app = app_with(Scenario::Populated);
        app.world_mut().resource_mut::<ArmedSpell>().0 = Some(1);
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::Escape);
        app.update();

        assert_eq!(app.world().resource::<ArmedSpell>().0, None);
    }

    #[test]
    fn dying_disarms_a_pending_spell() {
        // Otherwise the next click fires a cast the server refuses, and the
        // refusal arrives with no obvious cause.
        let mut app = app_with(Scenario::Populated);
        app.world_mut().resource_mut::<ArmedSpell>().0 = Some(1);
        app.update();
        assert_eq!(app.world().resource::<ArmedSpell>().0, Some(1));

        app.world_mut().resource_mut::<UiState>().set(fixtures::snapshot(Scenario::DeadGhost));
        app.update();

        assert_eq!(app.world().resource::<ArmedSpell>().0, None);
    }

    #[test]
    fn running_out_of_mana_disarms_a_pending_spell() {
        let mut app = app_with(Scenario::Populated);
        app.world_mut().resource_mut::<ArmedSpell>().0 = Some(1);
        app.update();

        app.world_mut().resource_mut::<UiState>().set(fixtures::snapshot(Scenario::Disabled));
        app.update();

        assert_eq!(app.world().resource::<ArmedSpell>().0, None);
    }

    #[test]
    fn every_blocker_has_its_own_key() {
        // Two sharing a key would show one reason for two different problems.
        let blockers = [
            SpellBlocker::Dead,
            SpellBlocker::InsufficientMana,
            SpellBlocker::InsufficientStamina,
            SpellBlocker::InsufficientSkill,
            SpellBlocker::OnCooldown,
            SpellBlocker::NoTarget,
            SpellBlocker::TargetDead,
            SpellBlocker::TargetLevelTooLow,
            SpellBlocker::EquipmentMask,
            SpellBlocker::WrongTerrain,
            SpellBlocker::ForbiddenHere,
        ];

        let mut keys: Vec<&str> = blockers.iter().map(|b| blocker_key(*b)).collect();
        keys.sort_unstable();
        let before = keys.len();
        keys.dedup();
        assert_eq!(keys.len(), before, "two blockers share a key");
    }

    #[test]
    fn blocked_spells_in_the_disabled_fixture_all_report_a_reason() {
        let disabled = fixtures::snapshot(Scenario::Disabled);
        for spell in &disabled.spellbook.spells {
            assert!(spell.primary_blocker().is_some(), "a blocked spell gave no reason");
        }
    }
}
