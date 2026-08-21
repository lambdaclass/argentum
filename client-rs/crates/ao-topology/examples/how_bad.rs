//! How many maps actually have problems, and how concentrated are they?
//!
//! Kept as a reproducible diagnostic rather than a one-off script, because the answer
//! decides scheduling: whether the seamless prototype waits for map curation or not. Run
//! it with the pack path. Its findings, on corpus 17afc00c9c7e0b4c:
//!
//! - 199 of the 842 maps have no geographic neighbour at all. They are reached through
//!   doors, portals and teleports, and they are not problems — they were never part of a
//!   stitched region.
//! - 643 maps are stitched into 27 components, and 25 of those are internally consistent.
//! - The four-map component (37, 167, 168, 264) is one decision: any single one of its
//!   four placements can be withdrawn to make it consistent.
//! - The 424-map continent is the only hard case, and it is one root cause rather than
//!   many: 44 of its 46 failing loops disagree by exactly 1,406 tiles, which is 19 map
//!   widths, and every one of them passes through the bridges between the 490s region and
//!   the Ullathorpe spine. Withdrawing claims does not fix it — the two regions are joined
//!   by many bridges that disagree with each other by the same 19 columns, so the greedy
//!   search just reroutes the contradiction. That is a question about what those bridges
//!   were meant to mean, which needs per-seam tile evidence rather than a vote.
use ao_core::topology::{self, Adjacency, Side};
use std::collections::{BTreeMap, BTreeSet};

fn consistent(edges: &BTreeSet<Adjacency>) -> bool {
    topology::cycle_witnesses(edges).is_empty()
}

fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let maps = ao_core::mappack::decode_all(&bytes).unwrap();
    let found = topology::evidence(&maps);
    let known: BTreeSet<u16> = maps.iter().map(|m| m.map_id).collect();
    let of_component = topology::component_of(&known, &found.adjacencies);

    // How the 842 maps are distributed across components.
    let mut sizes: BTreeMap<u16, usize> = BTreeMap::new();
    for component in of_component.values() {
        *sizes.entry(*component).or_default() += 1;
    }
    let singletons = sizes.values().filter(|n| **n == 1).count();
    let stitched: usize = sizes.values().filter(|n| **n > 1).sum();
    println!("maps with no geographic neighbour at all: {singletons}");
    println!("maps stitched to at least one other:      {stitched}");
    println!(
        "components with more than one map:        {}",
        sizes.values().filter(|n| **n > 1).count()
    );

    // The inconsistent components, and how few edges hold the contradiction.
    let implicated: BTreeSet<u16> =
        found.witnesses.iter().flat_map(|w| w.loop_maps.iter().copied()).collect();
    let bad_components: BTreeSet<u16> =
        implicated.iter().filter_map(|m| of_component.get(m).copied()).collect();

    for component in &bad_components {
        let members: BTreeSet<u16> =
            of_component.iter().filter(|(_, c)| *c == component).map(|(m, _)| *m).collect();
        let edges: BTreeSet<Adjacency> =
            found.adjacencies.iter().filter(|e| members.contains(&e.from_map)).copied().collect();
        let here: Vec<&topology::CycleWitness> = found
            .witnesses
            .iter()
            .filter(|w| w.loop_maps.iter().any(|m| members.contains(m)))
            .collect();

        println!(
            "\ncomponent named {component}: {} maps, {} placements",
            members.len(),
            edges.len()
        );
        println!("  maps named in a failing loop: {}", implicated.intersection(&members).count());
        println!("  witnesses: {}", here.len());

        // How wide and tall is this component, laid out? If the residual equals the span,
        // the loops are not contradicting each other — they are going round the world.
        let (origins, _) = topology::lay_out(*members.iter().next().unwrap(), &edges);
        let xs: Vec<i64> = origins.values().map(|o| o.x).collect();
        let ys: Vec<i64> = origins.values().map(|o| o.y).collect();
        if let (Some(minx), Some(maxx), Some(miny), Some(maxy)) =
            (xs.iter().min(), xs.iter().max(), ys.iter().min(), ys.iter().max())
        {
            let across = (maxx - minx) / topology::PITCH_X + 1;
            let down = (maxy - miny) / topology::PITCH_Y + 1;
            println!(
                "  laid out span: {across} maps across ({} tiles), {down} maps down ({} tiles)",
                maxx - minx + topology::PITCH_X,
                maxy - miny + topology::PITCH_Y
            );
        }

        let mut residuals: BTreeMap<(i64, i64), usize> = BTreeMap::new();
        for w in &here {
            *residuals.entry(w.residual).or_default() += 1;
        }
        println!("  residuals: {residuals:?}");

        // The loops behind the commonest residual: where the continent disagrees.
        let worst = residuals.iter().max_by_key(|(_, n)| **n).map(|(r, _)| *r);
        if let Some(worst) = worst {
            let mut shown = 0;
            for w in here.iter().filter(|w| w.residual == worst) {
                if shown >= 3 {
                    break;
                }
                shown += 1;
                println!(
                    "    loop out by {:?} ({} maps): {:?}",
                    w.residual,
                    w.loop_maps.len() - 1,
                    w.loop_maps
                );
            }
        }

        // Which single placements, if withdrawn, make the whole component consistent?
        let undirected: BTreeSet<(u16, u16)> =
            edges.iter().map(|e| (e.from_map.min(e.to_map), e.from_map.max(e.to_map))).collect();
        let mut single_fixes = Vec::new();
        for pair in &undirected {
            let kept: BTreeSet<Adjacency> = edges
                .iter()
                .filter(|e| (e.from_map.min(e.to_map), e.from_map.max(e.to_map)) != *pair)
                .copied()
                .collect();
            if consistent(&kept) {
                single_fixes.push(*pair);
            }
        }
        println!("  single placements whose withdrawal fixes it: {}", single_fixes.len());
        for pair in single_fixes.iter().take(10) {
            let side = edges
                .iter()
                .find(|e| (e.from_map.min(e.to_map), e.from_map.max(e.to_map)) == *pair)
                .map(|e| e.side)
                .unwrap_or(Side::West);
            println!("    {} <-> {} ({side:?})", pair.0, pair.1);
        }

        // Greedy: withdraw the placement that appears in the most failing loops, and
        // repeat. Answers "how many decisions is this" rather than "how many edges are
        // implicated".
        if single_fixes.is_empty() {
            let mut kept = edges.clone();
            let mut withdrawn: Vec<(u16, u16)> = Vec::new();
            for _ in 0..12 {
                let witnesses = topology::cycle_witnesses(&kept);
                if witnesses.is_empty() {
                    break;
                }
                let mut appearances: BTreeMap<(u16, u16), usize> = BTreeMap::new();
                for w in &witnesses {
                    for pair in w.loop_maps.windows(2) {
                        let key = (pair[0].min(pair[1]), pair[0].max(pair[1]));
                        *appearances.entry(key).or_default() += 1;
                    }
                }
                let Some((worst, count)) = appearances.into_iter().max_by_key(|(_, n)| *n) else {
                    break;
                };
                withdrawn.push(worst);
                println!(
                    "    withdraw {} <-> {} (in {count} loops), {} loops left",
                    worst.0,
                    worst.1,
                    witnesses.len()
                );
                kept.retain(|e| (e.from_map.min(e.to_map), e.from_map.max(e.to_map)) != worst);
            }
            println!(
                "  greedy: {} withdrawals leave {} loops",
                withdrawn.len(),
                topology::cycle_witnesses(&kept).len()
            );
        }

        if false {
            // Try pairs, greedily: the cheapest disposition may be two claims.
            let candidates: Vec<(u16, u16)> = undirected.iter().copied().collect();
            let mut found_pair = None;
            'outer: for (i, a) in candidates.iter().enumerate() {
                for b in candidates.iter().skip(i + 1) {
                    let kept: BTreeSet<Adjacency> = edges
                        .iter()
                        .filter(|e| {
                            let key = (e.from_map.min(e.to_map), e.from_map.max(e.to_map));
                            key != *a && key != *b
                        })
                        .copied()
                        .collect();
                    if consistent(&kept) {
                        found_pair = Some((*a, *b));
                        break 'outer;
                    }
                }
            }
            match found_pair {
                Some((a, b)) => println!("  two withdrawals suffice: {a:?} and {b:?}"),
                None => println!("  no single or paired withdrawal fixes it"),
            }
        }
    }
}
