//! What shape is the world, and which maps are actually wrong?
//!
//! `how_bad.rs` measured the corpus as a *plane* and reported that the 424-map continent
//! disagrees with itself by 1,406 tiles — 19 map widths — through loops that no single or
//! paired withdrawal repairs. Then the four-map component's claims were printed in full,
//! and every one of them was doubled with its opposite: map 37 has 168 to its West *and*
//! to its East, and 264 to its North *and* to its South. Those four maps are not
//! contradictory. They are a 2x2 world that loops in both directions, and a plane is the
//! wrong shape to judge it with.
//!
//! So this asks three questions of every inconsistent component, in order, and stops at the
//! first that holds:
//!
//! 1. Is it consistent as a plane?
//! 2. Is it consistent as a cylinder or a torus — a plane quotiented by a period, where
//!    positions are equal when they differ by a whole number of periods? A candidate period
//!    is only admissible if the component still *fits*: no two maps may land on the same
//!    cell. Without that test a small period always wins by collapsing the world onto
//!    itself, which is how "wraps every 2 maps" came to explain 424 maps in 44 cells.
//! 3. Is it consistent once the open water is set aside? The disputed bridges out of the
//!    continent run from coastline into maps that are 90-99% blocked and named "Alta Mar"
//!    and "Mar este del desierto" — sea tiles, reachable by boat, authored as their own
//!    strip rather than as a geographically consistent surround. Water is identified by
//!    measuring the blocked fraction, not by reading names.
//!
//! Nothing here is assumed. A period that does not explain the loops, or does not fit, is
//! rejected and reported as rejected.
//!
//! Usage: `cargo run -p ao-topology --example wrap -- <pack>`

use ao_core::mappack::PackedMap;
use ao_core::topology::{self, Adjacency, PITCH_X, PITCH_Y};
use std::collections::{BTreeMap, BTreeSet};

/// A map this full of blocked tiles has no land to walk on: it is open water, crossed by
/// boat. Measured, so the threshold is visible and arguable rather than hidden in a name
/// match. 95% keeps islands (84% on this corpus) and takes the sea (90% and 99%).
const WATER_BLOCKED_PERCENT: usize = 95;

/// A position on a cylinder, a torus, or a plane, depending on the periods.
///
/// `0` means "does not wrap on this axis", where equality is exact. Anything else is a
/// modulus. Reducing every offset the same way is what makes the quotient a consistent
/// arithmetic rather than a special case bolted onto the planar test.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Period {
    x: i64,
    y: i64,
}

impl Period {
    const PLANE: Period = Period { x: 0, y: 0 };

    fn reduce(&self, offset: (i64, i64)) -> (i64, i64) {
        let axis =
            |value: i64, period: i64| if period == 0 { value } else { value.rem_euclid(period) };
        (axis(offset.0, self.x), axis(offset.1, self.y))
    }

    fn describe(&self) -> String {
        match (self.x, self.y) {
            (0, 0) => "plane".to_string(),
            (x, 0) => format!("cylinder wrapping every {x} tiles east-west ({} maps)", x / PITCH_X),
            (0, y) => {
                format!("cylinder wrapping every {y} tiles north-south ({} maps)", y / PITCH_Y)
            }
            (x, y) => format!("torus of {x} x {y} tiles ({} x {} maps)", x / PITCH_X, y / PITCH_Y),
        }
    }
}

/// Weighted union-find over a quotient of the plane.
///
/// The same accumulation as `topology::Offsets`, with every offset reduced by the period
/// before it is stored or compared. With `Period::PLANE` this is exactly the planar test,
/// which is what keeps the comparison honest: one implementation, every geometry.
#[derive(Debug)]
struct Quotient {
    period: Period,
    parent: BTreeMap<u16, u16>,
    delta: BTreeMap<u16, (i64, i64)>,
}

impl Quotient {
    fn new(period: Period) -> Self {
        Quotient { period, parent: BTreeMap::new(), delta: BTreeMap::new() }
    }

    fn find(&mut self, map: u16) -> (u16, (i64, i64)) {
        let parent = *self.parent.entry(map).or_insert(map);
        if parent == map {
            return (map, (0, 0));
        }
        let (root, up) = self.find(parent);
        let mine = self.delta.get(&map).copied().unwrap_or((0, 0));
        let total = self.period.reduce((mine.0 + up.0, mine.1 + up.1));
        self.parent.insert(map, root);
        self.delta.insert(map, total);
        (root, total)
    }

    /// Returns the residual if this claim cannot hold in the quotient.
    fn constrain(&mut self, from: u16, to: u16, delta: (i64, i64)) -> Option<(i64, i64)> {
        let (from_root, from_off) = self.find(from);
        let (to_root, to_off) = self.find(to);
        let delta = self.period.reduce(delta);

        if from_root == to_root {
            let established = (to_off.0 - from_off.0, to_off.1 - from_off.1);
            let residual = self.period.reduce((established.0 - delta.0, established.1 - delta.1));
            // In the quotient, "closed" means the reduced residual is zero. On the plane
            // `reduce` is the identity, so this is the ordinary test.
            return if residual == (0, 0) { None } else { Some(residual) };
        }

        let root_delta =
            self.period.reduce((from_off.0 + delta.0 - to_off.0, from_off.1 + delta.1 - to_off.1));
        self.parent.insert(to_root, from_root);
        self.delta.insert(to_root, root_delta);
        None
    }

    /// The grid the component occupies here, and how many maps share a cell with another.
    ///
    /// A wrap that is real also *fits*: on a cylinder of 19 map widths, 424 maps cannot
    /// occupy 19 x 22 cells without two of them standing in the same place. Collisions are
    /// what disqualifies a period that merely divides the residuals.
    fn shape(&mut self, maps: &BTreeSet<u16>) -> (usize, usize, usize) {
        let mut cells: BTreeMap<(i64, i64), usize> = BTreeMap::new();
        let mut columns = BTreeSet::new();
        let mut rows = BTreeSet::new();
        for map in maps {
            let (_, offset) = self.find(*map);
            let cell = (offset.0.div_euclid(PITCH_X), offset.1.div_euclid(PITCH_Y));
            columns.insert(cell.0);
            rows.insert(cell.1);
            *cells.entry(cell).or_default() += 1;
        }
        let shared = cells.values().filter(|count| **count > 1).map(|count| *count).sum::<usize>();
        (columns.len(), rows.len(), shared)
    }
}

/// Apply every claim in order, collecting what does not fit.
fn test(period: Period, edges: &[Adjacency]) -> (Quotient, Vec<((u16, u16), (i64, i64))>) {
    let mut quotient = Quotient::new(period);
    let mut failures = Vec::new();
    for edge in edges {
        let (dx, dy) = edge.side.step();
        let delta = (dx as i64 * PITCH_X, dy as i64 * PITCH_Y);
        if let Some(residual) = quotient.constrain(edge.from_map, edge.to_map, delta) {
            failures.push(((edge.from_map, edge.to_map), residual));
        }
    }
    (quotient, failures)
}

/// The geometry that explains a group of maps, or the plane if none does.
///
/// Periods are drawn from the magnitudes of the group's own failing loops — the corpus
/// names its own candidates, rather than being tried against a guess — and any period that
/// puts two maps in one cell is rejected.
fn best_geometry(
    edges: &[Adjacency],
    members: &BTreeSet<u16>,
) -> (Period, Vec<((u16, u16), (i64, i64))>, (usize, usize, usize)) {
    let (mut quotient, planar) = test(Period::PLANE, edges);
    let planar_shape = quotient.shape(members);
    if planar.is_empty() {
        return (Period::PLANE, planar, planar_shape);
    }

    let xs: BTreeSet<i64> = planar.iter().map(|(_, r)| r.0.abs()).filter(|v| *v > 0).collect();
    let ys: BTreeSet<i64> = planar.iter().map(|(_, r)| r.1.abs()).filter(|v| *v > 0).collect();
    let mut candidates = BTreeSet::new();
    for x in std::iter::once(0).chain(xs) {
        for y in std::iter::once(0).chain(ys.iter().copied()) {
            candidates.insert(Period { x, y });
        }
    }

    let mut best = (Period::PLANE, planar, planar_shape);
    for candidate in candidates {
        if candidate == Period::PLANE {
            continue;
        }
        let (mut quotient, failures) = test(candidate, edges);
        let shape = quotient.shape(members);
        // Admissible first, then fewest unexplained claims, then the smallest world.
        if shape.2 == 0 && failures.len() < best.1.len() {
            best = (candidate, failures, shape);
        }
    }
    best
}

fn report(label: &str, edges: &[Adjacency], members: &BTreeSet<u16>) -> usize {
    let (period, failures, shape) = best_geometry(edges, members);
    println!(
        "{label}: {} maps, {} claims -> {} as {} ({} x {} maps{})",
        members.len(),
        edges.len(),
        if failures.is_empty() {
            "consistent".to_string()
        } else {
            format!("{} claims fail", failures.len())
        },
        period.describe(),
        shape.0,
        shape.1,
        if shape.2 == 0 { String::new() } else { format!(", {} maps overlapping", shape.2) },
    );
    for ((from, to), residual) in failures.iter().take(4) {
        println!("    {from} <-> {to} out by {residual:?}");
    }
    failures.len()
}

/// Split a set of claims into connected groups, so removing maps reports each piece.
fn group(edges: &[Adjacency]) -> BTreeMap<u16, (Vec<Adjacency>, BTreeSet<u16>)> {
    let mut ids = BTreeSet::new();
    let mut adjacencies = BTreeSet::new();
    for edge in edges {
        ids.insert(edge.from_map);
        ids.insert(edge.to_map);
        adjacencies.insert(*edge);
    }
    let component = topology::component_of(&ids, &adjacencies);

    let mut grouped: BTreeMap<u16, (Vec<Adjacency>, BTreeSet<u16>)> = BTreeMap::new();
    for edge in edges {
        let entry = grouped.entry(component[&edge.from_map]).or_default();
        entry.0.push(*edge);
        entry.1.insert(edge.from_map);
        entry.1.insert(edge.to_map);
    }
    grouped
}

fn main() {
    let pack = std::env::args().nth(1).expect("pack path");
    let bytes = std::fs::read(&pack).expect("read pack");
    let decoded = ao_core::mappack::decode_all(&bytes).expect("decode");
    let found = topology::evidence(&decoded);
    let by_id: BTreeMap<u16, &PackedMap> = decoded.iter().map(|m| (m.map_id, m)).collect();

    let blocked_percent = |map: &PackedMap| {
        map.tiles.iter().filter(|t| **t != 0).count() * 100 / map.tiles.len().max(1)
    };
    let water: BTreeSet<u16> = decoded
        .iter()
        .filter(|map| blocked_percent(map) >= WATER_BLOCKED_PERCENT)
        .map(|map| map.map_id)
        .collect();
    println!(
        "{} of {} maps are at least {WATER_BLOCKED_PERCENT}% blocked (open water)\n",
        water.len(),
        decoded.len()
    );

    let mut planar_failures = 0;
    let mut explained = 0;
    let mut remaining = 0;

    for (name, (edges, members)) in group(&found.adjacencies.iter().copied().collect::<Vec<_>>()) {
        let (_, planar) = test(Period::PLANE, &edges);
        if planar.is_empty() {
            continue;
        }
        planar_failures += planar.len();

        let left = report(&format!("component {name}"), &edges, &members);
        if left == 0 {
            explained += planar.len();
            println!();
            continue;
        }

        // Still inconsistent: set the open water aside and ask again. The continent and the
        // sea can each be internally consistent while no single plane holds both.
        let dry: Vec<Adjacency> = edges
            .iter()
            .copied()
            .filter(|e| !water.contains(&e.from_map) && !water.contains(&e.to_map))
            .collect();
        let removed = members.iter().filter(|m| water.contains(m)).count();
        println!("  without its {removed} open-water maps:");
        let mut worst = 0;
        for (piece, (piece_edges, piece_members)) in group(&dry) {
            worst += report(&format!("    piece {piece}"), &piece_edges, &piece_members);
        }
        remaining += worst;
        println!();
    }

    println!("planar model: {planar_failures} failing claims across the corpus");
    println!("explained by a wrap: {explained}");
    println!("still failing after water is set aside: {remaining}");

    println!("\nsurface of the maps in the renders:");
    for id in [199u16, 274, 573, 570, 37, 167, 168, 264, 10, 495, 17, 103] {
        let Some(map) = by_id.get(&id) else { continue };
        println!(
            "  map {id:>4} \"{}\": {:>3}% blocked, {} exits{}",
            map.name,
            blocked_percent(map),
            map.exits.len(),
            if water.contains(&id) { ", open water" } else { "" },
        );
    }
}
