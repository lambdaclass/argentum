//! AO20 wire protocol, the parts this client speaks.
//!
//! Pure encode/decode so it can be tested natively. Ported from the Elixir
//! server (`AoProtocol`) and cross-checked against `BotArmy.Bot`, which is the
//! smallest working reference for the login handshake.
//!
//! Strings are `i16` little-endian length followed by raw bytes — the same
//! convention as the map pack, and the same one whose `readString8` name
//! previously misled a port into using a single byte.

/// Packets this client sends.
pub mod client {
    /// Creates a character on login. This is what BotArmy uses, which is why it
    /// was mistaken for existing-character login while porting.
    pub const LOGIN_NEW_CHAR: i16 = 74;
    /// Logs in an already-created character. This is the one a real client wants.
    pub const LOGIN_EXISTING_CHAR: i16 = 73;
    pub const WALK: i16 = 78;
    /// Extension (900-999 band): latency probe, no VB6 ancestor.
    pub const PING: i16 = 900;
}

/// Packets this client understands. Everything else is skipped.
pub mod server {
    pub const POS_UPDATE: i16 = 31;
    /// Extension (200-299 band): echo of a ping token.
    pub const PONG: i16 = 204;
}

fn put_i16(out: &mut Vec<u8>, value: i16) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_string(out: &mut Vec<u8>, value: &str) {
    put_i16(out, value.len() as i16);
    out.extend_from_slice(value.as_bytes());
}

/// Protocol version this client reports: major, minor, build.
const CLIENT_VERSION: [u8; 3] = [1, 0, 0];

/// The choices made when a character is created.
///
/// These are not decoration: the server reads every one of them and they
/// determine the character it creates. An earlier port described them as
/// trailing fields the server ignores, which is why they were left as literals
/// copied out of `BotArmy`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NewCharacter {
    pub race: u8,
    pub gender: u8,
    pub class: u8,
    pub head: i16,
    pub home_city: u8,
}

impl Default for NewCharacter {
    /// Human male warrior from Ullathorpe — the combination `BotArmy` uses, and
    /// the one guaranteed to be valid on a stock server.
    fn default() -> Self {
        Self { race: 1, gender: 1, class: 6, head: 1, home_city: 1 }
    }
}

/// Create a character and log in as it (packet 74).
///
/// Layout, from `AoProtocol.Client.Decoder.decode_packet/2`: session token,
/// username, three version bytes, client hash, then race, gender, class, head
/// and home city.
///
/// This is what `BotArmy` sends, which is exactly why it was mistaken for
/// ordinary login while porting. A real client only wants it once per
/// character; every later session uses [`encode_login_existing_char`].
pub fn encode_login_new_char(
    username: &str,
    session_token: &str,
    client_hash: &str,
    character: NewCharacter,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(64);
    put_i16(&mut out, client::LOGIN_NEW_CHAR);
    put_string(&mut out, session_token);
    put_string(&mut out, username);
    out.extend_from_slice(&CLIENT_VERSION);
    put_string(&mut out, client_hash);
    out.push(character.race);
    out.push(character.gender);
    out.push(character.class);
    put_i16(&mut out, character.head);
    out.push(character.home_city);
    out
}

/// Log in as an already-created character (packet 73).
///
/// Layout: session token, character id, three version bytes, client hash.
/// Distinct from packet 74 in more than field order — this one identifies an
/// existing character by id and creates nothing, so sending 74 for a returning
/// player is not a slower path to the same place, it is a different operation.
///
/// The session token comes from the server's `session_token` packet (id 200),
/// which is issued after a successful login.
pub fn encode_login_existing_char(session_token: &str, char_id: i32, client_hash: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(48);
    put_i16(&mut out, client::LOGIN_EXISTING_CHAR);
    put_string(&mut out, session_token);
    out.extend_from_slice(&char_id.to_le_bytes());
    out.extend_from_slice(&CLIENT_VERSION);
    put_string(&mut out, client_hash);
    out
}

/// Latency probe.
///
/// The token is opaque to the server, which echoes it unchanged. Keeping the
/// meaning entirely client-side is what makes the measurement immune to clock
/// skew: no shared time base is ever needed. Exactly 8 bytes, matching the
/// server decoder.
pub fn encode_ping(token: [u8; 8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(10);
    put_i16(&mut out, client::PING);
    out.extend_from_slice(&token);
    out
}

/// Heading values as the wire uses them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    North = 1,
    East = 2,
    South = 3,
    West = 4,
}

/// A walk intent.
///
/// `count` is a per-command counter the server's anti-cheat requires to be
/// strictly increasing; a client that resets or repeats it is disconnected.
pub fn encode_walk(direction: Direction, count: i32) -> Vec<u8> {
    let mut out = Vec::with_capacity(7);
    put_i16(&mut out, client::WALK);
    out.push(direction as u8);
    out.extend_from_slice(&count.to_le_bytes());
    out
}

/// A decoded server message this client acts on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerMessage {
    /// Authoritative position for our own character.
    PosUpdate { x: u8, y: u8 },
    /// Echo of a ping token, for round-trip timing.
    Pong { token: [u8; 8] },
}

/// Pull the next message from `buffer`.
///
/// Returns the message (if it is one we handle) and how many bytes it consumed,
/// or `None` when more data is needed. Unknown packet ids cannot be skipped
/// safely because their length is not encoded, so the caller is told to drop
/// the connection rather than desynchronise silently.
pub enum Decoded {
    Message(ServerMessage, usize),
    /// Recognised but not acted on; consumed `usize` bytes.
    Ignored(usize),
    /// Not enough bytes yet.
    Incomplete,
    /// Unknown id — the stream cannot be resynchronised.
    Unknown(i16),
}

pub fn decode(buffer: &[u8]) -> Decoded {
    if buffer.len() < 2 {
        return Decoded::Incomplete;
    }
    let id = i16::from_le_bytes([buffer[0], buffer[1]]);

    match id {
        server::PONG => {
            if buffer.len() < 10 {
                return Decoded::Incomplete;
            }
            let mut token = [0u8; 8];
            token.copy_from_slice(&buffer[2..10]);
            Decoded::Message(ServerMessage::Pong { token }, 10)
        }
        server::POS_UPDATE => {
            if buffer.len() < 4 {
                return Decoded::Incomplete;
            }
            Decoded::Message(ServerMessage::PosUpdate { x: buffer[2], y: buffer[3] }, 4)
        }
        _ => Decoded::Unknown(id),
    }
}

impl core::fmt::Debug for Decoded {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Decoded::Message(m, used) => write!(f, "Message({m:?}, {used})"),
            Decoded::Ignored(used) => write!(f, "Ignored({used})"),
            Decoded::Incomplete => write!(f, "Incomplete"),
            Decoded::Unknown(id) => write!(f, "Unknown({id})"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_character_login_matches_the_servers_decoder() {
        // Field order and widths come from AoProtocol.Client.Decoder; the
        // integration test in client_handler_integration_test.exs sends the
        // same shape over a real socket.
        let character = NewCharacter { race: 1, gender: 1, class: 6, head: 1, home_city: 1 };
        let bytes = encode_login_new_char("Bot_1", "tok", "hash", character);

        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), 74);
        // Session token, length-prefixed with an i16 — not a byte, despite the
        // server calling the helper `read_string8`.
        assert_eq!(i16::from_le_bytes([bytes[2], bytes[3]]), 3);
        assert_eq!(&bytes[4..7], b"tok");
        // Username follows.
        assert_eq!(i16::from_le_bytes([bytes[7], bytes[8]]), 5);
        assert_eq!(&bytes[9..14], b"Bot_1");
        assert_eq!(&bytes[14..17], &CLIENT_VERSION);
        assert_eq!(i16::from_le_bytes([bytes[17], bytes[18]]), 4);
        assert_eq!(&bytes[19..23], b"hash");
        // race, gender, class, head (i16), home city
        assert_eq!(&bytes[23..26], &[1, 1, 6]);
        assert_eq!(i16::from_le_bytes([bytes[26], bytes[27]]), 1);
        assert_eq!(bytes[28], 1);
        assert_eq!(bytes.len(), 29);
    }

    #[test]
    fn creation_choices_reach_the_wire_rather_than_being_hardcoded() {
        // These were previously literals copied from BotArmy, described as
        // fields the server ignores. It does not ignore them.
        let character = NewCharacter { race: 3, gender: 2, class: 4, head: 260, home_city: 5 };
        let bytes = encode_login_new_char("N", "t", "h", character);
        let tail = &bytes[bytes.len() - 6..];

        assert_eq!(tail[0..3], [3, 2, 4]);
        assert_eq!(i16::from_le_bytes([tail[3], tail[4]]), 260);
        assert_eq!(tail[5], 5);
    }

    #[test]
    fn existing_character_login_identifies_a_character_by_id() {
        let bytes = encode_login_existing_char("session", 4242, "hash");

        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), 73);
        assert_eq!(i16::from_le_bytes([bytes[2], bytes[3]]), 7);
        assert_eq!(&bytes[4..11], b"session");
        assert_eq!(i32::from_le_bytes([bytes[11], bytes[12], bytes[13], bytes[14]]), 4242);
        assert_eq!(&bytes[15..18], &CLIENT_VERSION);
        assert_eq!(i16::from_le_bytes([bytes[18], bytes[19]]), 4);
        assert_eq!(&bytes[20..24], b"hash");
        assert_eq!(bytes.len(), 24);
    }

    // Exact bytes for the shared cross-language fixture. The identical arrays
    // are asserted against the server's own decoder in
    // `apps/ao_protocol/test/client_login_layout_test.exs`. Changing an
    // encoder here without changing that file is what a silent protocol
    // divergence looks like, so both must be edited together.
    const NEW_CHAR_FIXTURE: &[u8] = &[
        74, 0, // packet id
        3, 0, b't', b'o', b'k', // session token
        5, 0, b'B', b'o', b't', b'_', b'1', // username
        1, 0, 0, // version
        4, 0, b'h', b'a', b's', b'h', // client hash
        1, 1, 6, // race, gender, class
        1, 0, // head
        1, // home city
    ];

    const EXISTING_CHAR_FIXTURE: &[u8] = &[
        73, 0, // packet id
        7, 0, b's', b'e', b's', b's', b'i', b'o', b'n', // session token
        0x92, 0x10, 0, 0, // char id 4242
        1, 0, 0, // version
        4, 0, b'h', b'a', b's', b'h', // client hash
    ];

    #[test]
    fn login_bytes_match_the_shared_cross_language_fixture() {
        assert_eq!(
            encode_login_new_char("Bot_1", "tok", "hash", NewCharacter::default()),
            NEW_CHAR_FIXTURE
        );
        assert_eq!(encode_login_existing_char("session", 4242, "hash"), EXISTING_CHAR_FIXTURE);
    }

    #[test]
    fn the_two_logins_are_different_operations_not_aliases() {
        // 74 creates a character; 73 logs an existing one in. Naming the
        // constant after the wrong one is how this was got wrong before, and
        // it cost a session that "connected" without ever logging in.
        assert_eq!(client::LOGIN_NEW_CHAR, 74);
        assert_eq!(client::LOGIN_EXISTING_CHAR, 73);

        let new = encode_login_new_char("a", "b", "c", NewCharacter::default());
        let existing = encode_login_existing_char("b", 1, "c");
        assert_ne!(new[0..2], existing[0..2]);
        assert_ne!(new, existing);
    }

    #[test]
    fn ping_carries_an_opaque_eight_byte_token() {
        let token = [1u8, 2, 3, 4, 5, 6, 7, 8];
        let bytes = encode_ping(token);
        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), 900);
        assert_eq!(&bytes[2..], &token);
        assert_eq!(bytes.len(), 10);
    }

    #[test]
    fn decodes_a_pong_and_round_trips_the_token() {
        let token = [9u8, 8, 7, 6, 5, 4, 3, 2];
        let mut bytes = vec![204u8, 0];
        bytes.extend_from_slice(&token);

        match decode(&bytes) {
            Decoded::Message(ServerMessage::Pong { token: got }, used) => {
                assert_eq!(got, token);
                assert_eq!(used, 10);
            }
            other => panic!("expected a pong, got {other:?}"),
        }
    }

    #[test]
    fn a_truncated_pong_asks_for_more_data() {
        for width in 2..10 {
            let bytes: Vec<u8> = std::iter::once(204u8)
                .chain(std::iter::once(0u8))
                .chain(std::iter::repeat(0u8))
                .take(width)
                .collect();
            assert!(
                matches!(decode(&bytes), Decoded::Incomplete),
                "width {width} should be incomplete"
            );
        }
    }

    #[test]
    fn walk_carries_direction_and_counter() {
        let bytes = encode_walk(Direction::East, 7);
        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), 78);
        assert_eq!(bytes[2], 2);
        assert_eq!(i32::from_le_bytes([bytes[3], bytes[4], bytes[5], bytes[6]]), 7);
    }

    #[test]
    fn decodes_a_position_update() {
        let bytes = [31u8, 0, 50, 60];
        match decode(&bytes) {
            Decoded::Message(ServerMessage::PosUpdate { x, y }, used) => {
                assert_eq!((x, y, used), (50, 60, 4));
            }
            other => panic!("expected a pos update, got {other:?}"),
        }
    }

    #[test]
    fn partial_packets_ask_for_more_data() {
        assert!(matches!(decode(&[]), Decoded::Incomplete));
        assert!(matches!(decode(&[31]), Decoded::Incomplete));
        assert!(matches!(decode(&[31, 0, 50]), Decoded::Incomplete));
    }

    #[test]
    fn unknown_ids_are_reported_rather_than_guessed() {
        // Packet lengths are not on the wire, so a client cannot skip an
        // unknown packet without losing sync with everything after it.
        assert!(matches!(decode(&[99, 0, 1, 2, 3]), Decoded::Unknown(99)));
    }
}
