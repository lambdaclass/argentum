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
    to_global, Adjacency, Atlas, ClaimClass, Origin, Resolved, Side, Surface, BAND_X, BAND_Y,
    CORE_X, CORE_Y,
};
use std::collections::{BTreeMap, BTreeSet};

/// What a character could do at one tile pair of a seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Crossing {
    /// Walkable ground on both sides.
    OnFoot,
    /// Navigable water on both sides: crossable while `navigating`, and only then.
    ByBoat,
    /// The way out is solid: the core edge or the transition band cannot be entered, so
    /// nobody leaves here. A cliff or a wall, and a perfectly ordinary thing for a seam to
    /// contain — most of a coastline is impassable.
    Blocked,
    /// The way out is open and the arrival is solid. A character reaches the band, the exit
    /// fires, and they are transferred into rock. This was previously counted as `Blocked`,
    /// which is wrong in the way that matters: "you cannot go this way" and "you go this way
    /// and end up inside a wall" are not the same thing, and only one of them is a defect.
    IntoSolid,
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
        // Solid on the way out means nobody leaves, whatever is on the far side.
        if departure == Tile::Solid || band == Tile::Solid {
            return Crossing::Blocked;
        }

        // Can a walker even reach the band? Only if both tiles under them are dry.
        let on_foot = departure == Tile::Walkable && band == Tile::Walkable;
        match (arrival, on_foot) {
            (Tile::Solid, _) => Crossing::IntoSolid,
            (Tile::Walkable, true) => Crossing::OnFoot,
            (Tile::Walkable, false) => Crossing::BeachesBoat,
            (Tile::Water, true) => Crossing::StrandsWalker,
            (Tile::Water, false) => Crossing::ByBoat,
        }
    }
}

/// Who draws a tile on one layer, and whether the two maps agree about it.
///
/// An *unreviewed record*, never a decision. The compiler can see that both maps draw
/// something at a boundary tile and whether the two pictures and the two collision values
/// match; it cannot see which one should win. Choosing a ground owner decides what a player
/// may walk on, the only signal available here is art, and art has already been shown silent
/// about exactly that -- 100% continuity across a boundary that walks a character into the
/// sea. `W-0101` supplies the artist rule; this supplies the evidence for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LayerOwnership {
    /// Ground, decoration, roof-adjacent, roof.
    pub layer: usize,
    /// The departing map draws something on its band tile for this layer.
    pub band_drawn: bool,
    /// The arriving map draws something on its core edge tile for this layer.
    pub neighbour_drawn: bool,
    /// Both draw, and they name the same graphic.
    pub same_graphic: bool,
    /// The band's collision value equals the neighbour's. Where these differ, whichever the
    /// runtime believes changes whether a character can pass, which is the one thing an
    /// artist rule must not be allowed to do by accident.
    pub collision_agrees: bool,
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
    /// The arrival's global position resolves, through the region's atlas, to exactly this
    /// map and this tile. Not an inversion of the same origin that produced it — that proves
    /// arithmetic. This proves the position is unambiguous in the whole region.
    pub resolves_uniquely: bool,
    /// The band's ground art repeats the neighbour's edge art: the gutter hypothesis.
    pub band_matches_neighbour: bool,
    /// The two core edge tiles carry the same ground art, which would be duplication
    /// rather than continuity.
    pub edges_identical: bool,
    /// Per-layer ownership records for this tile pair, in layer order. Every one is
    /// unreviewed by construction.
    pub ownership: [LayerOwnership; 4],
    /// The arrival tile has no ground drawn on it at all. Walking across lands the character
    /// in a tile that is not part of the map -- and 2,444 such tiles in this corpus read as
    /// walkable, so nothing would stop them.
    pub arrival_is_void: bool,
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

        let lost = self.pairs.iter().filter(|pair| !pair.resolves_uniquely).count();
        if lost > 0 {
            defects.push(format!("{lost} arrivals do not resolve to exactly one map"));
        }

        // Being transferred into rock, where an exit actually does it.
        let walled = self
            .pairs
            .iter()
            .filter(|pair| pair.crossing == Crossing::IntoSolid && pair.exit_out)
            .count();
        if walled > 0 {
            defects.push(format!("{walled} exits transfer a character into solid ground"));
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

        // Walking into a tile the map does not draw. Counted only where an exit sends
        // somebody there, for the same reason a stranding is.
        let nowhere =
            self.pairs.iter().filter(|pair| pair.exit_out && pair.arrival_is_void).count();
        if nowhere > 0 {
            defects.push(format!("{nowhere} exits arrive on a tile with no ground"));
        }

        let one_way = self.pairs.iter().filter(|pair| pair.exit_out && !pair.exit_back).count();
        if one_way > 0 {
            defects.push(format!("{one_way} exits are not returned by the other map"));
        }

        defects
    }

    /// How much of the band's ground art repeats the neighbour's edge art, as a percentage
    /// of the pairs whose path contains no solid tile.
    ///
    /// Named for its denominator on purpose. It is not "crossable pairs": the pairs counted
    /// here include the ones that strand a walker and the ones that beach a boat, because
    /// those have continuous art too — that is exactly why art is the weakest signal
    /// available and why it was silent while a three-state field was read as two.
    ///
    /// A review signal and nothing more. `W-0097` puts thresholds at 95% automatic, 85-95%
    /// review and below that correct-or-classify, and this reports the number rather than
    /// applying them. Nothing may be activated on tile-graphic identity alone.
    pub fn gutter_continuity_over_non_solid(&self) -> Option<usize> {
        let relevant = self.pairs.iter().filter(|pair| pair.crossing != Crossing::Blocked).count();
        if relevant == 0 {
            return None;
        }
        let matching = self
            .pairs
            .iter()
            .filter(|pair| pair.crossing != Crossing::Blocked && pair.band_matches_neighbour)
            .count();
        Some(matching * 100 / relevant)
    }

    /// Every pair falls in exactly one class, and the classes sum to the pairs.
    ///
    /// Asserted rather than assumed: an accounting that does not close is how a category gets
    /// double-counted, which is precisely what turned four strandings into 897.
    pub fn accounting_closes(&self) -> bool {
        let classified = self.count(Crossing::OnFoot)
            + self.count(Crossing::ByBoat)
            + self.count(Crossing::Blocked)
            + self.count(Crossing::IntoSolid)
            + self.count(Crossing::StrandsWalker)
            + self.count(Crossing::BeachesBoat);
        classified == self.pairs.len()
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
    layer_art(map, 0)
}

fn layer_art(map: &PackedMap, layer: usize) -> BTreeMap<(u8, u8), i32> {
    map.layers[layer].iter().map(|tile| ((tile.x, tile.y), tile.grh)).collect()
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
    atlas: &Atlas,
) -> SeamEvidence {
    let from_art = ground_art(from);
    let to_art = ground_art(to);
    let to_simulated = crate::mask::simulated_tiles(to);
    let from_layers: [BTreeMap<(u8, u8), i32>; 4] =
        [layer_art(from, 0), layer_art(from, 1), layer_art(from, 2), layer_art(from, 3)];
    let to_layers: [BTreeMap<(u8, u8), i32>; 4] =
        [layer_art(to, 0), layer_art(to, 1), layer_art(to, 2), layer_art(to, 3)];
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
            // The arrival must resolve, through the whole region's atlas, to this map and no
            // other. A layout that places two maps on one cell can satisfy `one_tile` and
            // invert its own arithmetic perfectly while the position means two things.
            let resolves_uniquely = there
                .map(|there| {
                    atlas.resolve(there)
                        == Resolved::Unique { map: to.map_id, x: arrival.0, y: arrival.1 }
                })
                .unwrap_or(false);

            // The reciprocal exit leaves the *other* map's band and arrives at this map's
            // core edge, which is the same pair read from the far side.
            let (_, back_arrival, back_band_tile) = back_band[index];

            let band_tile = Tile::of(from.tile_at(band.0 as i32, band.1 as i32));
            let arrival_tile = Tile::of(to.tile_at(arrival.0 as i32, arrival.1 as i32));
            let ownership = std::array::from_fn(|layer| {
                let mine = from_layers[layer].get(&band);
                let theirs = to_layers[layer].get(&arrival);
                LayerOwnership {
                    layer,
                    band_drawn: mine.is_some(),
                    neighbour_drawn: theirs.is_some(),
                    same_graphic: mine.is_some() && mine == theirs,
                    collision_agrees: band_tile == arrival_tile,
                }
            });

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
                resolves_uniquely,
                ownership,
                arrival_is_void: !to_simulated.contains(&arrival),
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

/// What one class of the corpus's candidate seams looks like.
///
/// An observation, pinned so it cannot drift. Not a promotion: a seam with no defects is a
/// seam worth reviewing, and `W-0101` decides which are activated.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SeamSummary {
    pub seams: usize,
    /// Seams with no geometry failure, no one-way exit and no exit across a medium change.
    pub without_defects: usize,
    pub tile_pairs: usize,
    pub on_foot: usize,
    pub by_boat: usize,
    pub blocked: usize,
    pub into_solid: usize,
    pub into_solid_with_exits: usize,
    pub strands_walker: usize,
    pub beaches_boat: usize,
    /// Strandings an exit actually sends a character across.
    pub strandings_with_exits: usize,
    pub one_tile_failures: usize,
    pub resolution_failures: usize,
    pub one_way_exits: usize,
    /// Exits arriving on a tile the destination does not draw.
    pub arrivals_in_void: usize,
    /// Boundary tiles where both maps draw the same layer and the pictures differ. Not a
    /// defect: it is the artist question `W-0101` answers, counted so the size of that
    /// question is known.
    pub contested_layer_tiles: usize,
    /// Boundary tiles where the band's collision disagrees with the neighbour's. Whichever
    /// the runtime believes changes whether a character can pass.
    pub contested_collision_tiles: usize,
    /// Seams whose band art repeats the neighbour's edge for at least 95% of crossable
    /// pairs, and for at least 85%.
    pub continuous_at_95: usize,
    pub continuous_at_85: usize,
}

/// Measure every candidate seam in the world, grouped by what it joins.
///
/// Every class, not just the land: "how many defects does the world have" cannot be answered
/// from a subset, and the ocean carries most of the corpus's remaining trouble. Grouped
/// rather than totalled because a single number would hide which part of the world is at
/// fault, which is the mistake this analysis has already made twice.
pub fn summarise(
    maps: &[PackedMap],
    seams: &BTreeSet<Adjacency>,
    regions: &[crate::topology::Region],
    surfaces: &BTreeMap<u16, Surface>,
) -> (BTreeMap<ClaimClass, SeamSummary>, Vec<SeamEvidence>) {
    let by_id: BTreeMap<u16, &PackedMap> = maps.iter().map(|map| (map.map_id, map)).collect();

    // One atlas per region, not one for the world. Each region has its own coordinate space
    // starting at its own north-west corner, so a single global index would report every
    // region as overlapping every other at the origin — which is exactly what it did.
    let atlases: BTreeMap<u16, Atlas> =
        regions.iter().map(|region| (region.id, Atlas::of(region))).collect();
    let mut home: BTreeMap<u16, u16> = BTreeMap::new();
    let mut origins: BTreeMap<u16, Origin> = BTreeMap::new();
    for region in regions {
        for (map, origin) in &region.origins {
            home.insert(*map, region.id);
            origins.insert(*map, *origin);
        }
    }
    let mut by_class: BTreeMap<ClaimClass, SeamSummary> = BTreeMap::new();
    let mut all = Vec::new();

    for seam in seams {
        let class = match (surfaces.get(&seam.from_map), surfaces.get(&seam.to_map)) {
            (Some(Surface::Land), Some(Surface::Land)) => ClaimClass::LandLand,
            (Some(Surface::Sea), Some(Surface::Sea)) => ClaimClass::SeaSea,
            (Some(_), Some(_)) => ClaimClass::LandSea,
            _ => continue,
        };
        let summary = by_class.entry(class).or_default();

        let (Some(from), Some(to)) = (by_id.get(&seam.from_map), by_id.get(&seam.to_map)) else {
            continue;
        };
        let (Some(origin), Some(neighbour)) =
            (origins.get(&seam.from_map), origins.get(&seam.to_map))
        else {
            continue;
        };
        // Both ends are in the same region by construction: regions *are* the components of
        // this seam graph. Anything else is a bug worth skipping loudly rather than averaging.
        let (Some(region), Some(other)) = (home.get(&seam.from_map), home.get(&seam.to_map)) else {
            continue;
        };
        if region != other {
            continue;
        }
        let Some(atlas) = atlases.get(region) else { continue };

        let found = evidence(from, to, seam.side, *origin, *neighbour, atlas);
        summary.seams += 1;
        summary.tile_pairs += found.pairs.len();
        summary.on_foot += found.count(Crossing::OnFoot);
        summary.by_boat += found.count(Crossing::ByBoat);
        summary.blocked += found.count(Crossing::Blocked);
        summary.into_solid += found.count(Crossing::IntoSolid);
        summary.into_solid_with_exits += found
            .pairs
            .iter()
            .filter(|pair| pair.crossing == Crossing::IntoSolid && pair.exit_out)
            .count();
        summary.strands_walker += found.count(Crossing::StrandsWalker);
        summary.beaches_boat += found.count(Crossing::BeachesBoat);
        summary.strandings_with_exits += found
            .pairs
            .iter()
            .filter(|pair| pair.crossing == Crossing::StrandsWalker && pair.exit_out)
            .count();
        summary.one_tile_failures += found.pairs.iter().filter(|pair| !pair.one_tile).count();
        summary.resolution_failures +=
            found.pairs.iter().filter(|pair| !pair.resolves_uniquely).count();
        summary.one_way_exits +=
            found.pairs.iter().filter(|pair| pair.exit_out && !pair.exit_back).count();
        summary.arrivals_in_void +=
            found.pairs.iter().filter(|pair| pair.exit_out && pair.arrival_is_void).count();
        summary.contested_layer_tiles += found
            .pairs
            .iter()
            .filter(|pair| {
                pair.ownership
                    .iter()
                    .any(|owner| owner.band_drawn && owner.neighbour_drawn && !owner.same_graphic)
            })
            .count();
        summary.contested_collision_tiles +=
            found.pairs.iter().filter(|pair| !pair.ownership[0].collision_agrees).count();
        if found.defects().is_empty() {
            summary.without_defects += 1;
        }
        match found.gutter_continuity_over_non_solid() {
            Some(percent) if percent >= 95 => {
                summary.continuous_at_95 += 1;
                summary.continuous_at_85 += 1;
            }
            Some(percent) if percent >= 85 => summary.continuous_at_85 += 1,
            _ => {}
        }

        all.push(found);
    }

    (by_class, all)
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

    /// An atlas over exactly the maps a test places, so unique resolution is checked against
    /// a real layout rather than against the origin that produced the position.
    fn atlas_of(origins: &[(u16, Origin)]) -> Atlas {
        Atlas::new(&origins.iter().copied().collect(), crate::topology::Geometry::Plane)
    }

    fn side_by_side() -> Atlas {
        atlas_of(&[(1, Origin { x: 0, y: 0 }), (2, Origin { x: PITCH_X, y: 0 })])
    }

    #[test]
    fn a_clean_east_seam_is_one_tile_wide_everywhere() {
        let west = blank(1);
        let east = blank(2);
        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &atlas_of(&[(1, Origin { x: 0, y: 0 }), (2, Origin { x: PITCH_X, y: 0 })]),
        );

        assert_eq!(found.pairs.len(), 80, "one pair per core row");
        assert!(found.pairs.iter().all(|pair| pair.one_tile));
        assert!(found.pairs.iter().all(|pair| pair.resolves_uniquely));
        assert!(found.accounting_closes());
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
            &atlas_of(&[
                (west.map_id, Origin { x: 0, y: 0 }),
                (east.map_id, Origin { x: STORAGE as i64, y: 0 }),
            ]),
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

        let found = evidence(
            &land,
            &sea,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &side_by_side(),
        );

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

        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &atlas_of(&[(1, Origin { x: 0, y: 0 }), (2, Origin { x: PITCH_X, y: 0 })]),
        );
        assert_eq!(found.count(Crossing::ByBoat), 80);
        assert_eq!(found.count(Crossing::StrandsWalker), 0);
        assert_eq!(found.count(Crossing::BeachesBoat), 0);
        assert_eq!(found.defects(), Vec::<String>::new());
    }

    #[test]
    fn a_solid_way_out_is_blocked_and_a_solid_arrival_is_not_the_same_thing() {
        // The distinction this test exists for. Solid on the way out means nobody leaves,
        // which is most of a coastline and no defect at all. Solid on *arrival*, reached
        // through an open band, means the exit transfers a character into rock.
        let mut open = blank(1);
        let mut wall = blank(2);
        for y in CORE_Y.0..=CORE_Y.1 {
            set_tile(&mut wall, CORE_X.0, y, 1);
        }
        open.exits.push(MapExit {
            x: BAND_X.1,
            y: 50,
            target_map: 2,
            target_x: CORE_X.0,
            target_y: 50,
        });

        let into_wall = evidence(
            &open,
            &wall,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &side_by_side(),
        );
        assert_eq!(into_wall.count(Crossing::IntoSolid), 80);
        assert_eq!(into_wall.count(Crossing::Blocked), 0);
        assert!(into_wall.accounting_closes());
        assert!(into_wall.defects().iter().any(|note| note.contains("into solid ground")));

        let mut west = blank(1);
        let east = blank(2);
        for y in CORE_Y.0..=CORE_Y.1 {
            set_tile(&mut west, CORE_X.1, y, 1);
        }

        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &atlas_of(&[(1, Origin { x: 0, y: 0 }), (2, Origin { x: PITCH_X, y: 0 })]),
        );
        assert_eq!(found.count(Crossing::Blocked), 80);
        assert_eq!(found.passable(), 0);
        assert_eq!(found.defects(), Vec::<String>::new(), "a cliff is not a defect");
        assert_eq!(found.gutter_continuity_over_non_solid(), None, "nothing crossable to judge");
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

        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &atlas_of(&[(1, Origin { x: 0, y: 0 }), (2, Origin { x: PITCH_X, y: 0 })]),
        );
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
    fn ownership_is_recorded_per_layer_and_never_decided() {
        // Both maps draw the same boundary tile with different roofs, and their collision
        // disagrees. The record says so on both counts and names no owner, because choosing
        // one decides what a player may walk on and the only evidence here is a picture.
        let mut west = blank(1);
        let mut east = blank(2);
        west.layers[0].push(LayerTile { x: BAND_X.1, y: 50, grh: 100 });
        east.layers[0].push(LayerTile { x: CORE_X.0, y: 50, grh: 100 });
        west.layers[3].push(LayerTile { x: BAND_X.1, y: 50, grh: 700 });
        east.layers[3].push(LayerTile { x: CORE_X.0, y: 50, grh: 800 });
        set_tile(&mut east, CORE_X.0, 50, 2);

        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &side_by_side(),
        );
        let pair = found.pairs.iter().find(|pair| pair.departure.1 == 50).expect("row 50");

        // Ground: both draw, same graphic, and the collision differs -- walkable band, water
        // arrival -- which is the case an artist rule must not be allowed to paper over.
        assert!(pair.ownership[0].band_drawn && pair.ownership[0].neighbour_drawn);
        assert!(pair.ownership[0].same_graphic);
        assert!(!pair.ownership[0].collision_agrees);

        // Roof: both draw and the pictures differ. A question for W-0101, not a defect.
        assert!(pair.ownership[3].band_drawn && pair.ownership[3].neighbour_drawn);
        assert!(!pair.ownership[3].same_graphic);

        // Layers nobody draws are recorded as such rather than as agreement.
        assert!(!pair.ownership[1].band_drawn && !pair.ownership[1].neighbour_drawn);
        assert!(!pair.ownership[1].same_graphic);

        // And no defect is raised for any of it: contested art is a decision, not a fault.
        assert!(!found.defects().iter().any(|note| note.contains("owner")));
    }

    #[test]
    fn an_arrival_two_maps_claim_does_not_resolve_even_though_it_round_trips() {
        // The gap the old check could not see. Inverting `to_global` with the same origin it
        // used proves arithmetic; it says nothing about whether the position means one place.
        // Here maps 2 and 3 are placed on the same cell, so every conversion inverts
        // perfectly and the arrival is still ambiguous.
        let west = blank(1);
        let east = blank(2);
        let overlapping = atlas_of(&[
            (1, Origin { x: 0, y: 0 }),
            (2, Origin { x: PITCH_X, y: 0 }),
            (3, Origin { x: PITCH_X, y: 0 }),
        ]);

        let found = evidence(
            &west,
            &east,
            Side::East,
            Origin { x: 0, y: 0 },
            Origin { x: PITCH_X, y: 0 },
            &overlapping,
        );

        assert!(found.pairs.iter().all(|pair| pair.one_tile), "the arithmetic is fine");
        assert!(
            found.pairs.iter().all(|pair| !pair.resolves_uniquely),
            "and the position still means two places"
        );
        assert!(found.defects().iter().any(|note| note.contains("exactly one map")));
        assert_eq!(overlapping.ambiguous_cells(), 1);

        // Local inversion, by contrast, is perfectly happy.
        let arrival = to_global(Origin { x: PITCH_X, y: 0 }, CORE_X.0, 50).unwrap();
        assert_eq!(to_local(Origin { x: PITCH_X, y: 0 }, arrival), Some((CORE_X.0, 50)));
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
