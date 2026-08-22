//! Whether a seam is real, judged one tile pair at a time.
//!
//! `topology` decides where maps *sit*. This decides whether the boundary between two of
//! them is somewhere a character can actually walk, and it is deliberately paranoid about
//! the difference between a number that is stable and a number that is right.
//!
//! That distinction is the reason this module exists in the shape it does. A pinned baseline
//! stops a count from drifting; it cannot notice that the count means something other than
//! what its name says. This corpus already produced one such error: the blocked layer holds
//! three states, was read as two, and the resulting classification was perfectly stable and
//! perfectly wrong for a week. Matching artwork across a boundary would not have caught it
//! either — the art was fine; the *semantics* were not. So every seam is judged on what a
//! character can do at it:
//!
//! - which tile classes meet, in the three states the layer really has;
//! - whether a crossing is valid on foot, valid by boat, or a change of medium that would
//!   put a walker in the sea;
//! - whether the exit exists in both directions;
//! - whether local and global coordinates round-trip exactly;
//! - whether one step across the boundary advances exactly one global tile;
//! - and whether the ground art is continuous, as a review signal rather than a verdict.
//!
//! Nothing here promotes a seam. Evidence is evidence; activation is a decision, and it
//! belongs to a person reading `W-0101`.

use crate::mappack::{PackedMap, Tile};
use crate::topology::{
    to_global, Adjacency, Origin, Side, Surface, BAND_X, BAND_Y, CORE_X, CORE_Y,
};
use std::collections::{BTreeMap, BTreeSet};

/// What a character could do at one tile pair of a seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Crossing {
    /// Walkable ground on both sides.
    OnFoot,
    /// Navigable water on both sides: crossable while `navigating`, and only then.
    ByBoat,
    /// Solid on at least one side. A cliff or a wall, and a perfectly ordinary thing for a
    /// seam to contain — most of a coastline is impassable.
    Blocked,
    /// A walker's path arrives on water. Nothing stops them:
    /// `Arena.Map.Movement.check_tile_exit/5` transfers on the destination the exit names,
    /// without checking the arrival tile or whether the character is `navigating`. So the
    /// character ends up standing on the sea, and this is precisely the case artwork
    /// comparison cannot see — the ground can be perfectly continuous across a boundary
    /// that strands somebody.
    StrandsWalker,
    /// A sailor's path arrives on land. The current server permits it, because the only
    /// navigation rule it has is `tile_val == 2 and not entity.navigating` — water is
    /// blocked without a boat, and nothing blocks a boat on dry ground. Recorded as an
    /// observation rather than corrected here: whether a ship may beach itself is a content
    /// decision, and inventing the opposite rule inside a compiler would be exactly the
    /// kind of assumption this module exists to avoid.
    BeachesBoat,
}

impl Crossing {
    /// Classify the whole three-tile path a crossing actually takes.
    ///
    /// Not two tiles. Leaving map A eastward means stepping from the core edge (`x = 87`)
    /// onto the transition band (`x = 88`), which is what fires the exit, and only then
    /// arriving on B's core edge (`x = 14`). The band gates whether a character can leave at
    /// all — `Arena.Map.Movement` applies the same walkable/water rules to that step as to
    /// any other — so judging the pair without it would report a medium change where the band
    /// is water and the crossing is a perfectly ordinary bit of sailing.
    pub fn of(departure: Tile, band: Tile, arrival: Tile) -> Crossing {
        if [departure, band, arrival].contains(&Tile::Solid) {
            return Crossing::Blocked;
        }

        // Can a walker even reach the band? Only if both tiles under them are dry.
        let on_foot = departure == Tile::Walkable && band == Tile::Walkable;
        match (arrival, on_foot) {
            (Tile::Walkable, true) => Crossing::OnFoot,
            (Tile::Walkable, false) => Crossing::BeachesBoat,
            (Tile::Water, true) => Crossing::StrandsWalker,
            (Tile::Water, false) => Crossing::ByBoat,
            (Tile::Solid, _) => unreachable!("solid was handled above"),
        }
    }
}

/// One tile pair on a seam, with everything known about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TilePair {
    /// Position on the departing map's core edge.
    pub departure: (u8, u8),
    /// Position on the arriving map's core edge.
    pub arrival: (u8, u8),
    /// The departing map's transition band tile, outside its core.
    pub band: (u8, u8),
    pub crossing: Crossing,
    /// An exit at the band that names the arrival exactly.
    pub exit_out: bool,
    /// The same claim from the other side.
    pub exit_back: bool,
    /// Global positions differ by exactly one tile in the seam's direction.
    pub one_tile: bool,
    /// Global position converts back to this exact map and local tile.
    pub round_trip: bool,
    /// The band's ground art repeats the neighbour's edge art: the gutter hypothesis.
    pub band_matches_neighbour: bool,
    /// The two core edge tiles carry the same ground art, which would be duplication
    /// rather than continuity.
    pub edges_identical: bool,
}

/// Everything measured about one candidate seam.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeamEvidence {
    pub seam: Adjacency,
    pub pairs: Vec<TilePair>,
}

impl SeamEvidence {
    pub fn count(&self, crossing: Crossing) -> usize {
        self.pairs.iter().filter(|pair| pair.crossing == crossing).count()
    }

    /// Pairs where a character could cross at all, on foot or by boat.
    pub fn passable(&self) -> usize {
        self.count(Crossing::OnFoot) + self.count(Crossing::ByBoat)
    }

    /// The failures that disqualify a seam outright: geometry that does not hold, or a
    /// crossing that changes the medium under the character.
    pub fn defects(&self) -> Vec<String> {
        let mut defects = Vec::new();

        let broken: Vec<&TilePair> = self.pairs.iter().filter(|pair| !pair.one_tile).collect();
        if !broken.is_empty() {
            defects.push(format!(
                "{} of {} tile pairs are not one tile apart",
                broken.len(),
                self.pairs.len()
            ));
        }

        let lost: Vec<&TilePair> = self.pairs.iter().filter(|pair| !pair.round_trip).collect();
        if !lost.is_empty() {
            defects.push(format!("{} tile pairs do not round-trip", lost.len()));
        }

        // A stranding matters where an exit actually sends somebody across it.
        let stranded = self
            .pairs
            .iter()
            .filter(|pair| pair.crossing == Crossing::StrandsWalker && pair.exit_out)
            .count();
        if stranded > 0 {
            defects.push(format!("{stranded} exits leave a walker standing on water"));
        }

        let one_way = self.pairs.iter().filter(|pair| pair.exit_out && !pair.exit_back).count();
        if one_way > 0 {
            defects.push(format!("{one_way} exits are not returned by the other map"));
        }

        defects
    }

    /// How much of the ground art is continuous across the boundary, as a percentage of the
    /// pairs where a crossing is possible at all.
    ///
    /// A review signal and nothing more. `W-0097` puts the thresholds at 95% automatic, 85%
    /// to 95% review and below that correct-or-classify, and this reports the number rather
    /// than applying them, because art continuity is the weakest of the checks here: it was
    /// silent about a three-state field being read as two.
    pub fn ground_continuity(&self) -> Option<usize> {
        let relevant: Vec<&TilePair> =
            self.pairs.iter().filter(|pair| pair.crossing != Crossing::Blocked).collect();
        if relevant.is_empty() {
            return None;
        }
        let matching = relevant.iter().filter(|pair| pair.band_matches_neighbour).count();
        Some(matching * 100 / relevant.len())
    }
}

/// The tile pairs a seam on this side is made of: core edge, neighbour's core edge, and the
/// band between them.
///
/// One function for all four sides so a corner or a direction cannot be handled specially by
/// accident. Walking east off my core's last column (`x = 87`) enters my band (`x = 88`),
/// which the exit turns into my neighbour's first core column (`x = 14`) — so those two core
/// columns are what must be adjacent in global space, 74 tiles from origin to origin.
fn tile_pairs(side: Side) -> Vec<((u8, u8), (u8, u8), (u8, u8))> {
    match side {
        Side::East => {
            (CORE_Y.0..=CORE_Y.1).map(|y| ((CORE_X.1, y), (CORE_X.0, y), (BAND_X.1, y))).collect()
        }
        Side::West => {
            (CORE_Y.0..=CORE_Y.1).map(|y| ((CORE_X.0, y), (CORE_X.1, y), (BAND_X.0, y))).collect()
        }
        Side::North => {
            (CORE_X.0..=CORE_X.1).map(|x| ((x, CORE_Y.0), (x, CORE_Y.1), (x, BAND_Y.0))).collect()
        }
        Side::South => {
            (CORE_X.0..=CORE_X.1).map(|x| ((x, CORE_Y.1), (x, CORE_Y.0), (x, BAND_Y.1))).collect()
        }
    }
}

fn ground_art(map: &PackedMap) -> BTreeMap<(u8, u8), i32> {
    map.layers[0].iter().map(|tile| ((tile.x, tile.y), tile.grh)).collect()
}

/// Judge one seam, tile pair by tile pair.
///
/// `origin` places the departing map and `neighbour_origin` the arriving one, so the
/// coordinate checks are made against the same layout the manifest would publish rather than
/// against an assumption about what adjacency means.
pub fn evidence(
    from: &PackedMap,
    to: &PackedMap,
    side: Side,
    origin: Origin,
    neighbour_origin: Origin,
) -> SeamEvidence {
    let from_art = ground_art(from);
    let to_art = ground_art(to);
    let (step_x, step_y) = side.step();

    let exits_out: BTreeSet<(u8, u8, u8, u8)> = from
        .exits
        .iter()
        .filter(|exit| exit.target_map == to.map_id)
        .map(|exit| (exit.x, exit.y, exit.target_x, exit.target_y))
        .collect();
    let exits_back: BTreeSet<(u8, u8, u8, u8)> = to
        .exits
        .iter()
        .filter(|exit| exit.target_map == from.map_id)
        .map(|exit| (exit.x, exit.y, exit.target_x, exit.target_y))
        .collect();
    let back_band = tile_pairs(side.opposite());

    let pairs = tile_pairs(side)
        .into_iter()
        .enumerate()
        .map(|(index, (departure, arrival, band))| {
            let crossing = Crossing::of(
                Tile::of(from.tile_at(departure.0 as i32, departure.1 as i32)),
                Tile::of(from.tile_at(band.0 as i32, band.1 as i32)),
                Tile::of(to.tile_at(arrival.0 as i32, arrival.1 as i32)),
            );

            let here = to_global(origin, departure.0, departure.1);
            let there = to_global(neighbour_origin, arrival.0, arrival.1);
            let one_tile = match (here, there) {
                (Some(here), Some(there)) => {
                    there == (here.0 + step_x as i64, here.1 + step_y as i64)
                }
                _ => false,
            };
            // The inverse must land back on this exact map and tile. A layout that places two
            // maps on the same cell can still satisfy `one_tile` while making the position
            // ambiguous, and an ambiguous global position is worse than a wrong one.
            let round_trip = there
                .and_then(|there| to_local(neighbour_origin, there))
                .map(|local| local == arrival)
                .unwrap_or(false);

            // The reciprocal exit leaves the *other* map's band and arrives at this map's
            // core edge, which is the same pair read from the far side.
            let (_, back_arrival, back_band_tile) = back_band[index];

            TilePair {
                departure,
                arrival,
                band,
                crossing,
                exit_out: exits_out.contains(&(band.0, band.1, arrival.0, arrival.1)),
                exit_back: exits_back.contains(&(
                    back_band_tile.0,
                    back_band_tile.1,
                    back_arrival.0,
                    back_arrival.1,
                )),
                one_tile,
                round_trip,
                band_matches_neighbour: from_art.get(&band) == to_art.get(&arrival)
                    && from_art.contains_key(&band),
                edges_identical: from_art.get(&departure) == to_art.get(&arrival)
                    && from_art.contains_key(&departure),
            }
        })
        .collect();

    SeamEvidence { seam: Adjacency { from_map: from.map_id, side, to_map: to.map_id }, pairs }
}

/// The local core tile a global position falls on, if it falls inside this origin's core.
pub fn to_local(origin: Origin, global: (i64, i64)) -> Option<(u8, u8)> {
    let x = global.0 - origin.x;
    let y = global.1 - origin.y;
    let width = (CORE_X.1 - CORE_X.0) as i64;
    let height = (CORE_Y.1 - CORE_Y.0) as i64;
    if x < 0 || y < 0 || x > width || y > height {
        return None;
    }
    Some((CORE_X.0 + x as u8, CORE_Y.0 + y as u8))
}

/// Where four maps meet, and whether the meeting point is covered exactly once.
///
/// A corner is where an off-by-one hides best: three of the four seams can be perfect while
/// the fourth tile is a hole or a duplicate, and no single-seam check looks at it. The four
/// core corner tiles must occupy four distinct, contiguous global positions forming a 2x2
/// block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CornerEvidence {
    pub maps: [u16; 4],
    pub tiles: Vec<(i64, i64)>,
    pub contiguous: bool,
    pub distinct: bool,
}

pub fn corner_evidence(
    north_west: (u16, Origin),
    north_east: (u16, Origin),
    south_west: (u16, Origin),
    south_east: (u16, Origin),
) -> CornerEvidence {
    // The tile of each map nearest the shared corner.
    let corners = [
        (north_west, (CORE_X.1, CORE_Y.1)),
        (north_east, (CORE_X.0, CORE_Y.1)),
        (south_west, (CORE_X.1, CORE_Y.0)),
        (south_east, (CORE_X.0, CORE_Y.0)),
    ];

    let tiles: Vec<(i64, i64)> =
        corners.iter().filter_map(|((_, origin), (x, y))| to_global(*origin, *x, *y)).collect();

    let unique: BTreeSet<(i64, i64)> = tiles.iter().copied().collect();
    let xs: BTreeSet<i64> = tiles.iter().map(|tile| tile.0).collect();
    let ys: BTreeSet<i64> = tiles.iter().map(|tile| tile.1).collect();

    let contiguous = tiles.len() == 4
        && unique.len() == 4
        && xs.len() == 2
        && ys.len() == 2
        && xs.iter().max().unwrap() - xs.iter().min().unwrap() == 1
        && ys.iter().max().unwrap() - ys.iter().min().unwrap() == 1;

    CornerEvidence {
        maps: [north_west.0, north_east.0, south_west.0, south_east.0],
        distinct: unique.len() == tiles.len(),
        tiles,
        contiguous,
    }
}

/// What the whole corpus's candidate land seams look like.
///
/// An observation, pinned so it cannot drift. Not a promotion: a seam with no defects is a
/// seam worth reviewing, and `W-0101` decides which are activated.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SeamSummary {
    pub land_seams: usize,
    /// Seams with no geometry failure, no one-way exit and no exit across a medium change.
    pub without_defects: usize,
    pub tile_pairs: usize,
    pub on_foot: usize,
    pub by_boat: usize,
    pub blocked: usize,
    pub strands_walker: usize,
    pub beaches_boat: usize,
    /// Strandings an exit actually sends a character across.
    pub strandings_with_exits: usize,
    pub one_tile_failures: usize,
    pub round_trip_failures: usize,
    pub one_way_exits: usize,
    /// Seams whose band art repeats the neighbour's edge for at least 95% of crossable
    /// pairs, and for at least 85%.
    pub continuous_at_95: usize,
    pub continuous_at_85: usize,
}

/// Measure every candidate land seam in a set of placed regions.
pub fn summarise(
    maps: &[PackedMap],
    seams: &BTreeSet<Adjacency>,
    origins: &BTreeMap<u16, Origin>,
    surfaces: &BTreeMap<u16, Surface>,
) -> (SeamSummary, Vec<SeamEvidence>) {
    let by_id: BTreeMap<u16, &PackedMap> = maps.iter().map(|map| (map.map_id, map)).collect();
    let mut summary = SeamSummary::default();
    let mut all = Vec::new();

    for seam in seams {
        let land = surfaces.get(&seam.from_map) == Some(&Surface::Land)
            && surfaces.get(&seam.to_map) == Some(&Surface::Land);
        if !land {
            continue;
        }
        let (Some(from), Some(to)) = (by_id.get(&seam.from_map), by_id.get(&seam.to_map)) else {
            continue;
        };
        let (Some(origin), Some(neighbour)) =
            (origins.get(&seam.from_map), origins.get(&seam.to_map))
        else {
            continue;
        };

        let found = evidence(from, to, seam.side, *origin, *neighbour);
        summary.land_seams += 1;
        summary.tile_pairs += found.pairs.len();
        summary.on_foot += found.count(Crossing::OnFoot);
        summary.by_boat += found.count(Crossing::ByBoat);
        summary.blocked += found.count(Crossing::Blocked);
        summary.strands_walker += found.count(Crossing::StrandsWalker);
        summary.beaches_boat += found.count(Crossing::BeachesBoat);
        summary.strandings_with_exits += found
            .pairs
            .iter()
            .filter(|pair| pair.crossing == Crossing::StrandsWalker && pair.exit_out)
            .count();
        summary.one_tile_failures += found.pairs.iter().filter(|pair| !pair.one_tile).count();
        summary.round_trip_failures += found.pairs.iter().filter(|pair| !pair.round_trip).count();
        summary.one_way_exits +=
            found.pairs.iter().filter(|pair| pair.exit_out && !pair.exit_back).count();
        if found.defects().is_empty() {
            summary.without_defects += 1;
        }
        match found.ground_continuity() {
            Some(percent) if percent >= 95 => {
                summary.continuous_at_95 += 1;
                summary.continuous_at_85 += 1;
            }
            Some(percent) if percent >= 85 => summary.continuous_at_85 += 1,
            _ => {}
        }

        all.push(found);
    }

    (summary, all)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mappack::{LayerTile, MapExit};
    use crate::topology::{PITCH_X, PITCH_Y, STORAGE};

    fn blank(map_id: u16) -> PackedMap {
        PackedMap {
            map_id,
            name: format!("map {map_id}"),
            width: STORAGE as u16,
            height: STORAGE as u16,
            music_hi: 0,
            music_low: 0,
            tiles: vec![0; STORAGE as usize * STORAGE as usize],
            layers: Default::default(),
            npcs: Vec::new(),
            objects: Vec::new(),
            exits: Vec::new(),
        }
    }

    fn set_tile(map: &mut PackedMap, x: u8, y: u8, value: u8) {
        let index = (y as usize - 1) * map.width as usize + (x as usize - 1);
        map.tiles[index] = value;
    }

    #[test]
    fn a_clean_east_seam_is_one_tile_wide_everywhere() {
        let west = blank(1);
        let east = blank(2);
        let found =
            evidence(&west, &east, Side::East, Origin { x: 0, y: 0 }, Origin { x: PITCH_X, y: 0 });

        assert_eq!(found.pairs.len(), 80, "one pair per core row");
        assert!(found.pairs.iter().all(|pair| pair.one_tile));
        assert!(found.pairs.iter().all(|pair| pair.round_trip));
        assert_eq!(found.count(Crossing::OnFoot), 80);
        assert_eq!(found.defects(), Vec::<String>::new());
    }

    #[test]
    fn a_layout_on_storage_centres_fails_every_pair() {
        // The mistake this catches: 100-tile pitch instead of the 74-tile core. Every map
        // lands on the right *side* of its neighbour and every tile pair is 27 apart, which
        // no test that only checks which map you arrive on would notice.
        let west = blank(1);
        let east = blank(2);
        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: STORAGE as i64, y: 0 },
        );

        assert!(found.pairs.iter().all(|pair| !pair.one_tile));
        assert!(!found.defects().is_empty());
    }

    #[test]
    fn walking_into_water_is_a_medium_change_and_a_defect_when_an_exit_sends_you_there() {
        // The case artwork comparison is blind to. Both maps have perfectly continuous
        // ground art; one side is land and the other is sea, and the exit walks a character
        // off the beach into the water.
        let mut land = blank(1);
        let mut sea = blank(2);
        set_tile(&mut land, CORE_X.1, 50, 0);
        set_tile(&mut land, BAND_X.1, 50, 0);
        set_tile(&mut sea, CORE_X.0, 50, 2);
        land.layers[0].push(LayerTile { x: BAND_X.1, y: 50, grh: 4242 });
        sea.layers[0].push(LayerTile { x: CORE_X.0, y: 50, grh: 4242 });
        land.exits.push(MapExit {
            x: BAND_X.1,
            y: 50,
            target_map: 2,
            target_x: CORE_X.0,
            target_y: 50,
        });

        let found =
            evidence(&land, &sea, Side::East, Origin { x: 0, y: 0 }, Origin { x: PITCH_X, y: 0 });

        let pair = found.pairs.iter().find(|pair| pair.departure.1 == 50).expect("row 50");
        assert_eq!(pair.crossing, Crossing::StrandsWalker);
        assert!(pair.band_matches_neighbour, "the art matches perfectly, and it is still wrong");
        assert!(pair.exit_out);
        assert!(found.defects().iter().any(|note| note.contains("standing on water")));
    }

    #[test]
    fn water_meeting_water_crosses_by_boat_and_is_not_a_defect() {
        let mut west = blank(1);
        let mut east = blank(2);
        for y in CORE_Y.0..=CORE_Y.1 {
            set_tile(&mut west, CORE_X.1, y, 2);
            set_tile(&mut west, BAND_X.1, y, 2);
            set_tile(&mut east, CORE_X.0, y, 2);
        }

        let found =
            evidence(&west, &east, Side::East, Origin { x: 0, y: 0 }, Origin { x: PITCH_X, y: 0 });
        assert_eq!(found.count(Crossing::ByBoat), 80);
        assert_eq!(found.count(Crossing::StrandsWalker), 0);
        assert_eq!(found.count(Crossing::BeachesBoat), 0);
        assert_eq!(found.defects(), Vec::<String>::new());
    }

    #[test]
    fn solid_ground_on_either_side_is_blocked_not_broken() {
        let mut west = blank(1);
        let east = blank(2);
        for y in CORE_Y.0..=CORE_Y.1 {
            set_tile(&mut west, CORE_X.1, y, 1);
        }

        let found =
            evidence(&west, &east, Side::East, Origin { x: 0, y: 0 }, Origin { x: PITCH_X, y: 0 });
        assert_eq!(found.count(Crossing::Blocked), 80);
        assert_eq!(found.passable(), 0);
        assert_eq!(found.defects(), Vec::<String>::new(), "a cliff is not a defect");
        assert_eq!(found.ground_continuity(), None, "nothing crossable to judge");
    }

    #[test]
    fn an_exit_the_other_map_does_not_return_is_reported() {
        let mut west = blank(1);
        let east = blank(2);
        west.exits.push(MapExit {
            x: BAND_X.1,
            y: 40,
            target_map: 2,
            target_x: CORE_X.0,
            target_y: 40,
        });

        let found =
            evidence(&west, &east, Side::East, Origin { x: 0, y: 0 }, Origin { x: PITCH_X, y: 0 });
        assert!(found.defects().iter().any(|note| note.contains("not returned")));
    }

    #[test]
    fn four_maps_meet_at_four_distinct_touching_tiles() {
        let north_west = (1u16, Origin { x: 0, y: 0 });
        let north_east = (2u16, Origin { x: PITCH_X, y: 0 });
        let south_west = (3u16, Origin { x: 0, y: PITCH_Y });
        let south_east = (4u16, Origin { x: PITCH_X, y: PITCH_Y });

        let corner = corner_evidence(north_west, north_east, south_west, south_east);
        assert!(corner.contiguous);
        assert!(corner.distinct);
        assert_eq!(corner.tiles.len(), 4);

        // Move one map a single tile and the corner stops closing, which is exactly the
        // off-by-one a per-seam check cannot see.
        let nudged = corner_evidence(
            north_west,
            north_east,
            south_west,
            (4u16, Origin { x: PITCH_X + 1, y: PITCH_Y }),
        );
        assert!(!nudged.contiguous);
    }

    #[test]
    fn a_global_position_converts_back_to_the_tile_it_came_from() {
        let origin = Origin { x: -1406, y: 720 };
        for (x, y) in [(CORE_X.0, CORE_Y.0), (CORE_X.1, CORE_Y.1), (50, 50)] {
            let global = to_global(origin, x, y).expect("inside the core");
            assert_eq!(to_local(origin, global), Some((x, y)));
        }
        // Outside the core in either direction is nothing, not a wrapped guess.
        let edge = to_global(origin, CORE_X.1, CORE_Y.1).unwrap();
        assert_eq!(to_local(origin, (edge.0 + 1, edge.1)), None);
        assert_eq!(to_local(origin, (origin.x - 1, origin.y)), None);
    }
}

#[cfg(test)]
mod cross_language {
    use crate::mappack::{tile_semantics_fixture, Tile};

    #[test]
    fn rust_agrees_with_the_elixir_server_about_what_every_tile_means() {
        let fixture = tile_semantics_fixture();
        assert!(fixture.len() >= 100, "the fixture should cover a real spread of positions");

        for row in &fixture {
            let tile = Tile::of(row.value);
            assert_eq!(
                tile.enterable(false),
                row.on_foot,
                "map {} ({}, {}) value {}: Elixir says on foot {}, Rust says {}",
                row.map_id,
                row.x,
                row.y,
                row.value,
                row.on_foot,
                tile.enterable(false)
            );
            assert_eq!(
                tile.enterable(true),
                row.navigating,
                "map {} ({}, {}) value {}: Elixir says navigating {}, Rust says {}",
                row.map_id,
                row.x,
                row.y,
                row.value,
                row.navigating,
                tile.enterable(true)
            );
        }
    }

    #[test]
    fn the_fixture_covers_all_three_tile_classes() {
        // A fixture of walkable tiles only would have agreed with reading the layer as a
        // boolean, which is the error it exists to prevent.
        let fixture = tile_semantics_fixture();
        for expected in [Tile::Walkable, Tile::Solid, Tile::Water] {
            assert!(
                fixture.iter().any(|row| Tile::of(row.value) == expected),
                "no {expected:?} tile in the fixture"
            );
        }
    }
}
