//! The bytes that cross the boundary, and nothing else.
//!
//! `fixtures/wire_contract.txt` is the specification: semantic values beside the exact bytes
//! they must become, with the hexadecimal produced by a third implementation rather than by
//! either codec. A fixture generated from the code it validates proves only that the code
//! agrees with itself, which is how two languages come to hold different beliefs about the
//! same field while both of their test suites pass.
//!
//! Three records, little-endian, each behind a u8 discriminant:
//!
//! ```text
//! 1 position  : topology_version u64, space u128, x i32, y i32         33 bytes
//! 2 ownership : entity u64, region u32, epoch u64                      21 bytes
//! 3 transfer  : transfer u64, transition u8, from_region u32, to u32   18 bytes
//! ```
//!
//! The topology version is the manifest's content hash, so a position can only claim a release
//! that was compiled. It was a freely constructed `u32` with no relationship to any artifact.
//!
//! A space id is 128 bits because not every space is compiled: `W-0104` mints one per live
//! dungeon instance, at runtime, from whichever region is asked. A narrower id would need a
//! central allocator or hand-managed ranges to stay unique, and getting that wrong puts two
//! parties in one space. Wide enough to mint without coordinating is the requirement.
//!
//! Coordinates are signed because the world has negative ones: a space's origin is wherever
//! its layout put it, and reading `x` as unsigned turns a tile one step west of the origin
//! into a position four billion tiles east.
//!
//! Zero is not a transition kind. An uninitialised byte must not decode as `GeographicSeam`,
//! the one kind that means a player crosses a boundary without noticing — a field nobody set
//! should never become the most permissive answer.
//!
//! Decoding is exact-length. A record with a trailing byte is refused rather than ignored,
//! because a decoder that tolerates extra bytes cannot tell a framing bug from a new field,
//! and will happily accept a message from a version it does not understand.

use crate::identity::{AuthorityEpoch, EntityId, RegionId, TransferId, TransitionKind};
use crate::position::{TopologyVersion, WorldPosition, WorldSpaceId};

pub const POSITION: u8 = 1;
pub const OWNERSHIP: u8 = 2;
pub const TRANSFER: u8 = 3;

const SEAM: u8 = 1;
const DOOR: u8 = 2;
const PORTAL: u8 = 3;
const TELEPORT: u8 = 4;
const INSTANCE: u8 = 5;

/// One record on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Record {
    Position { version: TopologyVersion, position: WorldPosition },
    Ownership { entity: EntityId, region: RegionId, epoch: AuthorityEpoch },
    Transfer { transfer: TransferId, transition: TransitionKind, from: RegionId, to: RegionId },
}

/// Why bytes were refused.
///
/// Named cases rather than a boolean, because "this is 16 bytes and should be 17" and "this
/// claims to be record type 9" send a reader to different places.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    /// Fewer bytes than the record needs.
    Truncated { needed: usize, found: usize },
    /// More bytes than the record needs.
    Oversized { expected: usize, found: usize },
    /// The leading discriminant is not a record this version knows.
    UnknownRecord(u8),
    /// The transition byte is not a kind. Includes zero.
    UnknownTransition(u8),
}

impl Record {
    /// The encoded length of this record, including its discriminant.
    pub fn len(&self) -> usize {
        match self {
            Record::Position { .. } => 33,
            Record::Ownership { .. } => 21,
            Record::Transfer { .. } => 18,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.len());
        match self {
            Record::Position { version, position } => {
                out.push(POSITION);
                out.extend_from_slice(&version.0.to_le_bytes());
                out.extend_from_slice(&position.space.0.to_le_bytes());
                out.extend_from_slice(&position.x.to_le_bytes());
                out.extend_from_slice(&position.y.to_le_bytes());
            }
            Record::Ownership { entity, region, epoch } => {
                out.push(OWNERSHIP);
                out.extend_from_slice(&entity.0.to_le_bytes());
                out.extend_from_slice(&region.0.to_le_bytes());
                out.extend_from_slice(&epoch.0.to_le_bytes());
            }
            Record::Transfer { transfer, transition, from, to } => {
                out.push(TRANSFER);
                out.extend_from_slice(&transfer.0.to_le_bytes());
                out.push(match transition {
                    TransitionKind::GeographicSeam => SEAM,
                    TransitionKind::Door => DOOR,
                    TransitionKind::Portal => PORTAL,
                    TransitionKind::Teleport => TELEPORT,
                    TransitionKind::InstanceEntrance => INSTANCE,
                });
                out.extend_from_slice(&from.0.to_le_bytes());
                out.extend_from_slice(&to.0.to_le_bytes());
            }
        }
        out
    }

    /// Decode exactly these bytes, or say why not.
    pub fn decode(bytes: &[u8]) -> Result<Record, WireError> {
        let Some(&discriminant) = bytes.first() else {
            return Err(WireError::Truncated { needed: 1, found: 0 });
        };

        let expected = match discriminant {
            POSITION => 33,
            OWNERSHIP => 21,
            TRANSFER => 18,
            other => return Err(WireError::UnknownRecord(other)),
        };

        if bytes.len() < expected {
            return Err(WireError::Truncated { needed: expected, found: bytes.len() });
        }
        if bytes.len() > expected {
            return Err(WireError::Oversized { expected, found: bytes.len() });
        }

        let u32_at = |at: usize| {
            u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
        };
        let i32_at = |at: usize| {
            i32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
        };
        let u128_at = |at: usize| {
            let mut buffer = [0u8; 16];
            buffer.copy_from_slice(&bytes[at..at + 16]);
            u128::from_le_bytes(buffer)
        };
        let u64_at = |at: usize| {
            u64::from_le_bytes([
                bytes[at],
                bytes[at + 1],
                bytes[at + 2],
                bytes[at + 3],
                bytes[at + 4],
                bytes[at + 5],
                bytes[at + 6],
                bytes[at + 7],
            ])
        };

        match discriminant {
            POSITION => Ok(Record::Position {
                version: TopologyVersion(u64_at(1)),
                position: WorldPosition {
                    space: WorldSpaceId(u128_at(9)),
                    x: i32_at(25),
                    y: i32_at(29),
                },
            }),
            OWNERSHIP => Ok(Record::Ownership {
                entity: EntityId(u64_at(1)),
                region: RegionId(u32_at(9)),
                epoch: AuthorityEpoch(u64_at(13)),
            }),
            TRANSFER => {
                let transition = match bytes[9] {
                    SEAM => TransitionKind::GeographicSeam,
                    DOOR => TransitionKind::Door,
                    PORTAL => TransitionKind::Portal,
                    TELEPORT => TransitionKind::Teleport,
                    INSTANCE => TransitionKind::InstanceEntrance,
                    other => return Err(WireError::UnknownTransition(other)),
                };
                Ok(Record::Transfer {
                    transfer: TransferId(u64_at(1)),
                    transition,
                    from: RegionId(u32_at(10)),
                    to: RegionId(u32_at(14)),
                })
            }
            _ => unreachable!("the discriminant was matched above"),
        }
    }
}

/// The golden fixture, compiled in.
pub fn contract() -> &'static str {
    include_str!("../fixtures/wire_contract.txt")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes_of(hex: &str) -> Vec<u8> {
        hex.split_whitespace().map(|pair| u8::from_str_radix(pair, 16).expect("hex byte")).collect()
    }

    fn transition_named(name: &str) -> TransitionKind {
        match name {
            "seam" => TransitionKind::GeographicSeam,
            "door" => TransitionKind::Door,
            "portal" => TransitionKind::Portal,
            "teleport" => TransitionKind::Teleport,
            "instance" => TransitionKind::InstanceEntrance,
            other => panic!("unknown transition {other}"),
        }
    }

    /// Parse one fixture line into what it claims.
    fn case(line: &str) -> Option<(Record, Vec<u8>)> {
        let (semantic, hex) = line.split_once('=')?;
        let field: Vec<&str> = semantic.split_whitespace().collect();
        let bytes = bytes_of(hex);

        let record = match field[0] {
            "position" => Record::Position {
                version: TopologyVersion(field[1].parse().expect("version")),
                position: WorldPosition {
                    space: WorldSpaceId(field[2].parse().expect("space")),
                    x: field[3].parse().expect("x"),
                    y: field[4].parse().expect("y"),
                },
            },
            "ownership" => Record::Ownership {
                entity: EntityId(field[1].parse().expect("entity")),
                region: RegionId(field[2].parse().expect("region")),
                epoch: AuthorityEpoch(field[3].parse().expect("epoch")),
            },
            "transfer" => Record::Transfer {
                transfer: TransferId(field[1].parse().expect("transfer")),
                transition: transition_named(field[2]),
                from: RegionId(field[3].parse().expect("from")),
                to: RegionId(field[4].parse().expect("to")),
            },
            other => panic!("unknown record {other}"),
        };

        Some((record, bytes))
    }

    fn lines() -> impl Iterator<Item = &'static str> {
        contract().lines().map(str::trim).filter(|line| !line.is_empty() && !line.starts_with('#'))
    }

    #[test]
    fn every_case_encodes_to_exactly_the_bytes_the_contract_states() {
        let mut checked = 0;
        for line in lines() {
            if line.starts_with("reject") {
                continue;
            }
            let (record, expected) = case(line).expect("a semantic case");
            assert_eq!(record.encode(), expected, "{line}");
            assert_eq!(record.len(), expected.len(), "{line}");
            checked += 1;
        }
        assert!(checked >= 18, "the contract should be worth checking: {checked}");
    }

    #[test]
    fn every_case_decodes_back_to_the_value_the_contract_names() {
        for line in lines() {
            if line.starts_with("reject") {
                continue;
            }
            let (record, bytes) = case(line).expect("a semantic case");
            assert_eq!(Record::decode(&bytes), Ok(record), "{line}");
        }
    }

    #[test]
    fn every_rejection_is_refused_for_the_reason_the_contract_states() {
        let mut checked = 0;
        for line in lines() {
            let Some(rest) = line.strip_prefix("reject ") else { continue };
            // The reason is the last word; everything between is the hex.
            let (hex, reason) = rest.rsplit_once(' ').expect("a reason");
            let bytes = bytes_of(hex);
            let error = Record::decode(&bytes).expect_err(line);

            let matches = match reason {
                "truncated" => matches!(error, WireError::Truncated { .. }),
                "oversized" => matches!(error, WireError::Oversized { .. }),
                "unknown-record" => matches!(error, WireError::UnknownRecord(_)),
                "unknown-transition" => matches!(error, WireError::UnknownTransition(_)),
                other => panic!("unknown rejection reason {other}"),
            };
            assert!(matches, "{line} produced {error:?}");
            checked += 1;
        }
        assert!(checked >= 8, "the contract should reject a real spread: {checked}");
    }

    #[test]
    fn a_zero_transition_byte_is_not_a_seam() {
        // The permissive-by-accident case. An uninitialised byte must not decode as the one
        // kind that means a player crosses without noticing.
        let mut bytes = Record::Transfer {
            transfer: TransferId(9),
            transition: TransitionKind::GeographicSeam,
            from: RegionId(330),
            to: RegionId(269),
        }
        .encode();
        assert_eq!(bytes[9], 1, "seam is 1, so zero is free to mean nothing");

        bytes[9] = 0;
        assert_eq!(Record::decode(&bytes), Err(WireError::UnknownTransition(0)));
    }

    #[test]
    fn a_negative_coordinate_survives_the_round_trip_as_a_negative_coordinate() {
        // Reading x as unsigned would turn one step west of the origin into four billion
        // tiles east, which is a plausible-looking position in a world that has negatives.
        let record = Record::Position {
            version: TopologyVersion(3),
            position: WorldPosition { space: WorldSpaceId(199), x: -1, y: -1406 },
        };
        let bytes = record.encode();
        assert_eq!(&bytes[25..29], &[0xff, 0xff, 0xff, 0xff]);
        assert_eq!(Record::decode(&bytes), Ok(record));
    }

    #[test]
    fn transposing_two_fields_of_equal_width_changes_the_bytes() {
        // Why the contract carries `1 2 3 4` cases. Both pairs here are u32, so a swapped
        // implementation would round-trip its own mistake without a case that distinguishes
        // them.
        let straight = Record::Position {
            version: TopologyVersion(1),
            position: WorldPosition { space: WorldSpaceId(2), x: 3, y: 4 },
        };
        let swapped_head = Record::Position {
            version: TopologyVersion(2),
            position: WorldPosition { space: WorldSpaceId(1), x: 3, y: 4 },
        };
        let swapped_tail = Record::Position {
            version: TopologyVersion(1),
            position: WorldPosition { space: WorldSpaceId(2), x: 4, y: 3 },
        };
        assert_ne!(straight.encode(), swapped_head.encode());
        assert_ne!(straight.encode(), swapped_tail.encode());

        let owner = Record::Ownership {
            entity: EntityId(1),
            region: RegionId(2),
            epoch: AuthorityEpoch(3),
        };
        let swapped = Record::Ownership {
            entity: EntityId(3),
            region: RegionId(2),
            epoch: AuthorityEpoch(1),
        };
        assert_ne!(owner.encode(), swapped.encode());
    }

    #[test]
    fn boundaries_round_trip_without_saturating() {
        for record in [
            Record::Position {
                version: TopologyVersion(u64::MAX),
                position: WorldPosition {
                    space: WorldSpaceId(u128::MAX),
                    x: i32::MIN,
                    y: i32::MAX,
                },
            },
            Record::Ownership {
                entity: EntityId(u64::MAX),
                region: RegionId(u32::MAX),
                epoch: AuthorityEpoch(u64::MAX),
            },
            Record::Transfer {
                transfer: TransferId(u64::MAX),
                transition: TransitionKind::InstanceEntrance,
                from: RegionId(0),
                to: RegionId(u32::MAX),
            },
        ] {
            assert_eq!(Record::decode(&record.encode()), Ok(record));
        }
    }

    #[test]
    fn a_record_one_byte_long_or_one_byte_over_is_refused_at_every_length() {
        // Exhaustive rather than sampled: every prefix of a valid record must be refused, and
        // so must every record with a byte added.
        for record in [
            Record::Position {
                version: TopologyVersion(1),
                position: WorldPosition { space: WorldSpaceId(199), x: 221, y: 214 },
            },
            Record::Ownership {
                entity: EntityId(7),
                region: RegionId(330),
                epoch: AuthorityEpoch(3),
            },
            Record::Transfer {
                transfer: TransferId(9),
                transition: TransitionKind::GeographicSeam,
                from: RegionId(330),
                to: RegionId(269),
            },
        ] {
            let bytes = record.encode();
            for shorter in 0..bytes.len() {
                let error =
                    Record::decode(&bytes[..shorter]).expect_err("a prefix is not a record");
                assert!(
                    matches!(error, WireError::Truncated { .. }),
                    "{shorter} bytes gave {error:?}"
                );
            }

            let mut longer = bytes.clone();
            longer.push(0);
            assert!(matches!(Record::decode(&longer), Err(WireError::Oversized { .. })));
        }
    }

    #[test]
    fn a_topology_version_is_a_manifest_hash_and_survives_the_wire() {
        // Codex review, 2026-08-23: the version was a freely constructed u32 unrelated to any
        // artifact, so "stale version" only ever compared hand-authored integers. It is now
        // the manifest's content hash, which means a position can name a release that exists.
        let pinned = crate::manifest::CONTENT_HASH;
        let version = TopologyVersion::from_manifest_hash(pinned).expect("the pinned hash");
        assert_eq!(version.manifest_hash(), pinned);

        let record = Record::Position {
            version,
            position: WorldPosition { space: WorldSpaceId(199), x: 221, y: 214 },
        };
        assert_eq!(Record::decode(&record.encode()), Ok(record));

        // Anything that is not sixteen hex characters is not a hash this system produced, and
        // accepting it would let a position claim a release that never existed.
        assert_eq!(TopologyVersion::from_manifest_hash(""), None);
        assert_eq!(TopologyVersion::from_manifest_hash("3e6df36b27c82aa"), None);
        assert_eq!(TopologyVersion::from_manifest_hash("3e6df36b27c82aabb"), None);
        assert_eq!(TopologyVersion::from_manifest_hash("zzzzzzzzzzzzzzzz"), None);
    }

    #[test]
    fn an_unknown_record_names_the_discriminant_it_did_not_know() {
        for discriminant in [0u8, 4, 9, 255] {
            let bytes = vec![discriminant; 21];
            assert_eq!(
                Record::decode(&bytes),
                Err(WireError::UnknownRecord(discriminant)),
                "discriminant {discriminant}"
            );
        }
    }
}
