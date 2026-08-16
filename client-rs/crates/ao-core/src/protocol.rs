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
    pub const LOGIN_EXISTING_CHAR: i16 = 74;
    pub const WALK: i16 = 78;
}

/// Packets this client understands. Everything else is skipped.
pub mod server {
    pub const POS_UPDATE: i16 = 31;
}

fn put_i16(out: &mut Vec<u8>, value: i16) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_string(out: &mut Vec<u8>, value: &str) {
    put_i16(out, value.len() as i16);
    out.extend_from_slice(value.as_bytes());
}

/// Log in as an existing character.
///
/// Field order mirrors `BotArmy.Bot.build_login/1`: password, name, three
/// version bytes, the client hash, then five trailing fields the server reads
/// but does not act on for an existing character.
pub fn encode_login(name: &str, password: &str, client_hash: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(64);
    put_i16(&mut out, client::LOGIN_EXISTING_CHAR);
    put_string(&mut out, password);
    put_string(&mut out, name);
    out.extend_from_slice(&[1, 0, 0]);
    put_string(&mut out, client_hash);
    out.extend_from_slice(&[1, 1, 6]);
    put_i16(&mut out, 1);
    out.push(1);
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
        server::POS_UPDATE => {
            if buffer.len() < 4 {
                return Decoded::Incomplete;
            }
            Decoded::Message(ServerMessage::PosUpdate { x: buffer[2], y: buffer[3] }, 4)
        }
        _ => Decoded::Unknown(id),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_matches_the_reference_layout() {
        let bytes = encode_login("Bot_1", "pass", "hash");

        // id
        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), 74);
        // password, length-prefixed with an i16 — not a byte
        assert_eq!(i16::from_le_bytes([bytes[2], bytes[3]]), 4);
        assert_eq!(&bytes[4..8], b"pass");
        // name follows
        assert_eq!(i16::from_le_bytes([bytes[8], bytes[9]]), 5);
        assert_eq!(&bytes[10..15], b"Bot_1");
        // three version bytes
        assert_eq!(&bytes[15..18], &[1, 0, 0]);
        // client hash
        assert_eq!(i16::from_le_bytes([bytes[18], bytes[19]]), 4);
        assert_eq!(&bytes[20..24], b"hash");
        assert_eq!(&bytes[24..27], &[1, 1, 6]);
        assert_eq!(i16::from_le_bytes([bytes[27], bytes[28]]), 1);
        assert_eq!(bytes[29], 1);
        assert_eq!(bytes.len(), 30);
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
