//! Sampling for the status readout: round-trip latency and players online.
//!
//! Data only. The numbers are drawn by `ui::topbar`, which owns the shell's
//! presentation; this module owns how often they are measured, which is a
//! server-side cost as much as a client one.

use crate::config::ClientConfig;
use crate::session::{ConnectionState, Session};
use crate::ui::telemetry::PingSchedule;
use bevy::prelude::*;
use std::sync::{Arc, Mutex};

/// The player count changes slowly and costs an HTTP round trip, so it is
/// polled far less often than latency.
const ONLINE_INTERVAL_SECS: f32 = 15.0;

pub struct HudPlugin;

impl Plugin for HudPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(HudStats::default())
            .init_resource::<PingSchedule>()
            .insert_resource(OnlineTimer(Timer::from_seconds(
                ONLINE_INTERVAL_SECS,
                TimerMode::Repeating,
            )))
            .add_systems(Update, (reset_schedule_on_reconnect, send_ping, poll_online).chain());
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
/// Reset the probe schedule when the connection restarts.
///
/// The elapsed time belonged to a socket that no longer exists. Carried over, a
/// reconnect either probes immediately — before the new session is ready — or
/// waits out the remainder of an interval that has nothing to do with it.
fn reset_schedule_on_reconnect(
    session: Res<Session>,
    mut schedule: ResMut<PingSchedule>,
    mut previous: Local<Option<ConnectionState>>,
) {
    let current = session.state();
    let restarted = matches!(current, ConnectionState::Connecting)
        && !matches!(*previous, Some(ConnectionState::Connecting));

    if restarted {
        schedule.reset();
    }
    *previous = Some(current);
}

fn send_ping(
    time: Res<Time>,
    mut schedule: ResMut<PingSchedule>,
    session: Res<Session>,
    platform: Res<crate::platform::Platform>,
) {
    // Scheduled on its own clock, not from the readout's refresh: tying the
    // probe to a display update makes its rate a function of the frame rate,
    // so a struggling client probes less exactly when latency matters most.
    //
    // The schedule fires at most once per call however long the frame was, so
    // a suspended tab resuming after thirty seconds sends one probe rather
    // than the six a catch-up timer would owe.
    if !schedule.tick(time.delta_secs_f64()) {
        return;
    }
    // Nothing to measure unless the socket is up, and probing a dead socket
    // would only accumulate timeouts.
    if !matches!(session.state(), ConnectionState::Authenticating | ConnectionState::Playing) {
        return;
    }
    // Paused while the tab is hidden: a backgrounded tab is throttled, so any
    // sample taken there measures the browser's scheduler, not the network.
    // The schedule has already been reset by the tick above, so resuming does
    // not immediately fire a held-over probe either.
    if !platform.clock.is_visible() {
        return;
    }

    if let Some(ping) = session.next_ping(platform.clock.now_ms()) {
        session.send(&ping);
    }
}

fn poll_online(
    time: Res<Time>,
    mut timer: ResMut<OnlineTimer>,
    stats: Res<HudStats>,
    config: Res<ClientConfig>,
    platform: Res<crate::platform::Platform>,
) {
    if !timer.0.tick(time.delta()).just_finished() {
        return;
    }
    if !platform.clock.is_visible() {
        return;
    }
    poll(stats.clone(), config.asset_origin.clone());
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

    /// An app running the probe schedule against a fake clock.
    fn probe_app() -> App {
        let mut app = App::new();
        app.insert_resource(Time::<()>::default())
            // Visible, because these tests are about the probe schedule rather than
            // about a backgrounded tab; the hidden case is its own test below.
            .insert_resource(crate::platform::Platform::with_clock(0.0, true))
            .init_resource::<PingSchedule>()
            .init_resource::<Session>()
            .add_systems(Update, (reset_schedule_on_reconnect, send_ping).chain());
        app
    }

    fn advance(app: &mut App, seconds: f32) {
        app.world_mut()
            .resource_mut::<Time<()>>()
            .advance_by(std::time::Duration::from_secs_f32(seconds));
        app.update();
    }

    #[test]
    fn reconnecting_resets_the_probe_schedule() {
        // The elapsed time belonged to a socket that no longer exists. Carried
        // over, a reconnect either probes before the new session is ready or
        // waits out the remainder of an interval that has nothing to do with
        // it.
        let mut app = probe_app();

        // Four seconds into the interval on the old connection.
        advance(&mut app, 4.0);
        assert!(app.world().resource::<PingSchedule>().remaining() < 2.0);

        app.world().resource::<Session>().set_state_for_test(ConnectionState::Connecting);
        // A zero-length frame: Bevy keeps the previous delta until it is
        // advanced again, so a plain update would re-apply the four seconds and
        // hide the reset that just happened.
        advance(&mut app, 0.0);

        assert_eq!(
            app.world().resource::<PingSchedule>().remaining(),
            crate::ui::telemetry::PING_INTERVAL_SECS,
            "the new connection inherited the old one's elapsed time"
        );
    }

    #[test]
    fn staying_connected_does_not_keep_resetting_the_schedule() {
        // The reset fires on the transition into Connecting, not for every
        // frame spent there — otherwise the probe never becomes due.
        let mut app = probe_app();
        app.world().resource::<Session>().set_state_for_test(ConnectionState::Connecting);
        advance(&mut app, 0.0);

        advance(&mut app, 3.0);
        assert!(
            app.world().resource::<PingSchedule>().remaining() < 3.0,
            "the schedule was reset again while already connecting"
        );
    }

    #[test]
    fn probing_is_rare_enough_not_to_be_a_load_source() {
        // Every connected client sends these, so the interval is a server-side
        // cost as much as a client one. The cadence itself is proved in
        // `ui::telemetry`; this only pins the relationship between the two
        // polls, which live in different modules and could drift apart.
        use crate::ui::telemetry::PING_INTERVAL_SECS;

        assert!(PING_INTERVAL_SECS >= 5.0, "at most one probe per five seconds");
        assert!(
            f64::from(ONLINE_INTERVAL_SECS) > PING_INTERVAL_SECS,
            "population moves slower than latency and must be polled less often"
        );
    }
}
