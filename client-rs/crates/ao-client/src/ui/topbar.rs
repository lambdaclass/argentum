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

/// How often the telemetry text is rewritten.
///
/// Not every frame. A per-frame reciprocal swings over a wide range and the
/// number becomes an unreadable blur; at 144Hz it is also 144 string
/// allocations and text re-layouts a second to convey one value.
const READOUT_REFRESH_SECS: f32 = 1.0;

/// Frames and time since the readout was last rewritten.
///
/// Counting frames over a full second is the honest measurement: it is exactly
/// "frames per second", where a smoothed per-frame reciprocal sampled once a
/// second is an estimate that can miss a stutter entirely.
#[derive(Component, Default)]
pub struct FpsAverage {
    frames: u32,
    /// Accumulated in f64. Summing 60 f32 frame times of 1/60 lands just under
    /// one second, so an exact `< 1.0` comparison withholds the refresh for a
    /// whole extra frame and the counter reads one low forever.
    elapsed: f64,
    /// Last value shown, so the text survives between refreshes.
    pub last: u32,
}

/// Slack on the refresh boundary, in seconds.
///
/// Frame times never sum to a round number. A microsecond is far below
/// anything a once-a-second display refresh cares about, and without it the
/// boundary depends on which way the last float happened to round.
const REFRESH_EPSILON: f64 = 1e-6;

impl FpsAverage {
    /// Record a frame. Returns the new rate when a refresh is due.
    pub fn tick(&mut self, dt: f32) -> Option<u32> {
        self.frames += 1;
        self.elapsed += dt as f64;
        if self.elapsed + REFRESH_EPSILON < READOUT_REFRESH_SECS as f64 {
            return None;
        }
        let rate = (self.frames as f64 / self.elapsed).round() as u32;
        self.frames = 0;
        self.elapsed = 0.0;
        self.last = rate;
        Some(rate)
    }
}

/// The telemetry readout, updated every frame.
#[derive(Component)]
struct StatusReadout;

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
    /// Expand the client to fill the page, and back.
    ///
    /// The client presents as a window on the page by default, like the
    /// reference client does. Bevy cannot resize its own host element, so this
    /// is the one action that has to reach the page — through a capability
    /// adapter, not by growing a second UI tree there.
    ToggleMaximise,
}

/// Whether the host page is currently maximised.
///
/// Mirrored here so the button can render its state without asking the page
/// every frame. The page remains authoritative; this is refreshed from it.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Maximised(pub bool);

pub struct TopBarPlugin;

impl Plugin for TopBarPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<Maximised>()
            .add_systems(Startup, populate.after(super::shell::spawn_shell))
            .add_systems(Update, (update_readout, handle_bar_clicks));
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
    mut readout: Query<(&mut Text, &mut FpsAverage), With<StatusReadout>>,
) {
    let dt = time.delta_secs();
    if dt <= 0.0 {
        return;
    }

    for (mut text, mut average) in &mut readout {
        // Every frame counts toward the rate, but the text is only rewritten
        // when a full second of them has been measured.
        let Some(fps) = average.tick(dt) else {
            continue;
        };

        let ping = ping_label(&session.state(), session.ping_ms());
        let online = stats.online().map(|v| v.to_string()).unwrap_or_else(|| String::from("--"));

        text.0 = format!("FPS {fps}   PING {ping}   ON {online}");
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

/// Ask the page to grow or shrink the client.
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
    fn the_readout_is_rewritten_at_most_once_a_second() {
        // At 144Hz a per-frame rewrite is 144 string allocations and text
        // re-layouts a second, and the number is an unreadable blur.
        let mut average = FpsAverage::default();
        let frame = 1.0 / 144.0;

        // An exact frame count, not an accumulated float clock: the loop
        // condition would otherwise carry the same rounding error the code
        // under test has to tolerate.
        let refreshes = (0..144 * 3).filter(|_| average.tick(frame).is_some()).count();

        assert_eq!(refreshes, 3, "expected one refresh per second over three seconds");
    }

    #[test]
    fn the_rate_is_counted_rather_than_estimated() {
        // Exactly "frames per second": a smoothed reciprocal sampled once a
        // second is an estimate that can miss a stutter entirely.
        let mut average = FpsAverage::default();
        for _ in 0..59 {
            assert_eq!(average.tick(1.0 / 60.0), None);
        }
        assert_eq!(average.tick(1.0 / 60.0), Some(60));
    }

    #[test]
    fn a_severe_stutter_is_reported_rather_than_smoothed_away() {
        // One 500ms frame in a second is the thing a player wants to see.
        let mut average = FpsAverage::default();
        average.tick(0.5);
        let rate = average.tick(0.5);
        assert_eq!(rate, Some(2), "two frames in one second is 2 fps");
    }

    #[test]
    fn the_last_value_survives_between_refreshes() {
        // Otherwise the number blanks for a second at a time.
        let mut average = FpsAverage::default();
        for _ in 0..60 {
            average.tick(1.0 / 60.0);
        }
        assert_eq!(average.last, 60);
        average.tick(1.0 / 60.0);
        assert_eq!(average.last, 60, "still showing the previous second's rate");
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
