//! Live connection to the game server.
//!
//! Speaks the AO20 binary protocol over the same WebSocket gateway the web
//! client uses (`ws://host:7667/ao`). Encoding and decoding live in `ao-core`
//! so they are testable natively; this module is only transport and plumbing.

use ao_core::protocol::{self, Decoded, ServerMessage};
use bevy::prelude::Resource;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq)]
pub enum ConnectionState {
    Offline,
    Connecting,
    /// Socket open, login sent, waiting for the server to place us.
    Authenticating,
    Playing,
    Failed(String),
}

/// A ping awaiting its echo.
struct Outstanding {
    token: [u8; 8],
    sent_at_ms: f64,
}

/// How long to wait before treating a ping as lost.
const PING_TIMEOUT_MS: f64 = 10_000.0;

/// Samples kept for the median. Small enough to react to a real change,
/// large enough that one unlucky packet does not move the number.
const PING_SAMPLES: usize = 5;

#[derive(Default)]
struct SessionInner {
    state: Option<ConnectionState>,
    inbox: Vec<ServerMessage>,
    /// Bytes received but not yet forming a whole packet.
    buffer: Vec<u8>,
    #[cfg(target_arch = "wasm32")]
    socket: Option<web_sys::WebSocket>,
    /// Anti-cheat requires a strictly increasing counter per command.
    walk_count: i32,
    /// At most one ping is ever in flight: pings must not accumulate if the
    /// server stops answering, or a stalled link would queue an unbounded
    /// backlog and then report a burst of meaningless samples.
    outstanding_ping: Option<Outstanding>,
    ping_samples: Vec<u32>,
    next_ping_token: u64,
}

#[derive(Resource, Clone)]
pub struct Session {
    inner: Arc<Mutex<SessionInner>>,
}

impl Default for Session {
    fn default() -> Self {
        Self { inner: Arc::new(Mutex::new(SessionInner::default())) }
    }
}

impl Session {
    pub fn state(&self) -> ConnectionState {
        self.inner.lock().ok().and_then(|s| s.state.clone()).unwrap_or(ConnectionState::Offline)
    }

    fn set_state(&self, state: ConnectionState) {
        if let Ok(mut s) = self.inner.lock() {
            s.state = Some(state);
        }
    }

    /// Note that the server has placed us in the world.
    ///
    /// The AO20 handshake has no "login accepted" packet: the server signals
    /// success by simply starting to send world state. The first position
    /// update is therefore the only evidence login worked, and it is what ends
    /// `Authenticating`. Only that transition is allowed here — a later
    /// position update must not resurrect a connection that has since failed.
    pub fn mark_playing(&self) {
        if let Ok(mut s) = self.inner.lock() {
            if s.state == Some(ConnectionState::Authenticating) {
                s.state = Some(ConnectionState::Playing);
            }
        }
    }

    /// Drain everything decoded since the last call.
    pub fn drain(&self) -> Vec<ServerMessage> {
        self.inner.lock().map(|mut s| std::mem::take(&mut s.inbox)).unwrap_or_default()
    }

    /// Feed received bytes and decode whole packets out of them.
    ///
    /// Packet lengths are not on the wire, so an unknown id cannot be skipped:
    /// everything after it would be misread. The connection is failed instead,
    /// which is loud rather than subtly wrong.
    ///
    /// Only the wasm socket callbacks call this today; native transport is not
    /// implemented yet.
    #[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
    fn ingest(&self, bytes: &[u8], now_ms: f64) {
        let mut failure = None;
        let mut pongs = Vec::new();

        if let Ok(mut s) = self.inner.lock() {
            s.buffer.extend_from_slice(bytes);

            loop {
                match protocol::decode(&s.buffer) {
                    Decoded::Message(message, used) => {
                        s.buffer.drain(..used);
                        match message {
                            // Latency is session bookkeeping, not gameplay, so
                            // it never reaches the inbox.
                            ServerMessage::Pong { token } => pongs.push(token),
                            other => s.inbox.push(other),
                        }
                    }
                    Decoded::Ignored(used) => {
                        s.buffer.drain(..used);
                    }
                    Decoded::Incomplete => break,
                    Decoded::Unknown(id) => {
                        failure = Some(format!(
                            "unknown packet id {id}; cannot resynchronise, dropping connection"
                        ));
                        s.buffer.clear();
                        break;
                    }
                }
            }
        }

        for token in pongs {
            self.record_pong(token, now_ms);
        }

        if let Some(message) = failure {
            self.set_state(ConnectionState::Failed(message));
        }
    }

    /// Median of recent round trips, or None until a ping is answered.
    pub fn ping_ms(&self) -> Option<u32> {
        let mut samples = self.inner.lock().ok()?.ping_samples.clone();
        if samples.is_empty() {
            return None;
        }
        samples.sort_unstable();
        Some(samples[samples.len() / 2])
    }

    /// Build the next ping, or None if one is already in flight.
    ///
    /// Returns the bytes to send rather than sending them, so the caller can
    /// decide whether the connection is in a state worth probing.
    pub fn next_ping(&self, now_ms: f64) -> Option<Vec<u8>> {
        let mut inner = self.inner.lock().ok()?;

        if let Some(pending) = &inner.outstanding_ping {
            if now_ms - pending.sent_at_ms < PING_TIMEOUT_MS {
                return None;
            }
            // Timed out. Drop it rather than counting it as a sample: a lost
            // ping says nothing about latency, only about loss.
            inner.outstanding_ping = None;
        }

        inner.next_ping_token = inner.next_ping_token.wrapping_add(1);
        let token = inner.next_ping_token.to_le_bytes();
        inner.outstanding_ping = Some(Outstanding { token, sent_at_ms: now_ms });
        Some(ao_core::encode_ping(token))
    }

    /// Record a pong, ignoring anything we did not ask for.
    fn record_pong(&self, token: [u8; 8], now_ms: f64) {
        if let Ok(mut inner) = self.inner.lock() {
            // A replayed or stale token must not produce a sample; only the
            // ping we are actually waiting on counts.
            let matched =
                inner.outstanding_ping.as_ref().is_some_and(|pending| pending.token == token);
            if !matched {
                return;
            }

            let sent_at = inner.outstanding_ping.take().map(|p| p.sent_at_ms).unwrap_or(now_ms);
            let rtt = (now_ms - sent_at).max(0.0).round() as u32;
            inner.ping_samples.push(rtt);
            if inner.ping_samples.len() > PING_SAMPLES {
                inner.ping_samples.remove(0);
            }
        }
    }

    /// Forget latency history. Called on reconnect: samples from a previous
    /// connection describe a link that no longer exists.
    pub fn reset_latency(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.outstanding_ping = None;
            inner.ping_samples.clear();
        }
    }

    /// Next walk counter. Must strictly increase or the server disconnects us.
    pub fn next_walk_count(&self) -> i32 {
        self.inner
            .lock()
            .map(|mut s| {
                s.walk_count += 1;
                s.walk_count
            })
            .unwrap_or(1)
    }
}

#[cfg(target_arch = "wasm32")]
mod wasm {
    use super::*;
    use wasm_bindgen::prelude::*;
    use wasm_bindgen::JsCast;

    impl Session {
        /// Open the socket and log in once it is ready.
        pub fn connect(&self, url: &str, name: String, password: String, client_hash: String) {
            self.set_state(ConnectionState::Connecting);
            // Latency samples describe a link that no longer exists once the
            // socket is replaced, and a ping left in flight from the previous
            // connection would otherwise block the first probe on the new one
            // until it timed out.
            self.reset_latency();

            let socket = match web_sys::WebSocket::new(url) {
                Ok(socket) => socket,
                Err(e) => {
                    return self.set_state(ConnectionState::Failed(format!("{url}: {e:?}")));
                }
            };
            // The protocol is binary; without this the browser hands back Blobs
            // and every read becomes asynchronous for no reason.
            socket.set_binary_type(web_sys::BinaryType::Arraybuffer);

            let on_open = {
                let session = self.clone();
                let socket = socket.clone();
                Closure::<dyn FnMut()>::new(move || {
                    // Packet 74: creates the character if it does not exist.
                    // Once there is a login screen this becomes 73 with a
                    // server-issued session token and a character id.
                    let login = protocol::encode_login_new_char(
                        &name,
                        &password,
                        &client_hash,
                        protocol::NewCharacter::default(),
                    );
                    if let Err(e) = socket.send_with_u8_array(&login) {
                        session.set_state(ConnectionState::Failed(format!("login send: {e:?}")));
                        return;
                    }
                    session.set_state(ConnectionState::Authenticating);
                    log::info!("socket open, login sent");
                })
            };
            socket.set_onopen(Some(on_open.as_ref().unchecked_ref()));
            on_open.forget();

            let on_message = {
                let session = self.clone();
                Closure::<dyn FnMut(web_sys::MessageEvent)>::new(
                    move |event: web_sys::MessageEvent| {
                        if let Ok(buffer) = event.data().dyn_into::<js_sys::ArrayBuffer>() {
                            let bytes = js_sys::Uint8Array::new(&buffer).to_vec();
                            session.ingest(&bytes, js_sys::Date::now());
                        }
                    },
                )
            };
            socket.set_onmessage(Some(on_message.as_ref().unchecked_ref()));
            on_message.forget();

            let on_error = {
                let session = self.clone();
                Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
                    // The browser withholds the reason for socket errors, so
                    // there is nothing more specific to report here.
                    session.set_state(ConnectionState::Failed("socket error".into()));
                })
            };
            socket.set_onerror(Some(on_error.as_ref().unchecked_ref()));
            on_error.forget();

            let on_close = {
                let session = self.clone();
                Closure::<dyn FnMut(web_sys::CloseEvent)>::new(move |event: web_sys::CloseEvent| {
                    session.set_state(ConnectionState::Failed(format!(
                        "socket closed: {} {}",
                        event.code(),
                        event.reason()
                    )));
                })
            };
            socket.set_onclose(Some(on_close.as_ref().unchecked_ref()));
            on_close.forget();

            if let Ok(mut s) = self.inner.lock() {
                s.socket = Some(socket);
            }
        }

        pub fn send(&self, bytes: &[u8]) {
            if let Ok(s) = self.inner.lock() {
                if let Some(socket) = &s.socket {
                    let _ = socket.send_with_u8_array(bytes);
                }
            }
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl Session {
    pub fn connect(&self, _url: &str, _name: String, _password: String, _hash: String) {
        self.set_state(ConnectionState::Failed("native networking not implemented yet".into()));
    }

    pub fn send(&self, _bytes: &[u8]) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drive a full ping/pong round trip and return the token that was sent.
    fn ping_token(session: &Session, at_ms: f64) -> [u8; 8] {
        let bytes = session.next_ping(at_ms).expect("a ping should be issued");
        let mut token = [0u8; 8];
        token.copy_from_slice(&bytes[2..10]);
        token
    }

    #[test]
    fn playing_is_only_entered_from_authenticating() {
        // There is no login-accepted packet: the first position update is the
        // acknowledgement. But a position update arriving after the socket
        // died must not resurrect the connection.
        let session = Session::default();

        session.mark_playing();
        assert_eq!(session.state(), ConnectionState::Offline);

        session.set_state(ConnectionState::Authenticating);
        session.mark_playing();
        assert_eq!(session.state(), ConnectionState::Playing);

        session.set_state(ConnectionState::Failed("socket closed".into()));
        session.mark_playing();
        assert_eq!(session.state(), ConnectionState::Failed("socket closed".into()));
    }

    #[test]
    fn only_one_ping_is_in_flight_at_a_time() {
        let session = Session::default();
        ping_token(&session, 0.0);
        // A second probe before the first is answered would let a stalled link
        // queue an unbounded backlog.
        assert!(session.next_ping(1_000.0).is_none());
    }

    #[test]
    fn a_timed_out_ping_is_replaced_and_not_counted() {
        let session = Session::default();
        let first = ping_token(&session, 0.0);

        let second = ping_token(&session, PING_TIMEOUT_MS + 1.0);
        assert_ne!(first, second, "a fresh token is needed to tell the replies apart");
        // The lost ping says nothing about latency, so it must leave no sample.
        assert_eq!(session.ping_ms(), None);
    }

    #[test]
    fn a_late_reply_to_a_timed_out_ping_is_discarded() {
        let session = Session::default();
        let stale = ping_token(&session, 0.0);
        ping_token(&session, PING_TIMEOUT_MS + 1.0);

        // Timing this against the new ping's send time would report a wildly
        // wrong RTT for a reply that belongs to a probe we already abandoned.
        session.record_pong(stale, PING_TIMEOUT_MS + 2.0);
        assert_eq!(session.ping_ms(), None);
    }

    #[test]
    fn an_unsolicited_pong_produces_no_sample() {
        let session = Session::default();
        session.record_pong([9, 9, 9, 9, 9, 9, 9, 9], 50.0);
        assert_eq!(session.ping_ms(), None);
    }

    #[test]
    fn a_matched_pong_records_the_round_trip() {
        let session = Session::default();
        let token = ping_token(&session, 100.0);
        session.record_pong(token, 142.0);
        assert_eq!(session.ping_ms(), Some(42));
    }

    #[test]
    fn the_reported_latency_is_a_median_over_a_bounded_window() {
        let session = Session::default();
        // One 900ms outlier among fast samples must not move the number.
        for (i, rtt) in [10.0, 12.0, 900.0, 11.0, 13.0].iter().enumerate() {
            let at = i as f64 * 10_000.0;
            let token = ping_token(&session, at);
            session.record_pong(token, at + rtt);
        }
        assert_eq!(session.ping_ms(), Some(12));

        // The window slides, so old samples stop counting.
        for i in 5..5 + PING_SAMPLES {
            let at = i as f64 * 10_000.0;
            let token = ping_token(&session, at);
            session.record_pong(token, at + 100.0);
        }
        assert_eq!(session.ping_ms(), Some(100));
    }

    #[test]
    fn reconnecting_forgets_the_previous_links_latency() {
        let session = Session::default();
        let token = ping_token(&session, 0.0);
        session.record_pong(token, 30.0);
        assert_eq!(session.ping_ms(), Some(30));

        session.reset_latency();
        assert_eq!(session.ping_ms(), None);
        // The in-flight slot is cleared too, so the next probe is not blocked
        // waiting on a reply that can never arrive.
        assert!(session.next_ping(1.0).is_some());
    }

    #[test]
    fn pongs_are_bookkeeping_and_never_reach_gameplay() {
        let session = Session::default();
        let token = ping_token(&session, 0.0);

        let mut bytes = vec![204u8, 0];
        bytes.extend_from_slice(&token);
        bytes.extend_from_slice(&[31u8, 0, 50, 60]);
        session.ingest(&bytes, 25.0);

        assert_eq!(session.drain(), vec![ServerMessage::PosUpdate { x: 50, y: 60 }]);
        assert_eq!(session.ping_ms(), Some(25));
    }

    #[test]
    fn an_unknown_packet_id_fails_the_connection_rather_than_desynchronising() {
        let session = Session::default();
        session.ingest(&[99u8, 0, 1, 2], 0.0);

        assert!(matches!(session.state(), ConnectionState::Failed(_)));
        assert!(session.drain().is_empty());
    }

    #[test]
    fn walk_counters_strictly_increase() {
        // The server's anti-cheat disconnects on a repeated or lower counter.
        let session = Session::default();
        let counts: Vec<i32> = (0..5).map(|_| session.next_walk_count()).collect();
        assert_eq!(counts, vec![1, 2, 3, 4, 5]);
    }
}
