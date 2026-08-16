//! The top status bar: identity on the left, telemetry and actions on the right.
//!
//! The reference client puts the build stamp in the title and FPS/latency/
//! population in the chrome, which the research notes call out as cheap trust
//! signals — a player can see at a glance whether a stutter is their machine,
//! the network or the server.
//!
//! Presentation only. Sampling lives in `hud`, which owns the probe cadence;
//! this module reads what it published.

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
    /// Enter and leave fullscreen.
    ///
    /// The client presents as a window on the page by default, like the
    /// reference client does; this takes over the whole display rather than
    /// merely filling the browser tab. Bevy cannot put its own host element
    /// into fullscreen, so this is the one action that has to reach the page —
    /// through a capability adapter, not by growing a second UI tree there.
    ToggleMaximise,
}

/// Whether the client is currently fullscreen.
///
/// Mirrored here so the button can render its state without asking the page
/// every frame. The page stays authoritative, and this is re-read from it
/// periodically — a player can leave fullscreen with Escape, which the client
/// never hears about otherwise and would then show the wrong state forever.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Maximised(pub bool);

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

fn icon_button(action: BarAction, glyph: &'static str) -> impl Bundle {
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
        children![label(glyph, type_scale::SMALL, ink::MUTED)],
    )
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
                    Node {
                        padding: UiRect::axes(Val::Px(space::WIDE), Val::Px(space::TIGHT)),
                        ..default()
                    },
                    BackgroundColor(surface::RAISED),
                    BarAction::Support,
                    children![label("SUPPORT", type_scale::SMALL, ink::GOLD)],
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
            for (action, glyph) in [
                (BarAction::Language, "LN"),
                (BarAction::Screenshot, "PIC"),
                (BarAction::MuteAudio, "AUD"),
                (BarAction::MuteCombat, "CBT"),
                (BarAction::Settings, "CFG"),
                (BarAction::ToggleMaximise, "\u{25a1}"),
            ] {
                group.spawn(icon_button(action, glyph));
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
    // A hidden or unfocused window is throttled by the platform, and reporting
    // that rate as performance tells a player their machine is failing when it
    // is idle.
    let foreground = windows.iter().any(|window| window.focused) && !document_hidden();

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
        if *action == BarAction::ToggleMaximise {
            maximised.0 = !maximised.0;
            set_page_maximised(maximised.0);
        }
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

    let actual = page_is_maximised();
    if actual != maximised.0 {
        maximised.0 = actual;
    }
}

#[cfg(target_arch = "wasm32")]
fn page_is_maximised() -> bool {
    use wasm_bindgen::JsValue;

    let Some(window) = web_sys::window() else {
        return false;
    };
    let Ok(adapter) = js_sys::Reflect::get(&window, &JsValue::from_str("aoWindow")) else {
        return false;
    };
    let Ok(getter) = js_sys::Reflect::get(&adapter, &JsValue::from_str("isMaximized")) else {
        return false;
    };
    getter
        .dyn_ref::<js_sys::Function>()
        .and_then(|f| f.call0(&adapter).ok())
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

#[cfg(not(target_arch = "wasm32"))]
fn page_is_maximised() -> bool {
    false
}

/// Ask the page to enter or leave fullscreen.
#[cfg(target_arch = "wasm32")]
fn set_page_maximised(on: bool) {
    use wasm_bindgen::JsValue;

    let Some(window) = web_sys::window() else {
        return;
    };
    let Ok(adapter) = js_sys::Reflect::get(&window, &JsValue::from_str("aoWindow")) else {
        return;
    };
    let Ok(setter) = js_sys::Reflect::get(&adapter, &JsValue::from_str("setMaximized")) else {
        return;
    };
    if let Some(setter) = setter.dyn_ref::<js_sys::Function>() {
        let _ = setter.call1(&adapter, &JsValue::from_bool(on));
    }
}

/// Native windows are maximised by the desktop, not by the client.
#[cfg(not(target_arch = "wasm32"))]
fn set_page_maximised(_on: bool) {}

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

        // The readout only measures a foreground window, so there has to be
        // one: a throttled background rate is not a frame rate.
        app.world_mut().spawn(Window { focused: true, ..Default::default() });

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

    #[test]
    fn an_unfocused_window_does_not_report_a_frame_rate() {
        // A throttled window's rate is the platform's scheduling, not the
        // machine's performance, and showing it tells a player their computer
        // is failing when it is idle.
        let mut app = App::new();
        app.insert_resource(Time::<()>::default())
            .init_resource::<HudStats>()
            .init_resource::<Session>()
            .add_systems(Update, update_readout);
        app.world_mut().spawn(Window { focused: false, ..Default::default() });

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

        assert_eq!(shown_values(&mut app, row)[0], "--", "a background rate was reported");
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
