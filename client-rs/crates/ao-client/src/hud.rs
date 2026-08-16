//! Status row: frame rate, round-trip latency and players online.
//!
//! Modelled on the reference client documented in `research/argentumunited`,
//! which keeps FPS, ping and online count permanently in the window chrome.
//! They are cheap trust signals — a player can see at a glance whether a
//! stutter is their machine, the network, or the server.

use crate::net::SERVER_ORIGIN;
use bevy::prelude::*;
use std::sync::{Arc, Mutex};

/// How often latency and the player count are refreshed. Frequent enough to be
/// useful, rare enough that the status row is not itself a load source.
const POLL_INTERVAL_SECS: f32 = 5.0;

pub struct HudPlugin;

impl Plugin for HudPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(HudStats::default())
            .insert_resource(PollTimer(Timer::from_seconds(
                POLL_INTERVAL_SECS,
                TimerMode::Repeating,
            )))
            .add_systems(Startup, spawn_hud)
            .add_systems(Update, (poll_server, update_hud));
    }
}

/// Values shared with the async poller.
#[derive(Resource, Clone)]
pub struct HudStats {
    inner: Arc<Mutex<Stats>>,
}

#[derive(Default)]
struct Stats {
    ping_ms: Option<u32>,
    online: Option<u32>,
}

impl Default for HudStats {
    fn default() -> Self {
        Self { inner: Arc::new(Mutex::new(Stats::default())) }
    }
}

impl HudStats {
    fn read(&self) -> (Option<u32>, Option<u32>) {
        self.inner
            .lock()
            .map(|s| (s.ping_ms, s.online))
            .unwrap_or((None, None))
    }

    fn write(&self, ping_ms: Option<u32>, online: Option<u32>) {
        if let Ok(mut s) = self.inner.lock() {
            if ping_ms.is_some() {
                s.ping_ms = ping_ms;
            }
            if online.is_some() {
                s.online = online;
            }
        }
    }
}

#[derive(Resource)]
struct PollTimer(Timer);

#[derive(Component)]
struct HudText;

/// Smoothed frame rate.
///
/// A raw per-frame reciprocal is unreadable — it flickers over a wide range
/// every frame. This is an exponential moving average, which is what makes the
/// number legible without hiding a genuine drop.
#[derive(Component, Default)]
struct FpsAverage(f32);

fn spawn_hud(mut commands: Commands) {
    commands.spawn((
        Text::new("FPS --   PING --   ON --"),
        TextFont { font_size: 13.0, ..default() },
        TextColor(Color::srgb(0.88, 0.66, 0.29)),
        Node {
            position_type: PositionType::Absolute,
            top: Val::Px(6.0),
            right: Val::Px(10.0),
            ..default()
        },
        HudText,
        FpsAverage::default(),
    ));
}

fn update_hud(
    time: Res<Time>,
    stats: Res<HudStats>,
    mut query: Query<(&mut Text, &mut FpsAverage), With<HudText>>,
) {
    let dt = time.delta_secs();
    if dt <= 0.0 {
        return;
    }

    for (mut text, mut average) in &mut query {
        let instant = 1.0 / dt;
        average.0 = if average.0 == 0.0 {
            instant
        } else {
            // ~0.9 weight on history: responsive to a real drop within a few
            // frames, but not jittering on single-frame noise.
            average.0 * 0.9 + instant * 0.1
        };

        let (ping, online) = stats.read();
        let ping = ping.map(|v| format!("{v}ms")).unwrap_or_else(|| "--".into());
        let online = online.map(|v| v.to_string()).unwrap_or_else(|| "--".into());

        text.0 = format!("FPS {}   PING {}   ON {}", average.0.round() as u32, ping, online);
    }
}

fn poll_server(time: Res<Time>, mut timer: ResMut<PollTimer>, stats: Res<HudStats>) {
    if !timer.0.tick(time.delta()).just_finished() {
        return;
    }
    poll(stats.clone());
}

/// Measure latency to the server and read the player count in one request.
///
/// This is HTTP round-trip, not game-socket latency. Once the session survives
/// login, walk -> pos_update is the better measure because it reflects what the
/// player actually feels; until then this is honest about what it timed.
#[cfg(target_arch = "wasm32")]
fn poll(stats: HudStats) {
    wasm_bindgen_futures::spawn_local(async move {
        let started = js_sys::Date::now();
        match crate::net::fetch_text_public(&format!("{SERVER_ORIGIN}/api/meta/online")).await {
            Ok(body) => {
                let elapsed = (js_sys::Date::now() - started).round() as u32;
                let online = body
                    .split("\"online\":")
                    .nth(1)
                    .and_then(|rest| {
                        let digits: String =
                            rest.chars().skip_while(|c| !c.is_ascii_digit())
                                .take_while(|c| c.is_ascii_digit())
                                .collect();
                        digits.parse::<u32>().ok()
                    });
                stats.write(Some(elapsed), online);
            }
            Err(_) => stats.write(None, None),
        }
    });
}

#[cfg(not(target_arch = "wasm32"))]
fn poll(_stats: HudStats) {}
