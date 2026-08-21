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

use crate::mappack::{MapExit, PackedMap};
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
    /// Maps inside an inconsistent component.
    pub inconsistent_maps: usize,
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
    cycle_witnesses: 992,
    conflict_clusters: 9,
    inconsistent_maps: 428,
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

    let tainted = inconsistent_maps(&adjacencies, &constraint_conflicts);
    baseline.inconsistent_maps = tainted.len();
    baseline.inconsistent_components = components(&tainted, &adjacencies)
        - tainted
            .iter()
            .filter(|map| !adjacencies.iter().any(|e| e.from_map == **map || e.to_map == **map))
            .count();

    Evidence {
        baseline,
        adjacencies,
        conflicts,
        constraint_conflicts,
        witnesses,
        inconsistent: tainted,
    }
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
        let total = (mine.0 + up.0, mine.1 + up.1);

        // Path compression, so a long chain is walked once rather than once per query.
        self.parent.insert(map, root);
        self.delta.insert(map, total);
        (root, total)
    }

    /// Record that `to` sits `delta` from `from`. Returns a conflict if that cannot hold.
    fn constrain(&mut self, from: u16, to: u16, delta: (i64, i64)) -> Option<ConstraintConflict> {
        let (from_root, from_off) = self.find(from);
        let (to_root, to_off) = self.find(to);

        if from_root == to_root {
            // Both already placed relative to the same root, so the answer is already
            // known: either this constraint agrees with it or the corpus contradicts
            // itself here.
            let established = (to_off.0 - from_off.0, to_off.1 - from_off.1);
            if established == delta {
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
        let root_delta = (from_off.0 + delta.0 - to_off.0, from_off.1 + delta.1 - to_off.1);
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
    let mut tree_edges: BTreeSet<(u16, u16)> = BTreeSet::new();

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
                tree_edges.insert((map.min(next), map.max(next)));
                queue.push_back(next);
            }
        }
    }

    // Offset from each map to its root, by walking the tree.
    let offset_to_root = |mut map: u16| {
        let mut total = (0i64, 0i64);
        while let Some((up, delta)) = parent.get(&map).copied() {
            total = (total.0 - delta.0, total.1 - delta.1);
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
        let key = (edge.from_map.min(edge.to_map), edge.from_map.max(edge.to_map));
        if tree_edges.contains(&key) {
            continue;
        }

        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);

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
    fn drift_names_every_field_that_moved() {
        // The failure message is the whole value of a drift check: "the baseline changed"
        // sends somebody to read 842 maps, and "standard seams: expected 156084, found
        // 156080" sends them to the four exits that stopped matching.
        let found = Baseline { standard_seams: 1, weak_components: 2, ..BASELINE };
        let lines = drift(&BASELINE, &found);

        assert_eq!(lines.len(), 2, "{lines:?}");
        assert!(lines
            .iter()
            .any(|line| line.contains("standard seams") && line.contains("156084")));
        assert!(lines.iter().any(|line| line.contains("weak components")));
        assert!(drift(&BASELINE, &BASELINE).is_empty());
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
