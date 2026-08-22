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

    // The world's actual shape, region by region. The counts above measure a plane; these
    // measure what the corpus is, which is not the same thing and is the more useful
    // document: a region is what gets a coordinate space, a manifest entry and an origin.
    println!("  regions                  {}", b.regions);
    println!("    that wrap              {}", b.wrapping_regions);
    println!("    unresolved seams       {}", b.unresolved_seams);
    println!("  sea maps (>=50% water)   {}", b.sea_maps);

    // Each class of claim on its own, because "the world is inconsistent" cannot say
    // whether the land, the ocean or the shore between them is the part that disagrees.
    println!("  by claim class:");
    for (class, evidence) in ao_core::topology::by_claim_class(&maps, &found.adjacencies) {
        println!(
            "    {:<10} {:>6} claims  {:>3} regions  {:>2} wrapping  {:>3} unresolved",
            match class {
                ao_core::topology::ClaimClass::LandLand => "land-land",
                ao_core::topology::ClaimClass::SeaSea => "sea-sea",
                ao_core::topology::ClaimClass::LandSea => "shore",
            },
            evidence.claims,
            evidence.components,
            evidence.wrapping,
            evidence.unresolved,
        );
    }

    let mut ranked: Vec<&topology::Region> = found.regions.iter().collect();
    ranked.sort_by_key(|region| std::cmp::Reverse(region.origins.len()));
    println!("  largest regions:");
    for region in ranked.iter().take(8) {
        let span_x = region.origins.values().map(|o| o.x).max().unwrap_or(0) / topology::PITCH_X;
        let span_y = region.origins.values().map(|o| o.y).max().unwrap_or(0) / topology::PITCH_Y;
        println!(
            "    region {:<5} {:>3} maps  {:<10} {:<28} {} x {} maps{}",
            region.id,
            region.origins.len(),
            format!("{} sea", region.sea_maps),
            match region.geometry {
                topology::Geometry::Plane => "plane".to_string(),
                topology::Geometry::Discrete => "reached only by transition".to_string(),
                topology::Geometry::Cylinder { axis, period } => {
                    format!("cylinder, {period} tiles on {axis:?}")
                }
                topology::Geometry::Torus { width, height } => {
                    format!("torus, {width} x {height} tiles")
                }
            },
            span_x + 1,
            span_y + 1,
            if region.unresolved.is_empty() {
                String::new()
            } else {
                format!("  [{} unresolved]", region.unresolved.len())
            },
        );
    }

    // Every region that still cannot be laid out, because each one needs a disposition and
    // none may be silently dropped.
    let unresolved: Vec<&topology::Region> =
        found.regions.iter().filter(|region| !region.unresolved.is_empty()).collect();
    if !unresolved.is_empty() {
        println!("  regions with unresolved seams:");
        for region in &unresolved {
            println!(
                "    region {:<5} {:>3} maps  {:<10} {} unresolved, first {:?}",
                region.id,
                region.origins.len(),
                format!("{} sea", region.sea_maps),
                region.unresolved.len(),
                region.unresolved.first().map(|edge| (edge.from_map, edge.side, edge.to_map)),
            );
        }
    }

    // Seam evidence: what a character could actually do at every candidate land boundary.
    // Reported as observation, deliberately separate from any promotion decision.
    let surfaces = topology::surfaces(&maps);
    let placed: std::collections::BTreeMap<u16, topology::Origin> = found
        .regions
        .iter()
        .flat_map(|region| region.origins.iter().map(|(id, origin)| (*id, *origin)))
        .collect();
    let (seams, per_seam) = ao_core::seam::summarise(&maps, &found.adjacencies, &placed, &surfaces);
    println!("  candidate land seams      {}", seams.land_seams);
    println!("    without defects         {}", seams.without_defects);
    println!("    tile pairs              {}", seams.tile_pairs);
    println!("      crossable on foot     {}", seams.on_foot);
    println!("      crossable by boat     {}", seams.by_boat);
    println!("      blocked               {}", seams.blocked);
    println!("      land meets water      {}", seams.medium_changes);
    println!("        with an exit        {}", seams.medium_changes_with_exits);
    println!("    not one tile apart      {}", seams.one_tile_failures);
    println!("    round-trip failures     {}", seams.round_trip_failures);
    println!("    one-way exits           {}", seams.one_way_exits);
    println!("    ground continuity >=95% {} seams", seams.continuous_at_95);
    println!("    ground continuity >=85% {} seams", seams.continuous_at_85);

    let mut worst: Vec<&ao_core::seam::SeamEvidence> =
        per_seam.iter().filter(|found| !found.defects().is_empty()).collect();
    worst.sort_by_key(|found| std::cmp::Reverse(found.defects().len()));
    if !worst.is_empty() {
        println!("  land seams with defects, worst first:");
        for found in worst.iter().take(6) {
            println!(
                "    {} {:?} {}: {}",
                found.seam.from_map,
                found.seam.side,
                found.seam.to_map,
                found.defects().join("; ")
            );
        }
    }

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
