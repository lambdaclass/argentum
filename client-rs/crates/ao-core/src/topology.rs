//! What the world's 842 maps actually say about how they join up.
//!
//! The seamless world needs one global coordinate space, and the only evidence for where
//! each map sits in it is the exits the maps themselves carry: 158,549 of them, written by
//! hand over twenty years, in a format that cannot express "these two maps are adjacent" —
//! only "stepping here puts you there".
//!
//! This module reads that evidence and says what it implies, without deciding anything. It
//! is deliberately the boring half of `W-0097`: classification, counting and contradiction
//! finding, with no geography chosen and no manifest emitted. Everything here is a pure
//! function over decoded maps so the numbers can be recomputed and diffed, which is the
//! whole point — the counts in the roadmap are a *reviewed baseline*, and the build fails
//! on unexplained drift rather than treating them as eternal.
//!
//! ## What a standard seam looks like
//!
//! Maps are stored 100×100 and simulated on a smaller core, so walking off one map arrives
//! near the opposite edge of the next. An exit at the west band lands at the east band of
//! the map to the west, at the same row. Those offsets are what make a seam *geographic*:
//! the two maps can be placed side by side and one step across the boundary advances
//! exactly one global tile. An exit that does not follow them may still be legitimate — a
//! door, a portal, a teleport — but it is not evidence of adjacency, and treating it as
//! such is how a compiler invents geography that does not exist.

use crate::mappack::{MapExit, PackedMap, Tile};
use std::collections::{BTreeMap, BTreeSet};

/// Storage size of every map in this corpus.
pub const STORAGE: u8 = 100;

/// The provisional simulation core, as audited: `x = 14..=87`, `y = 11..=90`.
///
/// Provisional because it is derived from where exits actually sit rather than from any
/// statement in the data. It is written down so a change to it is a visible decision.
pub const CORE_X: (u8, u8) = (14, 87);
pub const CORE_Y: (u8, u8) = (11, 90);

/// The transition bands: the columns and rows an exit sits in when it is a seam.
pub const BAND_X: (u8, u8) = (13, 88);
pub const BAND_Y: (u8, u8) = (10, 91);

/// How far apart two adjacent maps sit in the global grid, in tiles.
///
/// The *core* size, not the storage size, and the corpus is what says so. Measured across
/// all 157,304 valid cross-map exits: 41,186 go from `x = 13` to `x = 87`, 40,877 from
/// `x = 88` to `x = 14`, 37,055 from `y = 10` to `y = 90` and 36,966 from `y = 91` to
/// `y = 11` — 156,084 together, which is exactly the audited count of standard seams.
///
/// Read as geometry: stepping off my core's west edge (`x = 14`) into the band (`x = 13`)
/// arrives at my neighbour's core *east* edge (`x = 87`). For that to be one tile of
/// movement, the neighbour's origin must be one core width to the west — 74, not 100. A
/// layout on 100-tile centres would leave a 26-tile hole at every seam, invisible in any
/// test that only checks which map you land on.
pub const PITCH_X: i64 = (CORE_X.1 - CORE_X.0 + 1) as i64;
pub const PITCH_Y: i64 = (CORE_Y.1 - CORE_Y.0 + 1) as i64;

/// Which side of a map a seam exit sits on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Side {
    West,
    East,
    North,
    South,
}

impl Side {
    /// The side an arriving traveller comes in on.
    pub fn opposite(self) -> Side {
        match self {
            Side::West => Side::East,
            Side::East => Side::West,
            Side::North => Side::South,
            Side::South => Side::North,
        }
    }

    /// The step this side implies in map coordinates: west is one map left, and so on.
    pub fn step(self) -> (i32, i32) {
        match self {
            Side::West => (-1, 0),
            Side::East => (1, 0),
            Side::North => (0, -1),
            Side::South => (0, 1),
        }
    }
}

/// Every side whose band contains this tile.
///
/// Usually one. A corner tile is in two bands, and which adjacency it describes is then
/// decided by where the exit *arrives* rather than by where it sits — four of the corpus's
/// seams are corner tiles, and excluding them outright loses four real adjacencies.
pub fn sides_of(x: u8, y: u8) -> Vec<Side> {
    let mut sides = Vec::new();
    if x == BAND_X.0 {
        sides.push(Side::West);
    }
    if x == BAND_X.1 {
        sides.push(Side::East);
    }
    if y == BAND_Y.0 {
        sides.push(Side::North);
    }
    if y == BAND_Y.1 {
        sides.push(Side::South);
    }
    sides
}

/// Whether an exit's arrival matches what `side` would require of a seam.
fn arrives_as_seam(exit: &MapExit, side: Side) -> bool {
    match side {
        Side::West => exit.target_x == CORE_X.1 && exit.target_y == exit.y,
        Side::East => exit.target_x == CORE_X.0 && exit.target_y == exit.y,
        Side::North => exit.target_y == CORE_Y.1 && exit.target_x == exit.x,
        Side::South => exit.target_y == CORE_Y.0 && exit.target_x == exit.x,
    }
}

/// What one exit is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExitKind {
    /// A seam: it leaves a transition band and arrives at the opposite band of the
    /// neighbour, on the same row or column. Evidence of adjacency.
    StandardSeam { side: Side },
    /// Valid, and not a seam. A door, a portal, a teleport — something that connects two
    /// places without claiming they touch.
    NonGeographic,
    /// Its destination is not a map in this corpus.
    MissingDestination,
    /// It leads back to the map it starts on.
    SameMap,
}

/// One exit, with what it turned out to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classified {
    pub from_map: u16,
    pub exit: MapExit,
    pub kind: ExitKind,
}

/// Classify one exit.
///
/// `known` is the set of map ids in the corpus, because "the destination does not exist" is
/// only answerable against the whole corpus and is the single most common defect in this
/// data — 1,196 of them.
pub fn classify(from_map: u16, exit: &MapExit, known: &BTreeSet<u16>) -> ExitKind {
    if exit.target_map == from_map {
        return ExitKind::SameMap;
    }
    if !known.contains(&exit.target_map) {
        return ExitKind::MissingDestination;
    }

    // The arrival has to be the opposite *core* edge, on the same line. Not the opposite
    // band: you step into your own band and arrive on your neighbour's last simulated
    // tile. An exit that lands anywhere else is not describing two maps that touch,
    // whatever else it may be — and reading the offsets as band-to-band, which is the
    // obvious guess, classifies every one of the corpus's 156,084 seams as something else.
    //
    // A corner tile is in two bands, so it is asked about both and accepted only if
    // exactly one answers. Two matching sides would be two different adjacencies from one
    // exit, which is the ambiguity this refuses to resolve by picking.
    let matching: Vec<Side> =
        sides_of(exit.x, exit.y).into_iter().filter(|side| arrives_as_seam(exit, *side)).collect();

    match matching.as_slice() {
        [side] => ExitKind::StandardSeam { side: *side },
        _ => ExitKind::NonGeographic,
    }
}

/// The *shape* of a transition, measured from its coordinates alone.
///
/// `W-0097` asks for every transition classified as `geographic_seam`, `door`, `portal`,
/// `teleport` or `instance_entrance`. Those last four are not measurable: nothing in a map
/// file distinguishes a doorway from a portal, and a compiler that assigned them would be
/// inventing content. What *is* measurable is the geometry, and the two must not be confused
/// — so this reports shape and `manifest::Disposition` records what a person decided.
///
/// The shapes are chosen to separate "nearly a seam" from "not a seam at all", because those
/// need different reviews. An `OffsetSeam` leaves a band and arrives on the correct opposite
/// core edge but on the wrong line: that is a seam somebody mis-typed, and it is a candidate
/// for corrected data. An `Interior` arrival is a door or a teleport and no amount of
/// correction turns it into adjacency.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Shape {
    /// Band to the opposite core edge, same line. Evidence of adjacency.
    StandardSeam {
        side: Side,
    },
    /// Band to the opposite core edge, wrong line. Seam-shaped and displaced.
    OffsetSeam {
        side: Side,
        drift: i32,
    },
    /// Arrives in the destination's transition band, which is not a place to stand.
    IntoBand,
    /// Leaves from a band tile but arrives somewhere inside the destination.
    BandToInterior,
    /// Leaves from inside the map: a door, a portal or a teleport, and the data cannot say
    /// which.
    Interior,
    SameMap,
    MissingDestination,
}

/// Which band lines a coordinate sits on, if any.
fn in_band(x: u8, y: u8) -> bool {
    x == BAND_X.0 || x == BAND_X.1 || y == BAND_Y.0 || y == BAND_Y.1
}

/// The shape of one exit.
///
/// Measured, never guessed. Where an exit is seam-shaped but displaced, the drift is reported
/// so a reviewer can see whether it is off by one row or by forty.
pub fn shape_of(from_map: u16, exit: &MapExit, known: &BTreeSet<u16>) -> Shape {
    if exit.target_map == from_map {
        return Shape::SameMap;
    }
    if !known.contains(&exit.target_map) {
        return Shape::MissingDestination;
    }

    let sides = sides_of(exit.x, exit.y);
    if sides.is_empty() {
        return Shape::Interior;
    }

    if let [side] = sides_of(exit.x, exit.y)
        .into_iter()
        .filter(|side| arrives_as_seam(exit, *side))
        .collect::<Vec<_>>()
        .as_slice()
    {
        return Shape::StandardSeam { side: *side };
    }

    if in_band(exit.target_x, exit.target_y) {
        return Shape::IntoBand;
    }

    // Seam-shaped and displaced: the arrival is on the correct opposite core edge for one of
    // the sides this tile belongs to, but on a different line.
    for side in &sides {
        let (arrives_on_edge, drift) = match side {
            Side::West => (exit.target_x == CORE_X.1, exit.target_y as i32 - exit.y as i32),
            Side::East => (exit.target_x == CORE_X.0, exit.target_y as i32 - exit.y as i32),
            Side::North => (exit.target_y == CORE_Y.1, exit.target_x as i32 - exit.x as i32),
            Side::South => (exit.target_y == CORE_Y.0, exit.target_x as i32 - exit.x as i32),
        };
        if arrives_on_edge && drift != 0 {
            return Shape::OffsetSeam { side: *side, drift };
        }
    }

    Shape::BandToInterior
}

/// A claimed adjacency: this map has that map on this side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Adjacency {
    pub from_map: u16,
    pub side: Side,
    pub to_map: u16,
}

/// Everything the corpus says, counted.
///
/// The fields are the numbers the roadmap pins as a reviewed baseline. Recomputed on every
/// run so drift is a failure rather than a discovery.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Baseline {
    pub maps: usize,
    pub exits: usize,
    pub valid_cross_map: usize,
    pub standard_seams: usize,
    pub other_valid: usize,
    pub same_map: usize,
    pub missing_destination: usize,

    /// Directed placements where the other map agrees: A says B is east *and* B says A is
    /// west. Counted per relationship, so a pair that claims two different relative
    /// placements contributes two.
    ///
    /// Named at this length on purpose. Called `reciprocal_pairs`, it was read as a count
    /// of map pairs and it is not: four pairs in this corpus claim two opposite placements
    /// each, so 1,102 relationships are 1,098 pairs.
    pub reciprocal_placements: usize,
    /// Distinct unordered map pairs that have at least one reciprocal placement.
    pub reciprocal_pairs: usize,
    /// Directed placements the other map does not return.
    pub one_sided_placements: usize,
    /// One map claiming two different neighbours on the same side — a contradiction in the
    /// *claims*, before any layout is attempted.
    pub contested_sides: usize,

    /// Groups joined by any geographic claim, reciprocal or not.
    pub weak_components: usize,
    /// Groups joined only by placements both maps agree on. Larger, because dropping
    /// one-sided claims splits groups that were held together by them.
    pub reciprocal_components: usize,
    /// Components whose constraints cannot all hold at once: the corpus is not a plane
    /// there. A property of the component, not of any traversal order.
    pub inconsistent_components: usize,
    /// Loops whose offsets do not close. Stable: a loop that fails to close is a fact
    /// about the world, unlike the count of constraints an algorithm blames for it.
    pub cycle_witnesses: usize,
    /// Groups of maps tied together by those loops. One disposition each.
    pub conflict_clusters: usize,
    /// Maps inside an inconsistent component. Larger than the maps actually implicated in
    /// a contradiction: a component cannot be laid out until its contradictions have a
    /// disposition, whether or not a given map is named in one.
    pub inconsistent_maps: usize,
    /// Squares of four maps with all four internal seams reciprocal and no contradiction
    /// anywhere in their component. What the seamless-world MVP can be built on today.
    pub conflict_free_quads: usize,
    /// Coordinate spaces over every standard seam, shore-to-sea claims included. Every map
    /// belongs to exactly one, including the maps with no seams at all.
    pub regions: usize,
    /// Regions whose own claims say they wrap: a cylinder or a torus rather than a plane.
    pub wrapping_regions: usize,
    /// Claims that cannot hold even in their region's measured geometry. Each needs a
    /// reviewed disposition; none may be dropped to make the arithmetic close.
    pub unresolved_seams: usize,
    /// Maps that are at least half navigable water.
    pub sea_maps: usize,
    /// Regions no seam reaches: reached by door, portal or teleport only.
    pub discrete_regions: usize,
    /// The same measurement taken of each class of claim alone, because an aggregate cannot
    /// tell "the land is a plane" from "the ocean is a plane" from "the shore joins them".
    pub land_land_unresolved: usize,
    pub sea_sea_unresolved: usize,
    pub land_sea_unresolved: usize,
    /// Seam evidence, from `crate::seam`, per class of claim.
    ///
    /// Observations about what a character could do at every candidate boundary in the
    /// world — pinned so they cannot drift, and pinned *only* as observations. A seam with
    /// no defects is a seam worth reviewing; promoting it to geography is a decision, and a
    /// baseline must never make that decision by having recorded a number.
    ///
    /// Kept per class rather than totalled. "How many defects does the world have" is not
    /// answerable from one number: the land and the ocean are in very different states, and
    /// a total would have hidden that twice already.
    /// Tile masks: which core tiles are really part of the world.
    pub mask: crate::mask::Mask,
    pub maps_fully_drawn: usize,
    /// Maps where the bounding rectangle makes a void tile look walkable.
    pub maps_with_lying_rectangle: usize,
    /// Exits arriving on a tile the destination map does not draw.
    pub arrivals_in_void: usize,
    /// Every exit by measured shape. The four content classes `W-0097` names -- door,
    /// portal, teleport, instance entrance -- are deliberately absent: nothing in a map file
    /// distinguishes them, and a compiler that assigned them would be inventing content.
    pub offset_seams: usize,
    pub into_band: usize,
    pub band_to_interior: usize,
    pub interior: usize,
    pub land_seams: SeamCounts,
    pub shore_seams: SeamCounts,
    pub sea_seams: SeamCounts,
}

/// What a class of seams looks like, tile pair by tile pair.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SeamCounts {
    pub seams: usize,
    /// No geometry failure, no one-way exit, and no exit that strands a walker.
    pub without_defects: usize,
    pub tile_pairs: usize,
    pub crossable_on_foot: usize,
    pub crossable_by_boat: usize,
    pub blocked: usize,
    /// Boundaries where the way out is open and the arrival is solid, and the subset an exit
    /// actually transfers somebody across. Previously counted as `blocked`, which conflated
    /// "you cannot go this way" with "you go this way and end up inside a wall".
    pub into_solid: usize,
    pub into_solid_with_exits: usize,
    /// Exits that leave a walker standing on water. The server transfers on the exit's
    /// destination without checking the arrival tile or whether the character is navigating,
    /// so each one strands somebody.
    pub strandings_with_exits: usize,
    /// Boundaries where a sailor's path arrives on dry land. Permitted today, because the
    /// server's only navigation rule blocks water without a boat and nothing else.
    pub beaches_boat: usize,
    pub one_tile_failures: usize,
    pub resolution_failures: usize,
    pub one_way_exits: usize,
    /// Seams whose band art repeats the neighbour's edge for at least 95% of crossable
    /// pairs: the gutter hypothesis, measured.
    pub ground_continuity_95: usize,
}

/// The corpus this baseline was measured against.
///
/// Part of the baseline because the numbers are meaningless without it: a different pack is
/// a different world, and a drift check that ignored which corpus it read would report the
/// world as broken every time the data was regenerated.
pub const CORPUS: &str = "17afc00c9c7e0b4c";

/// What this corpus contains, measured and pinned.
///
/// Seven counts reproduce the audit recorded in the roadmap exactly — 842 maps, 158,549
/// exits, 157,304 valid cross-map, 156,084 standard seams, 1,220 other valid, 49 same-map
/// and 1,196 missing destinations — which is the evidence that the seam rule here is the
/// rule the audit used.
///
/// The rest were renamed rather than reconciled, because the old names were the problem.
/// `reciprocal_pairs` counted *relationships* and was read as *pairs*, and the two differ:
/// four pairs in this corpus claim two opposite placements each — 37 with 168, 37 with 264,
/// 167 with 168, 167 with 264 — so 1,102 relationships are 1,098 pairs. "Components" was
/// ambiguous in the same way: 226 counting every geographic claim, 232 counting only
/// placements both maps return.
///
/// The old `placement_conflicts` figure is gone entirely rather than corrected. It was a
/// depth-first traversal's report, and moving the root of the 424-map component moved it
/// from 48 conflicting targets to 161. A number that depends on where the walk started is
/// a fact about the walk. What replaces it is a constraint model: every contradiction is a
/// signed relationship that disagrees with the offsets already established for its pair,
/// found in sorted order and therefore the same every time.
///
/// `cycle_witnesses` moved from 50 to 56 when the spanning forest stopped keying tree edges
/// by map *pair*. Two maps can be joined by two contradictory claims — 37 says 168 is to its
/// West and also to its East — and the second was being mistaken for the tree edge and
/// skipped, so a contradiction with no third map in it produced no witness. 56 is also the
/// figure the original audit recorded, which is corroboration rather than coincidence.
///
/// The region counts describe what the corpus *is*, as opposed to what a plane would force
/// on it, and they are measured over every standard seam including shore-to-sea claims. The
/// three per-class numbers are the ones that matter, because an aggregate cannot say which
/// part of the world disagrees: **the 931 land-land claims are entirely consistent, the 439
/// shore claims have one exception, and all 34 remaining contradictions are sea-to-sea.**
/// Sailing is movement through the world — `Arena.Map.Movement` crosses a water tile when
/// the character is `navigating` — so a shore seam is geography and the ocean is where the
/// curation is owed. Combined, those 34 propagate to 99 unresolved claims in the single
/// 424-map region, which is why the per-class split is pinned beside the total.
///
/// The roadmap's original 1,091 / 58 / 237 are superseded by these, dated in both
/// roadmaps. Reproduce them all with `ao-topology --check`.
pub const BASELINE: Baseline = Baseline {
    maps: 842,
    exits: 158_549,
    valid_cross_map: 157_304,
    standard_seams: 156_084,
    other_valid: 1_220,
    same_map: 49,
    missing_destination: 1_196,
    reciprocal_placements: 1_102,
    reciprocal_pairs: 1_098,
    one_sided_placements: 15,
    contested_sides: 0,
    weak_components: 226,
    reciprocal_components: 232,
    inconsistent_components: 2,
    cycle_witnesses: 56,
    conflict_clusters: 2,
    inconsistent_maps: 428,
    conflict_free_quads: 87,
    regions: 226,
    wrapping_regions: 1,
    unresolved_seams: 99,
    sea_maps: 287,
    discrete_regions: 199,
    land_land_unresolved: 0,
    sea_sea_unresolved: 34,
    land_sea_unresolved: 1,
    mask: crate::mask::Mask {
        simulated: 4_840_960,
        void: 143_680,
        void_walkable: 2_444,
        void_solid: 141_236,
        void_water: 0,
    },
    maps_fully_drawn: 748,
    maps_with_lying_rectangle: 47,
    arrivals_in_void: 48,
    offset_seams: 0,
    into_band: 0,
    band_to_interior: 19,
    interior: 1_201,
    land_seams: SeamCounts {
        seams: 931,
        without_defects: 610,
        tile_pairs: 71528,
        crossable_on_foot: 41560,
        crossable_by_boat: 12176,
        blocked: 17229,
        into_solid: 107,
        into_solid_with_exits: 107,
        strandings_with_exits: 4,
        beaches_boat: 452,
        one_tile_failures: 912,
        resolution_failures: 542,
        one_way_exits: 2412,
        ground_continuity_95: 898,
    },
    shore_seams: SeamCounts {
        seams: 439,
        without_defects: 352,
        tile_pairs: 33908,
        crossable_on_foot: 2891,
        crossable_by_boat: 28764,
        blocked: 1782,
        into_solid: 62,
        into_solid_with_exits: 62,
        strandings_with_exits: 0,
        beaches_boat: 409,
        one_tile_failures: 1454,
        resolution_failures: 2636,
        one_way_exits: 713,
        ground_continuity_95: 421,
    },
    sea_seams: SeamCounts {
        seams: 849,
        without_defects: 668,
        tile_pairs: 65400,
        crossable_on_foot: 148,
        crossable_by_boat: 65201,
        blocked: 47,
        into_solid: 0,
        into_solid_with_exits: 0,
        strandings_with_exits: 0,
        beaches_boat: 4,
        one_tile_failures: 6008,
        resolution_failures: 10004,
        one_way_exits: 397,
        ground_continuity_95: 711,
    },
};

/// How `found` differs from `expected`, field by field, or nothing if it does not.
///
/// Returned as text because the caller is a build step and its output is read by a person
/// deciding whether a change to the world data was intended.
pub fn drift(expected: &Baseline, found: &Baseline) -> Vec<String> {
    let mut lines = Vec::new();
    let mut note = |name: &str, want: usize, got: usize| {
        if want != got {
            lines.push(format!("{name}: expected {want}, found {got}"));
        }
    };

    note("maps", expected.maps, found.maps);
    note("exits", expected.exits, found.exits);
    note("valid cross-map", expected.valid_cross_map, found.valid_cross_map);
    note("standard seams", expected.standard_seams, found.standard_seams);
    note("other valid", expected.other_valid, found.other_valid);
    note("same-map", expected.same_map, found.same_map);
    note("missing destination", expected.missing_destination, found.missing_destination);
    note("reciprocal placements", expected.reciprocal_placements, found.reciprocal_placements);
    note("reciprocal pairs", expected.reciprocal_pairs, found.reciprocal_pairs);
    note("one-sided placements", expected.one_sided_placements, found.one_sided_placements);
    note("contested sides", expected.contested_sides, found.contested_sides);
    note("weak components", expected.weak_components, found.weak_components);
    note("reciprocal-only components", expected.reciprocal_components, found.reciprocal_components);
    note(
        "inconsistent components",
        expected.inconsistent_components,
        found.inconsistent_components,
    );
    note("cycle witnesses", expected.cycle_witnesses, found.cycle_witnesses);
    note("conflict clusters", expected.conflict_clusters, found.conflict_clusters);
    note("inconsistent maps", expected.inconsistent_maps, found.inconsistent_maps);
    note("conflict-free quads", expected.conflict_free_quads, found.conflict_free_quads);
    note("regions", expected.regions, found.regions);
    note("wrapping regions", expected.wrapping_regions, found.wrapping_regions);
    note("unresolved seams", expected.unresolved_seams, found.unresolved_seams);
    note("sea maps", expected.sea_maps, found.sea_maps);
    note("discrete regions", expected.discrete_regions, found.discrete_regions);
    note("land-land unresolved", expected.land_land_unresolved, found.land_land_unresolved);
    note("sea-sea unresolved", expected.sea_sea_unresolved, found.sea_sea_unresolved);
    note("land-sea unresolved", expected.land_sea_unresolved, found.land_sea_unresolved);
    note("simulated core tiles", expected.mask.simulated, found.mask.simulated);
    note("void core tiles", expected.mask.void, found.mask.void);
    note("void tiles reading as walkable", expected.mask.void_walkable, found.mask.void_walkable);
    note("void tiles already blocked", expected.mask.void_solid, found.mask.void_solid);
    note("void tiles marked water", expected.mask.void_water, found.mask.void_water);
    note("maps fully drawn", expected.maps_fully_drawn, found.maps_fully_drawn);
    note(
        "maps whose rectangle lies",
        expected.maps_with_lying_rectangle,
        found.maps_with_lying_rectangle,
    );
    note("exits arriving on no ground", expected.arrivals_in_void, found.arrivals_in_void);
    note("offset seams", expected.offset_seams, found.offset_seams);
    note("exits into a band", expected.into_band, found.into_band);
    note("band-to-interior exits", expected.band_to_interior, found.band_to_interior);
    note("interior exits", expected.interior, found.interior);

    for (label, want, got) in [
        ("land", &expected.land_seams, &found.land_seams),
        ("shore", &expected.shore_seams, &found.shore_seams),
        ("sea", &expected.sea_seams, &found.sea_seams),
    ] {
        note(&format!("{label} seams"), want.seams, got.seams);
        note(&format!("{label} seams without defects"), want.without_defects, got.without_defects);
        note(&format!("{label} tile pairs"), want.tile_pairs, got.tile_pairs);
        note(&format!("{label} crossable on foot"), want.crossable_on_foot, got.crossable_on_foot);
        note(&format!("{label} crossable by boat"), want.crossable_by_boat, got.crossable_by_boat);
        note(&format!("{label} blocked"), want.blocked, got.blocked);
        note(&format!("{label} arriving in solid"), want.into_solid, got.into_solid);
        note(
            &format!("{label} exits into solid"),
            want.into_solid_with_exits,
            got.into_solid_with_exits,
        );
        note(
            &format!("{label} exits stranding a walker"),
            want.strandings_with_exits,
            got.strandings_with_exits,
        );
        note(&format!("{label} boundaries beaching a boat"), want.beaches_boat, got.beaches_boat);
        note(&format!("{label} one-tile failures"), want.one_tile_failures, got.one_tile_failures);
        note(
            &format!("{label} ambiguous arrivals"),
            want.resolution_failures,
            got.resolution_failures,
        );
        note(&format!("{label} one-way exits"), want.one_way_exits, got.one_way_exits);
        note(
            &format!("{label} seams with 95% ground continuity"),
            want.ground_continuity_95,
            got.ground_continuity_95,
        );
    }

    // Self-consistency, independent of what was pinned: every exit has exactly one shape,
    // so the shapes must account for all of them. A category that double-counts or drops
    // exits is how 897 strandings happened, and this is the cheapest possible guard.
    let accounted = found.standard_seams
        + found.same_map
        + found.missing_destination
        + found.offset_seams
        + found.into_band
        + found.band_to_interior
        + found.interior;
    if accounted != found.exits {
        lines.push(format!(
            "exit shapes account for {accounted} of {} exits; every exit has exactly one shape",
            found.exits
        ));
    }

    lines
}

/// A map claiming two different neighbours on one side.
///
/// Not resolved here. Each one needs a reviewed disposition — corrected data, a
/// non-geographic transition, or geography this compiler will not support — and choosing
/// silently is the failure mode this type exists to prevent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlacementConflict {
    pub map: u16,
    pub side: Side,
    pub claims: Vec<u16>,
}

/// What the corpus implies, with nothing decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Evidence {
    pub baseline: Baseline,
    pub adjacencies: BTreeSet<Adjacency>,
    pub conflicts: Vec<PlacementConflict>,
    /// Every contradiction, as a constraint that disagrees with the offsets already
    /// established for the same pair. Deterministic, though *which* constraint of a loop
    /// is blamed is a property of this algorithm rather than of the corpus.
    pub constraint_conflicts: BTreeSet<ConstraintConflict>,
    /// Loops that do not close, and the clusters they form: the review unit.
    pub witnesses: Vec<CycleWitness>,
    /// Maps in components that cannot be laid out. A component with none of these can be
    /// promoted to geography; one with any cannot, until the conflict has a disposition.
    pub inconsistent: BTreeSet<u16>,
    /// The coordinate spaces the corpus actually describes, each with its measured shape.
    ///
    /// Not the same partition as `inconsistent`, and that is the point: the maps a planar
    /// model calls inconsistent include a dungeon that simply wraps and a continent joined
    /// to the open sea, both of which are consistent once the world is allowed the shape it
    /// has.
    pub regions: Vec<Region>,
}

/// Read the corpus.
pub fn evidence(maps: &[PackedMap]) -> Evidence {
    let known: BTreeSet<u16> = maps.iter().map(|map| map.map_id).collect();
    let mut baseline = Baseline { maps: maps.len(), ..Baseline::default() };

    // Every side of every map, with the neighbours claimed for it. A set rather than a
    // single value: the whole question is whether anything claims two.
    let mut claims: BTreeMap<(u16, Side), BTreeSet<u16>> = BTreeMap::new();

    for map in maps {
        for exit in &map.exits {
            baseline.exits += 1;
            match shape_of(map.map_id, exit, &known) {
                Shape::OffsetSeam { .. } => baseline.offset_seams += 1,
                Shape::IntoBand => baseline.into_band += 1,
                Shape::BandToInterior => baseline.band_to_interior += 1,
                Shape::Interior => baseline.interior += 1,
                Shape::StandardSeam { .. } | Shape::SameMap | Shape::MissingDestination => {}
            }
            match classify(map.map_id, exit, &known) {
                ExitKind::SameMap => baseline.same_map += 1,
                ExitKind::MissingDestination => baseline.missing_destination += 1,
                ExitKind::NonGeographic => {
                    baseline.valid_cross_map += 1;
                    baseline.other_valid += 1;
                }
                ExitKind::StandardSeam { side } => {
                    baseline.valid_cross_map += 1;
                    baseline.standard_seams += 1;
                    claims.entry((map.map_id, side)).or_default().insert(exit.target_map);
                }
            }
        }
    }

    let mut adjacencies = BTreeSet::new();
    let mut conflicts = Vec::new();

    for ((map, side), targets) in &claims {
        if targets.len() > 1 {
            conflicts.push(PlacementConflict {
                map: *map,
                side: *side,
                claims: targets.iter().copied().collect(),
            });
            continue;
        }
        if let Some(target) = targets.iter().next() {
            adjacencies.insert(Adjacency { from_map: *map, side: *side, to_map: *target });
        }
    }

    baseline.contested_sides = conflicts.len();

    // Reciprocal *placements*: A says B is east and B says A is west. One direction of
    // each is counted, so a pair that agrees on one relative position contributes one —
    // and a pair that claims two different ones contributes two, which is the distinction
    // the old name hid.
    let reciprocal: BTreeSet<Adjacency> = adjacencies
        .iter()
        .copied()
        .filter(|edge| {
            adjacencies.contains(&Adjacency {
                from_map: edge.to_map,
                side: edge.side.opposite(),
                to_map: edge.from_map,
            })
        })
        .collect();

    baseline.reciprocal_placements =
        reciprocal.iter().filter(|edge| matches!(edge.side, Side::East | Side::South)).count();

    baseline.reciprocal_pairs = reciprocal
        .iter()
        .map(|edge| (edge.from_map.min(edge.to_map), edge.from_map.max(edge.to_map)))
        .collect::<BTreeSet<_>>()
        .len();

    baseline.one_sided_placements = adjacencies.len() - reciprocal.len();

    baseline.weak_components = components(&known, &adjacencies);
    baseline.reciprocal_components = components(&known, &reciprocal);

    // Contradictions as constraints rather than as a walk. The walk's answer depended on
    // where it started — the 424-map component reported anywhere from 48 to 161 conflicting
    // targets depending on the root — so it measured the traversal, not the world.
    let constraint_conflicts = constraint_conflicts(&adjacencies);
    let witnesses = cycle_witnesses(&adjacencies);
    baseline.cycle_witnesses = witnesses.len();
    baseline.conflict_clusters = conflict_clusters(&witnesses).len();

    // Every map in a component that contains a contradiction, found through component
    // identity rather than by counting components of the tainted subgraph — that subgraph
    // is not the same shape as the components its maps came from, and counting it reported
    // two inconsistent components while the cluster evidence showed contradictions in maps
    // that a 2x2 candidate search was then happy to build on.
    let of_component = component_of(&known, &adjacencies);
    let inconsistent_components: BTreeSet<u16> = witnesses
        .iter()
        .flat_map(|witness| witness.loop_maps.iter())
        .filter_map(|map| of_component.get(map).copied())
        .collect();

    let tainted: BTreeSet<u16> = of_component
        .iter()
        .filter(|(_, component)| inconsistent_components.contains(component))
        .map(|(map, _)| *map)
        .collect();

    baseline.inconsistent_maps = tainted.len();
    baseline.inconsistent_components = inconsistent_components.len();

    // The shape of the world, as opposed to the shape a plane would force on it. Measured
    // last because it reads the adjacencies the classification above produced.
    let spaces = regions(maps, &adjacencies);
    baseline.regions = spaces.len();
    baseline.wrapping_regions = spaces.iter().filter(|region| region.geometry.wraps()).count();
    baseline.unresolved_seams = spaces.iter().map(|region| region.unresolved.len()).sum();
    baseline.sea_maps = surfaces(maps).values().filter(|s| **s == Surface::Sea).count();
    baseline.discrete_regions =
        spaces.iter().filter(|region| region.geometry == Geometry::Discrete).count();

    // Seam evidence needs the maps placed, so it reads the regions just measured. It builds
    // one atlas per region itself: each region's coordinates start at its own corner, so a
    // single world-wide index would call every region an overlap of every other.
    let (seams, _) = crate::seam::summarise(maps, &adjacencies, &spaces, &surfaces(maps));
    let counts = |class: ClaimClass| {
        seams
            .get(&class)
            .map(|found: &crate::seam::SeamSummary| SeamCounts {
                seams: found.seams,
                without_defects: found.without_defects,
                tile_pairs: found.tile_pairs,
                crossable_on_foot: found.on_foot,
                crossable_by_boat: found.by_boat,
                blocked: found.blocked,
                into_solid: found.into_solid,
                into_solid_with_exits: found.into_solid_with_exits,
                strandings_with_exits: found.strandings_with_exits,
                beaches_boat: found.beaches_boat,
                one_tile_failures: found.one_tile_failures,
                resolution_failures: found.resolution_failures,
                one_way_exits: found.one_way_exits,
                ground_continuity_95: found.continuous_at_95,
            })
            .unwrap_or_default()
    };
    baseline.land_seams = counts(ClaimClass::LandLand);
    baseline.shore_seams = counts(ClaimClass::LandSea);
    baseline.sea_seams = counts(ClaimClass::SeaSea);

    let mask = crate::mask::coverage(maps);
    baseline.mask = mask.total;
    baseline.maps_fully_drawn = mask.fully_drawn;
    baseline.maps_with_lying_rectangle = mask.lying_rectangles.len();
    baseline.arrivals_in_void = seams.values().map(|found| found.arrivals_in_void).sum();

    let classes = by_claim_class(maps, &adjacencies);
    let unresolved = |class: ClaimClass| classes.get(&class).map(|c| c.unresolved).unwrap_or(0);
    baseline.land_land_unresolved = unresolved(ClaimClass::LandLand);
    baseline.sea_sea_unresolved = unresolved(ClaimClass::SeaSea);
    baseline.land_sea_unresolved = unresolved(ClaimClass::LandSea);

    let evidence = Evidence {
        baseline,
        adjacencies,
        conflicts,
        constraint_conflicts,
        witnesses,
        inconsistent: tainted,
        regions: spaces,
    };

    let quads = conflict_free_quads(&evidence).len();
    Evidence { baseline: Baseline { conflict_free_quads: quads, ..evidence.baseline }, ..evidence }
}

/// How many groups the maps fall into, joined by standard seams alone.
///
/// A world that is one component can be laid out in one coordinate space. 237 of them
/// means the corpus describes 237 islands, which is a fact about the data rather than a
/// problem to be solved here.
fn components(known: &BTreeSet<u16>, adjacencies: &BTreeSet<Adjacency>) -> usize {
    let mut neighbours: BTreeMap<u16, BTreeSet<u16>> = BTreeMap::new();
    for edge in adjacencies {
        neighbours.entry(edge.from_map).or_default().insert(edge.to_map);
        neighbours.entry(edge.to_map).or_default().insert(edge.from_map);
    }

    let mut seen: BTreeSet<u16> = BTreeSet::new();
    let mut count = 0;

    for map in known {
        if seen.contains(map) {
            continue;
        }
        count += 1;

        let mut stack = vec![*map];
        while let Some(current) = stack.pop() {
            if !seen.insert(current) {
                continue;
            }
            if let Some(next) = neighbours.get(&current) {
                stack.extend(next.iter().copied());
            }
        }
    }

    count
}

/// A contradiction, as the constraint that could not hold and the offset it disagreed with.
///
/// Deterministic: the constraints are visited in sorted order, so the same corpus always
/// produces the same witnesses. That is the property a depth-first traversal report does
/// not have — changing which map the walk starts from moved the reported conflict count of
/// the 424-map component from 48 to 161, which makes it a fact about the walk rather than
/// about the world.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ConstraintConflict {
    /// The two maps, smaller id first, so a conflict has one name.
    pub pair: (u16, u16),
    /// What the offsets already imply for `pair.1 - pair.0`.
    pub established: (i64, i64),
    /// What this constraint asks for instead.
    pub claimed: (i64, i64),
}

/// Offsets between maps, accumulated so that a contradiction is found where it is, rather
/// than wherever a walk happened to reach it.
///
/// Weighted union-find: every map carries its offset from the root of its group, so
/// merging two groups is one subtraction and testing a constraint is two lookups. A
/// constraint that disagrees with the offsets already established is a conflict, and it is
/// the *constraint* that is reported — not a map, and not a traversal target.
#[derive(Debug, Default)]
struct Offsets {
    /// The shape the offsets are accumulated in.
    ///
    /// `Geometry::Plane` reduces to exact arithmetic, which is why every planar count in
    /// `BASELINE` is unaffected by this being general: there is one union-find for every
    /// geometry, so a wrapping region and a flat one cannot disagree about what a
    /// contradiction is.
    geometry: Geometry,
    parent: BTreeMap<u16, u16>,
    /// Offset from this map to its parent.
    delta: BTreeMap<u16, (i64, i64)>,
}

impl Offsets {
    /// The root of `map`'s group and `map`'s offset from it.
    fn find(&mut self, map: u16) -> (u16, (i64, i64)) {
        let parent = *self.parent.entry(map).or_insert(map);
        if parent == map {
            return (map, (0, 0));
        }

        let (root, up) = self.find(parent);
        let mine = self.delta.get(&map).copied().unwrap_or((0, 0));
        let total = self.geometry.reduce((mine.0 + up.0, mine.1 + up.1));

        // Path compression, so a long chain is walked once rather than once per query.
        self.parent.insert(map, root);
        self.delta.insert(map, total);
        (root, total)
    }

    /// Record that `to` sits `delta` from `from`. Returns a conflict if that cannot hold.
    fn constrain(&mut self, from: u16, to: u16, delta: (i64, i64)) -> Option<ConstraintConflict> {
        let (from_root, from_off) = self.find(from);
        let (to_root, to_off) = self.find(to);
        let delta = self.geometry.reduce(delta);

        if from_root == to_root {
            // Both already placed relative to the same root, so the answer is already
            // known: either this constraint agrees with it or the corpus contradicts
            // itself here. "Agrees" means the difference is zero *in this geometry* — on a
            // torus a whole period is no distance at all.
            let established = (to_off.0 - from_off.0, to_off.1 - from_off.1);
            let residual = self.geometry.reduce((established.0 - delta.0, established.1 - delta.1));
            if residual == (0, 0) {
                return None;
            }
            let (pair, established, claimed) = if from < to {
                ((from, to), established, delta)
            } else {
                ((to, from), (-established.0, -established.1), (-delta.0, -delta.1))
            };
            return Some(ConstraintConflict { pair, established, claimed });
        }

        // Different groups: join them. `to_root` hangs off `from_root` at whatever offset
        // makes this constraint true.
        let root_delta = self
            .geometry
            .reduce((from_off.0 + delta.0 - to_off.0, from_off.1 + delta.1 - to_off.1));
        self.parent.insert(to_root, from_root);
        self.delta.insert(to_root, root_delta);
        None
    }
}

/// Every contradiction in the corpus, found without traversing it.
///
/// One pass over the adjacencies in sorted order. A pair may appear more than once with
/// different claims; each distinct disagreement is reported once.
pub fn constraint_conflicts(adjacencies: &BTreeSet<Adjacency>) -> BTreeSet<ConstraintConflict> {
    let mut offsets = Offsets::default();

    // Keyed by the *relationship* — the pair and the offset it asks for — and not by the
    // offset already established when it was tested. The same relationship can be tested
    // against different accumulated offsets as groups merge, and counting those separately
    // reports the same disagreement more than once: 55 rather than 42 on this corpus. What
    // a reviewer needs is the set of signed constraints that cannot all hold.
    let mut conflicts: BTreeMap<((u16, u16), (i64, i64)), (i64, i64)> = BTreeMap::new();

    for edge in adjacencies {
        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);
        if let Some(conflict) = offsets.constrain(edge.from_map, edge.to_map, delta) {
            conflicts.entry((conflict.pair, conflict.claimed)).or_insert(conflict.established);
        }
    }

    conflicts
        .into_iter()
        .map(|((pair, claimed), established)| ConstraintConflict { pair, established, claimed })
        .collect()
}

/// Which component each map belongs to, named by its smallest member.
///
/// Named by the smallest id rather than by wherever a walk started, so the name is a fact
/// about the group. Needed because "how many components are inconsistent" was inferred
/// from the shape of the tainted subgraph, which is not the shape of the components those
/// maps came from — it reported two while a 2x2 candidate search was happily building on
/// maps that appear in a conflict cluster.
pub fn component_of(
    known: &BTreeSet<u16>,
    adjacencies: &BTreeSet<Adjacency>,
) -> BTreeMap<u16, u16> {
    let mut neighbours: BTreeMap<u16, BTreeSet<u16>> = BTreeMap::new();
    for edge in adjacencies {
        neighbours.entry(edge.from_map).or_default().insert(edge.to_map);
        neighbours.entry(edge.to_map).or_default().insert(edge.from_map);
    }

    let mut assigned: BTreeMap<u16, u16> = BTreeMap::new();

    for map in known {
        if assigned.contains_key(map) {
            continue;
        }
        let mut group = BTreeSet::new();
        let mut stack = vec![*map];
        while let Some(current) = stack.pop() {
            if !group.insert(current) {
                continue;
            }
            if let Some(next) = neighbours.get(&current) {
                stack.extend(next.iter().copied());
            }
        }
        let name = group.iter().copied().next().unwrap_or(*map);
        for member in group {
            assigned.insert(member, name);
        }
    }

    assigned
}

/// A loop of maps whose offsets do not close, and by how much.
///
/// This is the stable form of a contradiction. How many *constraints* get blamed for an
/// inconsistency depends on the algorithm: union-find over sorted claims blames whichever
/// constraint closes a cycle and reports 55; collapsing a depth-first traversal's
/// contradictions blames whichever edge disagreed with its spanning tree and reports 42;
/// restricting to reciprocal claims reports 30. All three describe the same corpus. The
/// loop itself does not move — it is a closed walk that fails to return to where it
/// started, which is a fact about the world.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CycleWitness {
    /// The loop, starting and ending at the same map, in traversal order.
    pub loop_maps: Vec<u16>,
    /// How far from closed it is, in tiles. Never `(0, 0)`.
    pub residual: (i64, i64),
}

/// Every loop in the corpus that fails to close, in deterministic order.
///
/// One spanning forest over the claims in sorted order; every claim that is not a tree
/// edge closes a cycle, and a cycle whose offsets do not sum to zero is a witness. The
/// witnesses are what a reviewer reads: "these five maps cannot all be where they say they
/// are, and the loop is out by 74 tiles" is a root cause, where "constraint 37→168
/// disagrees" is a symptom of it.
pub fn cycle_witnesses(adjacencies: &BTreeSet<Adjacency>) -> Vec<CycleWitness> {
    // Spanning forest, built in sorted order so the tree is the same every run.
    let mut parent: BTreeMap<u16, (u16, (i64, i64))> = BTreeMap::new();
    let mut root_of: BTreeMap<u16, u16> = BTreeMap::new();
    // A tree edge is a *claim*, not a pair of maps. Two maps can be joined by more than
    // one claim — 37 says 168 is to its West and also to its East — and keying the forest
    // by the pair alone swallowed the second one, so a direct contradiction between two
    // maps produced no witness at all. Keyed by the signed constraint, canonicalised so a
    // claim and its reciprocal are one key.
    let mut tree_edges: BTreeSet<((u16, u16), (i64, i64))> = BTreeSet::new();

    fn signed(a: u16, b: u16, delta: (i64, i64)) -> ((u16, u16), (i64, i64)) {
        if a <= b {
            ((a, b), delta)
        } else {
            ((b, a), (-delta.0, -delta.1))
        }
    }

    let mut neighbours: BTreeMap<u16, Vec<(u16, (i64, i64))>> = BTreeMap::new();
    for edge in adjacencies {
        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);
        neighbours.entry(edge.from_map).or_default().push((edge.to_map, delta));
        neighbours.entry(edge.to_map).or_default().push((edge.from_map, (-delta.0, -delta.1)));
    }

    for start in neighbours.keys().copied().collect::<Vec<_>>() {
        if root_of.contains_key(&start) {
            continue;
        }
        root_of.insert(start, start);

        let mut queue = std::collections::VecDeque::from([start]);
        while let Some(map) = queue.pop_front() {
            for (next, _) in neighbours.get(&map).cloned().unwrap_or_default() {
                if root_of.contains_key(&next) {
                    continue;
                }
                let delta = neighbours[&map]
                    .iter()
                    .find(|(to, _)| *to == next)
                    .map(|(_, d)| *d)
                    .unwrap_or((0, 0));
                parent.insert(next, (map, delta));
                root_of.insert(next, start);
                tree_edges.insert(signed(map, next, delta));
                queue.push_back(next);
            }
        }
    }

    // Offset from each map to its root, by walking the tree.
    // Position relative to the root, accumulated up the tree.
    //
    // `parent[child] = (parent, delta)` records that the child sits `delta` from its
    // parent, so the child's offset from the root is its parent's offset *plus* delta.
    // Subtracting instead — the sign I wrote first — makes every second edge of a square
    // look like a contradiction: a consistent 2x2 came out "out by 148 tiles", which is
    // two core widths, and the same figure then appeared all over the corpus and read
    // convincingly as a systematic two-map displacement in the data. It was arithmetic.
    let offset_to_root = |mut map: u16| {
        let mut total = (0i64, 0i64);
        while let Some((up, delta)) = parent.get(&map).copied() {
            total = (total.0 + delta.0, total.1 + delta.1);
            map = up;
        }
        total
    };

    // The path from a map up to the root, for splicing cycles.
    let path_to_root = |mut map: u16| {
        let mut path = vec![map];
        while let Some((up, _)) = parent.get(&map).copied() {
            path.push(up);
            map = up;
        }
        path
    };

    let mut witnesses: BTreeSet<CycleWitness> = BTreeSet::new();

    for edge in adjacencies {
        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);

        if tree_edges.contains(&signed(edge.from_map, edge.to_map, delta)) {
            continue;
        }

        let from = offset_to_root(edge.from_map);
        let to = offset_to_root(edge.to_map);
        let residual = ((to.0 - from.0) - delta.0, (to.1 - from.1) - delta.1);
        if residual == (0, 0) {
            continue;
        }

        // The loop: up from one end, down to the other, spliced at their meeting point.
        let up = path_to_root(edge.from_map);
        let down = path_to_root(edge.to_map);
        let meeting = up.iter().find(|map| down.contains(map)).copied();

        let mut loop_maps = Vec::new();
        if let Some(meeting) = meeting {
            for map in &up {
                loop_maps.push(*map);
                if *map == meeting {
                    break;
                }
            }
            let tail: Vec<u16> = down.iter().take_while(|map| **map != meeting).copied().collect();
            loop_maps.extend(tail.into_iter().rev());
            loop_maps.push(edge.from_map);
        } else {
            loop_maps = vec![edge.from_map, edge.to_map, edge.from_map];
        }

        witnesses.insert(CycleWitness { loop_maps, residual });
    }

    witnesses.into_iter().collect()
}

/// Groups of maps tied together by contradictions.
///
/// A cluster is what needs one disposition: the maps whose claims cannot all hold, joined
/// through the loops they appear in. Reviewing clusters is reviewing root causes; reviewing
/// blamed constraints is reviewing whichever edge an algorithm happened to accuse.
pub fn conflict_clusters(witnesses: &[CycleWitness]) -> Vec<BTreeSet<u16>> {
    let mut clusters: Vec<BTreeSet<u16>> = Vec::new();

    for witness in witnesses {
        let maps: BTreeSet<u16> = witness.loop_maps.iter().copied().collect();
        let mut merged = maps;
        let mut rest = Vec::new();

        for cluster in clusters.drain(..) {
            if cluster.intersection(&merged).next().is_some() {
                merged.extend(cluster);
            } else {
                rest.push(cluster);
            }
        }

        rest.push(merged);
        clusters = rest;
    }

    clusters.sort_by_key(|cluster| cluster.iter().copied().next().unwrap_or(0));
    clusters
}

/// Which maps are in groups that cannot be laid out at all.
///
/// A component is inconsistent if any constraint inside it conflicts. Reported as the set
/// of maps rather than a count of conflicts, because "this group is not a plane" is the
/// fact a caller acts on: a conflict-free component can be promoted to geography, and one
/// with any conflict cannot until the conflict has a disposition.
pub fn inconsistent_maps(
    adjacencies: &BTreeSet<Adjacency>,
    conflicts: &BTreeSet<ConstraintConflict>,
) -> BTreeSet<u16> {
    if conflicts.is_empty() {
        return BTreeSet::new();
    }

    let mut neighbours: BTreeMap<u16, BTreeSet<u16>> = BTreeMap::new();
    for edge in adjacencies {
        neighbours.entry(edge.from_map).or_default().insert(edge.to_map);
        neighbours.entry(edge.to_map).or_default().insert(edge.from_map);
    }

    let mut tainted = BTreeSet::new();
    for conflict in conflicts {
        for seed in [conflict.pair.0, conflict.pair.1] {
            if tainted.contains(&seed) {
                continue;
            }
            let mut stack = vec![seed];
            while let Some(map) = stack.pop() {
                if !tainted.insert(map) {
                    continue;
                }
                if let Some(next) = neighbours.get(&map) {
                    stack.extend(next.iter().copied());
                }
            }
        }
    }

    tainted
}

/// Where a map's *core* sits, in tiles, once a component is laid out.
///
/// The origin of the core, not of the storage: the band and gutter columns outside it are
/// storage that no global position addresses. Integer by construction, because every
/// standard seam is exactly one core width or height apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Origin {
    pub x: i64,
    pub y: i64,
}

/// A square of four maps that can be composed with no contradiction anywhere in it.
///
/// What the seamless-world MVP needs: two by two, every internal seam reciprocal, and the
/// whole group outside any inconsistent component. Curating the 424-map continent is a
/// separate job — a candidate here has to be provably safe, not merely likely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Quad {
    pub north_west: u16,
    pub north_east: u16,
    pub south_west: u16,
    pub south_east: u16,
}

/// Every conflict-free 2x2 square in the corpus, in deterministic order.
///
/// A square qualifies only if all four of its internal seams are reciprocal — both maps
/// name each other — and none of its maps sits in a component that cannot be laid out. The
/// second condition matters even though the square itself closes: a map inside an
/// inconsistent component has a position that depends on which contradiction is resolved,
/// so building the MVP on it would mean rebuilding it afterwards.
pub fn conflict_free_quads(evidence: &Evidence) -> Vec<Quad> {
    let mut east: BTreeMap<u16, u16> = BTreeMap::new();
    let mut south: BTreeMap<u16, u16> = BTreeMap::new();

    for edge in &evidence.adjacencies {
        // Reciprocal only, checked in both directions.
        let mutual = evidence.adjacencies.contains(&Adjacency {
            from_map: edge.to_map,
            side: edge.side.opposite(),
            to_map: edge.from_map,
        });
        if !mutual {
            continue;
        }
        match edge.side {
            Side::East => {
                east.insert(edge.from_map, edge.to_map);
            }
            Side::South => {
                south.insert(edge.from_map, edge.to_map);
            }
            _ => {}
        }
    }

    let mut quads = Vec::new();

    for (north_west, north_east) in &east {
        let Some(south_west) = south.get(north_west) else {
            continue;
        };
        let Some(south_east) = south.get(north_east) else {
            continue;
        };
        // The fourth corner has to agree from both directions, or the square is not one.
        if east.get(south_west) != Some(south_east) {
            continue;
        }

        let quad = Quad {
            north_west: *north_west,
            north_east: *north_east,
            south_west: *south_west,
            south_east: *south_east,
        };

        let clean = [quad.north_west, quad.north_east, quad.south_west, quad.south_east]
            .iter()
            .all(|map| !evidence.inconsistent.contains(map));

        if clean {
            quads.push(quad);
        }
    }

    quads.sort();
    quads
}

/// The global tile a local coordinate maps to, given where its core sits.
///
/// Local coordinates are 1-based and include the storage margin; global coordinates count
/// core tiles from the component's own zero. A tile outside the core has no global position
/// at all — that is what makes the band a band — so this returns `None` rather than a
/// number nobody should use.
pub fn to_global(origin: Origin, x: u8, y: u8) -> Option<(i64, i64)> {
    if x < CORE_X.0 || x > CORE_X.1 || y < CORE_Y.0 || y > CORE_Y.1 {
        return None;
    }
    Some((origin.x + (x - CORE_X.0) as i64, origin.y + (y - CORE_Y.0) as i64))
}

/// Lay out one component from a starting map, following standard seams.
///
/// Returns the origins it could place and the seams that contradict them. A contradiction
/// is a seam whose two ends imply different positions for the same map — which is the
/// evidence that the corpus is not a plane, and it is reported rather than smoothed over.
pub fn lay_out(
    start: u16,
    adjacencies: &BTreeSet<Adjacency>,
) -> (BTreeMap<u16, Origin>, Vec<Adjacency>) {
    let mut neighbours: BTreeMap<u16, Vec<Adjacency>> = BTreeMap::new();
    for edge in adjacencies {
        neighbours.entry(edge.from_map).or_default().push(*edge);
        neighbours.entry(edge.to_map).or_default().push(Adjacency {
            from_map: edge.to_map,
            side: edge.side.opposite(),
            to_map: edge.from_map,
        });
    }

    let mut origins: BTreeMap<u16, Origin> = BTreeMap::new();
    let mut contradictions = Vec::new();
    origins.insert(start, Origin { x: 0, y: 0 });

    let mut stack = vec![start];
    while let Some(map) = stack.pop() {
        let here = origins[&map];
        for edge in neighbours.get(&map).cloned().unwrap_or_default() {
            let (dx, dy) = edge.side.step();
            let there = Origin { x: here.x + dx as i64 * PITCH_X, y: here.y + dy as i64 * PITCH_Y };

            match origins.get(&edge.to_map) {
                None => {
                    origins.insert(edge.to_map, there);
                    stack.push(edge.to_map);
                }
                Some(existing) if *existing != there => contradictions.push(edge),
                Some(_) => {}
            }
        }
    }

    (origins, contradictions)
}

/// How a global position resolves back to a map.
///
/// The distinction that matters is `Ambiguous`. Inverting `to_global` with the same origin it
/// used is nearly tautological — it proves arithmetic, not topology. What a manifest has to
/// guarantee is that a global position resolves to *exactly one* map, and a layout whose
/// claims contradict each other can place two maps on the same cell while every individual
/// conversion still round-trips perfectly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    Unique {
        map: u16,
        x: u8,
        y: u8,
    },
    /// More than one map covers this tile. The layout is not injective here, so no position
    /// in this area means anything until the contradiction has a disposition.
    Ambiguous(Vec<u16>),
    /// No map covers it.
    Outside,
}

/// A lookup from global position to the map that owns it, within one region.
///
/// Origins inside a region are always whole multiples of the pitch, because every constraint
/// that placed them was a pitch step, so a global tile belongs to exactly one grid cell and
/// the index is exact rather than a search.
#[derive(Debug, Clone, Default)]
pub struct Atlas {
    geometry: Geometry,
    cells: BTreeMap<(i64, i64), Vec<u16>>,
}

impl Atlas {
    pub fn new(origins: &BTreeMap<u16, Origin>, geometry: Geometry) -> Atlas {
        let mut cells: BTreeMap<(i64, i64), Vec<u16>> = BTreeMap::new();
        for (map, origin) in origins {
            let reduced = geometry.reduce((origin.x, origin.y));
            let cell = (reduced.0.div_euclid(PITCH_X), reduced.1.div_euclid(PITCH_Y));
            cells.entry(cell).or_default().push(*map);
        }
        Atlas { geometry, cells }
    }

    pub fn of(region: &Region) -> Atlas {
        Atlas::new(&region.origins, region.geometry)
    }

    /// Which map owns a global tile, and where it sits on it.
    pub fn resolve(&self, global: (i64, i64)) -> Resolved {
        let reduced = self.geometry.reduce(global);
        let cell = (reduced.0.div_euclid(PITCH_X), reduced.1.div_euclid(PITCH_Y));
        match self.cells.get(&cell) {
            None => Resolved::Outside,
            Some(maps) if maps.len() > 1 => Resolved::Ambiguous(maps.clone()),
            Some(maps) => {
                let x = CORE_X.0 + reduced.0.rem_euclid(PITCH_X) as u8;
                let y = CORE_Y.0 + reduced.1.rem_euclid(PITCH_Y) as u8;
                Resolved::Unique { map: maps[0], x, y }
            }
        }
    }

    /// Tiles covered by more than one map, which is the failure a per-tile round trip cannot
    /// see.
    pub fn ambiguous_cells(&self) -> usize {
        self.cells.values().filter(|maps| maps.len() > 1).count()
    }

    /// The groups of maps that share a cell.
    ///
    /// Worth naming, because a space can satisfy every one of its claims and still be
    /// non-injective: nothing in the corpus asserts that two maps reached by different paths
    /// are different places, so a consistent set of constraints can stack them. Three spaces
    /// in this corpus do exactly that, and no count of contradictory claims would show it.
    pub fn overlaps(&self) -> Vec<Vec<u16>> {
        self.cells.values().filter(|maps| maps.len() > 1).cloned().collect()
    }
}

/// A map with at least this share of navigable water is sea rather than shore.
///
/// A descriptor, not a verdict. An earlier version of this rule counted every non-walkable
/// tile and called 278 maps "open water", which put nine dry caves and pyramids in the
/// ocean — `Interconexion Catacumbas` is 95% solid rock and 0% water — and then used that
/// bad label to argue the sea was not a place. Water is navigable space: 2,232,228 tiles of
/// it, crossed by boat, and no map in this corpus lacks walkable ground entirely.
pub const SEA_WATER_PERCENT: usize = 50;

/// The share of a map that is walkable, solid and navigable water, in that order.
pub fn composition(map: &PackedMap) -> (usize, usize, usize) {
    let total = map.tiles.len().max(1);
    let count = |kind: Tile| {
        map.tiles.iter().filter(|value| Tile::of(**value) == kind).count() * 100 / total
    };
    (count(Tile::Walkable), count(Tile::Solid), count(Tile::Water))
}

/// What a map is mostly made of.
///
/// Descriptive only. Whether a shore-to-sea claim is a seam, a boat route or a portal is a
/// reviewed disposition, not something this label decides — sailing across the ocean is
/// movement through the world, so a sea seam losing continuity would be a real defect
/// rather than a tidy simplification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Surface {
    Land,
    Sea,
}

/// Which surfaces a claim joins, so land, sea and shore can be measured apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ClaimClass {
    LandLand,
    SeaSea,
    /// A shore claiming the open sea, or the reverse. The class whose geometry is unknown.
    LandSea,
}

/// How one class of claim behaves on its own.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ClassEvidence {
    pub claims: usize,
    pub components: usize,
    pub wrapping: usize,
    pub unresolved: usize,
}

/// The shape a region's own claims say it is.
///
/// Named explicitly rather than inferred from a pair of periods, because this is what the
/// manifest publishes and what Elixir and Rust have to agree on: a reader should not have
/// to know that "period 0" means "does not wrap". The legacy world intentionally contains
/// more than one of these, and the compiler's job is to model them, not to flatten them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum Geometry {
    /// Unbounded in both directions. Most of the world.
    #[default]
    Plane,
    /// Wraps on one axis. Walking far enough one way returns you to where you started.
    Cylinder { axis: Axis, period: i64 },
    /// Wraps on both. The four Newbie Dungeon maps are one, 148 x 160 tiles.
    Torus { width: i64, height: i64 },
    /// A space its maps reach only by transition: no seam joins them to anything. 199 maps
    /// of this corpus are their own such space, reached by door or teleport, and saying so
    /// is more honest than inventing a neighbour for them.
    Discrete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Axis {
    X,
    Y,
}

impl Geometry {
    fn from_periods(x: i64, y: i64) -> Geometry {
        match (x, y) {
            (0, 0) => Geometry::Plane,
            (x, 0) => Geometry::Cylinder { axis: Axis::X, period: x },
            (0, y) => Geometry::Cylinder { axis: Axis::Y, period: y },
            (width, height) => Geometry::Torus { width, height },
        }
    }

    /// The wrap period on each axis, `0` where the space does not wrap.
    pub fn periods(&self) -> (i64, i64) {
        match self {
            Geometry::Plane | Geometry::Discrete => (0, 0),
            Geometry::Cylinder { axis: Axis::X, period } => (*period, 0),
            Geometry::Cylinder { axis: Axis::Y, period } => (0, *period),
            Geometry::Torus { width, height } => (*width, *height),
        }
    }

    pub fn wraps(&self) -> bool {
        self.periods() != (0, 0)
    }

    /// Bring an offset into this geometry's canonical range.
    pub fn reduce(&self, offset: (i64, i64)) -> (i64, i64) {
        let (px, py) = self.periods();
        let axis =
            |value: i64, period: i64| if period == 0 { value } else { value.rem_euclid(period) };
        (axis(offset.0, px), axis(offset.1, py))
    }
}

/// One coordinate space: a set of maps, the shape they agree on, and where each one sits.
///
/// Named by its smallest map so the name is a fact about the group rather than about the
/// order it was discovered in. Every map in the corpus belongs to exactly one region, and a
/// map with no seams at all is a region of one — 199 of them are, which is honest: they are
/// reached by door or teleport, and pretending otherwise would invent geography.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Region {
    pub id: u16,
    /// How many of its maps are mostly sea. A region may be all land, all sea, or a coast
    /// that is both, and splitting it by surface would be a decision rather than a reading.
    pub sea_maps: usize,
    pub geometry: Geometry,
    /// Where each map's core sits, in the region's own coordinates.
    pub origins: BTreeMap<u16, Origin>,
    /// Claims that cannot hold even in this geometry. Every one needs a reviewed
    /// disposition; none may be silently dropped.
    pub unresolved: Vec<Adjacency>,
}

/// Lay a group out in one geometry, reporting the claims that cannot hold in it.
fn place(geometry: Geometry, edges: &[Adjacency]) -> (Offsets, Vec<Adjacency>) {
    let mut offsets = Offsets { geometry, ..Offsets::default() };
    let mut unresolved = Vec::new();
    for edge in edges {
        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);
        if offsets.constrain(edge.from_map, edge.to_map, delta).is_some() {
            unresolved.push(*edge);
        }
    }
    (offsets, unresolved)
}

/// How many maps end up sharing a cell with another one.
///
/// A wrap that is real also *fits*. Without this test the smallest period always wins by
/// folding the world onto itself: a 2-map wrap "explains" 424 maps in 44 cells, which is
/// exactly the wrong answer this analysis produced before the test existed.
fn overlapping(offsets: &mut Offsets, members: &BTreeSet<u16>) -> usize {
    let mut cells: BTreeMap<(i64, i64), usize> = BTreeMap::new();
    for map in members {
        let (_, offset) = offsets.find(*map);
        let cell = (offset.0.div_euclid(PITCH_X), offset.1.div_euclid(PITCH_Y));
        *cells.entry(cell).or_default() += 1;
    }
    cells.values().filter(|count| **count > 1).copied().sum()
}

/// The shape a group of maps is, measured from its own claims.
///
/// The plane is tried first and kept unless something better fits, so a consistent group is
/// never described as wrapping. Candidate periods come from the magnitudes of the group's
/// own failing loops — the corpus names its own candidates rather than being tested against
/// a guess — and a candidate is admissible only if it leaves no two maps in one cell.
pub fn measure_geometry(
    edges: &[Adjacency],
    members: &BTreeSet<u16>,
) -> (Geometry, Vec<Adjacency>) {
    let (_, planar) = place(Geometry::Plane, edges);
    if planar.is_empty() {
        return (Geometry::Plane, planar);
    }

    // The periods worth testing are the distances the group's own loops fail to close by.
    let mut offsets = Offsets::default();
    let mut candidates: BTreeSet<Geometry> = BTreeSet::new();
    let mut xs: BTreeSet<i64> = BTreeSet::new();
    let mut ys: BTreeSet<i64> = BTreeSet::new();
    for edge in edges {
        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);
        if let Some(conflict) = offsets.constrain(edge.from_map, edge.to_map, delta) {
            let residual = (
                conflict.established.0 - conflict.claimed.0,
                conflict.established.1 - conflict.claimed.1,
            );
            if residual.0 != 0 {
                xs.insert(residual.0.abs());
            }
            if residual.1 != 0 {
                ys.insert(residual.1.abs());
            }
        }
    }
    for x in std::iter::once(0).chain(xs) {
        for y in std::iter::once(0).chain(ys.iter().copied()) {
            candidates.insert(Geometry::from_periods(x, y));
        }
    }

    let mut best = (Geometry::Plane, planar);
    for candidate in candidates {
        if !candidate.wraps() {
            continue;
        }
        let (mut offsets, unresolved) = place(candidate, edges);
        if overlapping(&mut offsets, members) == 0 && unresolved.len() < best.1.len() {
            best = (candidate, unresolved);
        }
    }
    best
}

/// What each map is mostly made of, measured from its tiles.
pub fn surfaces(maps: &[PackedMap]) -> BTreeMap<u16, Surface> {
    maps.iter()
        .map(|map| {
            let (_, _, water) = composition(map);
            let surface = if water >= SEA_WATER_PERCENT { Surface::Sea } else { Surface::Land };
            (map.map_id, surface)
        })
        .collect()
}

/// Which surfaces each claim joins.
pub fn class_of(edge: &Adjacency, surfaces: &BTreeMap<u16, Surface>) -> ClaimClass {
    match (surfaces.get(&edge.from_map), surfaces.get(&edge.to_map)) {
        (Some(Surface::Sea), Some(Surface::Sea)) => ClaimClass::SeaSea,
        (Some(Surface::Land), Some(Surface::Land)) => ClaimClass::LandLand,
        _ => ClaimClass::LandSea,
    }
}

/// How each class of claim behaves when it is the only evidence.
///
/// The question the corpus has to answer before anything is promoted or discarded: the land
/// may be a plane while the ocean is a cylinder while the shore claims join them
/// inconsistently, and one aggregate number cannot tell those apart. Measured per class and
/// pinned, so a later change to the ocean's shape is a visible decision rather than a drift
/// in a total.
pub fn by_claim_class(
    maps: &[PackedMap],
    adjacencies: &BTreeSet<Adjacency>,
) -> BTreeMap<ClaimClass, ClassEvidence> {
    let surfaces = surfaces(maps);
    let mut report = BTreeMap::new();

    for class in [ClaimClass::LandLand, ClaimClass::SeaSea, ClaimClass::LandSea] {
        let only: BTreeSet<Adjacency> =
            adjacencies.iter().copied().filter(|edge| class_of(edge, &surfaces) == class).collect();
        let members: BTreeSet<u16> = only.iter().flat_map(|e| [e.from_map, e.to_map]).collect();
        let regions = regions_of(&members, &only, &surfaces);

        report.insert(
            class,
            ClassEvidence {
                claims: only.len(),
                components: regions.len(),
                wrapping: regions.iter().filter(|region| region.geometry.wraps()).count(),
                unresolved: regions.iter().map(|region| region.unresolved.len()).sum(),
            },
        );
    }

    report
}

/// Every coordinate space in the corpus, with its shape measured rather than assumed.
///
/// Every standard seam is evidence here, including shore-to-sea claims. Splitting the world
/// by surface would decide the very thing under review: the sea is navigable space, so a
/// claim across a coastline may be exactly as geographic as one inland, and dropping it to
/// make the arithmetic close would be inventing geography by subtraction.
pub fn regions(maps: &[PackedMap], adjacencies: &BTreeSet<Adjacency>) -> Vec<Region> {
    let surface = surfaces(maps);
    let known: BTreeSet<u16> = surface.keys().copied().collect();
    regions_of(&known, adjacencies, &surface)
}

fn regions_of(
    known: &BTreeSet<u16>,
    seams: &BTreeSet<Adjacency>,
    surface: &BTreeMap<u16, Surface>,
) -> Vec<Region> {
    let of_component = component_of(known, seams);

    let mut grouped: BTreeMap<u16, (Vec<Adjacency>, BTreeSet<u16>)> = BTreeMap::new();
    for map in known {
        grouped.entry(of_component[map]).or_default().1.insert(*map);
    }
    for edge in seams {
        if let Some(group) = grouped.get_mut(&of_component[&edge.from_map]) {
            group.0.push(*edge);
        }
    }

    grouped
        .into_iter()
        .map(|(id, (edges, members))| {
            let (geometry, unresolved) = if edges.is_empty() {
                (Geometry::Discrete, Vec::new())
            } else {
                measure_geometry(&edges, &members)
            };
            let (mut offsets, _) = place(geometry, &edges);

            let mut origins: BTreeMap<u16, Origin> = members
                .iter()
                .map(|map| {
                    let (_, offset) = offsets.find(*map);
                    (*map, Origin { x: offset.0, y: offset.1 })
                })
                .collect();

            // An unwrapped axis has no natural zero, so it gets one: the region's own edge.
            // A wrapped axis is already in `[0, period)` and moving it would be a lie.
            let (period_x, period_y) = geometry.periods();
            if period_x == 0 {
                let least = origins.values().map(|o| o.x).min().unwrap_or(0);
                origins.values_mut().for_each(|o| o.x -= least);
            }
            if period_y == 0 {
                let least = origins.values().map(|o| o.y).min().unwrap_or(0);
                origins.values_mut().for_each(|o| o.y -= least);
            }

            let sea_maps =
                members.iter().filter(|map| surface.get(map) == Some(&Surface::Sea)).count();

            Region { id, sea_maps, geometry, origins, unresolved }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exit(x: u8, y: u8, target_map: u16, target_x: u8, target_y: u8) -> MapExit {
        MapExit { x, y, target_map, target_x, target_y }
    }

    fn map(map_id: u16, exits: Vec<MapExit>) -> PackedMap {
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
            exits,
        }
    }

    /// A sea map: navigable water, which is 2 and not 1. Using 1 here would make the
    /// fixture a solid rock cube that the old classifier happily called an ocean.
    fn sea(map_id: u16) -> PackedMap {
        PackedMap { tiles: vec![2; STORAGE as usize * STORAGE as usize], ..map(map_id, Vec::new()) }
    }

    fn joined(from_map: u16, side: Side, to_map: u16) -> Adjacency {
        Adjacency { from_map, side, to_map }
    }

    /// Both directions of one adjacency, which is what a reciprocal seam looks like.
    fn both(a: u16, side: Side, b: u16) -> Vec<Adjacency> {
        vec![joined(a, side, b), joined(b, side.opposite(), a)]
    }

    #[test]
    fn a_square_that_agrees_is_a_plane_on_core_centres() {
        // 1 2
        // 3 4
        let mut edges = Vec::new();
        edges.extend(both(1, Side::East, 2));
        edges.extend(both(3, Side::East, 4));
        edges.extend(both(1, Side::South, 3));
        edges.extend(both(2, Side::South, 4));
        let maps: Vec<PackedMap> = (1..=4).map(|id| map(id, Vec::new())).collect();

        let spaces = regions(&maps, &edges.into_iter().collect());
        assert_eq!(spaces.len(), 1);
        let region = &spaces[0];
        assert_eq!(region.id, 1);
        assert_eq!(region.geometry, Geometry::Plane);
        assert_eq!(region.unresolved, Vec::new());
        assert_eq!(region.sea_maps, 0);
        // 74 and 80, not 100: the pitch is the core, so one step across a seam is one tile.
        assert_eq!(region.origins[&1], Origin { x: 0, y: 0 });
        assert_eq!(region.origins[&2], Origin { x: PITCH_X, y: 0 });
        assert_eq!(region.origins[&3], Origin { x: 0, y: PITCH_Y });
        assert_eq!(region.origins[&4], Origin { x: PITCH_X, y: PITCH_Y });
    }

    #[test]
    fn a_pair_claiming_both_of_its_opposite_sides_is_a_world_that_wraps() {
        // The four Newbie Dungeon maps, in miniature: each pair claims the other to its
        // West *and* its East. Read as a plane that is a contradiction out by two map
        // widths. Read as a shape it is a 2x2 world that loops, and it closes exactly.
        let mut edges = Vec::new();
        for side in [Side::East, Side::West] {
            edges.extend(both(1, side, 2));
            edges.extend(both(3, side, 4));
        }
        for side in [Side::North, Side::South] {
            edges.extend(both(1, side, 3));
            edges.extend(both(2, side, 4));
        }
        let maps: Vec<PackedMap> = (1..=4).map(|id| map(id, Vec::new())).collect();

        let spaces = regions(&maps, &edges.into_iter().collect());
        assert_eq!(spaces.len(), 1);
        assert_eq!(spaces[0].geometry, Geometry::Torus { width: 2 * PITCH_X, height: 2 * PITCH_Y });
        assert_eq!(spaces[0].unresolved, Vec::new());
        // Every map still has its own cell; a wrap that folds maps onto each other is not
        // a wrap, it is a smaller lie.
        let cells: BTreeSet<(i64, i64)> = spaces[0].origins.values().map(|o| (o.x, o.y)).collect();
        assert_eq!(cells.len(), 4);
    }

    #[test]
    fn a_period_that_does_not_fit_is_rejected_and_the_claim_stays_unresolved() {
        // An agreeing square, plus one claim too many: 4 is already east of 3, and this also
        // puts it south of 3. The loop fails to close by (74, -80), so 74 and 80 both look
        // like periods — and either one folds maps onto each other. This is the test that
        // was missing when a 2-map wrap "explained" 424 maps in 44 cells.
        let mut edges = Vec::new();
        edges.extend(both(1, Side::East, 2));
        edges.extend(both(3, Side::East, 4));
        edges.extend(both(1, Side::South, 3));
        edges.extend(both(2, Side::South, 4));
        edges.push(joined(3, Side::South, 4));
        let maps: Vec<PackedMap> = (1..=4).map(|id| map(id, Vec::new())).collect();

        let spaces = regions(&maps, &edges.into_iter().collect());
        assert_eq!(spaces[0].geometry, Geometry::Plane);
        assert_eq!(spaces[0].unresolved, vec![joined(3, Side::South, 4)]);
        let cells: BTreeSet<(i64, i64)> = spaces[0].origins.values().map(|o| (o.x, o.y)).collect();
        assert_eq!(cells.len(), 4);
    }

    #[test]
    fn two_maps_claiming_each_other_twice_produce_a_witness() {
        // The defect this test pins: the spanning forest keyed tree edges by map pair, so a
        // second claim between the *same two maps* was mistaken for the tree edge and
        // skipped. A pair that says "you are to my west" and "you are to my east" is a
        // contradiction with no third map in it, and it was reported as no contradiction.
        let edges: BTreeSet<Adjacency> =
            BTreeSet::from([joined(1, Side::East, 2), joined(1, Side::West, 2)]);

        let witnesses = cycle_witnesses(&edges);
        assert_eq!(witnesses.len(), 1, "a two-map contradiction is still a contradiction");
        // Two core widths apart: the West claim became the tree edge, so the East claim
        // asks for the opposite side of a map that is already placed.
        assert_eq!(witnesses[0].residual, (-2 * PITCH_X, 0));
        assert_eq!(witnesses[0].loop_maps, vec![1, 2, 1]);
    }

    #[test]
    fn a_solid_cave_is_not_an_ocean() {
        // The classifier bug this test exists to prevent: reading the blocked layer as a
        // boolean made 278 maps "open water", nine of which are dry rock. Water is the
        // tile value 2, and nothing else is.
        let cave = PackedMap {
            tiles: vec![1; STORAGE as usize * STORAGE as usize],
            ..map(41, Vec::new())
        };
        assert_eq!(composition(&cave), (0, 100, 0));
        assert_eq!(surfaces(&[cave])[&41], Surface::Land);

        let ocean = sea(495);
        assert_eq!(composition(&ocean), (0, 0, 100));
        assert_eq!(surfaces(&[ocean])[&495], Surface::Sea);

        assert_eq!(Tile::of(0), Tile::Walkable);
        assert_eq!(Tile::of(1), Tile::Solid);
        assert_eq!(Tile::of(2), Tile::Water);
        assert!(Tile::of(0).walkable());
        assert!(!Tile::of(2).walkable());
    }

    #[test]
    fn a_shore_to_sea_claim_stays_a_seam_and_is_measured_apart() {
        // Sailing is movement through the world, so a coast claiming the sea to its east is
        // evidence like any other. It is classified so its geometry can be judged on its
        // own, never dropped to make the land's arithmetic close.
        let maps = vec![map(1, Vec::new()), sea(2), sea(3)];
        let edges: BTreeSet<Adjacency> =
            both(1, Side::East, 2).into_iter().chain(both(2, Side::East, 3)).collect();

        let spaces = regions(&maps, &edges);
        assert_eq!(spaces.len(), 1, "every seam is evidence, so this is one region");
        assert_eq!(spaces[0].origins.len(), 3);
        assert_eq!(spaces[0].sea_maps, 2);
        assert_eq!(spaces[0].unresolved, Vec::new());

        let classes = by_claim_class(&maps, &edges);
        assert_eq!(classes[&ClaimClass::LandSea].claims, 2);
        assert_eq!(classes[&ClaimClass::SeaSea].claims, 2);
        assert_eq!(classes[&ClaimClass::LandLand].claims, 0);
        assert_eq!(classes[&ClaimClass::LandSea].unresolved, 0);
    }

    #[test]
    fn a_map_with_no_seams_is_a_region_of_one() {
        // 199 maps in the corpus are reached only by door or teleport. Leaving them out of
        // the region list would lose them; inventing a neighbour for them would be worse.
        let maps = vec![map(1, Vec::new()), map(2, Vec::new())];
        let spaces = regions(&maps, &BTreeSet::new());
        assert_eq!(spaces.len(), 2);
        assert!(spaces.iter().all(|region| region.origins.len() == 1));
        assert!(spaces.iter().all(|region| region.geometry == Geometry::Discrete));
        assert_eq!(spaces[0].origins[&1], Origin { x: 0, y: 0 });
    }

    #[test]
    fn a_whole_period_is_no_distance_on_a_torus() {
        let torus = Geometry::Torus { width: 148, height: 160 };
        assert_eq!(torus.reduce((148, 160)), (0, 0));
        assert_eq!(torus.reduce((-74, -80)), (74, 80));
        // A plane keeps every tile it is given, including negative ones.
        assert_eq!(Geometry::Plane.reduce((-1406, 74)), (-1406, 74));
        assert!(!Geometry::Plane.wraps());
        assert!(torus.wraps());
    }

    #[test]
    fn a_standard_seam_is_recognised_on_every_side() {
        let known = BTreeSet::from([1, 2]);

        // West: leaves the west band, arrives at the east band, same row.
        assert_eq!(
            classify(1, &exit(BAND_X.0, 50, 2, CORE_X.1, 50), &known),
            ExitKind::StandardSeam { side: Side::West }
        );
        assert_eq!(
            classify(1, &exit(BAND_X.1, 50, 2, CORE_X.0, 50), &known),
            ExitKind::StandardSeam { side: Side::East }
        );
        assert_eq!(
            classify(1, &exit(50, BAND_Y.0, 2, 50, CORE_Y.1), &known),
            ExitKind::StandardSeam { side: Side::North }
        );
        assert_eq!(
            classify(1, &exit(50, BAND_Y.1, 2, 50, CORE_Y.0), &known),
            ExitKind::StandardSeam { side: Side::South }
        );
    }

    #[test]
    fn an_exit_that_lands_somewhere_else_is_not_evidence_of_adjacency() {
        // The rule that stops the compiler inventing geography. All of these are perfectly
        // good exits and none of them says two maps touch.
        let known = BTreeSet::from([1, 2]);

        // Right band, wrong row: a door in the wall, not a seam.
        assert_eq!(
            classify(1, &exit(BAND_X.0, 50, 2, CORE_X.1, 20), &known),
            ExitKind::NonGeographic
        );
        // Right row, arrives mid-map: a teleport.
        assert_eq!(classify(1, &exit(BAND_X.0, 50, 2, 50, 50), &known), ExitKind::NonGeographic);
        // Not in a band at all.
        assert_eq!(classify(1, &exit(50, 50, 2, 50, 50), &known), ExitKind::NonGeographic);
        // A corner, which implies two adjacencies at once and therefore neither.
        // A corner whose arrival matches *both* patterns would be two adjacencies from
        // one exit, so it is neither.
        assert_eq!(
            classify(1, &exit(BAND_X.0, BAND_Y.0, 2, CORE_X.1, CORE_Y.1), &known),
            ExitKind::NonGeographic
        );
    }

    #[test]
    fn a_destination_outside_the_corpus_is_its_own_category() {
        // 1,196 of the corpus's exits point at nothing. Counting them as "invalid" loses
        // the distinction between data that is wrong and data that is merely not a seam.
        let known = BTreeSet::from([1, 2]);
        assert_eq!(
            classify(1, &exit(BAND_X.0, 50, 999, CORE_X.1, 50), &known),
            ExitKind::MissingDestination
        );
        assert_eq!(classify(1, &exit(BAND_X.0, 50, 1, CORE_X.1, 50), &known), ExitKind::SameMap);
    }

    #[test]
    fn the_counts_add_up() {
        // Every exit lands in exactly one category, and the valid cross-map total is the
        // sum of the two that are valid. A classifier that double-counts would make the
        // baseline meaningless in the direction that looks like progress.
        let corpus = vec![
            map(
                1,
                vec![
                    exit(BAND_X.1, 50, 2, CORE_X.0, 50),
                    exit(50, 50, 2, 40, 40),
                    exit(10, 10, 999, 1, 1),
                    exit(20, 20, 1, 30, 30),
                ],
            ),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50)]),
        ];

        let found = evidence(&corpus);
        let b = &found.baseline;

        assert_eq!(b.maps, 2);
        assert_eq!(b.exits, 5);
        assert_eq!(b.standard_seams, 2);
        assert_eq!(b.other_valid, 1);
        assert_eq!(b.same_map, 1);
        assert_eq!(b.missing_destination, 1);
        assert_eq!(b.valid_cross_map, b.standard_seams + b.other_valid);
        assert_eq!(b.exits, b.valid_cross_map + b.same_map + b.missing_destination);
    }

    #[test]
    fn two_maps_that_agree_are_a_reciprocal_pair_counted_once() {
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50)]),
        ];

        let found = evidence(&corpus);
        assert_eq!(
            found.baseline.reciprocal_placements, 1,
            "a placement was counted from both ends"
        );
        assert_eq!(found.baseline.reciprocal_pairs, 1);
        assert_eq!(found.adjacencies.len(), 2, "both directions are still recorded");
        assert_eq!(found.baseline.weak_components, 1);
    }

    #[test]
    fn one_side_claiming_two_neighbours_is_a_conflict_and_not_a_choice() {
        // Measured at zero in this corpus — every map that claims a neighbour on a side
        // claims only one — but the rule stays: picking one silently is how a compiler ends
        // up asserting a geography nobody reviewed.
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50), exit(BAND_X.1, 60, 3, CORE_X.0, 60)]),
            map(2, vec![]),
            map(3, vec![]),
        ];

        let found = evidence(&corpus);
        assert_eq!(found.baseline.contested_sides, 1);
        assert_eq!(found.conflicts[0].claims, vec![2, 3]);
        assert!(
            found.adjacencies.is_empty(),
            "a contested side was laid out anyway: {:?}",
            found.adjacencies
        );
    }

    #[test]
    fn maps_that_do_not_join_are_separate_components() {
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50)]),
            map(7, vec![]),
        ];

        assert_eq!(evidence(&corpus).baseline.weak_components, 2);
    }

    #[test]
    fn a_component_lays_out_on_integer_origins_one_core_apart() {
        // The property the whole seamless world rests on: a step across a standard seam
        // advances exactly one tile, which is only true if maps sit exactly one *core*
        // width apart on integer origins — 74 and 80, not the 100 of storage.
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50), exit(50, BAND_Y.1, 3, 50, CORE_Y.0)]),
            map(3, vec![exit(50, BAND_Y.0, 2, 50, CORE_Y.1)]),
        ];

        let found = evidence(&corpus);
        let (origins, contradictions) = lay_out(1, &found.adjacencies);

        assert_eq!(origins[&1], Origin { x: 0, y: 0 });
        assert_eq!(origins[&2], Origin { x: PITCH_X, y: 0 });
        assert_eq!(origins[&3], Origin { x: PITCH_X, y: PITCH_Y });
        assert!(contradictions.is_empty(), "{contradictions:?}");
    }

    #[test]
    fn a_cycle_that_does_not_close_is_reported_rather_than_smoothed_over() {
        // Three maps in a line whose third claims to be west of the first: the corpus is
        // then not a plane. Choosing one of the two positions would produce a world where
        // walking east three times and west once does not return you to where you were.
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50), exit(BAND_X.1, 50, 3, CORE_X.0, 50)]),
            map(
                3,
                vec![
                    exit(BAND_X.0, 50, 2, CORE_X.1, 50),
                    // 3 also claims 1 is directly east of it, which cannot be.
                    exit(BAND_X.1, 50, 1, CORE_X.0, 50),
                ],
            ),
        ];

        let found = evidence(&corpus);
        let (_, contradictions) = lay_out(1, &found.adjacencies);

        assert!(!contradictions.is_empty(), "an impossible layout was accepted");
    }

    #[test]
    fn a_corner_tile_is_in_two_bands_and_the_arrival_decides_which() {
        // Four of the corpus's seams sit on corners. Refusing them outright loses four real
        // adjacencies; accepting them without checking the arrival would invent two.
        assert_eq!(sides_of(BAND_X.0, 50), vec![Side::West]);
        assert_eq!(sides_of(50, BAND_Y.1), vec![Side::South]);
        assert_eq!(sides_of(BAND_X.0, BAND_Y.0), vec![Side::West, Side::North]);
        assert!(sides_of(50, 50).is_empty());

        let known = BTreeSet::from([1, 2]);
        // A corner exit that arrives as a west seam is a west seam.
        assert_eq!(
            classify(1, &exit(BAND_X.0, BAND_Y.0, 2, CORE_X.1, BAND_Y.0), &known),
            ExitKind::StandardSeam { side: Side::West }
        );
        // One that matches neither is neither.
        assert_eq!(
            classify(1, &exit(BAND_X.0, BAND_Y.0, 2, 50, 50), &known),
            ExitKind::NonGeographic
        );
    }

    #[test]
    fn a_loop_that_closes_produces_no_witness() {
        // The test this module was missing, and its absence let a sign error stand: a
        // square whose four seams agree is consistent, so it must yield nothing at all.
        // Without it, `cycle_witnesses` reported a contradiction for essentially every
        // non-tree edge in the corpus — 992 of them, more than the number of non-tree
        // edges — and the conclusion "no conflict-free square exists" was manufactured.
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50), exit(50, BAND_Y.1, 3, 50, CORE_Y.0)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50), exit(50, BAND_Y.1, 4, 50, CORE_Y.0)]),
            map(3, vec![exit(50, BAND_Y.0, 1, 50, CORE_Y.1), exit(BAND_X.1, 50, 4, CORE_X.0, 50)]),
            map(4, vec![exit(50, BAND_Y.0, 2, 50, CORE_Y.1), exit(BAND_X.0, 50, 3, CORE_X.1, 50)]),
        ];

        let found = evidence(&corpus);
        assert_eq!(
            found.witnesses,
            Vec::new(),
            "a square whose seams agree was reported as contradictory"
        );
        assert_eq!(found.baseline.cycle_witnesses, 0);
        assert_eq!(found.baseline.inconsistent_components, 0);
        assert_eq!(found.baseline.inconsistent_maps, 0);
    }

    #[test]
    fn a_loop_that_does_not_close_produces_exactly_one_witness_per_direction() {
        // Three maps in a row where the third also claims to be east of the first. The loop
        // is out by two core widths, which is the residual a reader acts on.
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50), exit(BAND_X.1, 50, 3, CORE_X.0, 50)]),
            map(3, vec![exit(BAND_X.0, 50, 2, CORE_X.1, 50), exit(BAND_X.1, 50, 1, CORE_X.0, 50)]),
        ];

        let found = evidence(&corpus);
        assert!(!found.witnesses.is_empty(), "an impossible loop was accepted");
        assert!(
            found.witnesses.iter().all(|witness| witness.residual != (0, 0)),
            "a witness with no residual is not a contradiction"
        );
        // Three maps in a row, and the third claims the first is one step east of it: the
        // loop is out by three core widths, because that is how far the first map would
        // have to move for the claim to hold.
        assert!(
            found.witnesses.iter().any(|w| w.residual.0.abs() == 3 * PITCH_X),
            "the residual does not name the displacement: {:?}",
            found.witnesses
        );
        assert_eq!(found.baseline.inconsistent_components, 1);
    }

    #[test]
    fn a_conflict_free_square_needs_all_four_seams_and_a_clean_component() {
        // What the MVP is built on has to be provably safe rather than probably fine: four
        // reciprocal seams that close, in maps whose positions do not depend on resolving
        // somebody else's contradiction.
        let corpus = vec![
            map(1, vec![exit(BAND_X.1, 50, 2, CORE_X.0, 50), exit(50, BAND_Y.1, 3, 50, CORE_Y.0)]),
            map(2, vec![exit(BAND_X.0, 50, 1, CORE_X.1, 50), exit(50, BAND_Y.1, 4, 50, CORE_Y.0)]),
            map(3, vec![exit(50, BAND_Y.0, 1, 50, CORE_Y.1), exit(BAND_X.1, 50, 4, CORE_X.0, 50)]),
            map(4, vec![exit(50, BAND_Y.0, 2, 50, CORE_Y.1), exit(BAND_X.0, 50, 3, CORE_X.1, 50)]),
        ];

        let found = evidence(&corpus);
        let quads = conflict_free_quads(&found);

        assert_eq!(
            quads,
            vec![Quad { north_west: 1, north_east: 2, south_west: 3, south_east: 4 }]
        );

        // One seam made one-sided and the square is no longer a candidate: a claim the
        // other map does not return is weaker evidence than the MVP should rest on.
        let mut weaker = corpus.clone();
        weaker[3].exits.retain(|exit| exit.target_map != 3);
        assert!(conflict_free_quads(&evidence(&weaker)).is_empty());
    }

    #[test]
    fn drift_names_every_field_that_moved() {
        // The failure message is the whole value of a drift check: "the baseline changed"
        // sends somebody to read 842 maps, and "standard seams: expected 156084, found
        // 156080" sends them to the four exits that stopped matching.
        // Two fields that do not participate in the exit accounting, so this case measures
        // naming alone.
        let found = Baseline { weak_components: 2, reciprocal_pairs: 3, ..BASELINE };
        let lines = drift(&BASELINE, &found);

        assert_eq!(lines.len(), 2, "{lines:?}");
        assert!(lines.iter().any(|line| line.contains("weak components") && line.contains("226")));
        assert!(lines.iter().any(|line| line.contains("reciprocal pairs")));
        assert!(drift(&BASELINE, &BASELINE).is_empty());

        // And the self-consistency guard fires on its own, without needing a pin to compare
        // against: 156,084 seams cannot become 1 while the same 158,549 exits still have a
        // shape each.
        let mangled = Baseline { standard_seams: 1, ..BASELINE };
        assert!(drift(&BASELINE, &mangled)
            .iter()
            .any(|line| line.contains("exit shapes account for")));
    }

    #[test]
    fn the_pinned_baseline_is_internally_consistent() {
        // A typo in one number would otherwise sit there looking authoritative. Every exit
        // is in exactly one category, and the valid ones are the two that are valid.
        let b = BASELINE;
        assert_eq!(b.valid_cross_map, b.standard_seams + b.other_valid);
        assert_eq!(b.exits, b.valid_cross_map + b.same_map + b.missing_destination);
        assert!(b.weak_components <= b.maps);
        assert!(b.reciprocal_components >= b.weak_components, "dropping claims cannot join groups");
        assert!(b.reciprocal_pairs <= b.reciprocal_placements, "pairs cannot exceed relationships");
    }

    #[test]
    fn the_core_sits_inside_the_bands_inside_the_storage() {
        // Stated as a test because every offset in this module depends on it, and a typo in
        // one constant would otherwise quietly reclassify thousands of exits.
        assert!(BAND_X.0 < CORE_X.0 && CORE_X.1 < BAND_X.1);
        assert!(BAND_Y.0 < CORE_Y.0 && CORE_Y.1 < BAND_Y.1);
        assert!(BAND_X.1 < STORAGE && BAND_Y.1 < STORAGE);
        assert_eq!(CORE_X.1 - CORE_X.0 + 1, 74, "the audited core is 74 wide");
        assert_eq!(CORE_Y.1 - CORE_Y.0 + 1, 80, "the audited core is 80 tall");
    }
}

#[cfg(test)]
mod shapes {
    use super::*;

    fn exit(x: u8, y: u8, target_map: u16, target_x: u8, target_y: u8) -> MapExit {
        MapExit { x, y, target_map, target_x, target_y }
    }

    #[test]
    fn a_seam_shaped_exit_on_the_wrong_line_is_offset_not_interior() {
        // The distinction that earns this type its place: an exit off by three rows is a
        // mis-typed seam and a candidate for corrected data, while an arrival in the middle
        // of the destination is a door and no correction makes it adjacency.
        let known = BTreeSet::from([1, 2]);

        assert_eq!(
            shape_of(1, &exit(BAND_X.1, 50, 2, CORE_X.0, 53), &known),
            Shape::OffsetSeam { side: Side::East, drift: 3 }
        );
        assert_eq!(
            shape_of(1, &exit(50, BAND_Y.0, 2, 47, CORE_Y.1), &known),
            Shape::OffsetSeam { side: Side::North, drift: -3 }
        );
        assert_eq!(
            shape_of(1, &exit(BAND_X.1, 50, 2, CORE_X.0, 50), &known),
            Shape::StandardSeam { side: Side::East }
        );
    }

    #[test]
    fn an_arrival_in_a_band_is_its_own_shape() {
        // Arriving on a transition band means arriving somewhere a character is not meant to
        // stand: the next step fires another exit.
        let known = BTreeSet::from([1, 2]);
        assert_eq!(shape_of(1, &exit(BAND_X.1, 50, 2, BAND_X.0, 50), &known), Shape::IntoBand);
        assert_eq!(shape_of(1, &exit(BAND_X.1, 50, 2, 50, BAND_Y.1), &known), Shape::IntoBand);
    }

    #[test]
    fn an_exit_from_inside_the_map_is_a_door_or_a_teleport_and_the_data_cannot_say_which() {
        let known = BTreeSet::from([1, 2]);
        assert_eq!(shape_of(1, &exit(50, 50, 2, 50, 50), &known), Shape::Interior);
        assert_eq!(shape_of(1, &exit(BAND_X.1, 50, 2, 40, 40), &known), Shape::BandToInterior);
    }

    #[test]
    fn the_two_shapes_that_are_not_about_geometry_come_first() {
        let known = BTreeSet::from([1, 2]);
        assert_eq!(shape_of(1, &exit(BAND_X.1, 50, 1, CORE_X.0, 50), &known), Shape::SameMap);
        assert_eq!(
            shape_of(1, &exit(BAND_X.1, 50, 999, CORE_X.0, 50), &known),
            Shape::MissingDestination
        );
    }

    #[test]
    fn shape_and_classify_agree_about_what_a_seam_is() {
        // Two functions read the same rule, so they must never disagree about the case they
        // share. `classify` feeds the pinned seam counts; `shape_of` refines what it rejects.
        let known = BTreeSet::from([1, 2]);
        for candidate in [
            exit(BAND_X.0, 50, 2, CORE_X.1, 50),
            exit(BAND_X.1, 50, 2, CORE_X.0, 50),
            exit(50, BAND_Y.0, 2, 50, CORE_Y.1),
            exit(50, BAND_Y.1, 2, 50, CORE_Y.0),
            exit(50, 50, 2, 50, 50),
            exit(BAND_X.1, 50, 2, CORE_X.0, 53),
        ] {
            let seam_by_classify =
                matches!(classify(1, &candidate, &known), ExitKind::StandardSeam { .. });
            let seam_by_shape =
                matches!(shape_of(1, &candidate, &known), Shape::StandardSeam { .. });
            assert_eq!(seam_by_classify, seam_by_shape, "disagreement about {candidate:?}");
        }
    }
}
