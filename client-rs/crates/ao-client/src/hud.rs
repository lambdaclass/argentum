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
            .init_resource::<OnlineRequest>()
            .add_systems(
                Update,
                (reset_schedule_on_reconnect, send_ping, poll_online, claim_online).chain(),
            );
    }
}

/// The online-count request waiting for an answer, if any.
///
/// One at a time on purpose: polling every fifteen seconds against a host that has
/// stopped answering would otherwise queue requests faster than they retire.
#[derive(Resource, Default)]
struct OnlineRequest {
    id: Option<crate::platform::RequestId>,
    /// Polls that have come round while this one was still outstanding.
    ///
    /// Without a limit, a request whose answer never arrives freezes the count for the
    /// rest of the session: `id` stays taken and every later poll declines to start. After
    /// a few intervals the request is abandoned and the next poll is allowed.
    waited: u8,
}

/// How many poll intervals an outstanding request may miss before it is abandoned.
const ONLINE_PATIENCE: u8 = 3;

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

/// Claim the online count, if it has arrived.
///
/// A separate system from the one that asks, because the answer arrives whenever the host
/// produces it. The code this replaces had a detached task write into an `Arc<Mutex<_>>`
/// that the readout also read, so the value reached the screen through a channel no system
/// declared. Now it is in the schedule, where it can be read and tested.
fn claim_online(
    platform: Res<crate::platform::Platform>,
    stats: Res<HudStats>,
    mut outstanding: ResMut<OnlineRequest>,
) {
    let Some(id) = outstanding.id else {
        return;
    };
    // Claimed by request, so this system cannot consume an answer meant for another. The
    // previous version drained the whole queue and dropped what it did not recognise,
    // which destroyed other consumers' results the moment there was one.
    let Some(outcome) = platform.http.claim(id) else {
        return;
    };
    outstanding.id = None;
    outstanding.waited = 0;

    match outcome.result {
        Ok(body) => stats.write(None, parse_online(&body)),
        // A count nobody could fetch is unknown, not zero: "0 players online" is a claim
        // about the world, and a failed fetch is a claim about the network.
        Err(_) => stats.write(None, None),
    }
}

/// Pull the count out of the meta document.
///
/// A targeted extraction rather than a JSON dependency for one integer, and pure, so the
/// shapes that have actually broken it can be tested without a network.
fn parse_online(body: &str) -> Option<u32> {
    // The token immediately after the key, not the next digits anywhere in the document.
    // Skipping forward to the first digit turns `{"online":null,"maps":842}` into 842 —
    // a number from another field, reported to the player as the population.
    let after = body.split("\"online\":").nth(1)?.trim_start();

    let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    digits.parse::<u32>().ok()
}

fn poll_online(
    time: Res<Time>,
    mut timer: ResMut<OnlineTimer>,
    config: Res<ClientConfig>,
    platform: Res<crate::platform::Platform>,
    mut outstanding: ResMut<OnlineRequest>,
) {
    if !timer.0.tick(time.delta()).just_finished() {
        return;
    }
    if !platform.clock.is_visible() {
        return;
    }
    if let Some(id) = outstanding.id {
        outstanding.waited = outstanding.waited.saturating_add(1);
        if outstanding.waited < ONLINE_PATIENCE {
            return;
        }
        // Given up on: the answer may still arrive, and nobody is waiting for it.
        platform.http.abandon(id);
        outstanding.id = None;
    }

    outstanding.waited = 0;
    outstanding.id =
        Some(platform.http.get_text(&format!("{}/api/meta/online", config.asset_origin)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::HostHttp;

    /// A host whose fetches answer exactly what a test says, when the test says.
    #[derive(Default)]
    struct ScriptedHttp {
        started: std::sync::Mutex<Vec<String>>,
        answers: std::sync::Mutex<Vec<crate::platform::Outcome>>,
    }

    impl crate::platform::HostHttp for ScriptedHttp {
        fn get_text(&self, url: &str) -> crate::platform::RequestId {
            let mut started = self.started.lock().expect("lock");
            started.push(url.to_string());
            crate::platform::RequestId(started.len() as u64)
        }

        fn claim(&self, id: crate::platform::RequestId) -> Option<crate::platform::Outcome> {
            let mut answers = self.answers.lock().expect("lock");
            let at = answers.iter().position(|outcome| outcome.id == id)?;
            Some(answers.remove(at))
        }

        fn abandon(&self, id: crate::platform::RequestId) {
            self.answers.lock().expect("lock").retain(|outcome| outcome.id != id);
        }
    }

    fn online_app(http: Arc<ScriptedHttp>) -> App {
        let mut app = App::new();
        app.insert_resource(Time::<()>::default())
            .insert_resource(crate::platform::Platform {
                http: http.clone(),
                ..crate::platform::Platform::with_clock(0.0, true)
            })
            .insert_resource(OnlineTimer(Timer::from_seconds(
                ONLINE_INTERVAL_SECS,
                TimerMode::Repeating,
            )))
            .init_resource::<OnlineRequest>()
            .init_resource::<HudStats>()
            .insert_resource(crate::config::ClientConfig {
                asset_origin: "http://host".to_string(),
                gateway_url: "ws://host".to_string(),
                scenario: None,
                credentials: None,
                client_hash: String::new(),
            })
            .add_systems(Update, (poll_online, claim_online).chain());
        app
    }

    #[test]
    fn the_online_count_is_read_out_of_the_answer() {
        // The shape the server actually sends, plus the shapes that have broken naive
        // parsing: another number first, and whitespace.
        assert_eq!(parse_online(r#"{"online":42,"maps":842}"#), Some(42));
        assert_eq!(parse_online(r#"{"maps":842,"online":7}"#), Some(7));
        assert_eq!(parse_online(r#"{"online": 128 }"#), Some(128));

        // And the shapes that are not an answer at all. None of them may become a count:
        // a made-up number on the status bar is worse than a dash.
        assert_eq!(parse_online("{}"), None);
        // Reviewed and found: skipping forward to the first digit read a number out of the
        // *next* field and reported it as the population.
        assert_eq!(parse_online(r#"{"online":null,"maps":842}"#), None);
        assert_eq!(parse_online(r#"{"online":,"maps":842}"#), None);
        assert_eq!(parse_online(r#"{"online":"many"}"#), None);
        assert_eq!(parse_online("<html>502 Bad Gateway</html>"), None);
        assert_eq!(parse_online(""), None);
    }

    #[test]
    fn one_poll_is_in_flight_at_a_time() {
        // Fifteen seconds apart against a host that stopped answering would otherwise
        // queue requests faster than they retire.
        let http = Arc::new(ScriptedHttp::default());
        let mut app = online_app(http.clone());

        // `advance` updates once itself, so one call is two ticks of the poll timer: the
        // first starts a request and the second must decline to start another.
        advance(&mut app, ONLINE_INTERVAL_SECS);

        assert_eq!(
            http.started.lock().expect("lock").len(),
            1,
            "a poll was started while one was already outstanding"
        );
    }

    #[test]
    fn a_request_that_is_never_answered_is_given_up_on() {
        // The other half, and the reason "one at a time" cannot be the whole rule: an
        // answer that never arrives would otherwise hold the slot for the rest of the
        // session and freeze the count permanently.
        let http = Arc::new(ScriptedHttp::default());
        let mut app = online_app(http.clone());

        // Driven until it recovers, with a bound: the exact tick it happens on is timer
        // bookkeeping, but that it happens within a few intervals is the contract.
        let bound = usize::from(ONLINE_PATIENCE) + 2;
        let mut started = 0;
        for _ in 0..bound {
            advance(&mut app, ONLINE_INTERVAL_SECS);
            started = http.started.lock().expect("lock").len();
            if started >= 2 {
                break;
            }
        }

        assert!(
            started >= 2,
            "the poll never recovered from an unanswered request in {bound} intervals"
        );

        // And the abandoned one is not left in the queue for somebody else to find.
        assert!(http.claim(crate::platform::RequestId(1)).is_none());
    }

    #[test]
    fn an_answer_reaches_the_readout_and_frees_the_next_poll() {
        let http = Arc::new(ScriptedHttp::default());
        let mut app = online_app(http.clone());

        advance(&mut app, ONLINE_INTERVAL_SECS);
        app.update();
        let id = crate::platform::RequestId(1);
        assert_eq!(app.world().resource::<OnlineRequest>().id, Some(id));

        http.answers
            .lock()
            .expect("lock")
            .push(crate::platform::Outcome { id, result: Ok(r#"{"online":314}"#.to_string()) });
        app.update();

        assert_eq!(app.world().resource::<HudStats>().online(), Some(314));
        assert_eq!(app.world().resource::<OnlineRequest>().id, None, "the slot stayed taken");

        // And the next interval starts a fresh one.
        advance(&mut app, ONLINE_INTERVAL_SECS);
        app.update();
        assert_eq!(http.started.lock().expect("lock").len(), 2);
    }

    #[test]
    fn a_failed_fetch_leaves_the_count_unknown_rather_than_zero() {
        // "0 players online" is a claim about the world; a failed fetch is a claim about
        // the network. The readout has a dash for the second and must use it.
        let http = Arc::new(ScriptedHttp::default());
        let mut app = online_app(http.clone());

        advance(&mut app, ONLINE_INTERVAL_SECS);
        app.update();
        http.answers.lock().expect("lock").push(crate::platform::Outcome {
            id: crate::platform::RequestId(1),
            result: Err(crate::platform::FetchError::Transport("socket closed".into())),
        });
        app.update();

        assert_eq!(app.world().resource::<HudStats>().online(), None);
        assert_eq!(app.world().resource::<OnlineRequest>().id, None);
    }

    #[test]
    fn an_answer_to_somebody_elses_request_is_left_where_it_was() {
        // Reviewed and found: the earlier version drained the whole queue and skipped what
        // it did not recognise — so the answer was gone, not left. Invisible with one
        // consumer, broken the moment there are two. This asserts the answer is *still
        // there* afterwards, which is the part that matters.
        let http = Arc::new(ScriptedHttp::default());
        let mut app = online_app(http.clone());

        advance(&mut app, ONLINE_INTERVAL_SECS);
        app.update();
        http.answers.lock().expect("lock").push(crate::platform::Outcome {
            id: crate::platform::RequestId(999),
            result: Ok(r#"{"online":5}"#.to_string()),
        });
        app.update();

        assert_eq!(app.world().resource::<HudStats>().online(), None);
        assert_eq!(
            app.world().resource::<OnlineRequest>().id,
            Some(crate::platform::RequestId(1)),
            "the outstanding request was retired by somebody else's answer"
        );

        // Still claimable by whoever it belongs to.
        let theirs = http.claim(crate::platform::RequestId(999));
        assert!(theirs.is_some(), "another consumer's answer was consumed and discarded");
    }

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
