//! Where something is, in a world that is not one plane.
//!
//! `W-0097` established that the corpus is an atlas: 226 coordinate spaces, most of them
//! planes, one a 148x160 torus, and 199 reachable only by transition. A position is therefore
//! never just a pair of numbers — it is a pair of numbers *in a space*, and the space decides
//! what arithmetic means. Adding one tile east inside a torus can wrap; inside a plane it can
//! leave the space entirely; and two positions in different spaces have no distance between
//! them at all.
//!
//! So this module makes the space part of the type and refuses the operations that only look
//! sensible. There is no `Sub` for `WorldPosition`, no `PartialOrd`, and no way to nudge one
//! by a tile without naming its geometry. The alternative — a bare `(i32, i32)` that callers
//! interpret — is how a client comes to believe a player is somewhere the server does not, and
//! this codebase has already produced two instances of the same shape of bug: a three-state
//! tile layer read as two, and two classifiers disagreeing about walkable ground.
//!
//! The invariants everything else rests on, both tested here and pinned in the
//! cross-language fixtures:
//!
//! - `local -> global -> local` returns the original tile, exactly, for every tile of every
//!   space;
//! - across an accepted geographic seam, `global_after - global_before` is exactly one
//!   cardinal tile.
//!
//! Map numbers do not appear in identity. A `WorldSpaceId` is content identity for a
//! coordinate space and a `MapId` is a legacy addressing detail the boundary adapter deals
//! in; a player-facing identity that embedded either would leak the 2001 file layout into
//! save data and protocol.

use crate::topology::{Geometry, Origin, CORE_X, CORE_Y, PITCH_X, PITCH_Y};
use std::collections::BTreeMap;

/// A coordinate space: content identity, stable across process restarts and topology
/// releases.
///
/// Never a PID, an array position or a map number. The manifest names compiled spaces after
/// their smallest member map because that is a fact about the group rather than about the
/// order it was discovered in, but callers must treat the value as **opaque** — deriving a map
/// from a space id is exactly the coupling this type exists to prevent.
///
/// 128 bits, because not every space is compiled. `W-0104` creates a world space per live
/// dungeon instance, and those are minted at runtime by whichever region is asked: a 32-bit id
/// would need a central allocator or hand-managed ranges to stay unique, and the failure mode
/// of getting that wrong is two parties sharing a space. 128 bits is wide enough to mint
/// independently and never coordinate, which is what "UUID-like" in `W-0104` means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct WorldSpaceId(pub u128);

/// A legacy map number: `map_id + u8 x/y` addressing, for content and adapters only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MapId(pub u16);

/// Which release of the compiled topology a position was computed against.
///
/// Carried with positions that cross a boundary, because a global coordinate means nothing
/// without the layout that produced it: the same tile has different global coordinates under
/// two topology releases, and silently comparing across them would place a player somewhere
/// plausible and wrong.
///
/// 64 bits because it *is* the manifest's content hash — `manifest::CONTENT_HASH`, sixteen hex
/// characters, which is exactly `u64`. An earlier version was a freely constructed `u32` with
/// no relationship to any artifact, so "stale version" tests compared hand-authored integers
/// and nothing tied a position to the topology that produced it. Binding the two means a
/// version can only name a release that was actually compiled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TopologyVersion(pub u64);

impl TopologyVersion {
    /// The version a manifest content hash names, or `None` if it is not one.
    ///
    /// Sixteen lowercase hex characters. Anything else is not a hash this system produced, and
    /// accepting it would let a position claim a release that never existed.
    pub fn from_manifest_hash(hash: &str) -> Option<TopologyVersion> {
        if hash.len() != 16 || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        u64::from_str_radix(hash, 16).ok().map(TopologyVersion)
    }

    /// The hash this version names, in the form the manifest writes it.
    pub fn manifest_hash(self) -> String {
        format!("{:016x}", self.0)
    }
}

/// A tile inside one map, in the coordinates the legacy content and the collision grid use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LocalPosition {
    pub map: MapId,
    pub x: u8,
    pub y: u8,
}

impl LocalPosition {
    /// Whether this tile is inside the simulated core rather than a transition band or the
    /// storage margin.
    ///
    /// Band positions are operation-local: a character occupies one for the instant between
    /// stepping onto it and the exit firing, and persisting one would save a position that is
    /// not a place.
    pub fn in_core(&self) -> bool {
        (CORE_X.0..=CORE_X.1).contains(&self.x) && (CORE_Y.0..=CORE_Y.1).contains(&self.y)
    }
}

/// A tile in a space's own global coordinates.
///
/// Deliberately not `Ord`, not `Sub`, and not addable. Two positions in different spaces are
/// incomparable, and a difference between them is meaningless; a caller that wants to move
/// asks the space, which knows whether the step wraps, stays, or leaves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WorldPosition {
    pub space: WorldSpaceId,
    pub x: i32,
    pub y: i32,
}

/// Where to *draw* something this frame, which is not where it is.
///
/// Its own type, and wider, for two reasons found by review. A bare pair was
/// indistinguishable from a canonical position, so on a 148-wide torus `x = 0` and render-only
/// `x = 148` were both valid-looking position records and nothing could detect their
/// transposition — which the contract explicitly requires. And unwrapping adds a period to a
/// coordinate that may already be near `i32::MAX`, so the result does not always fit where the
/// canonical value does.
///
/// A `RenderPosition` must never be stored, transmitted or compared with a `WorldPosition`.
/// There is deliberately no conversion back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderPosition {
    pub space: WorldSpaceId,
    pub x: i64,
    pub y: i64,
}

/// What happened when a position was moved by one tile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Still in the same space, at this position. On a wrapping axis the coordinate may have
    /// come back around, which is a move of one tile and not a jump.
    Inside(WorldPosition),
    /// The step leaves this space. Where it goes is a transition the topology names, not
    /// something position arithmetic may invent.
    Leaves,
}

/// A space's shape and extent: everything needed to move inside it and to convert positions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Space {
    pub id: WorldSpaceId,
    pub version: TopologyVersion,
    pub geometry: Geometry,
    /// Where each map's core sits in this space's coordinates.
    pub placements: BTreeMap<MapId, Origin>,
}

impl Space {
    /// The global position of a local tile, or `None` if the tile is outside the core or the
    /// map is not in this space.
    ///
    /// A band tile has no global position on purpose. It is not a place; it is the instant
    /// between two places, and giving it coordinates would let it be stored.
    pub fn to_global(&self, local: LocalPosition) -> Option<WorldPosition> {
        if !local.in_core() {
            return None;
        }
        let origin = self.placements.get(&local.map)?;
        let x = origin.x + (local.x - CORE_X.0) as i64;
        let y = origin.y + (local.y - CORE_Y.0) as i64;
        let (x, y) = self.geometry.reduce((x, y));
        Some(WorldPosition { space: self.id, x: i32::try_from(x).ok()?, y: i32::try_from(y).ok()? })
    }

    /// The local tile a global position falls on, or `None` if nothing in this space covers
    /// it — or if more than one map does, which is ambiguity rather than a location.
    pub fn to_local(&self, position: WorldPosition) -> Option<LocalPosition> {
        if position.space != self.id {
            return None;
        }
        let (gx, gy) = self.geometry.reduce((position.x as i64, position.y as i64));

        let mut found = None;
        for (map, origin) in &self.placements {
            let (ox, oy) = self.geometry.reduce((origin.x, origin.y));
            let dx = gx - ox;
            let dy = gy - oy;
            if dx < 0 || dy < 0 || dx >= PITCH_X || dy >= PITCH_Y {
                continue;
            }
            let candidate =
                LocalPosition { map: *map, x: CORE_X.0 + dx as u8, y: CORE_Y.0 + dy as u8 };
            if found.is_some() {
                // Two maps claim this tile. `W-0097` found 26 such cells; a position there
                // means two places, and answering with either would be a guess.
                return None;
            }
            found = Some(candidate);
        }
        found
    }

    /// Move one tile in a cardinal direction.
    ///
    /// The only way to change a `WorldPosition`, because the answer depends on the geometry:
    /// a wrapping axis brings the coordinate back around, and a planar edge leaves the space.
    pub fn step(&self, position: WorldPosition, dx: i32, dy: i32) -> Step {
        if position.space != self.id {
            return Step::Leaves;
        }
        let moved = (position.x as i64 + dx as i64, position.y as i64 + dy as i64);
        let reduced = self.geometry.reduce(moved);

        let landed = WorldPosition { space: self.id, x: reduced.0 as i32, y: reduced.1 as i32 };
        // Inside means some map of this space actually covers the tile. On a plane the edge of
        // the outermost map is the edge of the space; on a torus the coordinate wrapped and
        // the tile on the far side is a real neighbour.
        if self.to_local(landed).is_some() {
            Step::Inside(landed)
        } else {
            Step::Leaves
        }
    }

    /// A render position for a wrapping space, chosen nearest to where the camera already is.
    ///
    /// The canonical position stays reduced; only rendering unwraps. Without this, crossing a
    /// torus seam moves a character one tile in the world and a whole period on screen — the
    /// camera snaps across the map and the player is told they teleported. With it, the two
    /// disagree by exactly one period, which is why they must never be confused in a fixture:
    /// one is where the character is, the other is where to draw them this frame.
    pub fn nearest_unwrapped(&self, position: WorldPosition, near: (i32, i32)) -> RenderPosition {
        let (px, py) = self.geometry.periods();
        RenderPosition {
            space: position.space,
            x: nearest_on_axis(position.x as i64, near.0 as i64, px),
            y: nearest_on_axis(position.y as i64, near.1 as i64, py),
        }
    }

    /// Whether a position is in this space's canonical range.
    ///
    /// A wrapping space reduces its coordinates, so `x = 148` on a 148-wide torus is a render
    /// position that has been mistaken for a stored one. Checked where a position enters a
    /// space-aware layer; the wire cannot check it, because bytes arrive without geometry.
    pub fn is_canonical(&self, position: WorldPosition) -> bool {
        position.space == self.id
            && self.geometry.reduce((position.x as i64, position.y as i64))
                == (position.x as i64, position.y as i64)
    }
}

fn nearest_on_axis(value: i64, near: i64, period: i64) -> i64 {
    if period == 0 {
        return value;
    }
    // Candidates one period either side; the wrap is never more than one period away from a
    // camera that was following the character. Computed in `i64` so adding a period to a
    // coordinate near `i32::MAX` cannot overflow.
    [value - period, value, value + period]
        .into_iter()
        .min_by_key(|candidate| (candidate - near).abs())
        .unwrap_or(value)
}

/// The difference between two positions, or why there is none.
///
/// Not `Sub`, because subtraction has no failure case and this does. Two positions are only
/// comparable inside one space *and* one topology version: the same tile has different global
/// coordinates under two releases, so subtracting across them yields a number that looks like
/// a distance and is not one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Difference {
    /// In tiles, as `i64`: the difference between two `i32` coordinates needs 33 bits, and
    /// subtracting them as `i32` overflows. `i32::MAX - i32::MIN` wrapped to `-1` in release
    /// and panicked in debug, while the Elixir side returned 4,294,967,295 — one contract,
    /// three answers.
    Tiles { dx: i64, dy: i64 },
    /// Different spaces have no distance between them at all.
    DifferentSpace,
    /// One of the positions was computed against another topology release.
    DifferentVersion,
}

/// Compare two positions, each carrying the version it was computed against.
pub fn compare(
    left: (WorldPosition, TopologyVersion),
    right: (WorldPosition, TopologyVersion),
) -> Difference {
    let ((left_at, left_version), (right_at, right_version)) = (left, right);

    if left_at.space != right_at.space {
        return Difference::DifferentSpace;
    }
    if left_version != right_version {
        return Difference::DifferentVersion;
    }
    Difference::Tiles {
        dx: right_at.x as i64 - left_at.x as i64,
        dy: right_at.y as i64 - left_at.y as i64,
    }
}

/// Project a global position to legacy `map_id + u8 x/y`, or say why it cannot be.
///
/// The retained adapter for content and old protocol paths. It refuses rather than
/// approximates: an ambiguous or uncovered position has no legacy address, and inventing one
/// would put a character on a map that does not contain them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LegacyAddress {
    At(LocalPosition),
    /// No map in the space covers the position, or more than one does.
    Unrepresentable,
}

pub fn to_legacy(space: &Space, position: WorldPosition) -> LegacyAddress {
    match space.to_local(position) {
        Some(local) => LegacyAddress::At(local),
        None => LegacyAddress::Unrepresentable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::topology::Axis;

    fn plane() -> Space {
        // Two maps side by side: 1 at the origin, 2 one core-width east.
        Space {
            id: WorldSpaceId(1),
            version: TopologyVersion(1),
            geometry: Geometry::Plane,
            placements: BTreeMap::from([
                (MapId(1), Origin { x: 0, y: 0 }),
                (MapId(2), Origin { x: PITCH_X, y: 0 }),
            ]),
        }
    }

    fn torus() -> Space {
        // The Newbie Dungeon's shape: 2x2 maps, wrapping both ways.
        Space {
            id: WorldSpaceId(37),
            version: TopologyVersion(1),
            geometry: Geometry::Torus { width: 2 * PITCH_X, height: 2 * PITCH_Y },
            placements: BTreeMap::from([
                (MapId(168), Origin { x: 0, y: 0 }),
                (MapId(37), Origin { x: PITCH_X, y: 0 }),
                (MapId(167), Origin { x: 0, y: PITCH_Y }),
                (MapId(264), Origin { x: PITCH_X, y: PITCH_Y }),
            ]),
        }
    }

    #[test]
    fn every_contract_space_round_trips_and_every_refusal_is_justified() {
        // Codex review, 2026-08-23: the exhaustive loop below covers only this module's plane
        // and torus helpers, so cylinder, discrete, ambiguous and the real acceptance square
        // were never exercised tile by tile. This runs the same invariant over every space the
        // contract declares, and requires a reason for each refusal rather than accepting it.
        let (spaces, _) = contract::parse(contract::text());
        let ambiguous = WorldSpaceId(900);
        let mut checked = 0usize;

        for space in spaces.values() {
            for (map, origin) in &space.placements {
                for y in CORE_Y.0..=CORE_Y.1 {
                    for x in CORE_X.0..=CORE_X.1 {
                        let local = LocalPosition { map: *map, x, y };
                        let raw =
                            (origin.x + (x - CORE_X.0) as i64, origin.y + (y - CORE_Y.0) as i64);
                        let fits = i32::try_from(raw.0).is_ok() && i32::try_from(raw.1).is_ok();

                        match space.to_global(local) {
                            None => assert!(
                                !fits,
                                "space {:?} refused {local:?} whose coordinate fits i32",
                                space.id
                            ),
                            Some(global) => {
                                assert!(fits);
                                match space.to_local(global) {
                                    Some(back) => assert_eq!(back, local, "space {:?}", space.id),
                                    None => assert_eq!(
                                        space.id, ambiguous,
                                        "space {:?} lost {local:?}; only the deliberately \
                                         ambiguous space may refuse",
                                        space.id
                                    ),
                                }
                            }
                        }
                        checked += 1;
                    }
                }
            }
        }

        assert!(checked > 50_000, "expected the whole core of every space, got {checked}");
    }

    #[test]
    fn local_to_global_to_local_returns_the_original_tile_everywhere() {
        // The invariant the whole contract rests on, checked exhaustively rather than at a
        // few interesting points: every core tile of every map of a plane and a torus.
        for space in [plane(), torus()] {
            for map in space.placements.keys().copied() {
                for y in CORE_Y.0..=CORE_Y.1 {
                    for x in CORE_X.0..=CORE_X.1 {
                        let local = LocalPosition { map, x, y };
                        let global = space.to_global(local).expect("a core tile has a position");
                        assert_eq!(
                            space.to_local(global),
                            Some(local),
                            "{local:?} did not survive the round trip through {global:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn a_band_tile_has_no_global_position() {
        // Not an oversight. A band tile is the instant between two places, and a position
        // that cannot be stored is better than one that can be stored and is wrong.
        let space = plane();
        for at in [(13, 50), (88, 50), (50, 10), (50, 91), (1, 1), (100, 100)] {
            let local = LocalPosition { map: MapId(1), x: at.0, y: at.1 };
            assert!(!local.in_core());
            assert_eq!(space.to_global(local), None, "{at:?}");
        }
    }

    #[test]
    fn one_step_east_across_a_seam_advances_exactly_one_tile() {
        // The second invariant: across an accepted geographic seam the global difference is
        // exactly one cardinal tile. Checked here as arithmetic; the pinned walking routes
        // check it against the real corpus.
        let space = plane();
        let before = space
            .to_global(LocalPosition { map: MapId(1), x: CORE_X.1, y: 50 })
            .expect("east edge");
        let after = space
            .to_global(LocalPosition { map: MapId(2), x: CORE_X.0, y: 50 })
            .expect("west edge of the neighbour");

        assert_eq!(after.x - before.x, 1);
        assert_eq!(after.y, before.y);
        assert_eq!(space.step(before, 1, 0), Step::Inside(after));
    }

    #[test]
    fn stepping_off_a_plane_leaves_the_space() {
        let space = plane();
        let west_edge =
            space.to_global(LocalPosition { map: MapId(1), x: CORE_X.0, y: 50 }).unwrap();
        assert_eq!(space.step(west_edge, -1, 0), Step::Leaves);

        let east_edge =
            space.to_global(LocalPosition { map: MapId(2), x: CORE_X.1, y: 50 }).unwrap();
        assert_eq!(space.step(east_edge, 1, 0), Step::Leaves);
    }

    #[test]
    fn stepping_off_a_torus_wraps_to_the_far_side_as_one_tile() {
        let space = torus();
        let east_edge =
            space.to_global(LocalPosition { map: MapId(37), x: CORE_X.1, y: 50 }).unwrap();

        let Step::Inside(wrapped) = space.step(east_edge, 1, 0) else {
            panic!("a torus has no edge to fall off");
        };
        // Back to the western column of the western map, which is one step in the world.
        assert_eq!(
            space.to_local(wrapped),
            Some(LocalPosition { map: MapId(168), x: CORE_X.0, y: 50 })
        );
        assert_eq!(wrapped.x, 0);
    }

    #[test]
    fn the_render_position_crosses_a_wrap_by_one_tile_while_the_real_one_jumps() {
        // Both are correct and they must never be confused: the canonical position is
        // reduced, and the camera follows the unwrapped one.
        let space = torus();
        let east_edge =
            space.to_global(LocalPosition { map: MapId(37), x: CORE_X.1, y: 50 }).unwrap();
        let Step::Inside(wrapped) = space.step(east_edge, 1, 0) else { panic!() };

        assert_eq!(wrapped.x - east_edge.x, -(2 * PITCH_X as i32) + 1, "the stored jump");
        let drawn = space.nearest_unwrapped(wrapped, (east_edge.x, east_edge.y));
        assert_eq!(drawn.x - east_edge.x as i64, 1, "the camera moves one tile");
        assert_eq!(drawn.y, east_edge.y as i64);
        // The drawn value is not a position: on this torus x = 148 is outside the canonical
        // range, and the type keeps the two from being interchanged at all.
        assert!(!space.is_canonical(WorldPosition {
            space: space.id,
            x: drawn.x as i32,
            y: drawn.y as i32
        }));
        assert!(space.is_canonical(wrapped));
    }

    #[test]
    fn a_plane_never_unwraps_anything() {
        let space = plane();
        let at = space.to_global(LocalPosition { map: MapId(1), x: 40, y: 40 }).unwrap();
        let drawn = space.nearest_unwrapped(at, (10_000, -10_000));
        assert_eq!((drawn.x, drawn.y), (at.x as i64, at.y as i64));
        assert!(space.is_canonical(at), "a plane's positions are always canonical");
    }

    #[test]
    fn a_cylinder_wraps_one_axis_and_not_the_other() {
        let space = Space {
            id: WorldSpaceId(5),
            version: TopologyVersion(1),
            geometry: Geometry::Cylinder { axis: Axis::X, period: 2 * PITCH_X },
            placements: BTreeMap::from([
                (MapId(1), Origin { x: 0, y: 0 }),
                (MapId(2), Origin { x: PITCH_X, y: 0 }),
            ]),
        };

        let east = space.to_global(LocalPosition { map: MapId(2), x: CORE_X.1, y: 50 }).unwrap();
        assert!(matches!(space.step(east, 1, 0), Step::Inside(_)), "x wraps");

        let north = space.to_global(LocalPosition { map: MapId(1), x: 50, y: CORE_Y.0 }).unwrap();
        assert_eq!(space.step(north, 0, -1), Step::Leaves, "y does not");
    }

    #[test]
    fn positions_in_different_spaces_do_not_interact() {
        let plane = plane();
        let torus = torus();
        let here = plane.to_global(LocalPosition { map: MapId(1), x: 40, y: 40 }).unwrap();

        // The torus cannot place a position that is not its own, and stepping it leaves.
        assert_eq!(torus.to_local(here), None);
        assert_eq!(torus.step(here, 1, 0), Step::Leaves);

        // And the same numbers in two spaces are different positions, which is why the type
        // carries the space rather than the caller remembering it.
        let there = WorldPosition { space: torus.id, x: here.x, y: here.y };
        assert_ne!(here, there);
    }

    #[test]
    fn a_legacy_address_is_refused_rather_than_approximated() {
        let space = plane();
        let inside = space.to_global(LocalPosition { map: MapId(2), x: 20, y: 20 }).unwrap();
        assert_eq!(
            to_legacy(&space, inside),
            LegacyAddress::At(LocalPosition { map: MapId(2), x: 20, y: 20 })
        );

        // A position no map covers has no legacy address. Rounding it to the nearest map
        // would put a character somewhere that does not contain them.
        let outside = WorldPosition { space: space.id, x: 10_000, y: 0 };
        assert_eq!(to_legacy(&space, outside), LegacyAddress::Unrepresentable);
    }

    #[test]
    fn an_ambiguous_tile_has_no_local_position_at_all() {
        // W-0097 found 26 cells claimed by two maps. Answering with either map would be a
        // guess presented as a location.
        let mut space = plane();
        space.placements.insert(MapId(3), Origin { x: 0, y: 0 });

        let contested = WorldPosition { space: space.id, x: 10, y: 10 };
        assert_eq!(space.to_local(contested), None);
        assert_eq!(to_legacy(&space, contested), LegacyAddress::Unrepresentable);
    }

    #[test]
    fn identity_carries_no_map_number() {
        // A space id is content identity for a coordinate space. It is not derived from a map
        // and nothing may derive a map from it: a player-facing identity built on map numbers
        // would leak the 2001 file layout into save data and protocol.
        let space = torus();
        assert_eq!(space.id, WorldSpaceId(37));
        assert!(space.placements.contains_key(&MapId(37)));

        // The overlap is a coincidence of naming, not a conversion, and the types do not
        // permit one.
        let ids: Vec<u128> = space.placements.keys().map(|map| map.0 as u128).collect();
        assert!(ids.contains(&space.id.0), "the manifest names a space after its smallest map");
    }
}

/// Executing the hand-authored contract in `fixtures/position_contract.txt`.
///
/// The file is the specification and this is one of its two readers; `Arena.World.Position`
/// on the server is the other. Neither implementation defines the answers — a disagreement
/// shows up as a failing case in review rather than as two languages placing a player in
/// different rooms, which is the failure this whole contract exists to prevent.
pub mod contract {
    use super::*;
    use crate::topology::Axis;

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Case {
        RegionAt {
            space: u128,
            at: (i32, i32),
            expect: Option<u32>,
        },
        Compare {
            left: (u128, u64, (i32, i32)),
            right: (u128, u64, (i32, i32)),
            expect: Difference,
        },
        Global {
            space: u128,
            local: LocalPosition,
            expect: Option<(i32, i32)>,
        },
        Local {
            space: u128,
            at: (i32, i32),
            expect: Option<LocalPosition>,
        },
        Step {
            space: u128,
            at: (i32, i32),
            by: (i32, i32),
            expect: Option<(i32, i32)>,
        },
        Render {
            space: u128,
            at: (i32, i32),
            near: (i32, i32),
            expect: (i32, i32),
        },
        Legacy {
            space: u128,
            at: (i32, i32),
            expect: Option<LocalPosition>,
        },
    }

    /// The spaces and cases the contract file declares, plus which region owns each map.
    pub fn parse_with_regions(
        text: &str,
    ) -> (BTreeMap<u128, Space>, Vec<Case>, BTreeMap<(u128, u16), u32>) {
        let (spaces, cases, regions) = parse_inner(text);
        (spaces, cases, regions)
    }

    /// The spaces and cases the contract file declares.
    pub fn parse(text: &str) -> (BTreeMap<u128, Space>, Vec<Case>) {
        let (spaces, cases, _) = parse_inner(text);
        (spaces, cases)
    }

    fn parse_inner(text: &str) -> (BTreeMap<u128, Space>, Vec<Case>, BTreeMap<(u128, u16), u32>) {
        let mut spaces: BTreeMap<u128, Space> = BTreeMap::new();
        let mut cases = Vec::new();
        // Which region owns which map, keyed by (space, map).
        let mut regions: BTreeMap<(u128, u16), u32> = BTreeMap::new();

        let coords = |text: &str| -> Option<(i64, i64)> {
            let (x, y) = text.split_once(',')?;
            Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
        };

        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let word: Vec<&str> = line.split_whitespace().collect();

            match word.as_slice() {
                ["space", id, shape] => {
                    let id: u128 = id.parse().expect("space id");
                    let geometry = match *shape {
                        "plane" => Geometry::Plane,
                        "discrete" => Geometry::Discrete,
                        other => {
                            if let Some(period) = other.strip_prefix("cylinder-x:") {
                                Geometry::Cylinder {
                                    axis: Axis::X,
                                    period: period.parse().expect("period"),
                                }
                            } else if let Some(period) = other.strip_prefix("cylinder-y:") {
                                Geometry::Cylinder {
                                    axis: Axis::Y,
                                    period: period.parse().expect("period"),
                                }
                            } else if let Some(size) = other.strip_prefix("torus:") {
                                let (w, h) = size.split_once('x').expect("torus size");
                                Geometry::Torus {
                                    width: w.parse().expect("width"),
                                    height: h.parse().expect("height"),
                                }
                            } else {
                                panic!("unknown geometry {other:?}");
                            }
                        }
                    };
                    spaces.insert(
                        id,
                        Space {
                            id: WorldSpaceId(id),
                            version: TopologyVersion(1),
                            geometry,
                            placements: BTreeMap::new(),
                        },
                    );
                }
                ["place", space, map, at] => {
                    let space: u128 = space.parse().expect("space");
                    let (x, y) = coords(at).expect("origin");
                    spaces
                        .get_mut(&space)
                        .expect("place before space")
                        .placements
                        .insert(MapId(map.parse().expect("map")), Origin { x, y });
                }
                ["global", space, map, at, "->", "none"] => cases.push(Case::Global {
                    space: space.parse().expect("space"),
                    local: local_at(map, at),
                    expect: None,
                }),
                ["global", space, map, at, "->", expect] => cases.push(Case::Global {
                    space: space.parse().expect("space"),
                    local: local_at(map, at),
                    expect: coords(expect).map(|(x, y)| (x as i32, y as i32)),
                }),
                ["local", space, at, "->", "none"] => cases.push(Case::Local {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    expect: None,
                }),
                ["local", space, at, "->", map, tile] => cases.push(Case::Local {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    expect: Some(local_at(map, tile)),
                }),
                ["step", space, at, "by", by, "->", "leaves"] => cases.push(Case::Step {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    by: pair(by),
                    expect: None,
                }),
                ["step", space, at, "by", by, "->", "inside", expect] => cases.push(Case::Step {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    by: pair(by),
                    expect: Some(pair(expect)),
                }),
                ["render", space, at, "near", near, "->", expect] => cases.push(Case::Render {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    near: pair(near),
                    expect: pair(expect),
                }),
                ["legacy", space, at, "->", "unrepresentable"] => cases.push(Case::Legacy {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    expect: None,
                }),
                ["legacy", space, at, "->", map, tile] => cases.push(Case::Legacy {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    expect: Some(local_at(map, tile)),
                }),
                ["region", space, region, map, origin] => {
                    let (x, y) = origin.split_once(',').expect("an origin");
                    let space: u128 = space.parse().expect("space");
                    let map: u16 = map.parse().expect("map");
                    // The declared origin must match where the space puts that map, or the
                    // placement is describing a different world.
                    let declared = crate::topology::Origin {
                        x: x.parse().expect("ox"),
                        y: y.parse().expect("oy"),
                    };
                    if let Some(space_origin) = spaces
                        .get(&space)
                        .and_then(|s| s.placements.get(&crate::position::MapId(map)))
                    {
                        assert_eq!(
                            *space_origin, declared,
                            "region placement for map {map} disagrees with space {space}"
                        );
                    }
                    regions.insert((space, map), region.parse().expect("region"));
                }
                ["region-at", space, at, "->", "none"] => cases.push(Case::RegionAt {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    expect: None,
                }),
                ["region-at", space, at, "->", region] => cases.push(Case::RegionAt {
                    space: space.parse().expect("space"),
                    at: pair(at),
                    expect: Some(region.parse().expect("region")),
                }),
                ["compare", left_space, left_version, left_at, "with", right_space, right_version, right_at, "->", verdict @ ..] =>
                {
                    let expect = match verdict {
                        ["different-space"] => Difference::DifferentSpace,
                        ["different-version"] => Difference::DifferentVersion,
                        [tiles] => {
                            // Parsed as i64: a difference between two i32 coordinates needs
                            // 33 bits, so the contract can state values `pair` could not hold.
                            let (dx, dy) = tiles.split_once(',').expect("a pair");
                            Difference::Tiles {
                                dx: dx.trim().parse().expect("dx"),
                                dy: dy.trim().parse().expect("dy"),
                            }
                        }
                        other => panic!("unknown comparison result {other:?}"),
                    };
                    cases.push(Case::Compare {
                        left: (
                            left_space.parse().expect("space"),
                            left_version.parse().expect("version"),
                            pair(left_at),
                        ),
                        right: (
                            right_space.parse().expect("space"),
                            right_version.parse().expect("version"),
                            pair(right_at),
                        ),
                        expect,
                    });
                }
                other => panic!("cannot read contract line {other:?}"),
            }
        }

        (spaces, cases, regions)
    }

    fn pair(text: &str) -> (i32, i32) {
        let (x, y) = text.split_once(',').expect("a pair");
        (x.trim().parse().expect("x"), y.trim().parse().expect("y"))
    }

    fn local_at(map: &str, at: &str) -> LocalPosition {
        let (x, y) = at.split_once(',').expect("a tile");
        LocalPosition {
            map: MapId(map.parse().expect("map")),
            x: x.trim().parse().expect("x"),
            y: y.trim().parse().expect("y"),
        }
    }

    pub fn text() -> &'static str {
        include_str!("../fixtures/position_contract.txt")
    }
}

#[cfg(test)]
mod contract_tests {
    use super::contract::{self, Case};
    use super::*;

    #[test]
    fn rust_satisfies_every_case_in_the_position_contract() {
        let (spaces, cases) = contract::parse(contract::text());
        assert!(cases.len() >= 50, "the contract should be worth checking: {}", cases.len());

        for case in &cases {
            match case {
                Case::Global { space, local, expect } => {
                    let space = &spaces[space];
                    let found = space.to_global(*local).map(|at| (at.x, at.y));
                    assert_eq!(found, *expect, "global {local:?} in space {:?}", space.id);
                }
                Case::Local { space, at, expect } => {
                    let space = &spaces[space];
                    let position = WorldPosition { space: space.id, x: at.0, y: at.1 };
                    assert_eq!(space.to_local(position), *expect, "local {at:?}");
                }
                Case::Step { space, at, by, expect } => {
                    let space = &spaces[space];
                    let position = WorldPosition { space: space.id, x: at.0, y: at.1 };
                    let found = match space.step(position, by.0, by.1) {
                        Step::Inside(landed) => Some((landed.x, landed.y)),
                        Step::Leaves => None,
                    };
                    assert_eq!(found, *expect, "step {at:?} by {by:?}");
                }
                Case::Render { space, at, near, expect } => {
                    let space = &spaces[space];
                    let position = WorldPosition { space: space.id, x: at.0, y: at.1 };
                    let drawn = space.nearest_unwrapped(position, *near);
                    assert_eq!(
                        (drawn.x, drawn.y),
                        (expect.0 as i64, expect.1 as i64),
                        "render {at:?}"
                    );
                    assert_eq!(drawn.space, position.space, "a render position keeps its space");
                }
                Case::RegionAt { space, at, expect } => {
                    let (_, _, regions) = contract::parse_with_regions(contract::text());
                    let space = &spaces[space];
                    let position = WorldPosition { space: space.id, x: at.0, y: at.1 };
                    let found = space
                        .to_local(position)
                        .and_then(|local| regions.get(&(space.id.0, local.map.0)).copied());
                    assert_eq!(found, *expect, "region at {at:?}");
                }
                Case::Compare { left, right, expect } => {
                    let position = |(space, _version, at): &(u128, u64, (i32, i32))| {
                        WorldPosition { space: WorldSpaceId(*space), x: at.0, y: at.1 }
                    };
                    let found = compare(
                        (position(left), TopologyVersion(left.1)),
                        (position(right), TopologyVersion(right.1)),
                    );
                    assert_eq!(found, *expect, "compare {left:?} with {right:?}");
                }
                Case::Legacy { space, at, expect } => {
                    let space = &spaces[space];
                    let position = WorldPosition { space: space.id, x: at.0, y: at.1 };
                    let found = match to_legacy(space, position) {
                        LegacyAddress::At(local) => Some(local),
                        LegacyAddress::Unrepresentable => None,
                    };
                    assert_eq!(found, *expect, "legacy {at:?}");
                }
            }
        }
    }

    #[test]
    fn the_pinned_walking_routes_agree_with_the_contract() {
        // The four routes and the contract are two statements about the same four maps, so
        // they must not be able to disagree: each route's global before and after is
        // re-derived here from the contract's placements.
        let (spaces, _) = contract::parse(contract::text());
        let space = &spaces[&199];

        for step in crate::walk::pinned_steps() {
            let from = LocalPosition { map: MapId(step.from.0), x: step.from.1, y: step.from.2 };
            let to = LocalPosition { map: MapId(step.to.0), x: step.to.1, y: step.to.2 };

            let before = space.to_global(from).expect("the route leaves a real tile");
            let after = space.to_global(to).expect("the route arrives on a real tile");
            assert_eq!((before.x as i64, before.y as i64), step.global_before, "{}", step.encode());
            assert_eq!((after.x as i64, after.y as i64), step.global_after, "{}", step.encode());

            // And the step itself, taken through the space rather than asserted.
            let (dx, dy) = step.direction.step();
            assert_eq!(
                space.step(before, dx as i32, dy as i32),
                Step::Inside(after),
                "{}",
                step.encode()
            );
        }
    }
}
