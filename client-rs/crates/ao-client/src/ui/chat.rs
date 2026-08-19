//! The world message overlay, the channel filters and the composer.
//!
//! Chat in Argentum is not a panel beside the world; it is text over it, in the world's
//! upper left, where it competes for attention with everything the player is trying to
//! see. That is why this is bounded, wrapped and faded rather than a list that grows: an
//! announcement long enough to reach the minimap has covered the one part of the screen
//! a player uses to decide where to go.
//!
//! Composition is where focus ownership becomes visible. While the composer holds the
//! keyboard, movement, spells and hotbar keys must all be silent — the rule lives in
//! `controls::TextInputActive` and is consumed here rather than reimplemented.

use super::controls::{Activated, ControlKey, FocusOwner, TextField, TextInputActive};
use super::state::{IntentMessage, UiState};
use super::tokens::{ink, size, space, status, surface, type_scale};
use ao_core::view::{ChatChannel, ChatLine, Intent};
use bevy::prelude::*;

/// The channels a player can filter, in the order the strip shows them.
pub const CHANNELS: [ChatChannel; 6] = [
    ChatChannel::Say,
    ChatChannel::Whisper,
    ChatChannel::Party,
    ChatChannel::Guild,
    ChatChannel::Faction,
    ChatChannel::System,
];

/// Lines the overlay shows when it is not expanded.
///
/// Five, because the overlay sits on top of the world: the player asked to see the world,
/// and chat that permanently covers a third of it has taken that decision from them.
const COLLAPSED_LINES: usize = 5;

/// Lines it shows when the player expands it.
const EXPANDED_LINES: usize = 14;

/// How faint the oldest visible line is drawn.
///
/// Fading rather than dropping: a line that vanishes the instant a newer one arrives is
/// unreadable in a fight, and one that stays at full strength forever reads as current.
const OLDEST_ALPHA: f32 = 0.45;

/// How the player is looking at the chat.
#[derive(Resource, Debug, Clone, PartialEq, Eq)]
pub struct ChatView {
    pub expanded: bool,
    /// Channels the player has switched off, by position in [`CHANNELS`].
    hidden: [bool; CHANNELS.len()],
}

impl Default for ChatView {
    fn default() -> Self {
        Self { expanded: false, hidden: [false; CHANNELS.len()] }
    }
}

impl ChatView {
    pub fn shows(&self, channel: ChatChannel) -> bool {
        match CHANNELS.iter().position(|candidate| *candidate == channel) {
            Some(index) => !self.hidden[index],
            // A channel the strip does not list cannot be switched off, so it shows.
            None => true,
        }
    }

    pub fn toggle(&mut self, channel: ChatChannel) {
        if let Some(index) = CHANNELS.iter().position(|candidate| *candidate == channel) {
            self.hidden[index] = !self.hidden[index];
        }
    }

    fn visible_lines(&self) -> usize {
        if self.expanded {
            EXPANDED_LINES
        } else {
            COLLAPSED_LINES
        }
    }
}

/// Marks a channel filter with the channel it hides.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChatFilterButton(pub ChatChannel);

/// Marks the control that expands and collapses the overlay.
#[derive(Component, Debug, Clone, Copy)]
pub struct ChatExpandButton;

/// Marks the control that cycles which channel the composer speaks on.
#[derive(Component, Debug, Clone, Copy)]
pub struct ChatChannelButton;

/// Marks the composer's text field.
#[derive(Component, Debug, Clone, Copy)]
pub struct ChatCompose;

/// Content of the overlay, rebuilt when the chat or the view changes.
#[derive(Component)]
struct OverlayContent;

pub struct ChatPanelPlugin;

impl Plugin for ChatPanelPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<ChatView>()
            .add_systems(
                Update,
                (
                    apply_chat_activations,
                    // After the activations, so a filter switched off this frame is drawn
                    // switched off this frame rather than a frame later.
                    present_chat,
                )
                    .chain()
                    .after(super::shell::spawn_shell)
                    .before(super::controls::ControlSet::Present),
            )
            .add_systems(
                Update,
                (open_composer, send_composed_line, close_composer)
                    .chain()
                    .in_set(super::controls::GameplayInput),
            );
    }
}

/// The colour a channel's text is drawn in.
///
/// Colour *as well as* the speaker's name, never instead of it: this phase forbids status
/// carried by colour alone, and a player who cannot distinguish two of these still has to
/// be able to tell a whisper from a shout.
fn channel_ink(channel: ChatChannel) -> Color {
    match channel {
        ChatChannel::Say => ink::PRIMARY,
        ChatChannel::Whisper => status::MANA,
        ChatChannel::Party => status::THIRST,
        ChatChannel::Guild => status::EXPERIENCE,
        ChatChannel::Faction => ink::GOLD,
        ChatChannel::System => ink::MUTED,
    }
}

/// A channel's short label, for the filter strip and the composer.
pub fn channel_label(channel: ChatChannel) -> &'static str {
    match channel {
        ChatChannel::Say => "say",
        ChatChannel::Whisper => "whisper",
        ChatChannel::Party => "party",
        ChatChannel::Guild => "guild",
        ChatChannel::Faction => "faction",
        ChatChannel::System => "system",
    }
}

/// One line as it appears in the overlay.
///
/// The speaker is part of the text rather than a separate column: the overlay is bounded
/// and a column of names would take width from the words. System lines have no speaker
/// and are not given a fake one.
pub fn rendered_line(line: &ChatLine) -> String {
    if line.speaker.is_empty() {
        super::fallback_label(&line.body)
    } else {
        format!("{}: {}", line.speaker, super::fallback_label(&line.body))
    }
}

/// Which lines the overlay shows, oldest first.
///
/// Pure, so the filter and the bound can be tested without a running app.
pub fn visible<'a>(lines: &'a [ChatLine], view: &ChatView) -> Vec<&'a ChatLine> {
    let kept: Vec<&ChatLine> = lines
        .iter()
        .filter(|line| view.shows(line.channel))
        // A line with no body is dropped rather than drawn. The malformed fixture carries
        // one, and it rendered as an invisible row that still took a place in the bound —
        // so a real line was pushed out of view by nothing at all.
        .filter(|line| !line.body.trim().is_empty())
        .collect();
    let bound = view.visible_lines();
    if kept.len() <= bound {
        kept
    } else {
        kept[kept.len() - bound..].to_vec()
    }
}

/// How faint a line is, by its position among the visible ones.
pub fn line_alpha(position: usize, shown: usize) -> f32 {
    if shown <= 1 {
        return 1.0;
    }
    let oldest_first = position as f32 / (shown - 1) as f32;
    OLDEST_ALPHA + (1.0 - OLDEST_ALPHA) * oldest_first
}

fn present_chat(
    state: Res<UiState>,
    view: Res<ChatView>,
    areas: Query<Entity, With<super::shell::WorldMessageArea>>,
    existing: Query<Entity, With<OverlayContent>>,
    mut commands: Commands,
    mut last: Local<Option<(usize, ChatView, Option<ChatChannel>)>>,
) {
    let snapshot = state.get();
    // Compared by value rather than by change tick: the snapshot changes for reasons that
    // have nothing to do with chat, and rebuilding this overlay on each of them would
    // respawn the composer — taking the keyboard away from a player mid-sentence.
    let signature = (snapshot.chat.lines.len(), view.clone(), snapshot.chat.active_channel);
    if last.as_ref() == Some(&signature) {
        return;
    }
    *last = Some(signature);

    for entity in &existing {
        commands.entity(entity).despawn();
    }

    let lines: Vec<(String, Color)> = {
        let shown = visible(&snapshot.chat.lines, &view);
        let count = shown.len();
        shown
            .into_iter()
            .enumerate()
            .map(|(position, line)| {
                let mut colour = channel_ink(line.channel);
                colour.set_alpha(line_alpha(position, count));
                (rendered_line(line), colour)
            })
            .collect()
    };
    let active = snapshot.chat.active_channel.unwrap_or(ChatChannel::Say);
    let expanded = view.expanded;
    let shows: Vec<bool> = CHANNELS.into_iter().map(|channel| view.shows(channel)).collect();

    // One overlay, so one area: the lines and the filter states are moved into the
    // spawner, and a loop would be claiming there could be a second world to draw them
    // over.
    let Some(area) = areas.iter().next() else {
        return;
    };
    {
        commands.entity(area).with_children(|parent| {
            parent.spawn((
                OverlayContent,
                Node {
                    flex_direction: FlexDirection::Column,
                    row_gap: Val::Px(space::HAIR),
                    // Bounded so a long announcement cannot grow the overlay across the
                    // world and under the minimap. The lines wrap inside this width; the
                    // height is what the line bound above buys.
                    max_width: Val::Percent(100.0),
                    ..default()
                },
                Pickable::IGNORE,
                Children::spawn((
                    // The filter strip and the expander, above the words: the controls
                    // stay in one place while the lines move under them.
                    Spawn((
                        Node {
                            flex_direction: FlexDirection::Row,
                            column_gap: Val::Px(space::HAIR),
                            align_items: AlignItems::Center,
                            ..default()
                        },
                        Children::spawn((
                            SpawnIter(CHANNELS.into_iter().enumerate().map(move |(index, channel)| {
                                (
                                    filter_button(channel, shows[index], index),
                                    ChatFilterButton(channel),
                                )
                            })),
                            Spawn((
                                overlay_button(if expanded { "less" } else { "more" }, 620),
                                ControlKey::new("chat.expand"),
                                super::controls::Selected(expanded),
                                ChatExpandButton,
                            )),
                        )),
                    )),
                    SpawnIter(lines.into_iter().map(|(text, colour)| {
                        (
                            Node { max_width: Val::Percent(100.0), ..default() },
                            Text::new(text),
                            TextFont { font_size: type_scale::SMALL, ..default() },
                            TextColor(colour),
                            Pickable::IGNORE,
                        )
                    })),
                    // The composer, under the words it will join.
                    Spawn((
                        Node {
                            flex_direction: FlexDirection::Row,
                            column_gap: Val::Px(space::HAIR),
                            align_items: AlignItems::Center,
                            width: Val::Percent(100.0),
                            ..default()
                        },
                        Children::spawn((
                            Spawn((
                                overlay_button(channel_label(active), 630),
                                ControlKey::new("chat.channel"),
                                ChatChannelButton,
                            )),
                            Spawn((
                                super::controls::text_field(TextField::new(), 631),
                                ControlKey::new("chat.compose"),
                                ChatCompose,
                            )),
                        )),
                    )),
                )),
            ));
        });
    }
}

/// A small control for the overlay's strip.
fn overlay_button(label: &str, tab_index: u32) -> impl Bundle {
    (
        Node {
            padding: UiRect::axes(Val::Px(space::SNUG), Val::Px(space::HAIR)),
            border: UiRect::all(Val::Px(size::BORDER)),
            align_items: AlignItems::Center,
            ..default()
        },
        BackgroundColor(surface::PANEL),
        BorderColor::all(surface::EDGE),
        super::controls::interactive(tab_index, true),
        children![(
            Text::new(label.to_string()),
            TextFont { font_size: type_scale::MICRO, ..default() },
            TextColor(ink::PRIMARY),
        )],
    )
}

fn filter_button(channel: ChatChannel, shown: bool, index: usize) -> impl Bundle {
    (
        Node {
            padding: UiRect::axes(Val::Px(space::SNUG), Val::Px(space::HAIR)),
            border: UiRect::all(Val::Px(size::BORDER)),
            align_items: AlignItems::Center,
            ..default()
        },
        BackgroundColor(surface::PANEL),
        BorderColor::all(surface::EDGE),
        super::controls::interactive(600 + index as u32, true),
        ControlKey::new(filter_key(channel)),
        // Selection says which filters are on, and `present_controls` owns the border
        // that shows it.
        super::controls::Selected(shown),
        children![(
            Text::new(channel_label(channel).to_string()),
            TextFont { font_size: type_scale::MICRO, ..default() },
            // Struck through is not available, so a hidden channel's own label is drawn
            // in the disabled ink as well as losing its selection border: two signals,
            // neither of them colour alone.
            TextColor(if shown { channel_ink(channel) } else { ink::DISABLED }),
        )],
    )
}

/// The stable key of a channel's filter control.
pub fn filter_key(channel: ChatChannel) -> String {
    format!("chat.filter.{}", channel_label(channel))
}

fn apply_chat_activations(
    mut activated: MessageReader<Activated>,
    filters: Query<&ChatFilterButton>,
    expanders: Query<(), With<ChatExpandButton>>,
    channels: Query<(), With<ChatChannelButton>>,
    state: Res<UiState>,
    mut view: ResMut<ChatView>,
    mut intents: MessageWriter<IntentMessage>,
) {
    for message in activated.read() {
        if let Ok(filter) = filters.get(message.entity) {
            view.toggle(filter.0);
            continue;
        }
        if expanders.get(message.entity).is_ok() {
            view.expanded = !view.expanded;
            continue;
        }
        if channels.get(message.entity).is_ok() {
            // The next channel in the strip's order, wrapping. The server owns which
            // channels a character may actually speak on, so this asks rather than
            // deciding.
            let active = state.get().chat.active_channel.unwrap_or(ChatChannel::Say);
            let at = CHANNELS.iter().position(|candidate| *candidate == active).unwrap_or(0);
            let next = CHANNELS[(at + 1) % CHANNELS.len()];
            intents.write(IntentMessage(Intent::SetActiveChannel { channel: Some(next) }));
        }
    }
}

/// Enter opens the composer.
///
/// The convention every AO client uses, and the reason the suppression rule exists: from
/// the moment this runs, the keyboard belongs to the composer and "w" is a letter rather
/// than a step north.
fn open_composer(
    text_input: Res<TextInputActive>,
    keys: Res<ButtonInput<KeyCode>>,
    composers: Query<(Entity, Option<&ControlKey>), With<ChatCompose>>,
    mut focus: ResMut<FocusOwner>,
) {
    if text_input.0 || !keys.just_pressed(KeyCode::Enter) {
        return;
    }
    if let Some((entity, key)) = composers.iter().next() {
        focus.focus(entity, key);
    }
}

/// Enter again sends what was typed.
fn send_composed_line(
    text_input: Res<TextInputActive>,
    keys: Res<ButtonInput<KeyCode>>,
    focus: Res<FocusOwner>,
    state: Res<UiState>,
    mut composers: Query<(Entity, &mut TextField), With<ChatCompose>>,
    mut intents: MessageWriter<IntentMessage>,
) {
    if !text_input.0 || !keys.just_pressed(KeyCode::Enter) {
        return;
    }
    for (entity, mut field) in &mut composers {
        if focus.entity() != Some(entity) {
            continue;
        }
        // An empty line is not a message. Sending one would ask the server to broadcast
        // nothing, and the player pressed Enter to *leave* the composer.
        if field.is_empty() {
            continue;
        }
        let body = field.take();
        let channel = state.get().chat.active_channel.unwrap_or(ChatChannel::Say);
        intents.write(IntentMessage(Intent::SendChat { channel, body }));
    }
}

/// Escape closes the composer and keeps what was typed.
///
/// Kept, not discarded: a player who hits Escape to dodge has not asked to lose the
/// sentence. The keyboard goes back to the world either way, which is the part that
/// matters in a fight.
fn close_composer(
    text_input: Res<TextInputActive>,
    keys: Res<ButtonInput<KeyCode>>,
    composers: Query<Entity, With<ChatCompose>>,
    mut focus: ResMut<FocusOwner>,
) {
    if !text_input.0 || !keys.just_pressed(KeyCode::Escape) {
        return;
    }
    if focus.entity().is_some_and(|entity| composers.get(entity).is_ok()) {
        focus.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures::{self, Scenario};

    fn line(channel: ChatChannel, speaker: &str, body: &str) -> ChatLine {
        ChatLine { channel, speaker: speaker.to_string(), body: body.to_string() }
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

    /// A running shell with the overlay on it, recording what it asks for.
    fn chat_app() -> App {
        let mut app = super::super::testing::shell_app(Vec2::new(1280.0, 832.0));
        app.init_resource::<Recorded>().add_systems(
            Update,
            record_intents.after(super::super::controls::GameplayInput),
        );
        app.update();
        app
    }

    fn intents(app: &App) -> Vec<Intent> {
        app.world().resource::<Recorded>().0.clone()
    }

    fn composer(app: &mut App) -> Entity {
        app.world_mut()
            .query_filtered::<Entity, With<ChatCompose>>()
            .iter(app.world())
            .next()
            .expect("the overlay has a composer")
    }

    fn overlay_text(app: &mut App) -> Vec<String> {
        app.world_mut()
            .query::<&Text>()
            .iter(app.world())
            .map(|text| text.0.clone())
            .collect()
    }

    #[test]
    fn the_overlay_draws_the_snapshots_lines_over_the_world() {
        let mut app = chat_app();
        let lines = app.world().resource::<UiState>().get().chat.lines.clone();
        assert!(!lines.is_empty(), "the fixture has no chat to draw");

        let shown = overlay_text(&mut app);
        for line in visible(&lines, &ChatView::default()) {
            let rendered = rendered_line(line);
            assert!(shown.contains(&rendered), "the overlay is missing {rendered:?}: {shown:?}");
        }
    }

    #[test]
    fn the_overlay_never_reaches_the_minimap() {
        // The rule this task states outright. Checked against a long announcement,
        // because a bounded overlay and a wrapped one are different things and only the
        // second survives a server notice nobody sized.
        use super::super::testing;

        let mut app = chat_app();
        let mut shouted = app.world().resource::<UiState>().get().clone();
        shouted.chat.lines.push(ChatLine {
            channel: ChatChannel::System,
            speaker: String::new(),
            body: "the gates of Nix have opened and every citizen is called to the walls \
                   before the second bell, by order of the council"
                .repeat(3),
        });
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), shouted);
        for _ in 0..4 {
            app.update();
        }

        let minimap = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::Minimap>>()
            .iter(app.world())
            .next()
            .expect("the shell has a minimap");
        let minimap_rect = testing::solved_rect(&app, minimap).expect("laid out");

        let overlay = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::shell::WorldMessageArea>>()
            .iter(app.world())
            .next()
            .expect("the shell has a message area");
        let mut drawn = 0;
        for entity in testing::descendants(&app, overlay) {
            let Some(rect) = testing::solved_rect(&app, entity) else {
                continue;
            };
            if rect.width() <= 0.0 || rect.height() <= 0.0 {
                continue;
            }
            drawn += 1;
            let overlaps = rect.min.x < minimap_rect.max.x
                && rect.max.x > minimap_rect.min.x
                && rect.min.y < minimap_rect.max.y
                && rect.max.y > minimap_rect.min.y;
            assert!(!overlaps, "chat at {rect:?} runs under the minimap at {minimap_rect:?}");
        }
        // Or the check above compared nothing against the minimap and passed for it.
        assert!(drawn > 3, "the overlay drew almost nothing to test: {drawn} nodes with area");
        assert!(minimap_rect.width() > 0.0, "the minimap has no area to run under");
    }

    #[test]
    fn enter_gives_the_keyboard_to_the_composer_and_escape_gives_it_back() {
        // The whole point of the focus rule: from the moment the composer holds the
        // keyboard, "w" is a letter rather than a step north.
        use super::super::testing;

        let mut app = chat_app();
        assert!(
            !app.world().resource::<TextInputActive>().0,
            "text owns the keyboard before anyone asked to type"
        );

        testing::tap_key(&mut app, KeyCode::Enter);
        app.update();
        let field = composer(&mut app);
        assert_eq!(
            app.world().resource::<FocusOwner>().entity(),
            Some(field),
            "Enter did not open the composer"
        );
        assert!(
            app.world().resource::<TextInputActive>().0,
            "the composer has focus but the keyboard is still the world's"
        );

        testing::tap_key(&mut app, KeyCode::Escape);
        app.update();
        assert!(
            !app.world().resource::<TextInputActive>().0,
            "Escape did not give the keyboard back to the world"
        );
    }

    #[test]
    fn what_was_typed_is_sent_on_the_active_channel_and_the_composer_clears() {
        use super::super::testing;

        let mut app = chat_app();
        testing::tap_key(&mut app, KeyCode::Enter);
        app.update();

        let field = composer(&mut app);
        {
            let mut text = app.world_mut().get_mut::<TextField>(field).expect("a field");
            for character in "hola".chars() {
                text.insert(character);
            }
        }
        testing::tap_key(&mut app, KeyCode::Enter);
        app.update();

        let asked = intents(&app);
        assert!(
            asked.iter().any(|intent| matches!(
                intent,
                Intent::SendChat { body, .. } if body == "hola"
            )),
            "the line was not sent: {asked:?}"
        );
        assert!(
            app.world().get::<TextField>(field).expect("a field").is_empty(),
            "the composer kept the line it just sent"
        );
    }

    #[test]
    fn an_empty_composer_sends_nothing() {
        use super::super::testing;

        let mut app = chat_app();
        testing::tap_key(&mut app, KeyCode::Enter);
        app.update();
        testing::tap_key(&mut app, KeyCode::Enter);
        app.update();

        assert!(
            !intents(&app).iter().any(|intent| matches!(intent, Intent::SendChat { .. })),
            "an empty composer broadcast nothing to everyone: {:?}",
            intents(&app)
        );
    }

    #[test]
    fn a_filter_control_hides_its_channel_and_says_so() {
        let mut app = chat_app();
        let (entity, channel) = app
            .world_mut()
            .query::<(Entity, &ChatFilterButton)>()
            .iter(app.world())
            .map(|(entity, filter)| (entity, filter.0))
            .find(|(_, channel)| *channel == ChatChannel::System)
            .expect("the strip has a system filter");

        app.world_mut().write_message(Activated {
            entity,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();
        app.update();

        assert!(
            !app.world().resource::<ChatView>().shows(ChatChannel::System),
            "the filter did not hide its channel"
        );
        let system_line = app
            .world()
            .resource::<UiState>()
            .get()
            .chat
            .lines
            .iter()
            .find(|line| line.channel == ChatChannel::System)
            .map(rendered_line)
            .expect("the fixture has a system line");
        assert!(
            !overlay_text(&mut app).contains(&system_line),
            "a hidden channel is still on screen"
        );
    }

    #[test]
    fn the_channel_control_asks_for_the_next_channel() {
        let mut app = chat_app();
        let entity = app
            .world_mut()
            .query_filtered::<Entity, With<ChatChannelButton>>()
            .iter(app.world())
            .next()
            .expect("the composer has a channel control");
        let before = app.world().resource::<UiState>().get().chat.active_channel;

        app.world_mut().write_message(Activated {
            entity,
            source: super::super::controls::ActivationSource::Keyboard,
        });
        app.update();

        let asked = intents(&app);
        assert!(
            asked.iter().any(|intent| matches!(
                intent,
                Intent::SetActiveChannel { channel } if *channel != before
            )),
            "the channel control asked for nothing new: {asked:?} from {before:?}"
        );
    }

    #[test]
    fn a_hidden_channel_is_filtered_out_and_the_rest_stay() {
        let lines = vec![
            line(ChatChannel::Say, "Aldar", "hello"),
            line(ChatChannel::System, "", "chat.welcome"),
            line(ChatChannel::Party, "Borzug", "north"),
        ];
        let mut view = ChatView::default();
        view.toggle(ChatChannel::System);

        let shown: Vec<&ChatLine> = visible(&lines, &view);

        assert_eq!(shown.len(), 2, "the filter removed the wrong number of lines");
        assert!(
            shown.iter().all(|line| line.channel != ChatChannel::System),
            "a hidden channel is still shown"
        );
        assert!(view.shows(ChatChannel::Say), "hiding one channel hid another");
    }

    #[test]
    fn the_overlay_shows_the_newest_lines_and_expands_to_more_of_them() {
        let lines: Vec<ChatLine> = (0..30)
            .map(|index| line(ChatChannel::Say, "Aldar", &format!("line {index}")))
            .collect();
        let mut view = ChatView::default();

        let collapsed = visible(&lines, &view);
        assert_eq!(collapsed.len(), COLLAPSED_LINES);
        assert_eq!(
            collapsed.last().map(|line| line.body.as_str()),
            Some("line 29"),
            "the overlay is showing the oldest lines rather than the newest"
        );

        view.expanded = true;
        assert_eq!(visible(&lines, &view).len(), EXPANDED_LINES);
    }

    #[test]
    fn fewer_lines_than_the_bound_are_all_shown() {
        let lines = vec![line(ChatChannel::Say, "Aldar", "hello")];
        assert_eq!(visible(&lines, &ChatView::default()).len(), 1);
    }

    #[test]
    fn the_oldest_visible_line_is_the_faintest_and_the_newest_is_full_strength() {
        assert_eq!(line_alpha(4, 5), 1.0);
        assert_eq!(line_alpha(0, 5), OLDEST_ALPHA);
        assert!(line_alpha(2, 5) > OLDEST_ALPHA && line_alpha(2, 5) < 1.0);
        // A single line is current, not half faded.
        assert_eq!(line_alpha(0, 1), 1.0);
    }

    #[test]
    fn a_system_line_is_not_given_a_speaker_it_does_not_have() {
        let system = line(ChatChannel::System, "", "chat.welcome");
        let rendered = rendered_line(&system);
        assert!(!rendered.contains(':'), "a system line was given a speaker: {rendered}");
        assert!(!rendered.contains('.'), "a semantic key reached the overlay: {rendered}");
    }

    #[test]
    fn every_channel_has_a_label_and_a_distinct_filter_key() {
        let mut keys = Vec::new();
        for channel in CHANNELS {
            let key = filter_key(channel);
            assert!(!keys.contains(&key), "{channel:?} reuses a filter key");
            assert!(!channel_label(channel).is_empty());
            keys.push(key);
        }
    }

    #[test]
    fn every_fixture_renders_its_chat_without_showing_a_key() {
        for scenario in Scenario::ALL {
            let snapshot = fixtures::snapshot(scenario);
            for line in visible(&snapshot.chat.lines, &ChatView::default()) {
                let rendered = rendered_line(line);
                assert!(!rendered.is_empty(), "{scenario:?} renders an empty line");
                assert!(
                    !rendered.contains(".sample.") && !rendered.starts_with("chat."),
                    "{scenario:?} shows a semantic key: {rendered}"
                );
            }
        }
    }
}
