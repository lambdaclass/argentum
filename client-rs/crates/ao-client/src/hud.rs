//! Status row: frame rate, round-trip latency and players online.
//!
//! Modelled on the reference client documented in `research/argentumunited`,
//! which keeps FPS, ping and online count permanently in the window chrome.
//! They are cheap trust signals — a player can see at a glance whether a
//! stutter is their machine, the network, or the server.

use crate::config::ClientConfig;
use crate::session::{ConnectionState, Session};
use bevy::prelude::*;
use std::sync::{Arc, Mutex};

/// How often latency is sampled. Frequent enough to track a change, rare enough
/// that the probe is not itself a load source.
const PING_INTERVAL_SECS: f32 = 5.0;

/// The player count changes slowly and costs an HTTP round trip, so it is
/// polled far less often than latency.
const ONLINE_INTERVAL_SECS: f32 = 15.0;

pub struct HudPlugin;

impl Plugin for HudPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(HudStats::default())
            .insert_resource(PingTimer(Timer::from_seconds(
                PING_INTERVAL_SECS,
                TimerMode::Repeating,
            )))
            .insert_resource(OnlineTimer(Timer::from_seconds(
                ONLINE_INTERVAL_SECS,
                TimerMode::Repeating,
            )))
            .add_systems(Startup, spawn_hud)
            .add_systems(Update, (send_ping, poll_online, update_hud));
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
        self.inner.lock().map(|s| (s.ping_ms, s.online)).unwrap_or((None, None))
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
struct PingTimer(Timer);

#[derive(Resource)]
struct OnlineTimer(Timer);

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
    session: Res<Session>,
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

        let (_http_ping, online) = stats.read();
        let ping = ping_label(&session.state(), session.ping_ms());
        let online = online.map(|v| v.to_string()).unwrap_or_else(|| "--".into());

        text.0 = format!("FPS {}   PING {}   ON {}", average.0.round() as u32, ping, online);
    }
}

/// What to show for latency.
///
/// "--" used to mean two unrelated things: no session to measure, and a session
/// that has not answered yet. Since the socket currently dies on the first
/// server frame it cannot decode, and the server only sends that frame when
/// login *succeeded*, whether a number ever appeared depended on how login went
/// — so the field looked random. They are now distinct: a reading, a wait, or
/// an explicit statement that there is nothing to measure.
fn ping_label(state: &ConnectionState, ping_ms: Option<u32>) -> String {
    match (state, ping_ms) {
        // A stale reading from a dead socket is worse than no reading.
        (ConnectionState::Offline | ConnectionState::Failed(_), _) => "--".into(),
        (_, Some(rtt)) => format!("{rtt}ms"),
        // Connected, nothing back yet. One probe every few seconds, so this is
        // the normal state for the first moments of a session.
        (ConnectionState::Connecting, None) => "...".into(),
        (_, None) => "...".into(),
    }
}

/// Probe game-socket latency.
///
/// This measures the game socket, not HTTP: it is the path a player's input
/// actually travels. It excludes egress queueing, so it answers "is the network
/// or server slow" rather than "am I being shed" — walk-to-confirmation is the
/// measure for the latter.
fn send_ping(time: Res<Time>, mut timer: ResMut<PingTimer>, session: Res<Session>) {
    if !timer.0.tick(time.delta()).just_finished() {
        return;
    }
    // Nothing to measure unless the socket is up, and probing a dead socket
    // would only accumulate timeouts.
    if !matches!(session.state(), ConnectionState::Authenticating | ConnectionState::Playing) {
        return;
    }
    // Paused while the tab is hidden: a backgrounded tab is throttled, so any
    // sample taken there measures the browser's scheduler, not the network.
    if document_hidden() {
        return;
    }

    if let Some(ping) = session.next_ping(now_ms()) {
        session.send(&ping);
    }
}

fn poll_online(
    time: Res<Time>,
    mut timer: ResMut<OnlineTimer>,
    stats: Res<HudStats>,
    config: Res<ClientConfig>,
) {
    if !timer.0.tick(time.delta()).just_finished() {
        return;
    }
    if document_hidden() {
        return;
    }
    poll(stats.clone(), config.asset_origin.clone());
}

#[cfg(target_arch = "wasm32")]
fn now_ms() -> f64 {
    js_sys::Date::now()
}

#[cfg(not(target_arch = "wasm32"))]
fn now_ms() -> f64 {
    0.0
}

#[cfg(target_arch = "wasm32")]
fn document_hidden() -> bool {
    web_sys::window().and_then(|w| w.document()).map(|d| d.hidden()).unwrap_or(false)
}

#[cfg(not(target_arch = "wasm32"))]
fn document_hidden() -> bool {
    false
}

/// Read the player count.
#[cfg(target_arch = "wasm32")]
fn poll(stats: HudStats, asset_origin: String) {
    wasm_bindgen_futures::spawn_local(async move {
        match crate::net::fetch_text_public(&format!("{asset_origin}/api/meta/online")).await {
            Ok(body) => {
                let online = body.split("\"online\":").nth(1).and_then(|rest| {
                    let digits: String = rest
                        .chars()
                        .skip_while(|c| !c.is_ascii_digit())
                        .take_while(|c| c.is_ascii_digit())
                        .collect();
                    digits.parse::<u32>().ok()
                });
                stats.write(None, online);
            }
            Err(_) => stats.write(None, None),
        }
    });
}

#[cfg(not(target_arch = "wasm32"))]
fn poll(_stats: HudStats, _asset_origin: String) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dead_socket_reports_nothing_to_measure() {
        // Not a stale number: the previous reading described a link that no
        // longer exists.
        assert_eq!(ping_label(&ConnectionState::Offline, None), "--");
        assert_eq!(ping_label(&ConnectionState::Failed("closed".into()), Some(12)), "--");
    }

    #[test]
    fn a_live_session_awaiting_its_first_reply_is_distinct_from_a_dead_one() {
        // The reported confusion. Both used to print "--", so a session that
        // had quietly died looked the same as one that simply had not been
        // probed yet, and the field appeared to flicker at random.
        assert_eq!(ping_label(&ConnectionState::Authenticating, None), "...");
        assert_eq!(ping_label(&ConnectionState::Playing, None), "...");
        assert_ne!(
            ping_label(&ConnectionState::Playing, None),
            ping_label(&ConnectionState::Offline, None)
        );
    }

    #[test]
    fn a_measured_round_trip_is_shown_in_milliseconds() {
        assert_eq!(ping_label(&ConnectionState::Playing, Some(8)), "8ms");
        assert_eq!(ping_label(&ConnectionState::Authenticating, Some(140)), "140ms");
    }

    #[test]
    fn probing_is_rare_enough_not_to_be_a_load_source() {
        // Every connected client sends these, so the interval is a server-side
        // cost as much as a client one.
        assert!(PING_INTERVAL_SECS >= 5.0, "at most one probe per five seconds");
        assert!(ONLINE_INTERVAL_SECS > PING_INTERVAL_SECS, "population moves slower than latency");
    }
}
