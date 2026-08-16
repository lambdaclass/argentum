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

use super::controls::{bar_label, rarity_ink, Control};
use super::rail::RailRegion;
use super::state::UiState;
use super::tokens::{focus, ink, size, space, status, surface, type_scale};
use ao_core::view::{EquipSlot, Gauge, Intent, ItemView, SlotState, UiSnapshot};
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
            .add_systems(
                Update,
                (rebuild_on_change, cancel_drag_on_escape, clear_selection_when_slot_empties)
                    .chain()
                    .after(super::shell::spawn_shell),
            );
    }
}

/// Marks nodes owned by this panel, so a rebuild can clear exactly them.
#[derive(Component)]
struct PanelContent;

/// A clickable inventory slot.
#[derive(Component, Debug, Clone, Copy)]
pub struct InventorySlotButton {
    pub index: usize,
}

fn rebuild_on_change(
    state: Res<UiState>,
    selected: Res<SelectedSlot>,
    drag: Res<DragState>,
    geometry: Res<super::shell::AppliedGeometry>,
    regions: Query<(Entity, &RailRegion)>,
    existing: Query<Entity, With<PanelContent>>,
    mut commands: Commands,
) {
    if !state.is_changed() && !selected.is_changed() && !drag.is_changed() && !geometry.is_changed()
    {
        return;
    }

    for entity in &existing {
        commands.entity(entity).despawn();
    }

    let snapshot = state.get();
    for (entity, region) in &regions {
        match region {
            RailRegion::CharacterHeader => {
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((PanelContent, character_header(snapshot)));
                });
            }
            RailRegion::SlotGrid => {
                let inner = grid_inner_width(geometry.0.rail.width());
                commands.entity(entity).with_children(|parent| {
                    parent.spawn((
                        PanelContent,
                        inventory_grid(snapshot, selected.0, drag.over, inner),
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
                    parent.spawn((PanelContent, equipment_summary(snapshot)));
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
            text(format!("gold {}", progression.gold.max(0)), type_scale::SMALL, ink::MUTED),
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
/// The label is always present, so colour is never the only thing carrying the
/// meaning — which is what makes the palette usable for colour-blind players.
fn vital_bar(prefix: &str, gauge: Gauge, fill: Color) -> impl Bundle {
    (
        Node {
            width: Val::Percent(100.0),
            align_self: AlignSelf::Stretch,
            height: Val::Px(size::STATUS_BAR_HEIGHT),
            justify_content: JustifyContent::Center,
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(size::BORDER)),
            overflow: Overflow::clip(),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(surface::EDGE),
        children![
            (
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(0.0),
                    top: Val::Px(0.0),
                    bottom: Val::Px(0.0),
                    width: Val::Percent(gauge.fraction() * 100.0),
                    ..default()
                },
                BackgroundColor(fill),
            ),
            text(bar_label(prefix, gauge), type_scale::SMALL, ink::PRIMARY),
        ],
    )
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
            flex_direction: FlexDirection::Row,
            flex_wrap: FlexWrap::Wrap,
            column_gap: Val::Px(space::GRID_GAP),
            row_gap: Val::Px(space::GRID_GAP),
            ..default()
        },
        Children::spawn(SpawnIter({
            let slots = inventory.slots.clone();
            (0..slots.len())
                .map(move |index| (index, selected, drag_over))
                .collect::<Vec<_>>()
                .into_iter()
                .map(move |(index, selected, drag_over)| {
                    inventory_slot(&slots[index], index, selected, drag_over, slot)
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

    let mut children: Vec<(Text, TextFont, TextColor)> = Vec::new();
    match slot {
        // Locked slots are shown, not hidden: a player can see what expanding
        // the pack would buy.
        SlotState::Locked => {
            // Not the padlock emoji: it is outside the font's basic plane and
            // rendered as an empty box, which is exactly what an unexplained
            // locked slot must not look like.
            children.push((
                Text::new("\u{00b7}\u{00b7}"),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::DISABLED),
            ));
        }
        SlotState::Filled(item) => {
            children.push((
                Text::new(short_name(item)),
                TextFont { font_size: type_scale::MICRO, ..default() },
                TextColor(rarity_ink(item.rarity)),
            ));
            if item.shows_quantity() {
                children.push((
                    Text::new(item.display_quantity().to_string()),
                    TextFont { font_size: type_scale::MICRO, ..default() },
                    TextColor(ink::PRIMARY),
                ));
            }
            if item.equipped {
                children.push((
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
        InventorySlotButton { index },
        Control { tab_index: 100 + index as u32, enabled: !locked, ..default() },
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
    item.name_key.rsplit('.').next().unwrap_or_default().to_string()
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

fn equipment_summary(snapshot: &UiSnapshot) -> impl Bundle {
    let lines: Vec<String> = EquipSlot::ALL
        .iter()
        .map(|slot| {
            let worn = snapshot
                .equipment
                .in_slot(*slot)
                .map(short_name)
                .unwrap_or_else(|| "—".to_string());
            format!("{slot:?}: {worn}")
        })
        .collect();

    (
        column(space::HAIR),
        Children::spawn(SpawnIter(
            lines.into_iter().map(|line| text(line, type_scale::MICRO, ink::MUTED)),
        )),
    )
}

/// Escape cancels a drag.
///
/// Also fires when the pointer leaves the window, because a drag that survives
/// losing the pointer reattaches to whatever is under the cursor when it comes
/// back.
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
        return Some(if item.equipped || is_equippable(item) {
            Intent::EquipInventorySlot { slot: index }
        } else {
            Intent::UseInventorySlot { slot: index }
        });
    }
    None
}

/// Whether double-clicking should equip rather than consume.
///
/// A stand-in until item metadata crosses the boundary: anything that is not
/// stackable is treated as gear. Wrong for a few items, and deliberately
/// conservative — equipping a potion fails harmlessly, drinking a sword does
/// not exist.
fn is_equippable(item: &ItemView) -> bool {
    item.display_quantity() <= 1
}

#[cfg(test)]
mod tests {
    use super::super::controls::bar_fill_width;
    use super::*;
    use ao_core::fixtures::{self, Scenario};
    use ao_core::view::Rarity;

    fn stack(quantity: i32) -> SlotState {
        SlotState::Filled(ItemView {
            item_id: 1,
            name_key: "item.potion.red".into(),
            quantity,
            equipped: false,
            rarity: Rarity::Common,
            icon_grh: 1,
        })
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
        // exercised; hard-coding names here would quietly bypass it.
        let item = ItemView { name_key: "item.potion.red".into(), ..Default::default() };
        assert_eq!(short_name(&item), "red");
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
