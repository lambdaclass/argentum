//! Deterministic gameplay rules, shared between client prediction and the server.
//!
//! The TypeScript client re-implements collision and walk gating that the Elixir
//! server also implements. Two implementations of the same rule in two languages
//! must agree exactly or the player is snapped back mid-step, and they have
//! drifted in practice. Putting the rules here lets the wasm client and (later)
//! the Rustler NIF run the identical code.
//!
//! Everything in this crate is pure: no I/O, no time source, no platform types.
//! Callers pass the clock in, which is what makes it testable and identical
//! across targets.

pub mod mappack;
pub mod movement;
pub mod protocol;
pub mod tiles;

pub use mappack::{decode_map, PackedMap};
pub use protocol::{decode, encode_login, encode_walk, Decoded, Direction, ServerMessage};
pub use movement::{WalkGate, WalkGateConfig, WalkOutcome};
pub use tiles::{is_walkable, TileFlags, TileKind};
