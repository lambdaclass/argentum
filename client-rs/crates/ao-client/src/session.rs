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
        self.inner
            .lock()
            .ok()
            .and_then(|s| s.state.clone())
            .unwrap_or(ConnectionState::Offline)
    }

    fn set_state(&self, state: ConnectionState) {
        if let Ok(mut s) = self.inner.lock() {
            s.state = Some(state);
        }
    }

    /// Drain everything decoded since the last call.
    pub fn drain(&self) -> Vec<ServerMessage> {
        self.inner
            .lock()
            .map(|mut s| std::mem::take(&mut s.inbox))
            .unwrap_or_default()
    }

    /// Feed received bytes and decode whole packets out of them.
    ///
    /// Packet lengths are not on the wire, so an unknown id cannot be skipped:
    /// everything after it would be misread. The connection is failed instead,
    /// which is loud rather than subtly wrong.
    fn ingest(&self, bytes: &[u8]) {
        let mut failure = None;

        if let Ok(mut s) = self.inner.lock() {
            s.buffer.extend_from_slice(bytes);

            loop {
                match protocol::decode(&s.buffer) {
                    Decoded::Message(message, used) => {
                        s.buffer.drain(..used);
                        s.inbox.push(message);
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

        if let Some(message) = failure {
            self.set_state(ConnectionState::Failed(message));
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
                    let login = protocol::encode_login(&name, &password, &client_hash);
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
                            session.ingest(&bytes);
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
        self.set_state(ConnectionState::Failed(
            "native networking not implemented yet".into(),
        ));
    }

    pub fn send(&self, _bytes: &[u8]) {}
}
