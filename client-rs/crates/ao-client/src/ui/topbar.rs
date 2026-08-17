//! The top status bar: identity on the left, telemetry and actions on the right.
//!
//! The reference client puts the build stamp in the title and FPS/latency/
//! population in the chrome, which the research notes call out as cheap trust
//! signals — a player can see at a glance whether a stutter is their machine,
//! the network or the server.
//!
//! Presentation only. Sampling lives in `hud`, which owns the probe cadence;
//! this module reads what it published.

use super::controls::{Control, ControlKey};
use super::icons::{action_icon, icon, AccessibleName, Icon, ShowsTooltip};
use super::shell::{label, Region};
use super::telemetry::{fps_label, FpsAverage};
use super::tokens::{ink, size, space, surface, type_scale};
use crate::hud::{ping_label, HudStats};
use crate::session::Session;
use bevy::prelude::*;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

/// Build identity shown in the bar.
///
/// The commit this binary was built from, stamped by `build.rs`. It is here so
/// a screenshot can be matched to a commit: without it, "this is how it looks
/// now" and "I just fixed that" cannot be lined up, which has already cost more
/// than one round trip.
///
/// A build with no git available says so rather than claiming an identity it
/// does not have.
fn build_stamp() -> String {
    match option_env!("AO_BUILD") {
        Some(build) => format!("build {build}"),
        None => "dev build".to_string(),
    }
}

/// The telemetry readout, updated every frame.
#[derive(Component)]
struct StatusReadout;

/// Whether the browser tab is hidden. Always false natively, where the window
/// being unfocused is the equivalent signal and Bevy reports it directly.
#[cfg(target_arch = "wasm32")]
fn document_hidden() -> bool {
    web_sys::window().and_then(|w| w.document()).map(|d| d.hidden()).unwrap_or(false)
}

#[cfg(not(target_arch = "wasm32"))]
fn document_hidden() -> bool {
    false
}

/// A platform action in the bar's right group.
///
/// Placeholders until W-0015 defines the platform-service boundary these need:
/// fullscreen, clipboard and external links are all capability calls.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub enum BarAction {
    Support,
    Language,
    Screenshot,
    MuteAudio,
    MuteCombat,
    Settings,
    /// Expand the host to the whole browser content area, and back.
    ///
    /// Distinct from fullscreen: the browser's tabs and address bar stay
    /// visible. Bevy cannot resize its own host element, so this reaches the
    /// page through a capability adapter.
    ToggleMaximise,
    /// Take over the display through the platform's fullscreen capability.
    ///
    /// Separate from maximise because they are different things to a player,
    /// and because this one needs a user gesture and can be refused.
    ToggleFullscreen,
}

/// Which host mode the client is in.
///
/// The host is authoritative; this is a mirror so the buttons can render their
/// state without asking the page every frame, re-read periodically because a
/// player can leave fullscreen with Escape and the page never says so.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum HostMode {
    /// A bounded, centred game window.
    #[default]
    Windowed,
    /// The whole browser content area, with the browser's own chrome visible.
    Maximized,
    /// The whole display.
    Fullscreen,
}

impl HostMode {
    /// The name the page uses.
    pub fn as_str(self) -> &'static str {
        match self {
            HostMode::Windowed => "windowed",
            HostMode::Maximized => "maximized",
            HostMode::Fullscreen => "fullscreen",
        }
    }

    pub fn from_str(name: &str) -> Self {
        match name {
            "maximized" => HostMode::Maximized,
            "fullscreen" => HostMode::Fullscreen,
            _ => HostMode::Windowed,
        }
    }

    /// What pressing maximise should ask for: it toggles back to windowed.
    pub fn toggled_maximize(self) -> Self {
        match self {
            HostMode::Maximized => HostMode::Windowed,
            _ => HostMode::Maximized,
        }
    }

    /// What pressing fullscreen should ask for.
    pub fn toggled_fullscreen(self) -> Self {
        match self {
            HostMode::Fullscreen => HostMode::Windowed,
            _ => HostMode::Fullscreen,
        }
    }
}

#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Maximised(pub HostMode);

/// How often the page is asked whether it is still fullscreen.
///
/// Escape leaves fullscreen without telling anyone, so the mirror has to be
/// refreshed. Twice a second is far below anything a player would notice and
/// far above one call per frame.
const FULLSCREEN_POLL_SECS: f32 = 0.5;

pub struct TopBarPlugin;

impl Plugin for TopBarPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<Maximised>()
            .add_systems(Startup, populate.after(super::shell::spawn_shell))
            .add_systems(Update, (update_readout, handle_bar_clicks, refresh_maximised));
    }
}

/// A top-bar action: an icon, a tooltip and an accessible name.
///
/// Never an abbreviation on its own. `LN`, `PIC`, `AUD`, `CBT` and `CFG` were
/// unreadable to anyone who had not written them, and an icon without a name is
/// the same guess in a different font.
fn icon_button(action: BarAction, kind: Icon) -> impl Bundle {
    (
        // Buttons opt back in to picking; the shell root ignores it so clicks
        // meant for the world are not swallowed by a transparent overlay.
        Button,
        Node {
            width: Val::Px(size::ICON_BUTTON),
            height: Val::Px(size::ICON_BUTTON),
            justify_content: JustifyContent::Center,
            align_items: AlignItems::Center,
            ..default()
        },
        BackgroundColor(surface::RAISED),
        action,
        AccessibleName::new(kind.name_key()),
        ShowsTooltip,
        ControlKey::new(kind.name_key()),
        Control { tab_index: bar_tab_index(action), ..default() },
        children![action_icon(kind, ink::PRIMARY)],
    )
}

/// Position of a bar action in the keyboard order.
///
/// Explicit rather than incidental: the bar is the first thing Tab reaches, and
/// its order should follow the row as it is read rather than the order the
/// systems happened to spawn it.
fn bar_tab_index(action: BarAction) -> u32 {
    match action {
        BarAction::Support => 1,
        BarAction::Language => 2,
        BarAction::Screenshot => 3,
        BarAction::MuteAudio => 4,
        BarAction::MuteCombat => 5,
        BarAction::Settings => 6,
        BarAction::ToggleMaximise => 7,
        BarAction::ToggleFullscreen => 8,
    }
}

/// One `LABEL value` pair in the status row.
///
/// The label is muted and the value is not, so the eye lands on the number
/// rather than on the word naming it.
fn readout_field(name: &'static str, value: &str) -> impl Bundle {
    (
        Node { align_items: AlignItems::Center, column_gap: Val::Px(space::TIGHT), ..default() },
        children![
            (
                Text::new(name),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::MUTED),
            ),
            (
                Text::new(value.to_string()),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::PRIMARY),
                ReadoutValue,
            ),
        ],
    )
}

/// The changing half of a readout field.
#[derive(Component)]
struct ReadoutValue;

fn populate(mut commands: Commands, bars: Query<(Entity, &Region)>) {
    let Some((bar, _)) = bars.iter().find(|(_, region)| **region == Region::TopBar) else {
        return;
    };

    commands.entity(bar).insert(Node {
        position_type: PositionType::Absolute,
        align_items: AlignItems::Center,
        justify_content: JustifyContent::SpaceBetween,
        padding: UiRect::horizontal(Val::Px(space::WIDE)),
        column_gap: Val::Px(space::WIDE),
        ..default()
    });

    commands.entity(bar).with_children(|bar| {
        // Identity.
        bar.spawn((
            Node { align_items: AlignItems::Center, column_gap: Val::Px(space::BASE), ..default() },
            children![
                label("Argentum", type_scale::BODY, ink::GOLD),
                label(build_stamp(), type_scale::SMALL, ink::MUTED),
            ],
        ));

        // Telemetry and actions.
        bar.spawn((
            Node { align_items: AlignItems::Center, column_gap: Val::Px(space::BASE), ..default() },
            children![
                (
                    Button,
                    Node {
                        padding: UiRect::axes(Val::Px(space::WIDE), Val::Px(space::TIGHT)),
                        align_items: AlignItems::Center,
                        column_gap: Val::Px(space::TIGHT),
                        ..default()
                    },
                    BackgroundColor(surface::RAISED),
                    BarAction::Support,
                    AccessibleName::new(Icon::Support.name_key()),
                    ShowsTooltip,
                    ControlKey::new(Icon::Support.name_key()),
                    Control { tab_index: bar_tab_index(BarAction::Support), ..default() },
                    // Icon *and* word: support is the one action a player looks
                    // for while something is already going wrong, and it is
                    // worth the width.
                    children![
                        icon(Icon::Support, type_scale::BODY, ink::GOLD),
                        label("SUPPORT", type_scale::SMALL, ink::GOLD),
                    ],
                ),
                // Three nodes with a real gap, not one string with spaces in
                // it. The face is proportional, so runs of spaces collapse to
                // about a character's width and the row reads "FPS144 PING--
                // ON1".
                (
                    Node {
                        align_items: AlignItems::Center,
                        column_gap: Val::Px(space::WIDE),
                        ..default()
                    },
                    StatusReadout,
                    FpsAverage::default(),
                    children![
                        readout_field("FPS", "--"),
                        readout_field("PING", "--"),
                        readout_field("ON", "--"),
                    ],
                ),
            ],
        ))
        .with_children(|group| {
            for (action, kind) in [
                (BarAction::Language, Icon::Language),
                (BarAction::Screenshot, Icon::Screenshot),
                (BarAction::MuteAudio, Icon::Audio),
                (BarAction::MuteCombat, Icon::Combat),
                (BarAction::Settings, Icon::Settings),
                (BarAction::ToggleMaximise, Icon::Maximise),
                (BarAction::ToggleFullscreen, Icon::Fullscreen),
            ] {
                group.spawn(icon_button(action, kind));
            }
        });
    });
}

fn update_readout(
    time: Res<Time>,
    stats: Res<HudStats>,
    session: Res<Session>,
    windows: Query<&Window>,
    mut rows: Query<(&mut FpsAverage, &Children), With<StatusReadout>>,
    fields: Query<&Children>,
    mut values: Query<&mut Text, With<ReadoutValue>>,
) {
    let dt = time.delta_secs_f64();
    if dt <= 0.0 {
        return;
    }
    // Visibility, not focus. A window that is visible but unfocused is still
    // being rendered continuously, and its frame rate is real — a player
    // watching the game beside a guide should see the truth. What must not be
    // reported is a *throttled* rate: a hidden tab runs at a few frames a
    // second, and showing that as performance says the machine is failing when
    // it is idle.
    let foreground = windows.iter().any(|window| window.visible) && !document_hidden();

    for (mut average, row) in &mut rows {
        average.set_foreground(foreground);

        // Every frame counts toward the rate, but the text is only rewritten
        // when a full foreground second of them has been measured.
        let Some(reading) = average.tick(dt) else {
            continue;
        };

        // Same order as `populate` spawns them.
        let next = [
            fps_label(reading),
            ping_label(&session.state(), session.ping_ms()),
            stats.online().map(|v| v.to_string()).unwrap_or_else(|| String::from("--")),
        ];

        for (field, value) in row.iter().zip(next) {
            let Ok(children) = fields.get(field) else {
                continue;
            };
            for child in children.iter() {
                if let Ok(mut text) = values.get_mut(child) {
                    text.0 = value.clone();
                }
            }
        }
    }
}

/// Act on a pressed bar button.
fn handle_bar_clicks(
    buttons: Query<(&Interaction, &BarAction), Changed<Interaction>>,
    mut maximised: ResMut<Maximised>,
) {
    for (interaction, action) in &buttons {
        if *interaction != Interaction::Pressed {
            continue;
        }
        let wanted = match action {
            BarAction::ToggleMaximise => maximised.0.toggled_maximize(),
            BarAction::ToggleFullscreen => maximised.0.toggled_fullscreen(),
            _ => continue,
        };
        // Optimistic, then corrected by the poll below: the page may refuse
        // fullscreen, and it is the page that knows.
        maximised.0 = wanted;
        request_host_mode(wanted);
    }
}

/// Re-read the page's fullscreen state.
///
/// A player can leave fullscreen with Escape, and the page does not tell the
/// client. Without this the mirror is wrong from then on and the button offers
/// to do what has already happened.
fn refresh_maximised(time: Res<Time>, mut since: Local<f32>, mut maximised: ResMut<Maximised>) {
    *since += time.delta_secs();
    if *since < FULLSCREEN_POLL_SECS {
        return;
    }
    *since = 0.0;

    let actual = page_host_mode();
    if actual != maximised.0 {
        maximised.0 = actual;
    }
}

#[cfg(target_arch = "wasm32")]
fn page_host_mode() -> HostMode {
    use wasm_bindgen::JsValue;

    let Some(window) = web_sys::window() else {
        return HostMode::Windowed;
    };
    let Ok(adapter) = js_sys::Reflect::get(&window, &JsValue::from_str("aoWindow")) else {
        return HostMode::Windowed;
    };
    let Ok(getter) = js_sys::Reflect::get(&adapter, &JsValue::from_str("getMode")) else {
        return HostMode::Windowed;
    };
    getter
        .dyn_ref::<js_sys::Function>()
        .and_then(|f| f.call0(&adapter).ok())
        .and_then(|v| v.as_string())
        .map(|name| HostMode::from_str(&name))
        .unwrap_or(HostMode::Windowed)
}

/// Native windows are managed by the desktop, not by the client.
#[cfg(not(target_arch = "wasm32"))]
fn page_host_mode() -> HostMode {
    HostMode::Windowed
}

/// Ask the page for a host mode.
#[cfg(target_arch = "wasm32")]
fn request_host_mode(mode: HostMode) {
    use wasm_bindgen::JsValue;

    let Some(window) = web_sys::window() else {
        return;
    };
    let Ok(adapter) = js_sys::Reflect::get(&window, &JsValue::from_str("aoWindow")) else {
        return;
    };
    let Ok(setter) = js_sys::Reflect::get(&adapter, &JsValue::from_str("setMode")) else {
        return;
    };
    if let Some(setter) = setter.dyn_ref::<js_sys::Function>() {
        let _ = setter.call1(&adapter, &JsValue::from_str(mode.as_str()));
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn request_host_mode(_mode: HostMode) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_readout_actually_replaces_its_values() {
        // Regression: splitting one string into three labelled fields left the
        // update writing to nothing, so the bar showed "FPS -- PING -- ON --"
        // forever. Compiling and laying out correctly is not the same as
        // updating, and only a test that runs the system can tell them apart.
        let mut app = App::new();
        app.insert_resource(Time::<()>::default())
            .init_resource::<HudStats>()
            .init_resource::<Session>()
            .add_systems(Update, update_readout);

        // The readout only measures a visible window, so there has to be one:
        // a throttled background rate is not a frame rate.
        app.world_mut().spawn(Window { visible: true, ..Default::default() });

        let row = app
            .world_mut()
            .spawn((StatusReadout, FpsAverage::default()))
            .with_children(|row| {
                for (name, value) in [("FPS", "--"), ("PING", "--"), ("ON", "--")] {
                    row.spawn(readout_field(name, value));
                }
            })
            .id();

        // Enough frames to cross the one-second refresh boundary.
        for _ in 0..70 {
            app.world_mut()
                .resource_mut::<Time<()>>()
                .advance_by(std::time::Duration::from_millis(16));
            app.update();
        }

        let shown = shown_values(&mut app, row);
        assert_eq!(shown.len(), 3, "expected three fields, got {shown:?}");
        assert_ne!(shown[0], "--", "the frame rate never updated");
    }

    /// The value half of each readout field, in order.
    fn shown_values(app: &mut App, row: Entity) -> Vec<String> {
        let fields: Vec<Entity> =
            app.world().get::<Children>(row).map(|c| c.iter().collect()).unwrap_or_default();

        let mut shown = Vec::new();
        for field in fields {
            let children: Vec<Entity> =
                app.world().get::<Children>(field).map(|c| c.iter().collect()).unwrap_or_default();
            for child in children {
                if app.world().get::<ReadoutValue>(child).is_some() {
                    if let Some(text) = app.world().get::<Text>(child) {
                        shown.push(text.0.clone());
                    }
                }
            }
        }
        shown
    }

    /// Build a readout app whose window has the given visibility.
    fn readout_app(visible: bool) -> (App, Entity) {
        let mut app = App::new();
        app.insert_resource(Time::<()>::default())
            .init_resource::<HudStats>()
            .init_resource::<Session>()
            .add_systems(Update, update_readout);
        app.world_mut().spawn(Window { visible, focused: false, ..Default::default() });

        let row = app
            .world_mut()
            .spawn((StatusReadout, FpsAverage::default()))
            .with_children(|row| {
                for (name, value) in [("FPS", "--"), ("PING", "--"), ("ON", "--")] {
                    row.spawn(readout_field(name, value));
                }
            })
            .id();

        for _ in 0..70 {
            app.world_mut()
                .resource_mut::<Time<()>>()
                .advance_by(std::time::Duration::from_millis(16));
            app.update();
        }
        (app, row)
    }

    #[test]
    fn a_visible_but_unfocused_window_still_reports_its_real_frame_rate() {
        // The task is explicit that a visible-but-unfocused window keeps
        // measuring actual rendered frames rather than switching to a
        // background reading. It is still being drawn, and a player watching
        // the game beside a guide should see the truth.
        let (mut app, row) = readout_app(true);
        assert_ne!(shown_values(&mut app, row)[0], "--", "an unfocused window reported nothing");
    }

    #[test]
    fn a_window_that_is_not_visible_does_not_report_a_frame_rate() {
        // What must never be shown is a *throttled* rate: a hidden tab runs at
        // a few frames a second, and reporting that as performance says the
        // machine is failing when it is idle.
        let (mut app, row) = readout_app(false);
        assert_eq!(shown_values(&mut app, row)[0], "--", "a throttled rate was reported");
    }

    #[test]
    fn a_local_build_does_not_claim_a_build_number() {
        // The stamp is a trust signal. A local build reporting "build 1" is
        // worse than one saying it is local, because it looks authoritative.
        let stamp = build_stamp();
        if option_env!("AO_BUILD").is_none() {
            assert_eq!(stamp, "dev build");
        } else {
            assert!(stamp.starts_with("build "));
            assert!(stamp.len() > "build ".len(), "an empty build stamp is worse than none");
        }
    }

    #[test]
    fn maximize_and_fullscreen_are_independent_controls() {
        // Two buttons, two jobs. The failure this rules out is either one
        // becoming a way to reach the other's mode, which is how a player ends
        // up unable to leave fullscreen because the button they pressed was
        // maximize and it put them back into fullscreen.
        for from in [HostMode::Windowed, HostMode::Maximized, HostMode::Fullscreen] {
            assert_ne!(
                from.toggled_maximize(),
                HostMode::Fullscreen,
                "maximize from {from:?} asks for fullscreen"
            );
            assert_ne!(
                from.toggled_fullscreen(),
                HostMode::Maximized,
                "fullscreen from {from:?} asks for maximize"
            );
            // And each does something from every mode: a control that is a
            // no-op in one mode is a control a player presses twice.
            assert_ne!(from.toggled_maximize(), from, "maximize from {from:?} changes nothing");
            assert_ne!(from.toggled_fullscreen(), from, "fullscreen from {from:?} changes nothing");
        }

        // Either mode is escapable by its own control, which is what makes
        // Escape a convenience rather than the only way out.
        assert_eq!(HostMode::Maximized.toggled_maximize(), HostMode::Windowed);
        assert_eq!(HostMode::Fullscreen.toggled_fullscreen(), HostMode::Windowed);
    }

    #[test]
    fn every_bar_action_is_distinct() {
        // These become platform-service calls in W-0015; two sharing an
        // identity would silently wire one button to the other's capability.
        let actions = [
            BarAction::Support,
            BarAction::Language,
            BarAction::Screenshot,
            BarAction::MuteAudio,
            BarAction::MuteCombat,
            BarAction::Settings,
        ];
        for (i, a) in actions.iter().enumerate() {
            for b in &actions[i + 1..] {
                assert_ne!(a, b);
            }
        }
    }
}
