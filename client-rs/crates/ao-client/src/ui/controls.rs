//! The shared control catalogue, and the one interaction model behind it.
//!
//! Every control in the client is built from these. The value is not the
//! drawing — that part is easy — it is that focus, disabled state, hover and
//! activation behave identically everywhere, on wasm and native alike. A panel
//! that grows its own button eventually grows its own focus rules, and then
//! Tab stops working in one corner of the interface for reasons nobody can
//! find.
//!
//! The interaction logic here is pure and tested without a window: focus
//! traversal, text editing, password masking, bar fills and cooldown sweeps are
//! all decidable from data.

use super::tokens::{focus, ink, size, space, status, surface, type_scale};
use ao_core::view::Gauge;
use bevy::prelude::*;

/// What a control looks like right now.
///
/// Ordered by precedence, which is the part that is easy to get wrong: a
/// disabled control that is also hovered is *disabled*, and a focused control
/// that is also pressed reads as pressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum ControlState {
    #[default]
    Normal,
    Hovered,
    Focused,
    Pressed,
    Disabled,
}

impl ControlState {
    /// Resolve the visible state from independent flags.
    ///
    /// Disabled wins over everything: a disabled control that happens to be
    /// under the cursor must not light up as though it can be clicked.
    pub fn resolve(enabled: bool, hovered: bool, focused: bool, pressed: bool) -> Self {
        if !enabled {
            return ControlState::Disabled;
        }
        if pressed {
            return ControlState::Pressed;
        }
        if focused {
            return ControlState::Focused;
        }
        if hovered {
            return ControlState::Hovered;
        }
        ControlState::Normal
    }

    /// Surface colour for this state.
    pub fn surface(self) -> Color {
        match self {
            ControlState::Normal => surface::RAISED,
            ControlState::Hovered => surface::EDGE,
            ControlState::Focused => surface::RAISED,
            ControlState::Pressed => surface::WELL,
            ControlState::Disabled => surface::WELL,
        }
    }

    /// Text colour for this state.
    pub fn ink(self) -> Color {
        match self {
            ControlState::Disabled => ink::DISABLED,
            _ => ink::PRIMARY,
        }
    }

    /// Whether a focus ring should be drawn.
    pub fn shows_focus_ring(self) -> bool {
        matches!(self, ControlState::Focused | ControlState::Pressed)
    }

    /// Whether activating this control does anything.
    pub fn is_actionable(self) -> bool {
        self != ControlState::Disabled
    }
}

/// A control that can be focused and activated.
#[derive(Component, Debug, Clone)]
pub struct Control {
    /// Position in the Tab order. Lower comes first.
    pub tab_index: u32,
    pub enabled: bool,
    pub hovered: bool,
    pub pressed: bool,
}

impl Default for Control {
    fn default() -> Self {
        Self { tab_index: 0, enabled: true, hovered: false, pressed: false }
    }
}

/// A control's identity across rebuilds.
///
/// Panels are rebuilt whenever their snapshot or the window geometry changes,
/// which despawns every control inside them. An entity is therefore not an
/// identity: focus expressed as an entity is lost by a resize, and a player who
/// has tabbed to an inventory slot loses their place when the window moves.
///
/// Keys are stable strings — `inventory.slot.3`, `topbar.settings` — so the
/// same control can be found again in the tree that replaced it.
#[derive(Component, Debug, Clone, PartialEq, Eq, Hash)]
pub struct ControlKey(pub String);

impl ControlKey {
    pub fn new(key: impl Into<String>) -> Self {
        Self(key.into())
    }

    /// Key for an indexed control in a group.
    pub fn indexed(group: &str, index: usize) -> Self {
        Self(format!("{group}.{index}"))
    }
}

/// Which control currently owns the keyboard.
///
/// Holds both: the entity for this frame's work, and the key so focus survives
/// the panel being rebuilt underneath it.
#[derive(Resource, Debug, Clone, Default)]
pub struct FocusOwner {
    entity: Option<Entity>,
    key: Option<ControlKey>,
}

impl FocusOwner {
    pub fn entity(&self) -> Option<Entity> {
        self.entity
    }

    pub fn key(&self) -> Option<&ControlKey> {
        self.key.as_ref()
    }

    /// Focus a control, remembering its key if it has one.
    pub fn focus(&mut self, entity: Entity, key: Option<&ControlKey>) {
        self.entity = Some(entity);
        self.key = key.cloned();
    }

    pub fn clear(&mut self) {
        self.entity = None;
        self.key = None;
    }

    /// Re-attach to the entity that now carries the remembered key.
    ///
    /// The key is kept even when nothing currently carries it: a panel can be
    /// absent for a frame while it rebuilds, and dropping the key there would
    /// lose the player's place for a reason they cannot see.
    fn reattach(&mut self, entity: Entity) {
        self.entity = Some(entity);
    }
}

/// One entry in the focus ring, as far as traversal is concerned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FocusCandidate {
    pub entity: Entity,
    pub tab_index: u32,
    pub enabled: bool,
}

/// Next focusable control after `current`.
///
/// Skips disabled controls and wraps. Pure so the traversal order — the thing
/// keyboard users actually experience — is testable without a window.
///
/// Candidates are sorted by `(tab_index, entity index)` rather than by
/// `tab_index` alone: two controls sharing an index would otherwise traverse in
/// whatever order the query happened to yield, which varies between runs.
///
/// The tie-break is `Entity::index()`, not `Entity` itself. `Entity` does
/// implement `Ord`, but its ordering follows the packed representation rather
/// than the spawn index, so sorting by it puts entity 3 before entity 1 — a
/// stable order, but not the one anyone reading the code would predict.
pub fn next_focus(
    candidates: &[FocusCandidate],
    current: Option<Entity>,
    backwards: bool,
) -> Option<Entity> {
    let mut ordered: Vec<FocusCandidate> =
        candidates.iter().copied().filter(|c| c.enabled).collect();
    if ordered.is_empty() {
        return None;
    }
    ordered.sort_by_key(|c| (c.tab_index, c.entity.index()));

    let position = current.and_then(|entity| ordered.iter().position(|c| c.entity == entity));

    let index = match (position, backwards) {
        (Some(i), false) => (i + 1) % ordered.len(),
        (Some(i), true) => (i + ordered.len() - 1) % ordered.len(),
        // Nothing focused: Tab enters at the start, Shift+Tab at the end.
        (None, false) => 0,
        (None, true) => ordered.len() - 1,
    };

    Some(ordered[index].entity)
}

/// A single-line text field's contents and caret.
///
/// Editing is modelled rather than delegated to the platform, because there is
/// no platform text field here: this is a canvas. The rules are the ones every
/// field has, and getting them wrong is immediately obvious to a typist.
#[derive(Component, Debug, Clone, Default, PartialEq, Eq)]
pub struct TextField {
    value: String,
    /// Caret position, as a character index rather than a byte index — a byte
    /// caret lands inside a multi-byte character and panics on the next slice.
    caret: usize,
    pub masked: bool,
    pub max_length: Option<usize>,
}

impl TextField {
    pub fn new() -> Self {
        Self::default()
    }

    /// A password field: same editing rules, different rendering.
    pub fn password() -> Self {
        Self { masked: true, ..Default::default() }
    }

    pub fn value(&self) -> &str {
        &self.value
    }

    pub fn caret(&self) -> usize {
        self.caret
    }

    pub fn char_count(&self) -> usize {
        self.value.chars().count()
    }

    /// What is drawn on screen.
    ///
    /// Masked fields never render their contents, and the mask is built from
    /// the character count rather than the byte length so an accented password
    /// does not leak its composition through a longer row of dots.
    pub fn display(&self) -> String {
        if self.masked {
            "\u{2022}".repeat(self.char_count())
        } else {
            self.value.clone()
        }
    }

    pub fn insert(&mut self, character: char) {
        // Control characters arrive from key events and would render as boxes.
        if character.is_control() {
            return;
        }
        if let Some(limit) = self.max_length {
            if self.char_count() >= limit {
                return;
            }
        }
        let byte = self.byte_offset(self.caret);
        self.value.insert(byte, character);
        self.caret += 1;
    }

    pub fn backspace(&mut self) {
        if self.caret == 0 {
            return;
        }
        let start = self.byte_offset(self.caret - 1);
        let end = self.byte_offset(self.caret);
        self.value.replace_range(start..end, "");
        self.caret -= 1;
    }

    pub fn delete_forward(&mut self) {
        if self.caret >= self.char_count() {
            return;
        }
        let start = self.byte_offset(self.caret);
        let end = self.byte_offset(self.caret + 1);
        self.value.replace_range(start..end, "");
    }

    pub fn move_caret(&mut self, delta: i32) {
        let target = self.caret as i32 + delta;
        self.caret = target.clamp(0, self.char_count() as i32) as usize;
    }

    pub fn caret_to_start(&mut self) {
        self.caret = 0;
    }

    pub fn caret_to_end(&mut self) {
        self.caret = self.char_count();
    }

    /// Take the contents and reset, as submitting a chat line does.
    pub fn take(&mut self) -> String {
        self.caret = 0;
        std::mem::take(&mut self.value)
    }

    pub fn is_empty(&self) -> bool {
        self.value.is_empty()
    }

    /// Byte offset of a character index. Clamped, so a caret that has somehow
    /// outrun the value cannot slice out of bounds.
    fn byte_offset(&self, char_index: usize) -> usize {
        self.value
            .char_indices()
            .nth(char_index)
            .map(|(offset, _)| offset)
            .unwrap_or(self.value.len())
    }
}

/// Width of a bar's fill, given its track.
///
/// Rounded to whole pixels: a fractional fill leaves a blurred edge against the
/// track, which on a 18px bar is most of what a player sees.
#[cfg(test)]
pub fn bar_fill_width(gauge: Gauge, track_width: f32) -> f32 {
    (track_width.max(0.0) * gauge.fraction()).round()
}

/// The text drawn inside a status bar.
///
/// Inside, not beside: the reference client does this and the roadmap records
/// it as one of the ideas worth taking, because it costs no extra height.
pub fn bar_label(prefix: &str, gauge: Gauge) -> String {
    format!("{prefix}: {}/{}", gauge.current.max(0), gauge.max.max(0))
}

/// Colour for a rarity, resolved at the token layer rather than in the model.
pub fn rarity_ink(rarity: ao_core::view::Rarity) -> Color {
    use ao_core::view::Rarity;
    match rarity {
        Rarity::Common => ink::PRIMARY,
        Rarity::Uncommon => status::HUNGER,
        Rarity::Rare => status::THIRST,
        Rarity::Epic => status::MANA,
        Rarity::Legendary => ink::GOLD,
    }
}

/// What a control was activated by.
///
/// Recorded because the two paths must stay equivalent: a control reachable by
/// mouse but not by keyboard is one a keyboard player cannot use at all, and
/// that is invisible unless something says which path fired.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivationSource {
    Pointer,
    Keyboard,
}

/// A control was activated.
///
/// One message for every control in the client, whatever activated it. Panels
/// listen for this rather than polling `Interaction` themselves, which is what
/// stops a click and an Enter press taking two different code paths that drift.
#[derive(Message, Debug, Clone, Copy, PartialEq, Eq)]
pub struct Activated {
    pub entity: Entity,
    pub source: ActivationSource,
}

/// Ordering for the interaction pipeline.
#[derive(SystemSet, Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ControlSet {
    /// Reads pointers and keys, updates `Control`, emits `Activated`.
    Interact,
    /// Redraws controls from their resolved state.
    Present,
}

pub struct ControlsPlugin;

impl Plugin for ControlsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<FocusOwner>()
            .add_message::<Activated>()
            .configure_sets(Update, ControlSet::Interact.before(ControlSet::Present))
            .add_systems(
                Update,
                (track_pointer, move_focus_with_tab, activate_with_keyboard, resolve_focus)
                    .chain()
                    .in_set(ControlSet::Interact),
            )
            .add_systems(Update, present_controls.in_set(ControlSet::Present));
    }
}

/// Mirror Bevy's `Interaction` into `Control`, and fire on release.
///
/// On release rather than on press, because a press that slides off the control
/// before letting go is a cancellation — every desktop toolkit behaves this way
/// and players notice when one does not.
fn track_pointer(
    mut controls: Query<(Entity, &Interaction, &mut Control, Option<&ControlKey>)>,
    mut focus: ResMut<FocusOwner>,
    mut activated: MessageWriter<Activated>,
) {
    for (entity, interaction, mut control, key) in &mut controls {
        let was_pressed = control.pressed;

        control.hovered = !matches!(interaction, Interaction::None);
        control.pressed = matches!(interaction, Interaction::Pressed);

        if !control.enabled {
            // A disabled control still tracks hover so the cursor can change,
            // but it never takes focus and never activates.
            control.pressed = false;
            continue;
        }

        if matches!(interaction, Interaction::Pressed) {
            focus.focus(entity, key);
        }

        // Released while still over the control.
        if was_pressed && matches!(interaction, Interaction::Hovered) {
            activated.write(Activated { entity, source: ActivationSource::Pointer });
        }
    }
}

/// Tab and Shift+Tab move focus.
///
/// Suppressed while a text field owns the keyboard is *not* the rule here: Tab
/// is how a player leaves a field. Text fields swallow ordinary characters, not
/// navigation.
fn move_focus_with_tab(
    keys: Res<ButtonInput<KeyCode>>,
    controls: Query<(Entity, &Control, Option<&ControlKey>)>,
    mut focus: ResMut<FocusOwner>,
) {
    if !keys.just_pressed(KeyCode::Tab) {
        return;
    }
    let backwards = keys.pressed(KeyCode::ShiftLeft) || keys.pressed(KeyCode::ShiftRight);

    let candidates: Vec<FocusCandidate> = controls
        .iter()
        .map(|(entity, control, _)| FocusCandidate {
            entity,
            tab_index: control.tab_index,
            enabled: control.enabled,
        })
        .collect();

    match next_focus(&candidates, focus.entity(), backwards) {
        Some(next) => {
            let key = controls.get(next).ok().and_then(|(_, _, key)| key);
            focus.focus(next, key);
        }
        None => focus.clear(),
    }
}

/// Enter and Space activate the focused control.
///
/// Space as well as Enter because a slot grid is navigated like a list, and
/// Space is what a player's hand reaches for there.
fn activate_with_keyboard(
    keys: Res<ButtonInput<KeyCode>>,
    controls: Query<&Control>,
    focus: Res<FocusOwner>,
    mut activated: MessageWriter<Activated>,
) {
    if !keys.just_pressed(KeyCode::Enter) && !keys.just_pressed(KeyCode::Space) {
        return;
    }
    let Some(entity) = focus.entity() else {
        return;
    };
    // A control that became disabled while focused must not fire.
    if controls.get(entity).map(|control| control.enabled).unwrap_or(false) {
        activated.write(Activated { entity, source: ActivationSource::Keyboard });
    }
}

/// Keep focus pointing at a usable control across rebuilds.
///
/// Panels rebuild whenever their snapshot or the window geometry changes, which
/// despawns the focused control. Two things have to happen:
///
/// The entity is re-attached to whatever now carries the remembered key, so a
/// resize does not move the player's place in the interface. Only then, if
/// nothing carries it and the entity is really gone, is focus dropped — left
/// dangling, Tab appears to do nothing, because traversal restarts from a
/// control that no longer exists.
fn resolve_focus(
    controls: Query<(Entity, &Control, Option<&ControlKey>)>,
    mut focus: ResMut<FocusOwner>,
) {
    let still_usable = focus
        .entity()
        .and_then(|entity| controls.get(entity).ok())
        .map(|(_, control, _)| control.enabled)
        .unwrap_or(false);

    if still_usable {
        return;
    }

    // The control was rebuilt: find its replacement by key.
    if let Some(key) = focus.key().cloned() {
        let replacement = controls
            .iter()
            .find(|(_, control, candidate)| control.enabled && *candidate == Some(&key));
        if let Some((entity, _, _)) = replacement {
            focus.reattach(entity);
            return;
        }
        // Keyed but currently absent — a panel mid-rebuild. Keep the key so it
        // can be found again, but stop pointing at a dead entity.
        focus.entity = None;
        return;
    }

    focus.clear();
}

/// Redraw controls from their resolved state.
fn present_controls(
    focus: Res<FocusOwner>,
    mut controls: Query<(Entity, &Control, &mut BackgroundColor, &mut BorderColor)>,
) {
    for (entity, control, mut background, mut border) in &mut controls {
        let state = ControlState::resolve(
            control.enabled,
            control.hovered,
            focus.entity() == Some(entity),
            control.pressed,
        );
        background.0 = state.surface();
        *border =
            BorderColor::all(if state.shows_focus_ring() { focus::RING } else { surface::EDGE });
    }
}

/// A button.
pub fn button(label_text: &str, state: ControlState, tab_index: u32) -> impl Bundle {
    (
        // `Button` is what makes this a control rather than a picture of one:
        // it requires `Interaction`, which is the component `track_pointer`
        // queries. Without it the builder produced something carrying `Control`
        // that the pointer pipeline could not see at all — hover, press and
        // pointer activation silently did nothing.
        Button,
        Node {
            padding: UiRect::axes(Val::Px(space::WIDE), Val::Px(space::SNUG)),
            justify_content: JustifyContent::Center,
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        BackgroundColor(state.surface()),
        BorderColor::all(if state.shows_focus_ring() { focus::RING } else { surface::EDGE }),
        Control { tab_index, enabled: state.is_actionable(), ..default() },
        children![(
            Text::new(label_text.to_string()),
            TextFont { font_size: type_scale::SMALL, ..default() },
            TextColor(state.ink()),
        )],
    )
}

/// A tab in a strip.
pub fn tab(label_text: &str, selected: bool, tab_index: u32) -> impl Bundle {
    (
        // `Button` is what makes this a control rather than a picture of one:
        // it requires `Interaction`, which is the component `track_pointer`
        // queries. Without it the builder produced something carrying `Control`
        // that the pointer pipeline could not see at all — hover, press and
        // pointer activation silently did nothing.
        Button,
        Node {
            flex_grow: 1.0,
            padding: UiRect::axes(Val::Px(space::BASE), Val::Px(space::SNUG)),
            justify_content: JustifyContent::Center,
            border: UiRect::bottom(Val::Px(focus::RING_WIDTH)),
            ..default()
        },
        BackgroundColor(if selected { surface::RAISED } else { surface::WELL }),
        // The selected tab is marked by its underline, not only by a slightly
        // different fill: two dark browns are not a distinction at a glance.
        BorderColor::all(if selected { focus::SELECTED } else { Color::NONE }),
        Control { tab_index, ..default() },
        children![(
            Text::new(label_text.to_string()),
            TextFont { font_size: type_scale::SMALL, ..default() },
            TextColor(if selected { ink::GOLD } else { ink::MUTED }),
        )],
    )
}

/// An inventory or spell slot.
pub fn slot(state: ControlState, tab_index: u32) -> impl Bundle {
    (
        // `Button` is what makes this a control rather than a picture of one:
        // it requires `Interaction`, which is the component `track_pointer`
        // queries. Without it the builder produced something carrying `Control`
        // that the pointer pipeline could not see at all — hover, press and
        // pointer activation silently did nothing.
        Button,
        Node {
            width: Val::Px(size::SLOT),
            height: Val::Px(size::SLOT),
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(if state.shows_focus_ring() { focus::RING } else { surface::EDGE }),
        Control { tab_index, enabled: state.is_actionable(), ..default() },
    )
}

/// A labelled status bar with its value inside it.
pub fn status_bar(prefix: &str, gauge: Gauge, fill: Color) -> impl Bundle {
    let fraction = gauge.fraction();
    (
        Node {
            width: Val::Percent(100.0),
            // Stretched, so a bar in a row of them fills its share rather than
            // shrinking to its text.
            align_self: AlignSelf::Stretch,
            height: Val::Px(size::STATUS_BAR_HEIGHT),
            justify_content: JustifyContent::Center,
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(size::BORDER)),
            // The label is centred and the track is fixed height, so a long
            // label must be cut rather than pushing the bar wider than its row.
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
                    width: Val::Percent(fraction * 100.0),
                    ..default()
                },
                BackgroundColor(fill),
            ),
            (
                Text::new(bar_label(prefix, gauge)),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::PRIMARY),
            ),
        ],
    )
}

/// A cooldown sweep drawn over a slot.
pub fn cooldown_overlay(fraction: f32) -> impl Bundle {
    (
        Node {
            position_type: PositionType::Absolute,
            left: Val::Px(0.0),
            right: Val::Px(0.0),
            bottom: Val::Px(0.0),
            height: Val::Percent(fraction.clamp(0.0, 1.0) * 100.0),
            ..default()
        },
        BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.6)),
    )
}

/// A hotkey reminder in the corner of a slot.
pub fn hotkey_prompt(key: &str) -> impl Bundle {
    (
        Node {
            position_type: PositionType::Absolute,
            left: Val::Px(space::HAIR),
            top: Val::Px(space::HAIR),
            ..default()
        },
        Text::new(key.to_string()),
        TextFont { font_size: type_scale::MICRO, ..default() },
        TextColor(ink::MUTED),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entity(index: u32) -> Entity {
        Entity::from_raw_u32(index).expect("a valid test entity")
    }

    fn candidate(index: u32, tab_index: u32, enabled: bool) -> FocusCandidate {
        FocusCandidate { entity: entity(index), tab_index, enabled }
    }

    /// An app running the interaction pipeline over a few controls.
    fn control_app(count: usize) -> (App, Vec<Entity>) {
        let mut app = App::new();
        app.add_plugins(ControlsPlugin).insert_resource(ButtonInput::<KeyCode>::default());

        let entities: Vec<Entity> = (0..count)
            .map(|index| {
                app.world_mut()
                    .spawn((
                        Control { tab_index: index as u32, ..default() },
                        Interaction::None,
                        BackgroundColor(Color::NONE),
                        BorderColor::all(Color::NONE),
                    ))
                    .id()
            })
            .collect();

        app.update();
        (app, entities)
    }

    /// Tap a key: press, run a frame, release.
    ///
    /// The release matters. `ButtonInput::press` only records `just_pressed`
    /// when the key was not already held, so pressing twice without releasing
    /// makes the second tap a no-op — a real keyboard sends the release, and a
    /// helper that does not silently tests one keystroke while claiming two.
    fn press_key(app: &mut App, key: KeyCode) {
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(key);
        app.update();
        let mut input = app.world_mut().resource_mut::<ButtonInput<KeyCode>>();
        input.release(key);
        input.clear();
    }

    fn activations(app: &mut App) -> Vec<Activated> {
        let messages = app.world().resource::<Messages<Activated>>();
        let mut cursor = messages.get_cursor();
        cursor.read(messages).copied().collect()
    }

    fn set_interaction(app: &mut App, entity: Entity, interaction: Interaction) {
        *app.world_mut().get_mut::<Interaction>(entity).unwrap() = interaction;
        app.update();
    }

    /// An app with the production interaction pipeline and nothing else.
    fn controls_app() -> App {
        let mut app = App::new();
        app.add_plugins(ControlsPlugin).insert_resource(ButtonInput::<KeyCode>::default());
        app
    }

    /// Drive the `Interaction` the builder was supposed to provide.
    ///
    /// Deliberately not inserted by the test: if a builder omits `Button`, and
    /// therefore `Interaction`, this returns `None` and the test fails — which is
    /// the whole point. Every builder here was carrying `Control` without
    /// `Interaction`, so the pointer pipeline could not see any of them.
    fn point_at(app: &mut App, entity: Entity, interaction: Interaction) {
        let mut found = app
            .world_mut()
            .get_mut::<Interaction>(entity)
            .expect("the builder produced a control with no Interaction to drive");
        *found = interaction;
        app.update();
    }

    #[test]
    fn a_button_from_the_shared_builder_activates_by_pointer() {
        // Spawned exactly as production spawns it, with nothing added by hand.
        let mut app = controls_app();
        let entity = app.world_mut().spawn(button("Attack", ControlState::Normal, 1)).id();
        app.update();

        point_at(&mut app, entity, Interaction::Hovered);
        assert!(
            app.world().get::<Control>(entity).expect("a control").hovered,
            "hover never reached the control"
        );

        point_at(&mut app, entity, Interaction::Pressed);
        assert!(app.world().get::<Control>(entity).expect("a control").pressed);

        // Release is the activation, not press: a press dragged off the control
        // and released elsewhere must not fire.
        point_at(&mut app, entity, Interaction::Hovered);
        let fired = activations(&mut app);
        assert_eq!(fired.len(), 1, "a pointer release produced {} activations", fired.len());
        assert_eq!(fired[0].entity, entity);
        assert_eq!(fired[0].source, ActivationSource::Pointer);
    }

    #[test]
    fn a_tab_from_the_shared_builder_activates_by_keyboard() {
        // Tab to it, then Enter. Both through the production systems.
        let mut app = controls_app();
        let entity = app.world_mut().spawn(tab("Inventory", false, 1)).id();
        app.update();

        press_key(&mut app, KeyCode::Tab);
        assert_eq!(
            app.world().resource::<FocusOwner>().entity(),
            Some(entity),
            "Tab did not reach a control built by the shared builder"
        );

        press_key(&mut app, KeyCode::Enter);
        let fired = activations(&mut app);
        assert_eq!(fired.len(), 1, "Enter produced {} activations", fired.len());
        assert_eq!(fired[0].source, ActivationSource::Keyboard);
    }

    #[test]
    fn a_slot_from_the_shared_builder_is_focusable_and_a_disabled_one_is_not() {
        let mut app = controls_app();
        let enabled = app.world_mut().spawn(slot(ControlState::Normal, 1)).id();
        let locked = app.world_mut().spawn(slot(ControlState::Disabled, 2)).id();
        app.update();

        assert!(app.world().get::<Control>(enabled).expect("a control").enabled);
        assert!(
            !app.world().get::<Control>(locked).expect("a control").enabled,
            "a disabled slot is offered as actionable"
        );

        // Focus skips the locked one rather than landing on something inert.
        press_key(&mut app, KeyCode::Tab);
        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(enabled));
        press_key(&mut app, KeyCode::Tab);
        assert_eq!(
            app.world().resource::<FocusOwner>().entity(),
            Some(enabled),
            "focus moved onto a disabled slot"
        );
    }

    #[test]
    fn a_disabled_button_from_the_shared_builder_never_activates() {
        let mut app = controls_app();
        let entity = app.world_mut().spawn(button("Cast", ControlState::Disabled, 1)).id();
        app.update();

        point_at(&mut app, entity, Interaction::Pressed);
        point_at(&mut app, entity, Interaction::Hovered);
        assert!(activations(&mut app).is_empty(), "a disabled button activated");
        assert_ne!(
            app.world().resource::<FocusOwner>().entity(),
            Some(entity),
            "a disabled button took focus"
        );
    }

    #[test]
    fn focus_survives_the_control_being_rebuilt() {
        // Panels rebuild on every snapshot and every window resize, which
        // despawns and respawns every control inside them. Focus held as an
        // entity is lost by a resize, so a player who has tabbed to an
        // inventory slot silently loses their place when the window moves.
        let mut app = App::new();
        app.add_plugins(ControlsPlugin).insert_resource(ButtonInput::<KeyCode>::default());

        let original = app
            .world_mut()
            .spawn((
                Control::default(),
                ControlKey::indexed("inventory.slot", 3),
                Interaction::None,
                BackgroundColor(Color::NONE),
                BorderColor::all(Color::NONE),
            ))
            .id();
        app.update();

        app.world_mut()
            .resource_mut::<FocusOwner>()
            .focus(original, Some(&ControlKey::indexed("inventory.slot", 3)));

        // The rebuild: the old control goes, an identical one takes its place.
        app.world_mut().despawn(original);
        let rebuilt = app
            .world_mut()
            .spawn((
                Control::default(),
                ControlKey::indexed("inventory.slot", 3),
                Interaction::None,
                BackgroundColor(Color::NONE),
                BorderColor::all(Color::NONE),
            ))
            .id();
        app.update();

        assert_eq!(
            app.world().resource::<FocusOwner>().entity(),
            Some(rebuilt),
            "focus did not follow the control through its rebuild"
        );
    }

    #[test]
    fn focus_is_kept_while_a_panel_is_briefly_absent() {
        // A rebuild can despawn before it respawns. Dropping the key in that
        // gap loses the player's place for a reason they cannot see.
        let mut app = App::new();
        app.add_plugins(ControlsPlugin).insert_resource(ButtonInput::<KeyCode>::default());

        let control = app
            .world_mut()
            .spawn((
                Control::default(),
                ControlKey::new("topbar.settings"),
                Interaction::None,
                BackgroundColor(Color::NONE),
                BorderColor::all(Color::NONE),
            ))
            .id();
        app.update();
        app.world_mut()
            .resource_mut::<FocusOwner>()
            .focus(control, Some(&ControlKey::new("topbar.settings")));

        app.world_mut().despawn(control);
        app.update();

        assert_eq!(app.world().resource::<FocusOwner>().entity(), None, "a dead entity was kept");
        assert_eq!(
            app.world().resource::<FocusOwner>().key(),
            Some(&ControlKey::new("topbar.settings")),
            "the key was dropped, so the control cannot be found again"
        );

        // And it is found again when the panel comes back.
        let rebuilt = app
            .world_mut()
            .spawn((
                Control::default(),
                ControlKey::new("topbar.settings"),
                Interaction::None,
                BackgroundColor(Color::NONE),
                BorderColor::all(Color::NONE),
            ))
            .id();
        app.update();

        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(rebuilt));
    }

    #[test]
    fn an_unkeyed_control_still_loses_focus_when_it_disappears() {
        // Keys are the mechanism for surviving a rebuild; a control without one
        // has no identity to restore, and holding a dead entity makes Tab
        // appear to do nothing.
        let mut app = App::new();
        app.add_plugins(ControlsPlugin).insert_resource(ButtonInput::<KeyCode>::default());

        let control = app
            .world_mut()
            .spawn((
                Control::default(),
                Interaction::None,
                BackgroundColor(Color::NONE),
                BorderColor::all(Color::NONE),
            ))
            .id();
        app.update();
        app.world_mut().resource_mut::<FocusOwner>().focus(control, None);

        app.world_mut().despawn(control);
        app.update();

        assert_eq!(app.world().resource::<FocusOwner>().entity(), None);
        assert_eq!(app.world().resource::<FocusOwner>().key(), None);
    }

    #[test]
    fn a_rebuilt_control_that_came_back_disabled_does_not_take_focus() {
        // Rebuilding is when a slot becomes locked. Re-attaching to it would
        // put the ring on something that cannot be activated.
        let mut app = App::new();
        app.add_plugins(ControlsPlugin).insert_resource(ButtonInput::<KeyCode>::default());

        let key = ControlKey::indexed("inventory.slot", 0);
        let original = app
            .world_mut()
            .spawn((
                Control::default(),
                key.clone(),
                Interaction::None,
                BackgroundColor(Color::NONE),
                BorderColor::all(Color::NONE),
            ))
            .id();
        app.update();
        app.world_mut().resource_mut::<FocusOwner>().focus(original, Some(&key));

        app.world_mut().despawn(original);
        app.world_mut().spawn((
            Control { enabled: false, ..default() },
            key.clone(),
            Interaction::None,
            BackgroundColor(Color::NONE),
            BorderColor::all(Color::NONE),
        ));
        app.update();

        assert_eq!(app.world().resource::<FocusOwner>().entity(), None);
    }

    #[test]
    fn a_click_activates_on_release_rather_than_on_press() {
        // A press that slides off before letting go is a cancellation. Every
        // desktop toolkit behaves this way and players notice when one does not.
        let (mut app, controls) = control_app(1);

        set_interaction(&mut app, controls[0], Interaction::Pressed);
        assert!(activations(&mut app).is_empty(), "activated on press");

        set_interaction(&mut app, controls[0], Interaction::Hovered);
        let fired = activations(&mut app);
        assert_eq!(fired.len(), 1);
        assert_eq!(fired[0].source, ActivationSource::Pointer);
    }

    #[test]
    fn a_press_that_slides_off_the_control_is_cancelled() {
        let (mut app, controls) = control_app(1);

        set_interaction(&mut app, controls[0], Interaction::Pressed);
        set_interaction(&mut app, controls[0], Interaction::None);

        assert!(activations(&mut app).is_empty(), "a cancelled press still fired");
    }

    #[test]
    fn clicking_a_control_gives_it_focus() {
        // So that Enter afterwards acts on what was just clicked, rather than
        // on wherever focus happened to be.
        let (mut app, controls) = control_app(2);

        set_interaction(&mut app, controls[1], Interaction::Pressed);
        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(controls[1]));
    }

    #[test]
    fn keyboard_and_pointer_activation_produce_the_same_message() {
        // The invariant that keeps a control usable both ways. Two separate
        // paths drift, and the keyboard one is the half nobody notices is
        // broken.
        let (mut app, controls) = control_app(1);

        set_interaction(&mut app, controls[0], Interaction::Pressed);
        set_interaction(&mut app, controls[0], Interaction::Hovered);
        let by_pointer = activations(&mut app);

        let (mut app, controls) = control_app(1);
        app.world_mut().resource_mut::<FocusOwner>().focus(controls[0], None);
        press_key(&mut app, KeyCode::Enter);
        let by_keyboard = activations(&mut app);

        assert_eq!(by_pointer.len(), 1);
        assert_eq!(by_keyboard.len(), 1);
        assert_eq!(by_pointer[0].entity, by_keyboard[0].entity);
        // Only the recorded source differs, which is the point of recording it.
        assert_ne!(by_pointer[0].source, by_keyboard[0].source);
    }

    #[test]
    fn space_activates_as_well_as_enter() {
        // A slot grid is navigated like a list, and Space is what the hand
        // reaches for there.
        let (mut app, controls) = control_app(1);
        app.world_mut().resource_mut::<FocusOwner>().focus(controls[0], None);

        press_key(&mut app, KeyCode::Space);
        assert_eq!(activations(&mut app).len(), 1);
    }

    #[test]
    fn tab_moves_focus_through_the_controls() {
        let (mut app, controls) = control_app(3);

        press_key(&mut app, KeyCode::Tab);
        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(controls[0]));

        press_key(&mut app, KeyCode::Tab);
        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(controls[1]));
    }

    #[test]
    fn shift_tab_moves_focus_backwards() {
        let (mut app, controls) = control_app(3);
        app.world_mut().resource_mut::<FocusOwner>().focus(controls[1], None);

        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().press(KeyCode::ShiftLeft);
        press_key(&mut app, KeyCode::Tab);
        app.world_mut().resource_mut::<ButtonInput<KeyCode>>().release(KeyCode::ShiftLeft);

        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(controls[0]));
    }

    #[test]
    fn a_disabled_control_neither_takes_focus_nor_activates() {
        let (mut app, controls) = control_app(2);
        app.world_mut().get_mut::<Control>(controls[0]).unwrap().enabled = false;

        set_interaction(&mut app, controls[0], Interaction::Pressed);
        set_interaction(&mut app, controls[0], Interaction::Hovered);

        assert!(activations(&mut app).is_empty(), "a disabled control activated");
        assert_ne!(app.world().resource::<FocusOwner>().entity(), Some(controls[0]));
    }

    #[test]
    fn a_control_disabled_while_focused_does_not_fire_on_enter() {
        // Panels rebuild constantly, and a control can lose its enabled state
        // between the player choosing it and pressing the key.
        let (mut app, controls) = control_app(1);
        app.world_mut().resource_mut::<FocusOwner>().focus(controls[0], None);
        app.world_mut().get_mut::<Control>(controls[0]).unwrap().enabled = false;

        press_key(&mut app, KeyCode::Enter);
        assert!(activations(&mut app).is_empty());
    }

    #[test]
    fn focus_is_dropped_when_the_focused_control_disappears() {
        // Panels rebuild on every snapshot, so the focused entity is routinely
        // despawned underneath the player. Left dangling, Tab appears to do
        // nothing because traversal restarts from something that is gone.
        let (mut app, controls) = control_app(2);
        app.world_mut().resource_mut::<FocusOwner>().focus(controls[0], None);
        app.world_mut().despawn(controls[0]);
        app.update();

        assert_eq!(app.world().resource::<FocusOwner>().entity(), None);

        // And traversal still works afterwards.
        press_key(&mut app, KeyCode::Tab);
        assert_eq!(app.world().resource::<FocusOwner>().entity(), Some(controls[1]));
    }

    #[test]
    fn the_focused_control_is_drawn_with_its_ring() {
        // Presentation follows the resolved state rather than being set at each
        // call site, so a control cannot be focused without looking focused.
        let (mut app, controls) = control_app(2);
        app.world_mut().resource_mut::<FocusOwner>().focus(controls[0], None);
        app.update();

        let ring = app.world().get::<BorderColor>(controls[0]).unwrap().top;
        let plain = app.world().get::<BorderColor>(controls[1]).unwrap().top;
        assert_eq!(ring, focus::RING);
        assert_ne!(plain, focus::RING);
    }

    #[test]
    fn hovering_changes_how_a_control_is_drawn() {
        let (mut app, controls) = control_app(1);
        let plain = app.world().get::<BackgroundColor>(controls[0]).unwrap().0;

        set_interaction(&mut app, controls[0], Interaction::Hovered);
        let hovered = app.world().get::<BackgroundColor>(controls[0]).unwrap().0;

        assert_ne!(plain, hovered);
    }

    #[test]
    fn disabled_wins_over_every_other_state() {
        // A disabled control under the cursor must not light up as though it
        // can be clicked.
        assert_eq!(ControlState::resolve(false, true, true, true), ControlState::Disabled);
        assert!(!ControlState::Disabled.is_actionable());
        assert!(!ControlState::Disabled.shows_focus_ring());
    }

    #[test]
    fn pressed_outranks_focused_which_outranks_hovered() {
        assert_eq!(ControlState::resolve(true, true, true, true), ControlState::Pressed);
        assert_eq!(ControlState::resolve(true, true, true, false), ControlState::Focused);
        assert_eq!(ControlState::resolve(true, true, false, false), ControlState::Hovered);
        assert_eq!(ControlState::resolve(true, false, false, false), ControlState::Normal);
    }

    #[test]
    fn a_pressed_control_still_shows_it_has_focus() {
        // Otherwise the ring vanishes for as long as a key is held, and a
        // keyboard user loses their place mid-activation.
        assert!(ControlState::Pressed.shows_focus_ring());
    }

    #[test]
    fn tab_moves_forward_through_the_declared_order() {
        let candidates = [candidate(1, 0, true), candidate(2, 1, true), candidate(3, 2, true)];

        assert_eq!(next_focus(&candidates, Some(entity(1)), false), Some(entity(2)));
        assert_eq!(next_focus(&candidates, Some(entity(2)), false), Some(entity(3)));
    }

    #[test]
    fn tab_wraps_at_both_ends() {
        let candidates = [candidate(1, 0, true), candidate(2, 1, true)];

        assert_eq!(next_focus(&candidates, Some(entity(2)), false), Some(entity(1)));
        assert_eq!(next_focus(&candidates, Some(entity(1)), true), Some(entity(2)));
    }

    #[test]
    fn tab_enters_at_the_start_and_shift_tab_at_the_end() {
        // With nothing focused, the two directions must not both land on the
        // first control — Shift+Tab into a form should reach its last field.
        let candidates = [candidate(1, 0, true), candidate(2, 1, true), candidate(3, 2, true)];

        assert_eq!(next_focus(&candidates, None, false), Some(entity(1)));
        assert_eq!(next_focus(&candidates, None, true), Some(entity(3)));
    }

    #[test]
    fn disabled_controls_are_skipped_rather_than_focused_and_ignored() {
        // Focusing one is a dead stop: the ring is on something that does
        // nothing, and the next Tab appears not to work.
        let candidates = [candidate(1, 0, true), candidate(2, 1, false), candidate(3, 2, true)];

        assert_eq!(next_focus(&candidates, Some(entity(1)), false), Some(entity(3)));
        assert_eq!(next_focus(&candidates, Some(entity(3)), true), Some(entity(1)));
    }

    #[test]
    fn traversal_is_stable_when_two_controls_share_a_tab_index() {
        // Sorting by index alone leaves the order to however the query
        // happened to yield, which varies between runs and makes Tab feel
        // random.
        let candidates = [candidate(3, 5, true), candidate(1, 5, true), candidate(2, 5, true)];

        let first = next_focus(&candidates, None, false);
        for _ in 0..10 {
            assert_eq!(next_focus(&candidates, None, false), first);
        }
        assert_eq!(first, Some(entity(1)), "ties should break on a stable key");
    }

    #[test]
    fn a_form_with_nothing_enabled_has_nowhere_to_focus() {
        // Returning the first candidate anyway would put the ring on a
        // disabled control.
        let candidates = [candidate(1, 0, false), candidate(2, 1, false)];
        assert_eq!(next_focus(&candidates, None, false), None);
        assert_eq!(next_focus(&[], None, false), None);
    }

    #[test]
    fn focus_recovers_when_the_focused_control_disappears() {
        // A panel closing under the cursor leaves a stale entity focused.
        // Traversal must not dead-end there.
        let candidates = [candidate(1, 0, true), candidate(2, 1, true)];
        assert_eq!(next_focus(&candidates, Some(entity(99)), false), Some(entity(1)));
    }

    #[test]
    fn typing_inserts_at_the_caret() {
        let mut field = TextField::new();
        for c in "helo".chars() {
            field.insert(c);
        }
        field.move_caret(-1);
        field.insert('l');

        assert_eq!(field.value(), "hello");
        assert_eq!(field.caret(), 4);
    }

    #[test]
    fn editing_uses_character_indices_rather_than_byte_offsets() {
        // A byte caret lands inside a multi-byte character and panics on the
        // next slice. Spanish is the client's first language, so this is the
        // common case, not an edge one.
        let mut field = TextField::new();
        for c in "año".chars() {
            field.insert(c);
        }
        assert_eq!(field.char_count(), 3);

        field.backspace();
        assert_eq!(field.value(), "añ");
        field.backspace();
        assert_eq!(field.value(), "a");
    }

    #[test]
    fn backspace_at_the_start_does_nothing() {
        let mut field = TextField::new();
        field.backspace();
        assert!(field.is_empty());
        assert_eq!(field.caret(), 0);
    }

    #[test]
    fn delete_forward_at_the_end_does_nothing() {
        let mut field = TextField::new();
        field.insert('a');
        field.delete_forward();
        assert_eq!(field.value(), "a");
    }

    #[test]
    fn the_caret_cannot_leave_the_value() {
        let mut field = TextField::new();
        field.insert('a');
        field.move_caret(-99);
        assert_eq!(field.caret(), 0);
        field.move_caret(99);
        assert_eq!(field.caret(), 1);
    }

    #[test]
    fn control_characters_are_not_inserted() {
        // Key events deliver these, and they render as boxes.
        let mut field = TextField::new();
        for c in ['\n', '\t', '\u{1b}', '\r'] {
            field.insert(c);
        }
        assert!(field.is_empty());
    }

    #[test]
    fn a_length_limit_is_enforced_in_characters() {
        let mut field = TextField { max_length: Some(3), ..TextField::new() };
        for c in "áéíóú".chars() {
            field.insert(c);
        }
        assert_eq!(field.char_count(), 3);
    }

    #[test]
    fn a_password_field_never_renders_its_contents() {
        let mut field = TextField::password();
        for c in "secret".chars() {
            field.insert(c);
        }

        assert_eq!(field.display(), "••••••");
        assert!(!field.display().contains("secret"));
        // The value is still available to the code that submits it.
        assert_eq!(field.value(), "secret");
    }

    #[test]
    fn a_password_mask_does_not_leak_the_byte_length() {
        // Masking by byte length would draw a longer row of dots for an
        // accented password, which discloses something about its composition.
        let mut ascii = TextField::password();
        let mut accented = TextField::password();
        for c in "aaaaa".chars() {
            ascii.insert(c);
        }
        for c in "ááááá".chars() {
            accented.insert(c);
        }

        assert_eq!(ascii.display().chars().count(), accented.display().chars().count());
    }

    #[test]
    fn taking_the_value_clears_the_field_and_the_caret() {
        // Submitting a chat line and leaving the caret past the end of an
        // empty value would panic on the next keystroke.
        let mut field = TextField::new();
        for c in "hola".chars() {
            field.insert(c);
        }

        assert_eq!(field.take(), "hola");
        assert!(field.is_empty());
        assert_eq!(field.caret(), 0);
        field.insert('x');
        assert_eq!(field.value(), "x");
    }

    #[test]
    fn a_bar_fill_lands_on_whole_pixels() {
        // A fractional fill leaves a blurred edge against the track, which on
        // an 18px bar is most of what a player sees.
        for current in 0..=100 {
            let width = bar_fill_width(Gauge::new(current, 100), 137.0);
            assert_eq!(width.fract(), 0.0, "{current}% produced {width}");
            assert!((0.0..=137.0).contains(&width));
        }
    }

    #[test]
    fn a_bar_with_no_maximum_draws_nothing_rather_than_everything() {
        assert_eq!(bar_fill_width(Gauge::new(5, 0), 100.0), 0.0);
    }

    #[test]
    fn a_bar_label_never_shows_a_negative_number() {
        // The gauge can arrive negative; "HP: -40/0" helps nobody.
        assert_eq!(bar_label("HP", Gauge::new(-40, -10)), "HP: 0/0");
        assert_eq!(bar_label("HP", Gauge::new(20, 20)), "HP: 20/20");
    }

    #[test]
    fn every_rarity_has_a_distinct_colour() {
        use ao_core::view::Rarity;
        let rarities =
            [Rarity::Common, Rarity::Uncommon, Rarity::Rare, Rarity::Epic, Rarity::Legendary];

        for (i, a) in rarities.iter().enumerate() {
            for b in &rarities[i + 1..] {
                assert_ne!(rarity_ink(*a), rarity_ink(*b), "{a:?} and {b:?} share a colour");
            }
        }
    }
}
