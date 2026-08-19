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
                (
                    trigger_hotbar_keys,
                    apply_hotbar_activations,
                    // Before the disarm rules, so a spell armed this frame is not
                    // examined for usability against the snapshot that armed it.
                    apply_spell_activations,
                    cast_armed_spell_on_world_click,
                    disarm_on_escape,
                    disarm_when_unusable,
                )
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

/// Fire a hotbar slot, whichever input asked for it.
///
/// One function so there is one path: the contract asks for it, and the reason is that
/// two paths drift. A key that refuses a cooling slot while a click sends it anyway is a
/// bug nobody finds until the server starts refusing casts.
fn fire_slot(index: usize, snapshot: &UiSnapshot, intents: &mut MessageWriter<IntentMessage>) {
    if let Some(intent) = hotbar_intent(snapshot.hotbar.slot(index), index) {
        intents.write(IntentMessage(intent));
    }
}

/// Fire a hotbar slot that was clicked or activated from the keyboard.
///
/// The pointer path is deliberately *not* suppressed while a text field owns the
/// keyboard, where the number keys are. A click is unambiguous, and it takes focus away
/// from the field as it lands — suppressing it would make the hotbar unclickable while
/// the chat box is focused, which is the opposite of what the rule protects.
fn apply_hotbar_activations(
    mut activated: MessageReader<super::controls::Activated>,
    slots: Query<&super::hotbar::HotbarSlot>,
    state: Res<UiState>,
    mut intents: MessageWriter<IntentMessage>,
) {
    for message in activated.read() {
        if let Ok(slot) = slots.get(message.entity) {
            fire_slot(slot.index, state.get(), &mut intents);
        }
    }
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
        let Some(key) = super::hotbar::slot_key_code(index) else {
            continue;
        };
        if !keys.just_pressed(key) {
            continue;
        }
        fire_slot(index, state.get(), &mut intents);
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

/// Marks a spellbook row with the spell it casts.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpellRowButton {
    pub spell_id: i32,
    pub index: usize,
}

/// One spellbook row.
///
/// A control, not a picture of one: it carries the shared interaction bundle and a
/// stable key, so the pointer pipeline can see it, Tab reaches it, and a browser test
/// can aim at it. The builder existed for some time with neither, which meant a
/// spellbook that could be rendered and not used.
pub fn spell_row(
    spell: &SpellView,
    index: usize,
    armed: bool,
    icon: Option<super::character::ItemIcon>,
) -> impl Bundle {
    let castable = spell.is_castable();
    // Localised at this boundary. The blocker keys are semantic — `spell.blocked.mana`
    // — and this task forbids showing them raw; the fallback is derived from the key
    // rather than hard-coded here so the catalogue replaces it in one place.
    let name = super::fallback_label(&spell.name_key);
    let detail = match spell.primary_blocker() {
        Some(blocker) => super::fallback_label(blocker_key(blocker)),
        None => format!("{} mana", spell.mana_cost.max(0)),
    };

    (
        Node {
            width: Val::Percent(100.0),
            // A row, so the graphic sits beside the words rather than above them: a
            // spellbook is scanned by icon and read by name.
            flex_direction: FlexDirection::Row,
            align_items: AlignItems::Center,
            column_gap: Val::Px(space::TIGHT),
            padding: UiRect::all(Val::Px(space::TIGHT)),
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(if armed { focus::RING } else { surface::EDGE }),
        // Armed is a selection: it survives `present_controls`, which owns borders and
        // would otherwise repaint the ring away on the next frame.
        super::controls::Selected(armed),
        super::controls::interactive(400 + index as u32, castable),
        super::controls::ControlKey::indexed("spell.row", index),
        SpellRowButton { spell_id: spell.spell_id, index },
        children![
            (
                Node {
                    width: Val::Px(size::ICON_BUTTON),
                    height: Val::Px(size::ICON_BUTTON),
                    flex_shrink: 0.0,
                    ..default()
                },
                super::character::ItemIcon::node(icon.as_ref()),
                Pickable::IGNORE,
            ),
            (
                Node {
                    flex_direction: FlexDirection::Column,
                    flex_grow: 1.0,
                    overflow: Overflow::clip(),
                    ..default()
                },
                Pickable::IGNORE,
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
            ),
        ],
    )
}

/// The spellbook, as the snapshot reports it.
pub fn spellbook_panel(
    snapshot: &UiSnapshot,
    armed: Option<i32>,
    icons: &[Option<super::character::ItemIcon>],
) -> impl Bundle {
    let spells = snapshot.spellbook.spells.clone();
    let empty = spells.is_empty();
    // Cloned into the iterator: the closure that spawns each row runs later, after the
    // caller's borrow of the graphics resources has ended.
    let icons: Vec<Option<super::character::ItemIcon>> = icons.to_vec();
    (
        Node {
            width: Val::Percent(100.0),
            flex_direction: FlexDirection::Column,
            row_gap: Val::Px(space::HAIR),
            ..default()
        },
        // Two spawners rather than two `Children` components: the rows and the
        // empty-book label are different bundles, and a panel that draws nothing when
        // the book is empty is indistinguishable from one that failed to draw.
        Children::spawn((
            SpawnIter(spells.into_iter().enumerate().map(move |(index, spell)| {
                let armed_here = armed == Some(spell.spell_id);
                spell_row(&spell, index, armed_here, icons[index].clone())
            })),
            SpawnIter(
                empty
                    .then(|| {
                        (
                            Text::new("no spells yet".to_string()),
                            TextFont { font_size: type_scale::SMALL, ..default() },
                            TextColor(ink::DISABLED),
                        )
                    })
                    .into_iter(),
            ),
        )),
    )
}

/// Turn a click or keypress on a spell row into a cast or an armed spell.
///
/// The counterpart of `character::apply_slot_activations`, and missing for the same
/// reason it was: `activate_spell` had no production caller at all, so the decision it
/// exists to make — cast now, or wait for a target — was never actually made.
fn apply_spell_activations(
    mut activated: MessageReader<super::controls::Activated>,
    rows: Query<&SpellRowButton>,
    state: Res<UiState>,
    mut armed: ResMut<ArmedSpell>,
    mut intents: MessageWriter<super::state::IntentMessage>,
) {
    for message in activated.read() {
        let Ok(row) = rows.get(message.entity) else {
            continue;
        };
        let snapshot = state.get();
        let Some(spell) =
            snapshot.spellbook.spells.iter().find(|spell| spell.spell_id == row.spell_id)
        else {
            continue;
        };

        match activate_spell(spell, &snapshot.target) {
            SpellActivation::Cast(spell_id) => {
                armed.0 = None;
                intents.write(super::state::IntentMessage(Intent::CastSpell { spell_id }));
            }
            SpellActivation::Arm(spell_id) => armed.0 = Some(spell_id),
            // Silent: the row already shows why, and a second message repeating it
            // would be noise the player did not ask for.
            SpellActivation::Blocked(_) => {}
        }
    }
}

/// Spend an armed spell on the next world tile the player clicks.
///
/// This is the other half of arming, and without it an armed spell could only be
/// disarmed: the ring appeared and nothing could ever consume it.
///
/// Reads the mouse and the resolved pointer rather than a picking event, because the
/// world is not a UI node — the shell's world region deliberately ignores picking so
/// that clicks reach the world at all. Target *selection* proper is W-0008; this is the
/// narrow case of a spell that is already waiting for somewhere to land.
fn cast_armed_spell_on_world_click(
    mouse: Res<ButtonInput<MouseButton>>,
    pointer: Res<super::pointer::PointerState>,
    mut armed: ResMut<ArmedSpell>,
    mut intents: MessageWriter<super::state::IntentMessage>,
) {
    let Some(spell_id) = armed.0 else {
        return;
    };
    if !mouse.just_pressed(MouseButton::Left) || !pointer.over_world() {
        return;
    }
    let Some(tile) = pointer.tile else {
        return;
    };

    // The target first, then the cast. That is the order the protocol uses and the
    // order the server can refuse in halves; sending the cast alone would ask the
    // server to guess what the player pointed at.
    intents.write(super::state::IntentMessage(Intent::SelectTarget {
        x: tile.x.clamp(0, u8::MAX as i32) as u8,
        y: tile.y.clamp(0, u8::MAX as i32) as u8,
    }));
    intents.write(super::state::IntentMessage(Intent::CastSpell { spell_id }));
    armed.0 = None;
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

    /// A running shell with the spellbook open.
    ///
    /// The production tree, not a hand-built row: the point of these tests is that the
    /// rows the rail actually spawns are operable, and a locally assembled entity would
    /// carry whatever components the test remembered to add.
    fn spellbook_app() -> App {
        let mut app = super::super::testing::shell_app(Vec2::new(1280.0, 832.0));
        // Ordered after the systems it records. Registered without ordering, the reader
        // ran before the writers and every intent was only visible a frame later — which
        // reads as "the click sent nothing".
        app.init_resource::<Recorded>().add_systems(
            Update,
            record_intents.after(super::super::controls::GameplayInput),
        );
        let tab = app
            .world_mut()
            .query::<(Entity, &super::super::character::RailTabButton)>()
            .iter(app.world())
            .find(|(_, button)| button.0 == super::super::character::RailTab::Spells)
            .map(|(entity, _)| entity)
            .expect("the rail has a spells tab");
        app.world_mut().write_message(super::super::controls::Activated {
            entity: tab,
            source: super::super::controls::ActivationSource::Pointer,
        });
        for _ in 0..3 {
            app.update();
        }
        app
    }

    #[derive(Resource, Default)]
    struct Recorded(Vec<Intent>);

    fn record_intents(
        mut messages: MessageReader<IntentMessage>,
        mut recorded: ResMut<Recorded>,
    ) {
        for message in messages.read() {
            recorded.0.push(message.0.clone());
        }
    }

    fn intents(app: &App) -> Vec<Intent> {
        app.world().resource::<Recorded>().0.clone()
    }

    fn row_for(app: &mut App, spell_id: i32) -> Entity {
        app.world_mut()
            .query::<(Entity, &SpellRowButton)>()
            .iter(app.world())
            .find(|(_, row)| row.spell_id == spell_id)
            .map(|(entity, _)| entity)
            .unwrap_or_else(|| panic!("no row for spell {spell_id}"))
    }

    fn activate(app: &mut App, entity: Entity) {
        app.world_mut().write_message(super::super::controls::Activated {
            entity,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();
    }

    fn hotbar_slot(app: &mut App, index: usize) -> Entity {
        app.world_mut()
            .query::<(Entity, &super::super::hotbar::HotbarSlot)>()
            .iter(app.world())
            .find(|(_, slot)| slot.index == index)
            .map(|(entity, _)| entity)
            .unwrap_or_else(|| panic!("no hotbar slot {index}"))
    }

    fn press_key(app: &mut App, key: KeyCode) {
        super::super::testing::tap_key(app, key);
    }

    #[test]
    fn a_number_key_and_a_click_ask_for_the_same_thing() {
        // One path, which is what the contract asks for and what keeps a key that
        // refuses a cooling slot from disagreeing with a click that sends it.
        let mut app = spellbook_app();
        let slot = hotbar_slot(&mut app, 0);
        activate(&mut app, slot);
        let clicked = intents(&app);

        let mut app = spellbook_app();
        press_key(&mut app, KeyCode::Digit1);
        app.update();
        let typed = intents(&app);

        assert_eq!(clicked, vec![Intent::TriggerHotbarSlot { index: 0 }]);
        assert_eq!(typed, clicked, "the key and the click asked for different things");
    }

    #[test]
    fn neither_input_fires_an_empty_slot() {
        // The fixture binds three slots, so the fourth is empty.
        let mut app = spellbook_app();
        let empty = hotbar_slot(&mut app, 4);
        activate(&mut app, empty);
        press_key(&mut app, KeyCode::Digit5);
        app.update();

        assert!(intents(&app).is_empty(), "an empty slot was fired: {:?}", intents(&app));
    }

    #[test]
    fn neither_input_fires_a_cooling_slot() {
        let mut app = spellbook_app();
        let mut cooling = app.world().resource::<UiState>().get().clone();
        cooling.hotbar.slots[0].cooldown = 0.6;
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), cooling);
        app.update();

        let cooling_slot = hotbar_slot(&mut app, 0);
        activate(&mut app, cooling_slot);
        press_key(&mut app, KeyCode::Digit1);
        app.update();

        assert!(intents(&app).is_empty(), "a cooling slot was fired: {:?}", intents(&app));
    }

    #[test]
    fn a_number_key_typed_into_a_text_field_fires_nothing() {
        // Through the snapshot rather than by assigning the resource: production
        // recomputes ownership from focus and the snapshot every frame, so a resource set
        // by hand is gone before the key is read — and the test would then be asserting
        // that a suppressed keystroke was suppressed by nothing.
        let mut app = spellbook_app();
        let mut composing = app.world().resource::<UiState>().get().clone();
        composing.chat.composing = true;
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), composing);
        app.update();
        assert!(
            app.world().resource::<super::super::controls::TextInputActive>().0,
            "text does not own the keyboard, so this test is not asking its question"
        );

        press_key(&mut app, KeyCode::Digit1);
        app.update();

        assert!(
            intents(&app).is_empty(),
            "typing a number in a text field cast a spell: {:?}",
            intents(&app)
        );
    }

    #[test]
    fn a_cooling_slot_is_veiled_in_proportion_to_what_is_left() {
        // The cooldown is a height rather than a rebuild: a slot respawned every frame a
        // cooldown ticks would lose focus continuously.
        let mut app = spellbook_app();
        let mut cooling = app.world().resource::<UiState>().get().clone();
        cooling.hotbar.slots[1].cooldown = 0.5;
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), cooling);
        app.update();

        let veiled: Vec<(Entity, Val)> = app
            .world_mut()
            .query::<(&ChildOf, &Node)>()
            .iter(app.world())
            .map(|(parent, node)| (parent.parent(), node.height))
            .collect();
        let veils: Vec<(usize, Val)> = veiled
            .into_iter()
            .filter_map(|(parent, height)| {
                let slot = app.world().get::<super::super::hotbar::HotbarSlot>(parent)?;
                Some((slot.index, height))
            })
            .collect();

        assert!(
            veils.iter().any(|(index, height)| *index == 1 && *height == Val::Percent(50.0)),
            "the cooling slot is not veiled: {veils:?}"
        );
        assert!(
            veils.iter().any(|(index, height)| *index == 0 && *height == Val::Percent(0.0)),
            "a ready slot is veiled anyway: {veils:?}"
        );
    }

    #[test]
    fn the_spellbook_spawns_a_row_for_every_spell_the_snapshot_carries() {
        let mut app = spellbook_app();
        let rows = app.world_mut().query::<&SpellRowButton>().iter(app.world()).count();
        assert_eq!(
            rows,
            fixtures::snapshot(Scenario::Populated).spellbook.spells.len(),
            "the spellbook drew a different number of rows than the snapshot has spells"
        );
    }

    #[test]
    fn clicking_a_self_cast_spell_emits_exactly_one_cast() {
        // Heal in the fixture: nothing to point at, so it goes straight out.
        let mut app = spellbook_app();
        let heal = row_for(&mut app, 2);

        activate(&mut app, heal);

        assert_eq!(
            intents(&app),
            vec![Intent::CastSpell { spell_id: 2 }],
            "a self-cast spell did not produce exactly one cast"
        );
        assert!(app.world().resource::<ArmedSpell>().0.is_none(), "a self-cast spell armed");
    }

    #[test]
    fn clicking_a_ground_spell_arms_it_rather_than_casting() {
        // Tremor is ground-targeted, and the fixture's selected target is an entity —
        // which is not somewhere a ground spell can land.
        let mut app = spellbook_app();
        let tremor = row_for(&mut app, 3);

        activate(&mut app, tremor);

        assert!(intents(&app).is_empty(), "arming a spell already sent a cast: {:?}", intents(&app));
        assert_eq!(app.world().resource::<ArmedSpell>().0, Some(3), "the spell did not arm");
    }

    #[test]
    fn an_armed_spell_is_spent_on_the_next_world_click_and_disarms() {
        // Without this the ring appeared and nothing could ever consume it: arming was
        // reachable and spending it was not.
        let mut app = spellbook_app();
        let tremor = row_for(&mut app, 3);
        activate(&mut app, tremor);

        let world_centre = super::super::testing::settled(&app).world.center();
        super::super::testing::move_pointer(&mut app, world_centre);
        assert!(
            app.world().resource::<super::super::pointer::PointerState>().over_world(),
            "the pointer is not over the world, so this test is not asking its question"
        );

        super::super::testing::press_mouse(&mut app, MouseButton::Left);

        let sent = intents(&app);
        assert!(
            matches!(sent.first(), Some(Intent::SelectTarget { .. })),
            "the cast did not say what it was aimed at: {sent:?}"
        );
        assert!(
            sent.contains(&Intent::CastSpell { spell_id: 3 }),
            "the armed spell was never cast: {sent:?}"
        );
        assert!(app.world().resource::<ArmedSpell>().0.is_none(), "the spell stayed armed");
    }

    #[test]
    fn a_world_click_with_nothing_armed_casts_nothing() {
        let mut app = spellbook_app();
        let world_centre = super::super::testing::settled(&app).world.center();
        super::super::testing::move_pointer(&mut app, world_centre);

        super::super::testing::press_mouse(&mut app, MouseButton::Left);

        assert!(intents(&app).is_empty(), "an unarmed world click cast something: {:?}", intents(&app));
    }

    #[test]
    fn a_blocked_spell_sends_nothing_and_does_not_arm() {
        let mut app = spellbook_app();
        let mut blocked = app.world().resource::<UiState>().get().clone();
        blocked.spellbook.spells[0].blockers = vec![SpellBlocker::InsufficientMana];
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), blocked);
        for _ in 0..2 {
            app.update();
        }

        let missile = row_for(&mut app, 1);
        activate(&mut app, missile);

        assert!(intents(&app).is_empty(), "a blocked spell was cast anyway: {:?}", intents(&app));
        assert!(app.world().resource::<ArmedSpell>().0.is_none(), "a blocked spell armed");
    }

    #[test]
    fn a_spell_row_says_why_in_words_rather_than_in_a_key() {
        // The contract is explicit: semantic keys are localised at this boundary and
        // never shown raw. `spell.blocked.mana` on screen is our source code, printed
        // for a player.
        let mut app = spellbook_app();
        let mut blocked = app.world().resource::<UiState>().get().clone();
        blocked.spellbook.spells[0].blockers = vec![SpellBlocker::InsufficientMana];
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), blocked);
        for _ in 0..2 {
            app.update();
        }

        let shown: Vec<String> =
            app.world_mut().query::<&Text>().iter(app.world()).map(|text| text.0.clone()).collect();
        assert!(
            shown.iter().any(|text| !text.is_empty() && !text.contains('.')),
            "the spellbook rendered nothing readable: {shown:?}"
        );
        assert!(
            !shown.iter().any(|text| text.starts_with("spell.")),
            "a semantic key reached the screen: {shown:?}"
        );
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
        let keys: Vec<KeyCode> =
            (0..SLOTS_PER_PAGE).filter_map(super::super::hotbar::slot_key_code).collect();
        assert_eq!(keys.len(), SLOTS_PER_PAGE);
        assert_eq!(keys[0], KeyCode::Digit1);
        assert_eq!(keys[9], KeyCode::Digit0);
        assert_eq!(super::super::hotbar::slot_key_code(SLOTS_PER_PAGE), None);
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
