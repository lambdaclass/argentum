//! Report what the world corpus says about its own geography.
//!
//! A standalone binary rather than a test, because its output is a *document*: the audited
//! baseline the roadmap pins, recomputed from the data so drift is visible. `W-0097` calls
//! for a human-readable map, a conflict list and per-seam evidence beside the machine
//! manifest; this is the first of those, and the manifest is built on the same numbers.
//!
//! Usage: `cargo run -p ao-topology -- <pack>`

use ao_core::topology;
use std::collections::BTreeMap;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let checking = args.iter().any(|arg| arg == "--check");
    let Some(path) = args.iter().find(|arg| !arg.starts_with("--")).cloned() else {
        eprintln!("usage: ao-topology [--check] <maps.pack>");
        std::process::exit(2);
    };

    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("{path}: {error}");
            std::process::exit(1);
        }
    };

    let maps = match ao_core::mappack::decode_all(&bytes) {
        Ok(maps) => maps,
        Err(error) => {
            eprintln!("{path}: {error:?}");
            std::process::exit(1);
        }
    };

    let found = topology::evidence(&maps);
    let b = &found.baseline;

    println!("corpus: {}", path);
    println!("  maps                     {}", b.maps);
    println!("  exits                    {}", b.exits);
    println!("  valid cross-map          {}", b.valid_cross_map);
    println!("    standard seams         {}", b.standard_seams);
    println!("    other valid            {}", b.other_valid);
    println!("  same-map                 {}", b.same_map);
    println!("  missing destination      {}", b.missing_destination);
    println!("  reciprocal placements    {}", b.reciprocal_placements);
    println!("  unique reciprocal pairs  {}", b.reciprocal_pairs);
    println!("  one-sided placements     {}", b.one_sided_placements);
    println!("  contested sides          {}", b.contested_sides);
    println!("  weak components          {}", b.weak_components);
    println!("  reciprocal-only comps    {}", b.reciprocal_components);
    println!("  inconsistent components  {}", b.inconsistent_components);
    println!("  cycle witnesses          {}", b.cycle_witnesses);
    println!("  conflict clusters        {}", b.conflict_clusters);
    println!("  inconsistent maps        {}", b.inconsistent_maps);
    println!(
        "  (blamed constraints      {}, algorithm-dependent)",
        found.constraint_conflicts.len()
    );

    // The largest components, because that is what a first seamless region is chosen from.
    let mut sizes: BTreeMap<u16, usize> = BTreeMap::new();
    let mut seen = std::collections::BTreeSet::new();
    for map in &maps {
        if seen.contains(&map.map_id) {
            continue;
        }
        let (origins, contradictions) = topology::lay_out(map.map_id, &found.adjacencies);
        for id in origins.keys() {
            seen.insert(*id);
        }
        if origins.len() > 1 {
            sizes.insert(map.map_id, origins.len());
            if !contradictions.is_empty() {
                println!(
                    "  component from map {:<5} {} maps, {} layout contradictions",
                    map.map_id,
                    origins.len(),
                    contradictions.len()
                );
            }
        }
    }

    let mut largest: Vec<(u16, usize)> = sizes.into_iter().collect();
    largest.sort_by_key(|(_, size)| std::cmp::Reverse(*size));
    println!("  largest components:");
    for (root, size) in largest.iter().take(8) {
        println!("    from map {root:<5} {size} maps");
    }

    if checking {
        // The drift gate. Exits non-zero and says which numbers moved, because "the world
        // changed" is not actionable and "standard seams: expected 156084, found 156080"
        // is — that exact line is what found the four corner seams this compiler had been
        // throwing away.
        let differences = topology::drift(&topology::BASELINE, b);
        if differences.is_empty() {
            println!("  baseline: matches the pinned corpus {}", topology::CORPUS);
        } else {
            eprintln!("\nthe corpus no longer matches its pinned baseline:");
            for line in &differences {
                eprintln!("  {line}");
            }
            eprintln!(
                "\nIf the world data changed on purpose, update ao_core::topology::BASELINE\n\
                 and say in the commit which numbers moved and why."
            );
            std::process::exit(1);
        }
    }

    // What the seamless-world MVP can be built on today.
    let quads = topology::conflict_free_quads(&found);
    println!("  conflict-free 2x2 squares {}", quads.len());
    for quad in quads.iter().take(6) {
        println!(
            "    {} {} / {} {}",
            quad.north_west, quad.north_east, quad.south_west, quad.south_east
        );
    }

    // The review unit: clusters, with the loops that prove them, smallest first — a
    // three-map loop out by 74 tiles is a root cause somebody can act on this afternoon.
    let clusters = topology::conflict_clusters(&found.witnesses);
    if !clusters.is_empty() {
        println!("  conflict clusters, smallest first:");
        let mut ordered: Vec<&std::collections::BTreeSet<u16>> = clusters.iter().collect();
        ordered.sort_by_key(|cluster| cluster.len());
        for cluster in ordered.iter().take(6) {
            let sample: Vec<String> = cluster.iter().take(8).map(|map| map.to_string()).collect();
            println!(
                "    {} maps: {}{}",
                cluster.len(),
                sample.join(", "),
                if cluster.len() > 8 { ", ..." } else { "" }
            );
        }

        println!("  shortest loops that do not close:");
        let mut loops = found.witnesses.clone();
        loops.sort_by_key(|witness| witness.loop_maps.len());
        for witness in loops.iter().take(6) {
            println!("    {:?} out by {:?}", witness.loop_maps, witness.residual);
        }
    }

    if !found.conflicts.is_empty() {
        println!("  first placement conflicts:");
        for conflict in found.conflicts.iter().take(8) {
            println!(
                "    map {:<5} {:?} claims {:?}",
                conflict.map, conflict.side, conflict.claims
            );
        }
    }
}
