//! The numbered hotbar, anchored to the bottom centre of the world viewport.
//!
//! Centred on the *viewport*, not the window. With a 420px rail, centring on
//! the window pushes the bar visibly right of the world it belongs to — the
//! roadmap calls this out specifically because it is easy to get wrong and
//! looks subtly off rather than obviously broken.

use super::shell::{label, Hotbar};
use super::tokens::{ink, size, space, surface, type_scale};
use ao_core::view::{HotbarBinding, UiSnapshot};
use bevy::prelude::*;

/// Slots on one page.
///
/// Ten, keyed 1-9 then 0, which is the row of number keys and the convention
/// every AO client uses.
pub const SLOTS_PER_PAGE: usize = 10;

/// A hotbar slot and the key that triggers it.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct HotbarSlot {
    pub index: usize,
}

/// The key label for a slot: 1-9 then 0.
pub fn slot_key_label(index: usize) -> String {
    match index {
        9 => "0".to_string(),
        other => (other + 1).to_string(),
    }
}

/// The keyboard key that fires a slot.
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

pub struct HotbarPlugin;

impl Plugin for HotbarPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, populate.after(super::shell::spawn_shell))
            .add_observer(assign_dropped)
            .add_systems(
                Update,
                (
                    // The bindings decide what a slot contains; the cooldown only decides
                    // how much of it is veiled, so it is a height rather than a rebuild.
                    present_bindings,
                    present_cooldowns,
                ),
            )
            .add_systems(Update, apply_hotbar_edits.in_set(super::controls::GameplayInput));
    }
}

/// Marks the control that turns the hotbar's page.
#[derive(Component, Debug, Clone, Copy)]
pub struct PageControl;

/// Assign whatever was dropped onto a slot.
///
/// The dragged entity comes from Bevy's own drop event, so no second drag model is
/// needed: an inventory slot carries the item it holds and a spellbook row carries its
/// spell, and either is enough to bind.
fn assign_dropped(
    drop: On<bevy::picking::events::Pointer<bevy::picking::events::DragDrop>>,
    slots: Query<&HotbarSlot>,
    items: Query<&super::character::InventorySlotButton>,
    spells: Query<&super::spells::SpellRowButton>,
    state: Res<super::state::UiState>,
    graphics: Res<crate::graphics::Graphics>,
    mut intents: MessageWriter<super::state::IntentMessage>,
) {
    let Ok(slot) = slots.get(drop.entity) else {
        return;
    };
    let dropped = drop.event.dropped;

    let binding = if let Ok(button) = items.get(dropped) {
        let item = state.get().inventory.slot(button.index).item().cloned();
        item.map(|item| HotbarBinding::Item {
            item_id: item.item_id,
            icon_grh: super::character::item_grh(item.item_id, item.icon_grh, &graphics),
        })
    } else if let Ok(row) = spells.get(dropped) {
        state.get().spellbook.spells.iter().find(|spell| spell.spell_id == row.spell_id).map(
            |spell| HotbarBinding::Spell { spell_id: spell.spell_id, icon_grh: spell.icon_grh },
        )
    } else {
        None
    };

    // Nothing recognisable was dropped. Silent rather than refused: the player may have
    // been dragging something this bar has no opinion about.
    if let Some(binding) = binding {
        intents.write(super::state::IntentMessage(ao_core::view::Intent::BindHotbarSlot {
            index: slot.index,
            binding,
        }));
    }
}

/// Empty a slot on Shift-click, and turn the page on the page control.
///
/// Shift for removal because a plain click is how a slot is *used*, and a hotbar where
/// clicking sometimes unbinds instead of firing would be unusable. It matches the
/// Shift-click rule the inventory already uses for the destructive action.
fn apply_hotbar_edits(
    mut activated: MessageReader<super::controls::Activated>,
    keys: Res<ButtonInput<KeyCode>>,
    slots: Query<&HotbarSlot>,
    pages: Query<(), With<PageControl>>,
    state: Res<super::state::UiState>,
    mut intents: MessageWriter<super::state::IntentMessage>,
) {
    let shift = keys.pressed(KeyCode::ShiftLeft) || keys.pressed(KeyCode::ShiftRight);
    for message in activated.read() {
        if pages.get(message.entity).is_ok() {
            let hotbar = &state.get().hotbar;
            let count = hotbar.page_count.max(1);
            // Wraps, so the last page is not a dead end on a bar with one control.
            let next = (hotbar.page + 1) % count;
            intents.write(super::state::IntentMessage(ao_core::view::Intent::ChangeHotbarPage {
                page: next,
            }));
            continue;
        }

        if !shift {
            continue;
        }
        if let Ok(slot) = slots.get(message.entity) {
            if state.get().hotbar.slot(slot.index).binding.is_some() {
                intents.write(super::state::IntentMessage(
                    ao_core::view::Intent::ClearHotbarSlot { index: slot.index },
                ));
            }
        }
    }
}

/// A slot's contents, rebuilt when its binding changes.
///
/// The slot entity itself is permanent. Rebuilding it would respawn a control the player
/// may have focused and would give it a new entity every time a cooldown ticked.
#[derive(Component)]
struct SlotContent;

/// The veil that shows how much of a cooldown is left.
#[derive(Component)]
struct SlotCooldown;

/// Draw what each slot is bound to.
fn present_bindings(
    state: Res<super::state::UiState>,
    graphics: Res<crate::graphics::Graphics>,
    sheets: Res<crate::graphics::SheetTextures>,
    mut atlases: ResMut<crate::world::SheetAtlases>,
    mut layouts: ResMut<Assets<TextureAtlasLayout>>,
    slots: Query<(Entity, &HotbarSlot)>,
    content: Query<(Entity, &ChildOf), With<SlotContent>>,
    mut commands: Commands,
    mut last: Local<Option<Vec<Option<HotbarBinding>>>>,
) {
    let snapshot = state.get();
    let bindings: Vec<Option<HotbarBinding>> =
        (0..SLOTS_PER_PAGE).map(|index| snapshot.hotbar.slot(index).binding).collect();

    // Artwork arrives long after the snapshot that named it, and nothing in the
    // bindings changes when it does — the same trap the inventory grid fell into, where
    // every slot kept the fallback it was first drawn with for the rest of the session.
    let drawable = bindings
        .iter()
        .flatten()
        .filter(|binding| {
            super::character::icon_for_grh(
                grh_of(binding, &graphics),
                &graphics,
                &sheets,
                &mut atlases,
                &mut layouts,
            )
            .is_some()
        })
        .count();
    let key = (bindings.clone(), drawable);
    if last.as_ref().map(|previous| (previous.clone(), drawable)) == Some(key.clone()) {
        return;
    }
    *last = Some(bindings.clone());

    for (entity, _) in &content {
        commands.entity(entity).despawn();
    }

    for (entity, slot) in &slots {
        let binding = bindings.get(slot.index).copied().flatten();
        let icon = binding.and_then(|binding| {
            super::character::icon_for_grh(
                grh_of(&binding, &graphics),
                &graphics,
                &sheets,
                &mut atlases,
                &mut layouts,
            )
        });
        commands.entity(entity).insert(super::character::ItemIcon::node(icon.as_ref()));

        commands.entity(entity).with_children(|slot_node| {
            // The cooldown veil exists whether or not the slot is cooling: spawning it
            // on demand would mean a frame of full brightness every time one starts.
            slot_node.spawn((
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(0.0),
                    right: Val::Px(0.0),
                    bottom: Val::Px(0.0),
                    height: Val::Percent(0.0),
                    ..default()
                },
                BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.6)),
                Pickable::IGNORE,
                SlotContent,
                SlotCooldown,
            ));

            // How many the player has, for a bound consumable. The count lives in the
            // inventory rather than in the binding, so a hotbar showing a potion with no
            // number is indistinguishable from one showing the last of them.
            if let Some(quantity) = bound_quantity(&binding, snapshot) {
                slot_node.spawn((
                    Node {
                        position_type: PositionType::Absolute,
                        right: Val::Px(space::HAIR),
                        bottom: Val::Px(space::HAIR),
                        ..default()
                    },
                    Text::new(quantity.to_string()),
                    TextFont { font_size: type_scale::MICRO, ..default() },
                    TextColor(ink::PRIMARY),
                    Pickable::IGNORE,
                    SlotContent,
                ));
            }
        });
    }
}

/// The graphic a binding draws with.
fn grh_of(binding: &HotbarBinding, graphics: &crate::graphics::Graphics) -> i32 {
    match binding {
        HotbarBinding::Item { item_id, icon_grh } => {
            super::character::item_grh(*item_id, *icon_grh, graphics)
        }
        // A spell's graphic is its own; there is no object table entry for it.
        HotbarBinding::Spell { icon_grh, .. } => *icon_grh,
    }
}

/// How many of a bound item the player is carrying, when that is worth saying.
fn bound_quantity(binding: &Option<HotbarBinding>, snapshot: &UiSnapshot) -> Option<i32> {
    let HotbarBinding::Item { item_id, .. } = binding.as_ref()? else {
        return None;
    };
    let quantity: i32 = snapshot
        .inventory
        .slots
        .iter()
        .filter_map(|slot| slot.item())
        .filter(|item| item.item_id == *item_id)
        .map(|item| item.quantity.max(0))
        .sum();
    (quantity > 1).then_some(quantity)
}

/// Veil each slot by how much of its cooldown is left.
fn present_cooldowns(
    state: Res<super::state::UiState>,
    slots: Query<&HotbarSlot>,
    mut veils: Query<(&ChildOf, &mut Node), With<SlotCooldown>>,
) {
    let snapshot = state.get();
    for (parent, mut node) in &mut veils {
        let Ok(slot) = slots.get(parent.parent()) else {
            continue;
        };
        let fraction = snapshot.hotbar.slot(slot.index).cooldown_fraction();
        let height = Val::Percent(fraction * 100.0);
        if node.height != height {
            node.height = height;
        }
    }
}

fn slot(index: usize) -> impl Bundle {
    (
        Node {
            width: Val::Px(size::HOTBAR_SLOT),
            height: Val::Px(size::HOTBAR_SLOT),
            border: UiRect::all(Val::Px(size::BORDER)),
            padding: UiRect::all(Val::Px(space::HAIR)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(surface::EDGE),
        HotbarSlot { index },
        // A real control. These slots carried no interaction components at all,
        // so clicking one did nothing and Tab passed straight over them — the
        // keys worked and the slots themselves were decoration.
        super::controls::interactive(200 + index as u32, true),
        super::controls::ControlKey::indexed("hotbar.slot", index),
        // The key label sits in the slot's top-left, as in every AO client: it is
        // a reminder, not a caption, so it must not take slot area from the icon.
        // Drawn by the shared prompt rather than a second copy of it here.
        children![super::controls::hotkey_prompt(&slot_key_label(index))],
    )
}

fn populate(mut commands: Commands, bars: Query<Entity, With<Hotbar>>) {
    for bar in &bars {
        commands.entity(bar).with_children(|bar| {
            for index in 0..SLOTS_PER_PAGE {
                bar.spawn(slot(index));
            }
            // Page arrow. A second page exists in the reference client; until
            // W-0007 gives it behaviour it is drawn disabled rather than
            // pretending to work.
            bar.spawn((
                Node {
                    width: Val::Px(size::HOTBAR_SLOT * 0.55),
                    height: Val::Px(size::HOTBAR_SLOT),
                    justify_content: JustifyContent::Center,
                    align_items: AlignItems::Center,
                    border: UiRect::all(Val::Px(size::BORDER)),
                    ..default()
                },
                BackgroundColor(surface::WELL),
                BorderColor::all(surface::EDGE),
                // A real control now. It was drawn disabled while the second page had no
                // behaviour, which was honest then and is a lie once turning the page
                // works.
                super::controls::interactive(210, true),
                super::controls::ControlKey::new("hotbar.page.next"),
                PageControl,
                children![label(">", type_scale::BODY, ink::PRIMARY)],
            ));
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Resource, Default)]
    struct Recorded(Vec<ao_core::view::Intent>);

    fn record_intents(
        mut messages: MessageReader<super::super::state::IntentMessage>,
        mut recorded: ResMut<Recorded>,
    ) {
        for message in messages.read() {
            recorded.0.push(message.0.clone());
        }
    }

    /// A running shell that records what the hotbar asks for.
    fn hotbar_app() -> App {
        let mut app = super::super::testing::shell_app(Vec2::new(1280.0, 832.0));
        app.init_resource::<Recorded>()
            .add_systems(Update, record_intents.after(super::super::controls::GameplayInput));
        app.update();
        app
    }

    fn intents(app: &App) -> Vec<ao_core::view::Intent> {
        app.world().resource::<Recorded>().0.clone()
    }

    fn slot_entity(app: &mut App, index: usize) -> Entity {
        app.world_mut()
            .query::<(Entity, &HotbarSlot)>()
            .iter(app.world())
            .find(|(_, slot)| slot.index == index)
            .map(|(entity, _)| entity)
            .unwrap_or_else(|| panic!("no hotbar slot {index}"))
    }

    fn activate(app: &mut App, entity: Entity) {
        app.world_mut().write_message(super::super::controls::Activated {
            entity,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();
    }

    /// Drop `dropped` onto `target` through Bevy's own drop event.
    fn drop_onto(app: &mut App, dropped: Entity, target: Entity) {
        use bevy::picking::backend::HitData;
        use bevy::picking::events::{DragDrop, Pointer};
        use bevy::picking::pointer::{Location, PointerButton, PointerId};

        // The real window, not a stand-in: these events propagate to the window when
        // they run out of parents, and a target entity without a `Window` component is
        // traversed to forever.
        let render_target = super::super::testing::window_target(app);
        let surface = app.world_mut().spawn_empty().id();
        app.world_mut().trigger(Pointer {
            entity: target,
            pointer_id: PointerId::Mouse,
            pointer_location: Location { target: render_target, position: Vec2::ZERO },
            event: DragDrop {
                button: PointerButton::Primary,
                dropped,
                hit: HitData::new(surface, 0.0, None, None),
            },
        });
        app.update();
    }

    #[test]
    fn dropping_an_inventory_item_on_a_slot_asks_to_bind_it() {
        let mut app = hotbar_app();
        let item = app
            .world_mut()
            .query::<(Entity, &super::super::character::InventorySlotButton)>()
            .iter(app.world())
            .find(|(_, button)| button.index == 0)
            .map(|(entity, _)| entity)
            .expect("the rail has an inventory");
        let target = slot_entity(&mut app, 6);

        drop_onto(&mut app, item, target);

        let asked = intents(&app);
        assert!(
            asked.iter().any(|intent| matches!(
                intent,
                ao_core::view::Intent::BindHotbarSlot { index: 6, .. }
            )),
            "dropping an item on a slot asked for nothing: {asked:?}"
        );
    }

    #[test]
    fn dropping_something_the_bar_does_not_recognise_asks_for_nothing() {
        let mut app = hotbar_app();
        let stranger = app.world_mut().spawn_empty().id();
        let target = slot_entity(&mut app, 6);

        drop_onto(&mut app, stranger, target);

        assert!(
            intents(&app).is_empty(),
            "an unrecognised drop bound something: {:?}",
            intents(&app)
        );
    }

    #[test]
    fn shift_clicking_a_bound_slot_asks_to_empty_it() {
        let mut app = hotbar_app();
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::ShiftLeft);
        let bound = slot_entity(&mut app, 0);

        activate(&mut app, bound);

        assert!(
            intents(&app).contains(&ao_core::view::Intent::ClearHotbarSlot { index: 0 }),
            "shift-clicking a bound slot did not ask to empty it: {:?}",
            intents(&app)
        );
    }

    #[test]
    fn shift_clicking_an_empty_slot_asks_for_nothing() {
        // The fixture binds three slots, so the eighth is empty. A request to empty an
        // empty slot is a round trip the server can only refuse.
        let mut app = hotbar_app();
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::ShiftLeft);
        let empty = slot_entity(&mut app, 7);

        activate(&mut app, empty);

        assert!(intents(&app).is_empty(), "an empty slot asked to be emptied: {:?}", intents(&app));
    }

    #[test]
    fn the_page_control_asks_for_the_next_page_and_wraps() {
        let mut app = hotbar_app();
        let control = app
            .world_mut()
            .query_filtered::<Entity, With<PageControl>>()
            .iter(app.world())
            .next()
            .expect("the hotbar has a page control");

        activate(&mut app, control);

        // The fixture has two pages and starts on the first.
        assert!(
            intents(&app).contains(&ao_core::view::Intent::ChangeHotbarPage { page: 1 }),
            "the page control asked for nothing: {:?}",
            intents(&app)
        );
    }

    #[test]
    fn slots_are_keyed_one_through_nine_then_zero() {
        // The number row's order, not its numeric order. Labelling the tenth
        // slot "10" would be correct arithmetic and the wrong key.
        let labels: Vec<String> = (0..SLOTS_PER_PAGE).map(slot_key_label).collect();
        assert_eq!(labels, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]);
    }

    #[test]
    fn every_slot_has_a_key_and_no_two_share_one() {
        // A duplicate binding silently makes one slot unreachable.
        let mut seen = Vec::new();
        for index in 0..SLOTS_PER_PAGE {
            let key = slot_key_code(index).expect("every slot on a page is bound");
            assert!(!seen.contains(&key), "slot {index} reuses a key");
            seen.push(key);
        }
    }

    #[test]
    fn the_tenth_slot_is_the_zero_key() {
        assert_eq!(slot_key_code(9), Some(KeyCode::Digit0));
        assert_eq!(slot_key_label(9), "0");
    }

    #[test]
    fn a_slot_beyond_the_page_has_no_key() {
        // Pages beyond the first are reached by the page control, not by
        // inventing keys that do not exist on the number row.
        assert_eq!(slot_key_code(SLOTS_PER_PAGE), None);
        assert_eq!(slot_key_code(99), None);
    }
}
