//! Sampling for the status readout: round-trip latency and players online.
//!
//! Data only. The numbers are drawn by `ui::topbar`, which owns the shell's
//! presentation; this module owns how often they are measured, which is a
//! server-side cost as much as a client one.

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
            .add_systems(Update, (send_ping, poll_online));
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
    /// Players online, or None until the first poll returns.
    pub fn online(&self) -> Option<u32> {
        self.read().1
    }

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

/// What to show for latency.
///
/// "--" used to mean two unrelated things: no session to measure, and a session
/// that has not answered yet. Since the socket currently dies on the first
/// server frame it cannot decode, and the server only sends that frame when
/// login *succeeded*, whether a number ever appeared depended on how login went
/// — so the field looked random. They are now distinct: a reading, a wait, or
/// an explicit statement that there is nothing to measure.
pub fn ping_label(state: &ConnectionState, ping_ms: Option<u32>) -> String {
    match (state, ping_ms) {
        // A stale reading from a dead socket is worse than no reading.
        (ConnectionState::Offline | ConnectionState::Failed(_), _) => "--".into(),
        (_, Some(rtt)) => format!("{rtt}ms"),
        // Connected, nothing back yet. One probe every few seconds, so this is
        // the normal state for the first moments of a session.
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
