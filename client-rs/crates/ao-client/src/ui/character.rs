//! The character rail's content: identity, vitals, inventory and equipment.
//!
//! Everything here reads [`UiState`] and writes [`IntentMessage`]. It cannot
//! reach a socket, so nothing on screen can claim an action succeeded — a
//! click asks, and the rail only changes when a new snapshot says it did.
//!
//! That distinction matters more than it sounds. A rail that optimistically
//! moves an item on click looks responsive until the server refuses, and then
//! the item reappears somewhere the player did not put it. Here, refusal is the
//! normal path: intents go out, snapshots come back, and the gap between them
//! is where a pending indicator lives.

use super::controls::{bar_label, rarity_ink, Control, ControlKey};
use super::rail::{CompactVital, CompactVitalFill, RailRegion};
use super::state::UiState;
use super::tokens::{focus, ink, size, space, status, surface, type_scale};
use ao_core::view::{EquipSlot, Gauge, Intent, ItemAction, ItemView, SlotState, UiSnapshot};
use bevy::prelude::*;

/// Which inventory slot the player last clicked.
///
/// Selection is client-side: the server has no opinion about which slot is
/// highlighted, and round-tripping it would make the rail feel laggy for no
/// gain.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SelectedSlot(pub Option<usize>);

/// A drag in progress.
///
/// Held here rather than on the dragged entity so cancelling is a single
/// assignment. A drag that lives on the entity leaks when the grid rebuilds
/// underneath it — which happens on every snapshot.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DragState {
    pub from: Option<usize>,
    pub over: Option<usize>,
}

impl DragState {
    pub fn is_dragging(&self) -> bool {
        self.from.is_some()
    }

    /// Cancel, returning nothing. Escape, a lost pointer, a closed panel and a
    /// rebuilt grid all end here.
    pub fn cancel(&mut self) {
        *self = Self::default();
    }

    /// Finish a drag, yielding the move it represents.
    ///
    /// `None` when the drag ended on its own slot or on nothing, which is a
    /// cancellation rather than a zero-length move — sending that to the server
    /// would be a pointless round trip that can still be refused.
    pub fn complete(&mut self) -> Option<(usize, usize)> {
        let result = match (self.from, self.over) {
            (Some(from), Some(to)) if from != to => Some((from, to)),
            _ => None,
        };
        self.cancel();
        result
    }
}

/// How much of a stack a split dialog will move.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SplitAmount(pub i32);

impl SplitAmount {
    /// Clamp a requested amount to what the stack actually holds.
    ///
    /// Both ends matter: zero is a no-op the server would refuse, and a
    /// quantity above the stack is a desync the client should not propagate.
    pub fn clamped(requested: i32, available: i32) -> i32 {
        requested.clamp(1, available.max(1))
    }
}

pub struct CharacterPanelPlugin;

impl Plugin for CharacterPanelPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<SelectedSlot>()
            .init_resource::<DragState>()
            .init_resource::<SplitAmount>()
            .init_resource::<PendingSlot>()
            .add_observer(begin_slot_drag)
            .add_observer(track_slot_drag_over)
            .add_observer(finish_slot_drag)
            .add_observer(cancel_slot_drag)
            .add_systems(
                Update,
                (
                    // Before the rebuild, so the frame that first sees an item also
                    // asks for its artwork.
                    request_item_graphics,
                    rebuild_on_change,
                    update_compact_vitals,
                    cancel_drag_on_escape,
                    cancel_drag_when_its_destination_becomes_unknowable,
                    clear_selection_when_slot_empties,
                    apply_slot_activations,
                    clear_pending_on_answer,
                )
                    .chain()
                    .after(super::shell::spawn_shell),
            );
    }
}

/// Marks nodes owned by this panel, so a rebuild can clear exactly them.
#[derive(Component)]
pub struct PanelContent;

/// A clickable inventory slot.
#[derive(Component, Debug, Clone, Copy)]
pub struct InventorySlotButton {
    pub index: usize,
}

/// Begin a drag when a slot is dragged rather than clicked.
///
/// Wired to Bevy's own drag events rather than to a hand-rolled press-and-move
/// state machine, so "what counts as a drag" is the platform's answer and matches
/// what the player's cursor is already doing. `DragState` was previously written
/// only by tests: dragging an item did nothing at all.
fn begin_slot_drag(
    start: On<bevy::picking::events::Pointer<bevy::picking::events::DragStart>>,
    slots: Query<&InventorySlotButton>,
    state: Res<UiState>,
    mut drag: ResMut<DragState>,
) {
    let Ok(button) = slots.get(start.entity) else {
        return;
    };
    // An empty slot has nothing to drag. Starting one anyway would let a player
    // "move" nothing onto an occupied slot and expect something to happen.
    if state.get().inventory.slot(button.index).item().is_none() {
        return;
    }
    drag.from = Some(button.index);
    drag.over = None;
}

/// Track which slot a drag is currently over.
fn track_slot_drag_over(
    over: On<bevy::picking::events::Pointer<bevy::picking::events::DragOver>>,
    slots: Query<&InventorySlotButton>,
    mut drag: ResMut<DragState>,
) {
    if !drag.is_dragging() {
        return;
    }
    if let Ok(button) = slots.get(over.entity) {
        drag.over = Some(button.index);
    }
}

/// Complete a drag, emitting a move only for a valid distinct destination.
fn finish_slot_drag(
    drop: On<bevy::picking::events::Pointer<bevy::picking::events::DragDrop>>,
    slots: Query<&InventorySlotButton>,
    state: Res<UiState>,
    mut drag: ResMut<DragState>,
    mut intents: MessageWriter<super::state::IntentMessage>,
) {
    let Ok(button) = slots.get(drop.entity) else {
        return;
    };
    drag.over = Some(button.index);

    // A destination that will not take the item is a cancellation, not a move: a
    // locked slot refuses drops, and sending the move anyway is a round trip the
    // server would only refuse.
    let accepts = state.get().inventory.slot(button.index).accepts_drop();
    if !accepts {
        drag.cancel();
        return;
    }

    // `complete` decides whether this is a move at all: the same slot, or nothing,
    // is a cancellation rather than a zero-length move.
    if let Some((from, to)) = drag.complete() {
        intents.write(super::state::IntentMessage(Intent::MoveInventorySlot { from, to }));
    }
}

/// End a drag that was released anywhere else.
///
/// Released over nothing is a cancellation, and the ghost must go with it — a drag
/// that ends invisibly still holds the interface in a dragging state, and the next
/// click behaves as a drop.
fn cancel_slot_drag(
    _end: On<bevy::picking::events::Pointer<bevy::picking::events::DragEnd>>,
    mut drag: ResMut<DragState>,
) {
    drag.cancel();
}

/// An intent that has been sent and not yet answered.
///
/// The task requires that an accidental double activation cannot emit a duplicate
/// command, and the reason is concrete: two identical use-intents drink two
/// potions. Held by slot rather than as a flag, so activating a *different* slot
/// while one is pending still works — a global lock would make a laggy connection
/// feel like a frozen interface.
#[derive(Resource, Debug, Clone, Default)]
pub struct PendingSlot {
    pub slot: Option<usize>,
    /// Seconds remaining before the guard gives up waiting for an answer.
    ///
    /// A guard with no expiry is a permanently dead control the first time a reply
    /// is dropped, which is worse than the duplicate it prevents.
    pub expires_in: f32,
}

impl PendingSlot {
    /// Whether this slot is already waiting for an answer.
    pub fn blocks(&self, slot: usize) -> bool {
        self.slot == Some(slot) && self.expires_in > 0.0
    }

    fn mark(&mut self, slot: usize) {
        self.slot = Some(slot);
        self.expires_in = PENDING_TIMEOUT_SECS;
    }

    fn clear(&mut self) {
        self.slot = None;
        self.expires_in = 0.0;
    }
}

/// How long an unanswered intent blocks its slot.
const PENDING_TIMEOUT_SECS: f32 = 2.0;

/// How close together two activations count as a double click.
const DOUBLE_CLICK_SECS: f32 = 0.4;

/// Turn slot activations into selection and intents.
///
/// This is what "connect the rendered slots to the interaction system" means, and
/// it was missing: the slots emitted `Activated` and nothing listened, so
/// `click_intent` had no production caller at all and clicking an item did nothing
/// a player could see.
///
/// One activation selects. A second on the same slot, soon enough, is the action.
/// Selection first, because a player who double-clicks still wants the details
/// panel to be showing the thing they acted on.
fn apply_slot_activations(
    mut activated: MessageReader<super::controls::Activated>,
    slots: Query<&InventorySlotButton>,
    keys: Res<ButtonInput<KeyCode>>,
    state: Res<UiState>,
    time: Res<Time>,
    mut selected: ResMut<SelectedSlot>,
    mut pending: ResMut<PendingSlot>,
    mut intents: MessageWriter<super::state::IntentMessage>,
    mut last: Local<Option<(usize, f32)>>,
) {
    let now = time.elapsed_secs();
    if pending.expires_in > 0.0 {
        pending.expires_in = (pending.expires_in - time.delta_secs()).max(0.0);
        if pending.expires_in == 0.0 {
            pending.clear();
        }
    }

    for message in activated.read() {
        let Ok(button) = slots.get(message.entity) else {
            continue;
        };
        let index = button.index;

        let double = matches!(*last, Some((previous, at)) if previous == index && now - at <= DOUBLE_CLICK_SECS);
        *last = Some((index, now));

        selected.0 = Some(index);

        let shift = keys.pressed(KeyCode::ShiftLeft) || keys.pressed(KeyCode::ShiftRight);
        if !double && !shift {
            continue;
        }

        if pending.blocks(index) {
            // Deliberately silent: the player pressed again because the first press
            // looked like it did nothing, and a refusal message would say the
            // interface is broken when it is merely waiting.
            continue;
        }

        let slot = state.get().inventory.slot(index);
        if let Some(intent) = click_intent(slot, index, double, shift) {
            intents.write(super::state::IntentMessage(intent));
            pending.mark(index);
        }
    }
}

/// Release the guard once the authority has answered.
///
/// Any snapshot change counts: the server's reply is a new snapshot, and an
/// accepted action and a rejected one both produce one.
fn clear_pending_on_answer(state: Res<UiState>, mut pending: ResMut<PendingSlot>) {
    if state.is_changed() && pending.slot.is_some() {
        pending.clear();
    }
}

/// Ask the loader for the sheets an item's artwork needs.
///
/// Sheets are fetched for the map tiles in view and nothing else, which is right
/// for the world and leaves the inventory with no artwork at all: every slot
/// resolved to nothing and drew its name instead. The items a player is carrying
/// are a small, bounded set — a handful of sheets — so they are requested as the
/// snapshot names them.
///
/// `Local` remembers what has been asked for, because the snapshot changes far more
/// often than its contents do and a request per heartbeat would refetch the same
/// sheets forever.
fn request_item_graphics(
    state: Res<UiState>,
    graphics: Res<crate::graphics::Graphics>,
    sheets: Res<crate::graphics::SheetTextures>,
    config: Option<Res<crate::config::ClientConfig>>,
    mut requested: Local<std::collections::HashSet<i32>>,
) {
    // Deliberately not gated on `state.is_changed()`. The snapshot's first change is
    // at boot, before the object table has been fetched, so a one-shot gate ran
    // exactly once — too early — and the inventory never got its artwork. The
    // `requested` set is what keeps this cheap: a few dozen ids compared per frame,
    // and each asked for once.
    let Some(config) = config else {
        return;
    };
    let (Some(objects), Some(index)) = (graphics.objects(), graphics.index()) else {
        return;
    };

    let snapshot = state.get();
    let carried = snapshot
        .inventory
        .slots
        .iter()
        .filter_map(|slot| slot.item())
        .chain(snapshot.equipment.worn.iter().map(|(_, item)| item));

    let mut wanted = Vec::new();
    for item in carried {
        let grh_id = objects.get(&item.item_id).copied().unwrap_or(item.icon_grh);
        if !requested.insert(grh_id) {
            continue;
        }
        // Only what is actually missing: a sheet the world already pulled in needs
        // no second fetch.
        if let Some(grh) = index.resolve(grh_id) {
            if !sheets.0.contains_key(&grh.sheet) {
                wanted.push(grh_id);
            }
        }
    }

    if !wanted.is_empty() {
        crate::net::start_graphics_load(graphics.clone(), config.asset_origin.clone(), wanted);
    }
}

/// A resolved item icon: the sheet, the atlas and the region inside it.
///
/// Resolved once per rebuild and handed to the slots, because resolution needs
/// resources a pure builder cannot hold — and threading the resources themselves
/// into every builder would put atlas bookkeeping inside the presentation.
#[derive(Clone)]
pub struct ItemIcon {
    image: Handle<Image>,
    layout: Handle<TextureAtlasLayout>,
    index: usize,
}

#[allow(clippy::too_many_arguments)]
fn rebuild_on_change(
    state: Res<UiState>,
    selected: Res<SelectedSlot>,
    drag: Res<DragState>,
    geometry: Res<super::shell::AppliedGeometry>,
    ui_scale: Res<UiScale>,
    // Full-rail regions only. The compact strip carries the same RailRegion
    // markers — it is the same region, presented differently — and without this
    // filter the labelled bars were spawned into the 56px strip as well, on top
    // of the slivers, overflowing it. That is what the compact capture showed.
    regions: Query<(Entity, &RailRegion), With<super::shell::FullRailOnly>>,
    existing: Query<Entity, With<PanelContent>>,
    graphics: Res<crate::graphics::Graphics>,
    sheets: Res<crate::graphics::SheetTextures>,
    mut atlases: ResMut<crate::world::SheetAtlases>,
    mut layouts: ResMut<Assets<TextureAtlasLayout>>,
    mut last_drawable: Local<usize>,
    mut commands: Commands,
) {
    // Artwork arrives asynchronously, long after the snapshot that named it, and
    // nothing else in this condition changes when it does — so the grid kept
    // whatever it drew when the items first appeared, which is the name fallback,
    // for the rest of the session.
    //
    // Counted as "carried items whose artwork is available *now*", not as "how many
    // sheets exist". The sheet count is decided by a system in another plugin, and
    // this one can run before it in a frame: the count then changes, the rebuild
    // happens against the sheets from before the upload, and the count never changes
    // again. That left exactly one item — the staff, whose sheet arrived in a later
    // batch than the potions — permanently on its fallback.
    let index = graphics.index();
    let drawable = state
        .get()
        .inventory
        .slots
        .iter()
        .filter_map(|slot| slot.item())
        .filter(|item| {
            let grh_id = graphics
                .objects()
                .and_then(|table| table.get(&item.item_id).copied())
                .unwrap_or(item.icon_grh);
            index
                .as_ref()
                .and_then(|index| index.resolve(grh_id))
                .is_some_and(|grh| sheets.0.contains_key(&grh.sheet))
        })
        .count();
    let artwork_arrived = *last_drawable != drawable;
    *last_drawable = drawable;

    if !state.is_changed()
        && !selected.is_changed()
        && !drag.is_changed()
        && !geometry.is_changed()
        && !artwork_arrived
    {
        return;
    }

    for entity in &existing {
        commands.entity(entity).despawn();
    }

    // No layout yet means no rail width, and the grid's column count is derived
    // from it. Rebuilding against a guess produces a grid that has to be thrown
    // away one frame later.
    let Some(shell) = geometry.0 else {
        return;
    };

    let snapshot = state.get();

    // Item artwork, through the same resolution the world uses to draw the item on
    // the ground. `None` for a graphic whose sheet has not arrived, or that the
    // index does not know — the slot then draws its fallback, which is visible
    // rather than empty.
    // The game's own object table maps an item id to its graphic. Preferred over the
    // view model's `icon_grh`, which fixtures fill with plausible-looking numbers
    // that are not real graphics — every one resolved to nothing, and every slot
    // drew its fallback. The field remains the override for items the table does
    // not cover.
    let objects = graphics.objects();
    let mut icon_for = |item: &ItemView| -> Option<ItemIcon> {
        let grh_id = objects
            .as_ref()
            .and_then(|table| table.get(&item.item_id).copied())
            .unwrap_or(item.icon_grh);
        let grh = index.as_ref()?.resolve(grh_id)?;
        let (image, layout, atlas_index) =
            crate::world::resolve_grh(&sheets, &mut atlases, &mut layouts, &grh)?;
        Some(ItemIcon { image, layout, index: atlas_index })
    };
    for (entity, region) in &regions {
        match region {
            RailRegion::CharacterHeader => {
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((PanelContent, character_header(snapshot)));
                });
            }
            RailRegion::SlotGrid => {
                // In the units the slots are declared in. Bevy multiplies every
                // Val::Px by the UI scale, so a width measured in logical
                // pixels would let six 43-unit slots be laid out into a space
                // that is only three of them wide once scaled.
                let inner = grid_inner_width(shell.rail.width() / ui_scale.0.max(0.001));
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((
                        PanelContent,
                        inventory_grid(snapshot, selected.0, drag.over, inner, &mut icon_for),
                    ));
                });
            }
            RailRegion::SelectedDetails => {
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((PanelContent, selected_details(snapshot, selected.0)));
                });
            }
            RailRegion::Equipment => {
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((PanelContent, equipment_summary(snapshot, &mut icon_for)));
                });
            }
            RailRegion::Vitals => {
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((PanelContent, vitals_stack(snapshot)));
                });
            }
            _ => {}
        }
    }
}

fn text(value: impl Into<String>, font_size: f32, color: Color) -> impl Bundle {
    (Text::new(value.into()), TextFont { font_size, ..default() }, TextColor(color))
}

fn column(gap: f32) -> Node {
    Node {
        width: Val::Percent(100.0),
        flex_direction: FlexDirection::Column,
        row_gap: Val::Px(gap),
        ..default()
    }
}

/// A centred column, for the character header.
fn centred_column(gap: f32) -> Node {
    Node { align_items: AlignItems::Center, ..column(gap) }
}

fn character_header(snapshot: &UiSnapshot) -> impl Bundle {
    let progression = &snapshot.progression;
    // A loading snapshot has no name yet. An em dash says "not known" where a
    // blank line reads as a rendering fault.
    let name =
        if progression.name.is_empty() { "—".to_string() } else { progression.name.clone() };
    let subtitle = format!("{} · level {}", progression.class_key, progression.level);

    (
        centred_column(space::TIGHT),
        children![
            text(name, type_scale::TITLE, ink::GOLD),
            text(subtitle, type_scale::SMALL, ink::MUTED),
            experience_bar(progression.experience),
            world_row(&snapshot.world),
            currency_row(progression.gold),
        ],
    )
}

/// The world's time and whether this place is safe.
///
/// Between the experience bar and the currency row, which is where the task puts it.
/// The two facts share a line because together they answer one question — is it safe
/// to be here right now — and time alone is trivia in a game where night changes what
/// spawns.
fn world_row(world: &ao_core::view::WorldStatus) -> impl Bundle {
    let (hour, minute) = world.clock();
    // Safety is a word, not a colour: the palette separates surfaces by very little
    // and this is the one line a player checks before committing to a fight.
    let (safety, ink_colour) =
        if world.safe_area { ("segura", ink::MUTED) } else { ("hostil", status::DANGER) };

    (
        Node {
            width: Val::Percent(100.0),
            justify_content: JustifyContent::SpaceBetween,
            align_items: AlignItems::Center,
            padding: UiRect::horizontal(Val::Px(space::SNUG)),
            ..default()
        },
        children![
            text(format!("{hour:02}:{minute:02}"), type_scale::MICRO, ink::MUTED),
            text(safety, type_scale::MICRO, ink_colour),
        ],
    )
}

/// Currency, as a row rather than a line under the name.
///
/// The task is explicit that gold must not consume the identity header when it can
/// be scanned in a currency row. The distinction is what the header is *for*: it
/// answers "who am I", and a number that changes every time something is sold does
/// not belong in the same breath as a character's name. As a labelled row it is
/// scanned rather than read.
fn currency_row(gold: i64) -> impl Bundle {
    (
        Node {
            width: Val::Percent(100.0),
            justify_content: JustifyContent::SpaceBetween,
            align_items: AlignItems::Center,
            padding: UiRect::horizontal(Val::Px(space::SNUG)),
            ..default()
        },
        children![
            text("oro", type_scale::MICRO, ink::MUTED),
            // Right-aligned and in the gold ink, so the eye finds the amount
            // without reading the label first.
            text(format!("{}", gold.max(0)), type_scale::SMALL, ink::GOLD),
        ],
    )
}

/// The XP bar, with its percentage drawn inside it.
fn experience_bar(experience: Gauge) -> impl Bundle {
    let percent = experience.fraction() * 100.0;
    (
        Node {
            width: Val::Percent(100.0),
            // The header centres its children, which makes a 100%-width bar
            // collapse to its content — the track vanished and the fill became
            // a small square floating in the middle of the panel.
            align_self: AlignSelf::Stretch,
            height: Val::Px(size::STATUS_BAR_HEIGHT),
            justify_content: JustifyContent::Center,
            align_items: AlignItems::Center,
            // The fill is absolutely positioned; without this it draws past the
            // track's rounded end and over whatever is beside it.
            border: UiRect::all(Val::Px(size::BORDER)),
            overflow: Overflow::clip(),
            ..default()
        },
        BackgroundColor(surface::WELL),
        // Outlined, or an empty track is indistinguishable from bare panel:
        // the well and the panel differ by 1.05:1, which is deliberate — the
        // reference is just as dark — and means the border is what makes a bar
        // read as a bar at all.
        BorderColor::all(surface::EDGE),
        children![
            (
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(0.0),
                    top: Val::Px(0.0),
                    bottom: Val::Px(0.0),
                    width: Val::Percent(percent),
                    ..default()
                },
                BackgroundColor(status::EXPERIENCE),
            ),
            text(format!("{percent:.1}%"), type_scale::SMALL, ink::PRIMARY),
        ],
    )
}

fn vitals_stack(snapshot: &UiSnapshot) -> impl Bundle {
    let vitals = snapshot.vitals;
    (
        column(space::HAIR),
        children![
            // The three that decide a fight, full width and stacked, as in the
            // reference composition.
            vital_bar("HP", vitals.health, status::HEALTH),
            vital_bar("Mana", vitals.mana, status::MANA),
            vital_bar("Sta", vitals.stamina, status::STAMINA),
            // Hunger and thirst change over minutes rather than seconds, so
            // they share a row and give their height back to the world.
            (
                Node { width: Val::Percent(100.0), column_gap: Val::Px(space::HAIR), ..default() },
                children![
                    half_width(vital_bar("Food", vitals.hunger, status::HUNGER)),
                    half_width(vital_bar("Water", vitals.thirst, status::THIRST)),
                ],
            ),
        ],
    )
}

/// Wrap a bar so two sit side by side.
fn half_width(inner: impl Bundle) -> impl Bundle {
    (Node { flex_grow: 1.0, flex_basis: Val::Px(0.0), ..default() }, children![inner])
}

/// One vital, with its numbers inside the bar.
///
/// Delegates to the shared control rather than repeating it. This panel had its
/// own copy — same track, same absolute fill, same centred label — which is two
/// implementations of one control and therefore two places for a token change to
/// land or not land.
///
/// The label is always present, so colour is never the only thing carrying the
/// meaning, which is what makes the palette usable for colour-blind players.
fn vital_bar(prefix: &str, gauge: Gauge, fill: Color) -> impl Bundle {
    super::controls::status_bar(prefix, gauge, fill)
}

/// Width the slot grid actually has, inside a rail of `rail_width`.
///
/// Every inset between the rail's edge and the slots has to be subtracted, and
/// missing one is not a cosmetic error: overflowing by a single pixel makes
/// flex wrap the sixth slot onto its own row, so the grid silently becomes five
/// columns and the last rows fall out of the panel. That is exactly what
/// happened when the region's border was left out of this sum.
pub fn grid_inner_width(rail_width: f32) -> f32 {
    let rail_padding = space::BASE * 2.0;
    let region_border = size::BORDER * 2.0;
    // No padding of its own: the reference grid sits flush inside its well, and
    // six 43-pixel slots plus their gaps need every pixel of a 280-pixel rail.
    let grid_padding = 0.0;
    // A pixel of slack, because the layout engine rounds and a grid that fits
    // exactly is one rounding step from not fitting.
    (rail_width - rail_padding - region_border - grid_padding - 1.0).max(0.0)
}

/// Slot size that fits `columns` of them across `available` logical pixels.
///
/// The grid is fixed at six columns to match the reference composition, but the
/// rail is a share of the window and at 1280 wide it is only about 260 pixels
/// inside its padding — less than six 44-pixel slots plus their gaps. Laid out
/// at a fixed size the row wrapped after five and the last rows fell out of the
/// panel entirely.
pub fn slot_size(available: f32, columns: usize) -> f32 {
    let columns = columns.max(1) as f32;
    let gaps = (columns - 1.0) * space::GRID_GAP;
    let fitted = (available - gaps) / columns;
    // Never larger than the design size, and never so small it stops being a
    // target: below this the compact rail is the right answer instead.
    fitted.clamp(24.0, size::SLOT).floor()
}

fn inventory_grid(
    snapshot: &UiSnapshot,
    selected: Option<usize>,
    drag_over: Option<usize>,
    rail_width: f32,
    icon_for: &mut dyn FnMut(&ItemView) -> Option<ItemIcon>,
) -> impl Bundle {
    let inventory = &snapshot.inventory;
    let columns = inventory.columns.max(1);
    let slot = slot_size(rail_width, columns);

    // Bounded to exactly `columns` slots wide. Left at 100% the row wraps by
    // available width instead, so a maximised window with a 420-pixel rail laid
    // the six-column grid out as eight — the reference composition silently
    // became a different one at a different window size.
    let grid_width = slot * columns as f32 + space::GRID_GAP * (columns - 1) as f32;

    (
        Node {
            width: Val::Px(grid_width),
            // Centred, because the grid is capped at its design slot size while
            // the rail is a share of the window: on an ultrawide the rail is
            // 757 logical pixels and the grid only fills 516 of them. Left
            // aligned, the remainder reads as a black column someone forgot to
            // fill rather than as margin.
            margin: UiRect::horizontal(Val::Auto),
            flex_direction: FlexDirection::Row,
            flex_wrap: FlexWrap::Wrap,
            column_gap: Val::Px(space::GRID_GAP),
            row_gap: Val::Px(space::GRID_GAP),
            ..default()
        },
        Children::spawn(SpawnIter({
            // Icons resolved here, while the resources are still borrowable, and
            // moved into the iterator: the closure that spawns each slot runs later
            // and cannot hold them.
            let slots = inventory.slots.clone();
            let icons: Vec<Option<ItemIcon>> =
                slots.iter().map(|slot| slot.item().and_then(|item| icon_for(item))).collect();
            (0..slots.len())
                .map(move |index| (index, selected, drag_over))
                .collect::<Vec<_>>()
                .into_iter()
                .map(move |(index, selected, drag_over)| {
                    inventory_slot(
                        &slots[index],
                        index,
                        selected,
                        drag_over,
                        slot,
                        icons[index].clone(),
                    )
                })
        })),
    )
}

fn inventory_slot(
    slot: &SlotState,
    index: usize,
    selected: Option<usize>,
    drag_over: Option<usize>,
    size_px: f32,
    icon: Option<ItemIcon>,
) -> impl Bundle {
    let is_selected = selected == Some(index);
    let is_drop_target = drag_over == Some(index) && slot.accepts_drop();
    let locked = matches!(slot, SlotState::Locked);

    let border = if is_selected {
        focus::SELECTED
    } else if is_drop_target {
        focus::RING
    } else {
        surface::EDGE
    };

    // Each child carries its own node so the quantity and the equipped marker can
    // sit in corners rather than across the artwork. The task asks for corner
    // overlays, and the reason is legibility: "498" printed over a potion obscures
    // the one thing the icon is there to convey.
    let mut children: Vec<(Node, Text, TextFont, TextColor)> = Vec::new();
    let centred = Node::default();
    let corner = |bottom: bool| Node {
        position_type: PositionType::Absolute,
        right: Val::Px(space::HAIR),
        top: if bottom { Val::Auto } else { Val::Px(space::HAIR) },
        bottom: if bottom { Val::Px(space::HAIR) } else { Val::Auto },
        ..default()
    };
    match slot {
        // Locked slots are shown, not hidden: a player can see what expanding
        // the pack would buy.
        SlotState::Locked => {
            // Not the padlock emoji: it is outside the font's basic plane and
            // rendered as an empty box, which is exactly what an unexplained
            // locked slot must not look like.
            children.push((
                centred.clone(),
                Text::new("\u{00b7}\u{00b7}"),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::DISABLED),
            ));
        }
        SlotState::Filled(item) => {
            // The name is the *fallback*, drawn only when the artwork is not
            // available — an unknown graphic, or a sheet still arriving. A slot that
            // shows neither is indistinguishable from an empty one, which is the
            // failure this avoids; the task calls for a stable visible fallback and
            // this is it.
            if icon.is_none() {
                children.push((
                    centred.clone(),
                    Text::new(short_name(item)),
                    TextFont { font_size: type_scale::MICRO, ..default() },
                    TextColor(rarity_ink(item.rarity)),
                ));
            }
            if item.shows_quantity() {
                children.push((
                    corner(true),
                    Text::new(item.display_quantity().to_string()),
                    TextFont { font_size: type_scale::MICRO, ..default() },
                    TextColor(ink::PRIMARY),
                ));
            }
            if item.equipped {
                children.push((
                    corner(false),
                    Text::new("E"),
                    TextFont { font_size: type_scale::MICRO, ..default() },
                    TextColor(ink::GOLD),
                ));
            }
        }
        SlotState::Empty => {}
    }

    (
        Node {
            width: Val::Px(size_px),
            height: Val::Px(size_px),
            flex_direction: FlexDirection::Column,
            align_items: AlignItems::Center,
            justify_content: JustifyContent::Center,
            border: UiRect::all(Val::Px(size::BORDER)),
            // Until slots draw their artwork, they hold a name, and a long one
            // ran across its neighbours and out of the panel. Clipping is the
            // honest stopgap: a truncated name is legibly truncated, where an
            // overflowing one silently corrupts the row.
            overflow: Overflow::clip(),
            ..default()
        },
        BackgroundColor(if locked { surface::VOID } else { surface::WELL }),
        BorderColor::all(border),
        // The artwork, on the slot itself rather than as a child: a UI node can be
        // both a container and an image, so the quantity and equipped markers draw
        // over the icon without a second layer to keep aligned.
        //
        // Stretched to the slot and nearest-sampled. A 32-pixel graphic in a
        // 43-pixel slot is not an integer multiple, so it is not pixel-exact; making
        // it so needs the slot sized from the artwork, which is a change to the
        // reference composition rather than to this function.
        match &icon {
            Some(icon) => ImageNode {
                image: icon.image.clone(),
                texture_atlas: Some(TextureAtlas {
                    layout: icon.layout.clone(),
                    index: icon.index,
                }),
                ..default()
            },
            // Invisible rather than absent: `ImageNode::default()` carries the
            // engine's white placeholder, which would draw a white square over every
            // empty slot.
            None => ImageNode { color: Color::NONE, ..default() },
        },
        InventorySlotButton { index },
        // Keyed so focus survives the grid being rebuilt, which happens on
        // every snapshot and every resize.
        ControlKey::indexed("inventory.slot", index),
        // The shared contract, not `Control` alone: this carried `Control` and no
        // `Button`, so it had no `Interaction` and the pointer pipeline could not
        // see it. Clicking an inventory slot did nothing.
        super::controls::interactive(100 + index as u32, !locked),
        Children::spawn(SpawnIter(children.into_iter())),
    )
}

/// The last segment of a localisation key, as a stand-in until the catalogue
/// exists.
///
/// Deliberately derived from the key rather than hard-coded: the fixtures carry
/// keys precisely so the localisation path is exercised, and inventing display
/// names here would quietly bypass it.
fn short_name(item: &ItemView) -> String {
    super::fallback_label(&item.name_key)
}

fn selected_details(snapshot: &UiSnapshot, selected: Option<usize>) -> impl Bundle {
    // One call site, not two branches: `text` is generic over `Into<String>`,
    // so a `&str` branch and a `String` branch instantiate different types and
    // cannot both be the function's single opaque return type.
    let (detail, colour) = match selected.and_then(|index| snapshot.inventory.slot(index).item()) {
        Some(item) => {
            (format!("{} ×{}", short_name(item), item.display_quantity()), rarity_ink(item.rarity))
        }
        None => ("select an item".to_string(), ink::MUTED),
    };

    (column(space::TIGHT), children![text(detail, type_scale::BODY, colour)])
}

/// Equipment as a row of slots, not a list of names.
///
/// The task forbids "a permanent list of raw item names" here, and the reason is
/// space: six lines of `Weapon: oak` fill a third of the rail to say almost
/// nothing, and the one line a player actually wants — what is in their hand right
/// now — is no easier to find than the five they do not. Six small squares are
/// scanned in one glance, and the full name lives in the tooltip and in the
/// selection details, which is where a player goes when they want it.
///
/// Empty slots are drawn rather than hidden, so the shape of the row is constant
/// and a missing shield is visibly missing rather than absent.
fn equipment_summary(
    snapshot: &UiSnapshot,
    icon_for: &mut dyn FnMut(&ItemView) -> Option<ItemIcon>,
) -> impl Bundle {
    let cells: Vec<_> = EquipSlot::ALL
        .iter()
        .map(|slot| {
            let worn = snapshot.equipment.in_slot(*slot);
            let icon = worn.and_then(|item| icon_for(item));
            equipment_cell(*slot, worn, icon)
        })
        .collect();

    (
        Node {
            width: Val::Percent(100.0),
            flex_direction: FlexDirection::Row,
            flex_wrap: FlexWrap::Wrap,
            column_gap: Val::Px(space::GRID_GAP),
            row_gap: Val::Px(space::GRID_GAP),
            justify_content: JustifyContent::Center,
            ..default()
        },
        Children::spawn(SpawnIter(cells.into_iter())),
    )
}

/// One equipment slot.
fn equipment_cell(slot: EquipSlot, worn: Option<&ItemView>, icon: Option<ItemIcon>) -> impl Bundle {
    // Until item artwork is drawn here, the first characters of the derived name
    // stand in — enough to tell an oak staff from an apprentice robe at a glance,
    // which is what the row is for. The full name is one hover away.
    let label = worn
        .map(|item| super::fallback_label(&item.name_key).chars().take(3).collect::<String>())
        .unwrap_or_else(|| "·".to_string());

    // The accessible name is the *item* when there is one and the *slot* when there
    // is not, so a tooltip on an empty slot says what could go there.
    let name_key =
        worn.map(|item| item.name_key.clone()).unwrap_or_else(|| slot.name_key().to_string());

    let filled = worn.is_some();
    let count = worn.map(|item| item.display_quantity()).unwrap_or(0);

    (
        Node {
            width: Val::Px(size::SLOT * 0.72),
            height: Val::Px(size::SLOT * 0.72),
            border: UiRect::all(Val::Px(size::BORDER)),
            justify_content: JustifyContent::Center,
            align_items: AlignItems::Center,
            overflow: Overflow::clip(),
            ..default()
        },
        BackgroundColor(if filled { surface::RAISED } else { surface::WELL }),
        // Equipped is marked by the border as well as the fill, since two dark
        // browns are not a distinction.
        BorderColor::all(if filled { focus::SELECTED } else { surface::EDGE }),
        match &icon {
            Some(icon) => ImageNode {
                image: icon.image.clone(),
                texture_atlas: Some(TextureAtlas {
                    layout: icon.layout.clone(),
                    index: icon.index,
                }),
                ..default()
            },
            None => ImageNode { color: Color::NONE, ..default() },
        },
        super::icons::AccessibleName::new(&name_key),
        super::icons::ShowsTooltip,
        children![(
            Node {
                flex_direction: FlexDirection::Column,
                align_items: AlignItems::Center,
                ..default()
            },
            children![
                text(label, type_scale::MICRO, if filled { ink::PRIMARY } else { ink::DISABLED }),
                // A concise counter, and only where it means something: ammunition
                // has a count, a helmet does not.
                text(
                    if count > 1 { format!("{count}") } else { String::new() },
                    type_scale::MICRO,
                    ink::MUTED
                ),
            ],
        )],
    )
}

/// Fill the compact rail's vital slivers from the snapshot.
///
/// The full rail rebuilds its whole subtree; the slivers are updated in place
/// instead, because they are five nodes that never change shape and rebuilding
/// them would throw away the navigation focus beside them on every heartbeat.
fn update_compact_vitals(
    state: Res<UiState>,
    slivers: Query<&Children, With<CompactVital>>,
    mut fills: Query<&mut Node, With<CompactVitalFill>>,
) {
    if !state.is_changed() {
        return;
    }

    let vitals = state.get().vitals;
    let gauges = [vitals.health, vitals.mana, vitals.stamina, vitals.hunger, vitals.thirst];

    for (children, gauge) in slivers.iter().zip(gauges) {
        for child in children.iter() {
            if let Ok(mut node) = fills.get_mut(child) {
                node.width = Val::Percent(gauge.fraction() * 100.0);
            }
        }
    }
}

/// Escape cancels a drag.
///
/// Also fires when the pointer leaves the window, because a drag that survives
/// losing the pointer reattaches to whatever is under the cursor when it comes
/// back.
/// End a drag whenever the thing being dragged onto stops being knowable.
///
/// The task names four of these beyond Escape: the pointer leaving the window,
/// focus loss, the panel closing and the grid rebuilding. They share one reason —
/// a drag is a promise about a destination, and each of these destroys the
/// client's knowledge of where the pointer is or what is under it. A drag that
/// survives becomes a move to a slot the player never chose.
fn cancel_drag_when_its_destination_becomes_unknowable(
    pointer: Res<super::pointer::PointerState>,
    windows: Query<&Window>,
    mut drag: ResMut<DragState>,
) {
    if !drag.is_dragging() {
        return;
    }

    // The pointer left the window, so there is no destination any more. Reported
    // as `Outside` or as no target at all, depending on how it left.
    let lost_pointer = !matches!(pointer.target, Some(super::pointer::PointerTarget::Interface))
        && pointer.position.is_none();
    // Focus loss. A drag continuing while the player is in another window ends
    // wherever the pointer happens to be when they come back.
    let lost_focus = windows.iter().next().is_some_and(|window| !window.focused);

    if lost_pointer || lost_focus {
        drag.cancel();
    }
}

fn cancel_drag_on_escape(keys: Res<ButtonInput<KeyCode>>, mut drag: ResMut<DragState>) {
    if drag.is_dragging() && keys.just_pressed(KeyCode::Escape) {
        drag.cancel();
    }
}

/// Drop a selection whose slot no longer holds anything.
///
/// The snapshot is authoritative: an item consumed, dropped or moved by the
/// server leaves the selection pointing at an empty slot, and the detail panel
/// would keep describing something the player no longer has.
fn clear_selection_when_slot_empties(state: Res<UiState>, mut selected: ResMut<SelectedSlot>) {
    if !state.is_changed() {
        return;
    }
    let Some(index) = selected.0 else {
        return;
    };
    if state.get().inventory.slot(index).item().is_none() {
        selected.0 = None;
    }
}

/// Turn a click into the intent it means.
///
/// Kept as a function so the mapping is testable without a pointer: the risk
/// here is a modifier silently doing the wrong thing, which no amount of
/// staring at a screenshot catches.
pub fn click_intent(
    slot: &SlotState,
    index: usize,
    double_click: bool,
    shift: bool,
) -> Option<Intent> {
    let item = slot.item()?;

    if shift && item.display_quantity() > 1 {
        // Shift-click splits rather than dropping the whole stack; dropping 498
        // potions because a modifier was held is not recoverable.
        return Some(Intent::DropInventorySlot { slot: index, amount: 1 });
    }
    if double_click {
        // From the item's own metadata, never from its stack size. The previous
        // rule treated anything not stackable as equipment, which called the last
        // potion of a stack a sword — the guess got worse as a player's inventory
        // emptied, which is the worst possible direction for it to fail in.
        //
        // An item that is already equipped is still Equip, so a second activation
        // takes it off rather than doing nothing.
        return match item.action {
            ItemAction::Equip => Some(Intent::EquipInventorySlot { slot: index }),
            ItemAction::Use | ItemAction::Open => Some(Intent::UseInventorySlot { slot: index }),
            // Nothing happens, and nothing is sent: a quest token that produces a
            // rejected intent teaches a player that the interface is unreliable.
            ItemAction::Inert => None,
        };
    }
    None
}

#[cfg(test)]
mod tests {
    use super::super::controls::bar_fill_width;
    use super::*;
    use ao_core::fixtures::{self, Scenario};
    use ao_core::view::Rarity;

    /// A slot holding an item that does `action`.
    fn slot_doing(action: ItemAction, quantity: i32) -> SlotState {
        SlotState::Filled(ItemView {
            item_id: 7,
            name_key: "item.test".into(),
            quantity,
            equipped: false,
            rarity: Rarity::Common,
            icon_grh: 1,
            action,
        })
    }

    /// An app with the drag cancellations and a drag already in progress.
    fn dragging_app(focused: bool, pointer: super::super::pointer::PointerState) -> App {
        let mut app = App::new();
        app.insert_resource(DragState { from: Some(2), over: Some(5) })
            .insert_resource(pointer)
            .add_systems(Update, cancel_drag_when_its_destination_becomes_unknowable);
        let mut window = Window::default();
        window.focused = focused;
        app.world_mut().spawn(window);
        app
    }

    #[test]
    fn a_drag_ends_when_the_pointer_leaves_the_window() {
        // A drag is a promise about a destination. Once the pointer is gone the
        // client no longer knows what is under it, and a drag that survives becomes
        // a move to a slot the player never chose.
        use super::super::pointer::PointerState;

        let mut app = dragging_app(true, PointerState::default());
        app.update();
        assert!(
            !app.world().resource::<DragState>().is_dragging(),
            "a drag survived the pointer leaving the window"
        );
    }

    #[test]
    fn a_drag_ends_when_the_window_loses_focus() {
        // Otherwise it ends wherever the pointer happens to be when the player
        // comes back from another window.
        use super::super::pointer::{PointerState, PointerTarget};

        let over_interface = PointerState {
            position: Some(Vec2::new(100.0, 100.0)),
            target: Some(PointerTarget::Interface),
            tile: None,
        };
        let mut app = dragging_app(false, over_interface);
        app.update();
        assert!(
            !app.world().resource::<DragState>().is_dragging(),
            "a drag survived the window losing focus"
        );
    }

    #[test]
    fn a_drag_over_the_interface_in_a_focused_window_continues() {
        // The cancellations must not be so eager that an ordinary drag across the
        // rail cancels itself halfway.
        use super::super::pointer::{PointerState, PointerTarget};

        let over_interface = PointerState {
            position: Some(Vec2::new(100.0, 100.0)),
            target: Some(PointerTarget::Interface),
            tile: None,
        };
        let mut app = dragging_app(true, over_interface);
        app.update();
        assert!(
            app.world().resource::<DragState>().is_dragging(),
            "an ordinary drag across the interface cancelled itself"
        );
        assert_eq!(app.world().resource::<DragState>().over, Some(5));
    }

    /// An app with the activation pipeline and a populated inventory.
    fn activation_app() -> (App, Entity) {
        let mut app = App::new();
        app.init_resource::<UiState>()
            .init_resource::<SelectedSlot>()
            .init_resource::<PendingSlot>()
            .insert_resource(ButtonInput::<KeyCode>::default())
            .insert_resource(Time::<()>::default())
            .add_message::<super::super::controls::Activated>()
            .add_message::<super::super::state::IntentMessage>()
            .init_resource::<Recorded>()
            .add_systems(
                Update,
                (apply_slot_activations, record_intents, clear_pending_on_answer).chain(),
            );
        UiState::set(
            &mut app.world_mut().resource_mut::<UiState>(),
            fixtures::snapshot(Scenario::Populated),
        );

        // A real slot entity, as the grid spawns them.
        let slot = app.world_mut().spawn(InventorySlotButton { index: 0 }).id();
        app.update();
        (app, slot)
    }

    fn activate(app: &mut App, slot: Entity) {
        app.world_mut().write_message(super::super::controls::Activated {
            entity: slot,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();
    }

    /// Every intent emitted since the app started.
    ///
    /// Accumulated by a system rather than read with a fresh cursor: `Messages` are
    /// double-buffered and drop after a couple of frames, so reading them at the end
    /// of a multi-frame test measures the buffer's retention rather than what the
    /// client sent. Two of these tests failed that way before this existed.
    #[derive(Resource, Default)]
    struct Recorded(Vec<Intent>);

    fn record_intents(
        mut messages: MessageReader<super::super::state::IntentMessage>,
        mut recorded: ResMut<Recorded>,
    ) {
        for message in messages.read() {
            recorded.0.push(message.0.clone());
        }
    }

    fn intents(app: &App) -> Vec<Intent> {
        app.world().resource::<Recorded>().0.clone()
    }

    #[test]
    fn one_click_selects_and_sends_nothing() {
        // Selecting is free; acting is not. A single click that used the item would
        // make the inventory dangerous to browse.
        let (mut app, slot) = activation_app();
        activate(&mut app, slot);

        assert_eq!(app.world().resource::<SelectedSlot>().0, Some(0));
        assert!(intents(&app).is_empty(), "a single click sent {:?}", intents(&app));
    }

    #[test]
    fn a_double_click_sends_exactly_one_intent() {
        // Exactly one: the task's word. Two use-intents drink two potions.
        let (mut app, slot) = activation_app();
        activate(&mut app, slot);
        activate(&mut app, slot);

        let sent = intents(&app);
        assert_eq!(sent.len(), 1, "a double click sent {} intents: {sent:?}", sent.len());
        assert_eq!(sent[0], Intent::UseInventorySlot { slot: 0 });
    }

    #[test]
    fn hammering_a_slot_while_it_waits_sends_nothing_more() {
        // The guard the task asks for. A player whose first click looked like it did
        // nothing clicks again, and again — and each extra one would be another
        // potion.
        let (mut app, slot) = activation_app();
        activate(&mut app, slot);
        activate(&mut app, slot);
        assert_eq!(intents(&app).len(), 1);

        for _ in 0..6 {
            activate(&mut app, slot);
        }
        let sent = intents(&app);
        assert_eq!(sent.len(), 1, "hammering produced {} intents", sent.len());
    }

    #[test]
    fn the_guard_lifts_when_the_authority_answers() {
        // Held forever, it would be a dead control the first time a reply is lost.
        let (mut app, slot) = activation_app();
        activate(&mut app, slot);
        activate(&mut app, slot);
        assert!(app.world().resource::<PendingSlot>().blocks(0));

        // The server's answer is a new snapshot, accepted or rejected alike.
        UiState::set(
            &mut app.world_mut().resource_mut::<UiState>(),
            fixtures::snapshot(Scenario::Rejected),
        );
        app.update();
        assert!(
            !app.world().resource::<PendingSlot>().blocks(0),
            "the guard survived the authority answering"
        );
    }

    #[test]
    fn a_pending_slot_does_not_block_a_different_one() {
        // A global lock would make a laggy connection feel like a frozen interface.
        let (mut app, first) = activation_app();
        let second = app.world_mut().spawn(InventorySlotButton { index: 1 }).id();
        app.update();

        activate(&mut app, first);
        activate(&mut app, first);
        assert_eq!(intents(&app).len(), 1);

        activate(&mut app, second);
        activate(&mut app, second);
        let sent = intents(&app);
        assert_eq!(sent.len(), 2, "a pending slot blocked an unrelated one: {sent:?}");
    }

    #[test]
    fn activation_comes_from_the_item_and_not_from_its_stack_size() {
        // The two cases the previous rule got wrong. It treated anything with a
        // count of one as equipment, so the last potion of a stack was a sword —
        // and the guess grew *more* wrong as a player's inventory emptied, which is
        // the worst direction for a guess to fail in.
        let last_potion = slot_doing(ItemAction::Use, 1);
        assert_eq!(
            click_intent(&last_potion, 3, true, false),
            Some(Intent::UseInventorySlot { slot: 3 }),
            "a single-copy consumable was treated as equipment"
        );

        // And a non-stackable piece of equipment is still equipment.
        let sword = slot_doing(ItemAction::Equip, 1);
        assert_eq!(
            click_intent(&sword, 4, true, false),
            Some(Intent::EquipInventorySlot { slot: 4 }),
            "equipment was treated as a consumable"
        );

        // A large stack of equipment — arrows, say — is equipment too, which the old
        // quantity rule also got backwards.
        let arrows = slot_doing(ItemAction::Equip, 500);
        assert_eq!(
            click_intent(&arrows, 5, true, false),
            Some(Intent::EquipInventorySlot { slot: 5 })
        );
    }

    #[test]
    fn an_inert_item_sends_nothing_at_all() {
        // A quest token that produces a rejected intent teaches a player that the
        // interface is unreliable. Better to do nothing visibly than to be refused.
        let token = slot_doing(ItemAction::Inert, 1);
        assert_eq!(click_intent(&token, 6, true, false), None);
        assert!(!ItemAction::Inert.is_activatable());
        for action in [ItemAction::Use, ItemAction::Equip, ItemAction::Open] {
            assert!(action.is_activatable(), "{action:?} should be activatable");
        }
    }

    #[test]
    fn opening_an_item_is_not_equipping_it() {
        // Distinct in the model, and both are "not Equip" — a container that
        // equipped itself would be a strange sight.
        let book = slot_doing(ItemAction::Open, 1);
        assert_eq!(
            click_intent(&book, 7, true, false),
            Some(Intent::UseInventorySlot { slot: 7 }),
            "an openable item should not equip"
        );
    }

    #[test]
    fn every_item_action_names_a_distinct_key() {
        let keys: Vec<&str> =
            [ItemAction::Use, ItemAction::Equip, ItemAction::Open, ItemAction::Inert]
                .into_iter()
                .map(ItemAction::name_key)
                .collect();
        let mut unique = keys.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), keys.len(), "two actions share a key: {keys:?}");
    }

    fn stack(quantity: i32) -> SlotState {
        SlotState::Filled(ItemView {
            item_id: 1,
            name_key: "item.potion.red".into(),
            quantity,
            equipped: false,
            rarity: Rarity::Common,
            icon_grh: 1,
            action: ItemAction::Use,
        })
    }

    #[test]
    fn six_columns_fit_at_every_ui_scale_as_well_as_every_window_size() {
        // The units bug, which cost two rounds of screenshots. Bevy multiplies
        // every Val::Px by the UI scale, so a grid measured in logical pixels
        // is laid out into a space only a fraction that size once scaled: at
        // 2x the rail stayed 420 logical pixels while its slots became 86, and
        // six columns silently became four with the rest spilling out of the
        // panel.
        use super::super::layout;

        let columns = 6usize;
        for window in
            [Vec2::new(1280.0, 832.0), Vec2::new(2560.0, 1440.0), Vec2::new(3840.0, 2160.0)]
        {
            for ui in [1.0f32, 1.25, 1.5, 2.0] {
                let geometry = layout::shell_geometry_scaled(window, ui);
                if geometry.rail_mode != layout::RailMode::Full {
                    continue;
                }

                // What the grid is declared in, which is what its children are.
                let inner = grid_inner_width(geometry.rail.width() / ui);
                let slot = slot_size(inner, columns);
                let declared = slot * columns as f32 + space::GRID_GAP * (columns - 1) as f32;

                assert!(
                    declared <= inner,
                    "{window:?} at {ui}x: the grid needs {declared} of {inner} declared units"
                );
                // And once Bevy scales it, still inside the rail it was laid
                // out against.
                assert!(
                    declared * ui <= geometry.rail.width(),
                    "{window:?} at {ui}x: the grid renders {} wide in a {} rail",
                    declared * ui,
                    geometry.rail.width()
                );
            }
        }
    }

    #[test]
    fn the_grid_is_the_same_number_of_columns_at_every_window_size() {
        // A maximised window gives the rail its full 420 pixels, and a grid
        // sized at 100% wrapped that into eight columns instead of six — the
        // reference composition quietly becoming a different one depending on
        // how large the window happened to be.
        use super::super::layout;

        let columns = 6usize;
        for width in [1280.0, 1920.0, 2560.0, 3840.0] {
            let geometry = layout::shell_geometry(Vec2::new(width, 1080.0));
            if geometry.rail_mode != layout::RailMode::Full {
                continue;
            }
            let inner = grid_inner_width(geometry.rail.width());
            let slot = slot_size(inner, columns);
            let grid = slot * columns as f32 + space::GRID_GAP * (columns - 1) as f32;

            assert!(grid <= inner, "at {width}px the grid is wider than the rail allows");
            // The container is exactly six columns wide, so flex has nowhere to
            // put a seventh however much rail is left over. Spare width becomes
            // margin, which is what a wider rail should buy.
            assert_eq!(
                grid,
                slot * columns as f32 + space::GRID_GAP * (columns - 1) as f32,
                "at {width}px the grid is not exactly {columns} columns"
            );
            assert!(
                inner - grid >= 0.0,
                "at {width}px the leftover is negative, so a column would be clipped"
            );
        }
    }

    #[test]
    fn six_columns_fit_the_rail_at_every_supported_window() {
        // The grid is six wide to match the reference composition, but the rail
        // is a share of the window: at 1280 it is only about 260 pixels inside
        // its padding, less than six 44-pixel slots and their gaps. Laid out at
        // a fixed size the row wrapped after five and the last rows fell out of
        // the panel entirely.
        use super::super::layout;

        for width in [1280.0, 1366.0, 1600.0, 1920.0, 2560.0, 3840.0] {
            let geometry = layout::shell_geometry(Vec2::new(width, 832.0));
            if geometry.rail_mode != layout::RailMode::Full {
                continue;
            }
            let inner = grid_inner_width(geometry.rail.width());
            let slot = slot_size(inner, 6);
            let used = slot * 6.0 + space::GRID_GAP * 5.0;

            assert!(used <= inner, "at {width}px the grid needs {used} of {inner} available");
            assert!(slot >= 24.0, "at {width}px a slot is only {slot}px, too small to hit");
        }
    }

    #[test]
    fn the_grid_width_accounts_for_every_inset_between_it_and_the_rail() {
        // Overflowing by one pixel makes flex wrap the sixth slot onto its own
        // row, so the grid silently becomes five columns and the last rows fall
        // out of the panel. Leaving the region's border out of the sum did
        // exactly that.
        let rail = 275.0;
        let inner = grid_inner_width(rail);
        // Every inset between the rail's edge and the first slot. The grid has
        // no padding of its own, matching the reference.
        let insets = space::BASE * 2.0 + size::BORDER * 2.0;

        assert!(inner <= rail - insets, "an inset is missing from the sum");
        assert!(inner > 0.0);

        // And the result genuinely fits six.
        let slot = slot_size(inner, 6);
        assert!(slot * 6.0 + space::GRID_GAP * 5.0 <= inner);
    }

    #[test]
    fn a_slot_never_exceeds_its_design_size() {
        // A very wide rail should leave space around the grid, not inflate the
        // artwork past the size it was drawn at.
        assert_eq!(slot_size(10_000.0, 6), size::SLOT);
    }

    #[test]
    fn a_slot_size_is_a_whole_number_of_pixels() {
        // Fractional slots put the pixel-art icons on half pixels.
        for available in [200.0, 259.0, 260.5, 331.0, 419.9] {
            assert_eq!(slot_size(available, 6).fract(), 0.0, "{available} gave a fractional slot");
        }
    }

    #[test]
    fn an_impossibly_narrow_rail_still_yields_a_usable_slot() {
        // Guards a negative or zero size, which lays out as an invisible grid
        // rather than an obviously broken one.
        for available in [0.0, -50.0, 10.0] {
            let slot = slot_size(available, 6);
            assert!(slot >= 24.0, "{available} produced a {slot}px slot");
        }
    }

    #[test]
    fn a_drag_onto_its_own_slot_is_a_cancellation_not_a_move() {
        // A zero-length move is a pointless round trip that the server can
        // still refuse, and the refusal would look like a bug.
        let mut drag = DragState { from: Some(3), over: Some(3) };
        assert_eq!(drag.complete(), None);
        assert!(!drag.is_dragging());
    }

    #[test]
    fn a_drag_onto_nothing_is_a_cancellation() {
        let mut drag = DragState { from: Some(3), over: None };
        assert_eq!(drag.complete(), None);
        assert!(!drag.is_dragging());
    }

    #[test]
    fn a_completed_drag_yields_the_move_and_clears_itself() {
        let mut drag = DragState { from: Some(1), over: Some(7) };
        assert_eq!(drag.complete(), Some((1, 7)));
        assert!(!drag.is_dragging(), "a completed drag must not stay armed");
    }

    #[test]
    fn cancelling_a_drag_leaves_no_residue() {
        // A half-cleared drag reattaches to whatever is under the cursor next.
        let mut drag = DragState { from: Some(2), over: Some(5) };
        drag.cancel();
        assert_eq!(drag, DragState::default());
    }

    #[test]
    fn escape_cancels_a_drag_in_progress() {
        let mut app = App::new();
        app.insert_resource(ButtonInput::<KeyCode>::default())
            .insert_resource(DragState { from: Some(1), over: Some(2) })
            .add_systems(Update, cancel_drag_on_escape);

        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::Escape);
        app.update();

        assert!(!app.world().resource::<DragState>().is_dragging());
    }

    #[test]
    fn a_split_amount_is_clamped_to_the_stack() {
        // Zero is a no-op the server refuses; more than the stack is a desync
        // the client should not propagate.
        assert_eq!(SplitAmount::clamped(0, 10), 1);
        assert_eq!(SplitAmount::clamped(-5, 10), 1);
        assert_eq!(SplitAmount::clamped(50, 10), 10);
        assert_eq!(SplitAmount::clamped(4, 10), 4);
    }

    #[test]
    fn splitting_an_empty_stack_still_yields_a_usable_amount() {
        // Guards a clamp of `1..=0`, which panics.
        assert_eq!(SplitAmount::clamped(1, 0), 1);
        assert_eq!(SplitAmount::clamped(1, -3), 1);
    }

    #[test]
    fn shift_clicking_a_stack_drops_one_rather_than_all_of_it() {
        // Dropping 498 potions because a modifier was held is not recoverable.
        let intent = click_intent(&stack(498), 2, false, true);
        assert_eq!(intent, Some(Intent::DropInventorySlot { slot: 2, amount: 1 }));
    }

    #[test]
    fn shift_clicking_a_single_item_does_not_drop_it() {
        // There is nothing to split, and a stray modifier should not throw
        // away a weapon.
        assert_eq!(click_intent(&stack(1), 2, false, true), None);
    }

    #[test]
    fn double_clicking_a_consumable_uses_it() {
        assert_eq!(
            click_intent(&stack(10), 4, true, false),
            Some(Intent::UseInventorySlot { slot: 4 })
        );
    }

    #[test]
    fn clicking_an_empty_or_locked_slot_asks_for_nothing() {
        assert_eq!(click_intent(&SlotState::Empty, 0, true, false), None);
        assert_eq!(click_intent(&SlotState::Locked, 0, true, true), None);
    }

    #[test]
    fn a_single_click_only_selects() {
        // Selection is local; acting takes a deliberate second click.
        assert_eq!(click_intent(&stack(5), 1, false, false), None);
    }

    #[test]
    fn selection_clears_when_the_server_empties_the_slot() {
        // Otherwise the detail panel keeps describing an item the player no
        // longer has.
        let mut app = App::new();
        app.init_resource::<UiState>()
            .insert_resource(SelectedSlot(Some(0)))
            .add_systems(Update, clear_selection_when_slot_empties);

        app.world_mut().resource_mut::<UiState>().set(fixtures::snapshot(Scenario::Populated));
        app.update();
        assert_eq!(app.world().resource::<SelectedSlot>().0, Some(0), "slot 0 is filled here");

        app.world_mut().resource_mut::<UiState>().set(fixtures::snapshot(Scenario::Empty));
        app.update();
        assert_eq!(app.world().resource::<SelectedSlot>().0, None);
    }

    #[test]
    fn a_selection_past_the_end_of_the_grid_clears_rather_than_panicking() {
        let mut app = App::new();
        app.init_resource::<UiState>()
            .insert_resource(SelectedSlot(Some(9_999)))
            .add_systems(Update, clear_selection_when_slot_empties);

        app.world_mut().resource_mut::<UiState>().set(fixtures::snapshot(Scenario::Populated));
        app.update();

        assert_eq!(app.world().resource::<SelectedSlot>().0, None);
    }

    #[test]
    fn a_locked_slot_refuses_to_be_a_drop_target() {
        assert!(!SlotState::Locked.accepts_drop());
        assert!(SlotState::Empty.accepts_drop());
        assert!(stack(1).accepts_drop());
    }

    #[test]
    fn display_names_come_from_the_key_rather_than_being_invented() {
        // The fixtures carry keys precisely so the localisation path is
        // exercised; hard-coding names here would quietly bypass it. Shared
        // with every other key the interface has to draw, so a tooltip and an
        // item name cannot disagree about what a key looks like.
        let item = ItemView { name_key: "item.potion.red".into(), ..Default::default() };
        assert_eq!(short_name(&item), "Red");
        assert_eq!(short_name(&item), super::super::fallback_label("item.potion.red"));
    }

    #[test]
    fn every_fixture_renders_its_header_without_an_empty_name() {
        // A loading snapshot has no name. A blank line reads as a rendering
        // fault rather than as "not known yet".
        for scenario in Scenario::ALL {
            let snapshot = fixtures::snapshot(scenario);
            let name = if snapshot.progression.name.is_empty() {
                "—".to_string()
            } else {
                snapshot.progression.name.clone()
            };
            assert!(!name.is_empty(), "{} rendered a blank name", scenario.key());
        }
    }

    #[test]
    fn every_fixture_produces_a_drawable_bar_width() {
        // The malformed fixture is the point: a NaN or negative width lays out
        // as an infinitely wide node and takes the rail with it.
        for scenario in Scenario::ALL {
            let snapshot = fixtures::snapshot(scenario);
            for gauge in [
                snapshot.vitals.health,
                snapshot.vitals.mana,
                snapshot.vitals.stamina,
                snapshot.vitals.hunger,
                snapshot.vitals.thirst,
                snapshot.progression.experience,
            ] {
                let width = bar_fill_width(gauge, 200.0);
                assert!(width.is_finite(), "{} produced {width}", scenario.key());
                assert!((0.0..=200.0).contains(&width), "{} produced {width}", scenario.key());
            }
        }
    }
}
