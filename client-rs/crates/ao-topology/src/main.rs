//! Report what the world corpus says about its own geography.
//!
//! A standalone binary rather than a test, because its output is a *document*: the audited
//! baseline the roadmap pins, recomputed from the data so drift is visible. `W-0097` calls
//! for a human-readable map, a conflict list and per-seam evidence beside the machine
//! manifest; this is the first of those, and the manifest is built on the same numbers.
//!
//! Usage: `cargo run -p ao-topology -- <pack>`

mod pixels;

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
    println!("  non-seam exits by shape:");
    println!("    seam-shaped, wrong line {}", b.offset_seams);
    println!("    into a transition band  {}", b.into_band);
    println!("    band to interior        {}", b.band_to_interior);
    println!("    from inside the map     {}", b.interior);
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

    // The assumption every tile classification rests on: the pack contains 0, 1 and 2 and
    // nothing else. Asserted against the corpus rather than trusted, because a fourth value
    // would be reclassified silently by whichever reader saw it first.
    let mut unexpected: std::collections::BTreeMap<u8, usize> = std::collections::BTreeMap::new();
    for map in &maps {
        for value in &map.tiles {
            if !ao_core::mappack::Tile::EXPECTED_VALUES.contains(value) {
                *unexpected.entry(*value).or_default() += 1;
            }
        }
    }
    println!("  unexpected tile values   {}", unexpected.len());
    for (value, count) in &unexpected {
        println!("    value {value} appears {count} times");
    }

    // Which tiles are actually part of the world. A bounding rectangle must never make a
    // void tile walkable; this says whether it does.
    let coverage = ao_core::mask::coverage(&maps);
    println!("  simulated core tiles     {}", coverage.total.simulated);
    println!("    void (no ground)       {}", coverage.total.void);
    println!("      reads as walkable    {}", coverage.total.void_walkable);
    println!("      already blocked      {}", coverage.total.void_solid);
    println!("      marked as water      {}", coverage.total.void_water);
    println!("  maps fully drawn         {} of {}", coverage.fully_drawn, maps.len());
    println!("  maps whose rectangle lies {}", coverage.lying_rectangles.len());
    for (map, count) in coverage.lying_rectangles.iter().take(6) {
        let name = maps.iter().find(|m| m.map_id == *map).map(|m| m.name.as_str()).unwrap_or("");
        println!("    map {map:<5} {count:>5} void tiles read as walkable  \"{name}\"");
    }

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

    // The other half of the cross-language contract. The unit tests assert that Rust and
    // Elixir agree on what a tile *value* means; only here, with the corpus present, can we
    // check that both are reading the same values out of the same maps.
    let semantics = ao_core::mappack::tile_semantics_fixture();
    let mut disagreements = Vec::new();
    for row in &semantics {
        if let Some(map) = maps.iter().find(|map| map.map_id == row.map_id) {
            let found = map.tile_at(row.x as i32, row.y as i32);
            if found != row.value {
                disagreements.push(format!(
                    "map {} ({}, {}): Elixir wrote {}, Rust reads {}",
                    row.map_id, row.x, row.y, row.value, found
                ));
            }
        }
    }
    println!(
        "  tile semantics fixture    {} rows, {} disagreements",
        semantics.len(),
        disagreements.len()
    );
    for line in disagreements.iter().take(5) {
        println!("    {line}");
    }

    // Seam evidence: what a character could actually do at every candidate land boundary.
    // Reported as observation, deliberately separate from any promotion decision.
    let surfaces = topology::surfaces(&maps);
    let placed: std::collections::BTreeMap<u16, topology::Origin> = found
        .regions
        .iter()
        .flat_map(|region| region.origins.iter().map(|(id, origin)| (*id, *origin)))
        .collect();
    // One atlas per region: each region's coordinates start at its own corner, so a single
    // world-wide index would call every region an overlap of every other.
    let atlases: std::collections::BTreeMap<u16, topology::Atlas> =
        found.regions.iter().map(|region| (region.id, topology::Atlas::of(region))).collect();
    let region_of: std::collections::BTreeMap<u16, u16> = found
        .regions
        .iter()
        .flat_map(|region| region.origins.keys().map(|map| (*map, region.id)))
        .collect();
    let overlapping: usize = atlases.values().map(|atlas| atlas.ambiguous_cells()).sum();
    println!("  cells claimed by two maps {overlapping}");
    let (by_class, per_seam) =
        ao_core::seam::summarise(&maps, &found.adjacencies, &found.regions, &surfaces);

    println!("  seam evidence, by what the boundary joins:");
    println!(
        "    {:<7} {:>6} {:>9} {:>8} {:>7} {:>8} {:>6} {:>8} {:>7}",
        "class", "seams", "no defect", "pairs", "foot", "boat", "wall", "1-tile!", "1-way!"
    );
    let mut totals = ao_core::seam::SeamSummary::default();
    for (class, found) in &by_class {
        println!(
            "    {:<7} {:>6} {:>9} {:>8} {:>7} {:>8} {:>6} {:>8} {:>7}",
            match class {
                ao_core::topology::ClaimClass::LandLand => "land",
                ao_core::topology::ClaimClass::SeaSea => "sea",
                ao_core::topology::ClaimClass::LandSea => "shore",
            },
            found.seams,
            found.without_defects,
            found.tile_pairs,
            found.on_foot,
            found.by_boat,
            found.blocked + found.into_solid,
            found.one_tile_failures,
            found.one_way_exits,
        );
        totals.seams += found.seams;
        totals.without_defects += found.without_defects;
        totals.tile_pairs += found.tile_pairs;
        totals.on_foot += found.on_foot;
        totals.by_boat += found.by_boat;
        totals.blocked += found.blocked;
        totals.into_solid += found.into_solid;
        totals.into_solid_with_exits += found.into_solid_with_exits;
        totals.strands_walker += found.strands_walker;
        totals.beaches_boat += found.beaches_boat;
        totals.strandings_with_exits += found.strandings_with_exits;
        totals.one_tile_failures += found.one_tile_failures;
        totals.resolution_failures += found.resolution_failures;
        totals.one_way_exits += found.one_way_exits;
        totals.continuous_at_95 += found.continuous_at_95;
    }

    // The whole-world ledger. Everything that is wrong with the map, in one place, so the
    // question "is the map good" has an answer rather than an anecdote.
    println!("\n  DEFECT LEDGER for the whole world");
    println!("    seams measured           {}", totals.seams);
    println!("      with no defect at all  {}", totals.without_defects);
    println!("    tile pairs measured      {}", totals.tile_pairs);
    println!("    -- geometry --");
    println!("    placement claims that cannot hold   {}", b.unresolved_seams);
    println!(
        "      of which land-land / shore / sea  {} / {} / {}",
        b.land_land_unresolved, b.land_sea_unresolved, b.sea_sea_unresolved
    );
    println!("    tile pairs not one tile apart       {}", totals.one_tile_failures);
    println!("    arrivals resolving to two maps      {}", totals.resolution_failures);
    println!("    -- traversal --");
    println!("    exits transferring into solid ground {}", totals.into_solid_with_exits);
    println!("    exits stranding a walker on water   {}", totals.strandings_with_exits);
    println!("    exits the other map does not return {}", totals.one_way_exits);
    println!("    boundaries beaching a boat          {} (permitted today)", totals.beaches_boat);
    println!("    -- exits --");
    println!("    exits pointing at no map            {}", b.missing_destination);
    println!("    exits targeting their own map       {}", b.same_map);
    println!("    sides claiming two neighbours       {}", b.contested_sides);

    let stranding_sites: Vec<String> = per_seam
        .iter()
        .flat_map(|found| {
            found
                .pairs
                .iter()
                .filter(|pair| {
                    pair.crossing == ao_core::seam::Crossing::StrandsWalker && pair.exit_out
                })
                .map(|pair| {
                    format!(
                        "map {} band ({}, {}) -> map {} ({}, {})",
                        found.seam.from_map,
                        pair.band.0,
                        pair.band.1,
                        found.seam.to_map,
                        pair.arrival.0,
                        pair.arrival.1
                    )
                })
                .collect::<Vec<_>>()
        })
        .collect();
    if !stranding_sites.is_empty() {
        println!("  exits that leave a walker on water, named:");
        for site in &stranding_sites {
            println!("    {site}");
        }
    }

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

    // Rendered-pixel agreement across the acceptance quad's seams. Needs the real sheets, so
    // it runs only when told where they are; everything else in this report works without
    // them.
    if let Some(index_at) = args.iter().position(|arg| arg == "--pixels") {
        match (args.get(index_at + 1), args.get(index_at + 2)) {
            (Some(sheet_dir), Some(index_path)) => {
                let json = std::fs::read_to_string(index_path).unwrap_or_default();
                let index = ao_core::grh::Index::parse(&json);
                let mut sheets = pixels::Sheets::new(sheet_dir);
                println!("\n  rendered-pixel agreement ({} regions indexed)", index.regions.len());

                let by_id: std::collections::BTreeMap<u16, &ao_core::mappack::PackedMap> =
                    maps.iter().map(|map| (map.map_id, map)).collect();
                let quad = topology::conflict_free_quads(&found);
                let Some(quad) = quad.first() else { return };

                for (from, side, to) in [
                    (quad.north_west, topology::Side::East, quad.north_east),
                    (quad.north_east, topology::Side::West, quad.north_west),
                    (quad.south_west, topology::Side::East, quad.south_east),
                    (quad.north_west, topology::Side::South, quad.south_west),
                ] {
                    let (Some(a), Some(b)) = (by_id.get(&from), by_id.get(&to)) else { continue };
                    let evidence = ao_core::seam::evidence(
                        a,
                        b,
                        side,
                        placed[&from],
                        placed[&to],
                        &atlases[&region_of[&from]],
                    );

                    // Band art against the neighbour's core edge: the gutter hypothesis, now
                    // judged on what is drawn rather than on which id is named.
                    let ground = |map: &ao_core::mappack::PackedMap, at: (u8, u8)| {
                        map.layers[0]
                            .iter()
                            .find(|tile| (tile.x, tile.y) == at)
                            .map(|tile| tile.grh)
                    };

                    let mut agreement = pixels::Agreement::default();
                    let mut same_id = 0usize;
                    for pair in &evidence.pairs {
                        let (Some(band), Some(arrival)) =
                            (ground(a, pair.band), ground(b, pair.arrival))
                        else {
                            continue;
                        };
                        if band == arrival {
                            same_id += 1;
                        }
                        agreement.add(&mut sheets, &index, band, arrival);
                    }

                    println!(
                        "    {from} {side:?} {to}: {} of {} tiles pixel-identical, {}% of pixels \
                         match, {} named the same graphic, {} undecodable",
                        agreement.identical,
                        agreement.compared(),
                        agreement.pixel_percent().map(|p| p.to_string()).unwrap_or("n/a".into()),
                        same_id,
                        agreement.unknown,
                    );
                }

                if !sheets.missing.is_empty() {
                    println!("    sheets that could not be read: {:?}", sheets.missing.keys());
                }
            }
            _ => {
                eprintln!("--pixels needs a sheet directory and an index path");
                std::process::exit(2);
            }
        }
    }

    // Every arrival the exit path currently allows and should not, plus the valid crossings
    // and permitted beachings that must keep working. This is W-0105's regression gate, and
    // it is generated from the corpus rather than hand-listed so it cannot fall behind it.
    if let Some(index) = args.iter().position(|arg| arg == "--arrivals") {
        let Some(path) = args.get(index + 1) else {
            eprintln!("--arrivals needs a path");
            std::process::exit(2);
        };

        let by_id: std::collections::BTreeMap<u16, &ao_core::mappack::PackedMap> =
            maps.iter().map(|map| (map.map_id, map)).collect();
        let mut rows: Vec<String> = Vec::new();
        let mut counts: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();

        for found in &per_seam {
            let Some(destination) = by_id.get(&found.seam.to_map) else { continue };
            for pair in &found.pairs {
                if !pair.exit_out {
                    continue;
                }

                // Classified by the *destination*, because that is what the rule is about. A
                // solid way out means nobody reaches the arrival today, but the arrival is no
                // more valid for being unreachable, and a rule that only covered reachable
                // ones would pass the whole gate and still admit the rest tomorrow.
                let locomotion = match pair.crossing {
                    ao_core::seam::Crossing::Blocked => "any",
                    ao_core::seam::Crossing::ByBoat | ao_core::seam::Crossing::BeachesBoat => {
                        "boat"
                    }
                    _ => "foot",
                };
                let arrival = ao_core::mappack::Tile::of(
                    destination.tile_at(pair.arrival.0 as i32, pair.arrival.1 as i32),
                );

                let verdict = if pair.arrival_is_void {
                    "reject void"
                } else {
                    match (arrival, locomotion) {
                        (ao_core::mappack::Tile::Solid, _) => "reject solid",
                        (ao_core::mappack::Tile::Water, "foot") => "reject water-on-foot",
                        (ao_core::mappack::Tile::Water, _) => "accept sailing",
                        (ao_core::mappack::Tile::Walkable, "boat") => "accept beaching",
                        (ao_core::mappack::Tile::Walkable, _) => "accept walking",
                    }
                };
                *counts.entry(verdict).or_default() += 1;

                let keep = verdict.starts_with("reject")
                    || counts.get(verdict).copied().unwrap_or(0) <= 40;
                if keep {
                    rows.push(format!(
                        "{} {} band {},{} to {} {},{} arrival {} drawn {} locomotion {locomotion} \
                         reachable {} -> {verdict}",
                        found.seam.from_map,
                        match found.seam.side {
                            topology::Side::West => "west",
                            topology::Side::East => "east",
                            topology::Side::North => "north",
                            topology::Side::South => "south",
                        },
                        pair.band.0,
                        pair.band.1,
                        found.seam.to_map,
                        pair.arrival.0,
                        pair.arrival.1,
                        // The rule's inputs, stated so the server test feeds them in rather
                        // than asserting the verdict against itself.
                        match arrival {
                            ao_core::mappack::Tile::Walkable => "walkable",
                            ao_core::mappack::Tile::Solid => "solid",
                            ao_core::mappack::Tile::Water => "water",
                        },
                        if pair.arrival_is_void { "no" } else { "yes" },
                        // Reachable means a character can get onto the band at all. An
                        // unreachable bad arrival is still a bad arrival; it just cannot bite
                        // until somebody clears the way out.
                        if locomotion == "any" { "no" } else { "yes" },
                    ));
                }
            }
        }
        rows.sort();

        let header = format!(
            "# Arrivals the exit path currently allows, with the verdict W-0105 must reach.\n\
             # Generated: ao-topology <pack> --arrivals <path>. Corpus {}.\n\
             # Every rejection is listed in full; acceptances are sampled at 40 per class.\n\
             # `reachable no` means the way out is solid, so nobody reaches that arrival today:\n\
             # of the solid arrivals 169 are reachable, of the void 24, and all 4 water ones.\n\
             # The rule rejects them regardless -- an arrival is not valid for being unreachable.\n\
             # Totals: {:?}\n\
             # columns: <from-map> <side> band <x,y> to <map> <x,y> arrival <class> drawn <yes|no> \n\
             #          locomotion <foot|boat|any> reachable <yes|no> -> <verdict>\n\
             # The class, drawn flag and locomotion are the rule's *inputs*; the verdict is what\n\
             # Arena.World.Arrival must return for them.\n",
            topology::CORPUS, counts
        );
        match std::fs::write(path, header + &rows.join("\n") + "\n") {
            Ok(()) => println!("\n  wrote {} arrival cases to {path}: {:?}", rows.len(), counts),
            Err(error) => {
                eprintln!("{path}: {error}");
                std::process::exit(1);
            }
        }
    }

    // Per-map exit annotations: for every exit, what the destination tile is. The server
    // needs this to judge an arrival *before* it releases a character, and it has no other
    // way to know — a MapServer holds its own map's tiles and nobody else's. Compiled in
    // here, one file per map, so the runtime does no cross-map lookup and no shared table.
    if let Some(index) = args.iter().position(|arg| arg == "--exit-annotations") {
        let Some(dir) = args.get(index + 1) else {
            eprintln!("--exit-annotations needs a directory");
            std::process::exit(2);
        };
        if let Err(error) = std::fs::create_dir_all(dir) {
            eprintln!("{dir}: {error}");
            std::process::exit(1);
        }

        // Hashed from the bytes actually read, not from the pinned corpus constant. Stamping
        // a constant would let annotations compiled from one pack claim to be from another,
        // which is the one thing the version is there to prevent.
        let input_hash = {
            let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
            for byte in &bytes {
                hash ^= *byte as u64;
                hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
            }
            format!("{hash:016x}")
        };

        let by_id: std::collections::BTreeMap<u16, &ao_core::mappack::PackedMap> =
            maps.iter().map(|map| (map.map_id, map)).collect();
        let mut written = 0usize;
        let mut annotated = 0usize;
        let mut unresolvable = 0usize;

        for map in &maps {
            let mut lines: Vec<String> = Vec::new();
            for exit in &map.exits {
                // An exit whose destination map does not exist cannot be annotated, and is
                // deliberately left out: the server fails closed on an unannotated exit,
                // which is the right answer for one that points at nothing.
                let Some(destination) = by_id.get(&exit.target_map) else {
                    unresolvable += 1;
                    continue;
                };

                let class = match ao_core::mappack::Tile::of(
                    destination.tile_at(exit.target_x as i32, exit.target_y as i32),
                ) {
                    ao_core::mappack::Tile::Walkable => "walkable",
                    ao_core::mappack::Tile::Solid => "solid",
                    ao_core::mappack::Tile::Water => "water",
                };
                let drawn = ao_core::mask::simulated_tiles(destination)
                    .contains(&(exit.target_x, exit.target_y));

                lines.push(format!(
                    "{} {} {} {} {} {class} {}",
                    exit.x,
                    exit.y,
                    exit.target_map,
                    exit.target_x,
                    exit.target_y,
                    if drawn { "drawn" } else { "undrawn" }
                ));
                annotated += 1;
            }

            lines.sort();
            let body = format!(
                "# Arrival classification for every exit of map {}.\n\
                 # version {}\n\
                 # Generated: ao-topology <pack> --exit-annotations <dir>\n\
                 # An exit absent from this file has no annotation, and the server refuses it.\n\
                 # columns: <band-x> <band-y> <dest-map> <dest-x> <dest-y> <class> <drawn|undrawn>\n{}\n",
                map.map_id,
                input_hash,
                lines.join("\n")
            );
            let path = format!("{dir}/map-{}.txt", map.map_id);
            if let Err(error) = std::fs::write(&path, body) {
                eprintln!("{path}: {error}");
                std::process::exit(1);
            }
            written += 1;
        }

        // The version the server must expect, written once beside the annotations so the two
        // cannot drift apart: they are produced by the same run from the same bytes.
        let version_path = format!("{dir}/version.txt");
        if let Err(error) = std::fs::write(&version_path, format!("{input_hash}\n")) {
            eprintln!("{version_path}: {error}");
            std::process::exit(1);
        }

        println!(
            "\n  wrote {written} exit-annotation files to {dir} at version {input_hash}: \
             {annotated} exits annotated, {unresolvable} left unannotated because their \
             destination map does not exist"
        );
    }

    // The manifest: measured evidence plus hand-recorded review, and the only place that
    // says what is allowed to be geography.
    let reviews = ao_core::manifest::reviews();
    let manifest = ao_core::manifest::build(&maps, &found, &reviews);
    println!("\n  manifest {} over corpus {}", manifest.content_hash(), manifest.corpus);
    println!("    review lines recorded  {}", reviews.len());
    for status in [
        ao_core::manifest::Status::Active,
        ao_core::manifest::Status::Reviewed,
        ao_core::manifest::Status::Candidate,
        ao_core::manifest::Status::Unresolved,
    ] {
        println!("    seams {:<11} {}", status.name(), manifest.count(status));
    }
    println!(
        "    spaces: {} of {} unresolved, {} not addressable as map + u8 x/y",
        manifest
            .spaces
            .iter()
            .filter(|space| space.status == ao_core::manifest::Status::Unresolved)
            .count(),
        manifest.spaces.len(),
        manifest.spaces.iter().filter(|space| !space.legacy_representable).count(),
    );

    let stuck: Vec<&ao_core::manifest::SpaceEntry> = manifest
        .spaces
        .iter()
        .filter(|space| space.status == ao_core::manifest::Status::Unresolved)
        .collect();
    if !stuck.is_empty() {
        println!("    unresolved spaces:");
        for space in &stuck {
            println!(
                "      space {:<5} {:>3} maps, {} claims that cannot hold, {} overlapping cells",
                space.id,
                space.origins.len(),
                space.unresolved_claims,
                space.overlapping_cells
            );
            // A space with no contradictory claim and an overlap anyway: every constraint
            // holds, and two maps still stand in the same place.
            for group in atlases[&space.id].overlaps() {
                println!("        maps sharing one cell: {group:?}");
            }
        }
    }
    let promotable: Vec<&ao_core::manifest::SeamEntry> = manifest
        .seams
        .iter()
        .filter(|entry| entry.status == ao_core::manifest::Status::Candidate)
        .collect();
    println!("    candidate seams sit in {} spaces", {
        let spaces: std::collections::BTreeSet<u16> = promotable
            .iter()
            .filter_map(|entry| region_of.get(&entry.seam.from_map).copied())
            .collect();
        spaces.len()
    });

    // What the biggest spaces need loaded. This is the input to per-region asset budgets:
    // a space that needs 12,000 graphics is a different proposition from one that needs 400.
    let mut by_weight: Vec<&ao_core::manifest::SpaceEntry> = manifest.spaces.iter().collect();
    by_weight.sort_by_key(|space| std::cmp::Reverse(space.dependencies.graphics.len()));
    println!("    heaviest spaces by graphics:");
    for space in by_weight.iter().take(5) {
        println!(
            "      space {:<5} {:>3} maps  {:>6} graphics  {:>4} npcs  {:>4} objects  {}",
            space.id,
            space.origins.len(),
            space.dependencies.graphics.len(),
            space.dependencies.npcs.len(),
            space.dependencies.objects.len(),
            space.dependencies.digest(),
        );
    }
    let lightest = by_weight.last().map(|space| space.dependencies.graphics.len()).unwrap_or(0);
    println!("      lightest space needs {lightest} graphics");

    if let Some(index) = args.iter().position(|arg| arg == "--dependencies") {
        match args.get(index + 1) {
            Some(dir) => {
                if let Err(error) = std::fs::create_dir_all(dir) {
                    eprintln!("{dir}: {error}");
                    std::process::exit(1);
                }
                for space in &manifest.spaces {
                    let path = format!("{dir}/space-{}.txt", space.id);
                    if let Err(error) = std::fs::write(&path, space.dependencies.encode()) {
                        eprintln!("{path}: {error}");
                        std::process::exit(1);
                    }
                }
                println!("    wrote {} dependency lists to {dir}", manifest.spaces.len());
            }
            None => {
                eprintln!("--dependencies needs a directory");
                std::process::exit(2);
            }
        }
    }

    if let Some(index) = args.iter().position(|arg| arg == "--manifest") {
        match args.get(index + 1) {
            Some(path) => match std::fs::write(path, manifest.encode()) {
                Ok(()) => println!("    wrote {path}"),
                Err(error) => {
                    eprintln!("{path}: {error}");
                    std::process::exit(1);
                }
            },
            None => {
                eprintln!("--manifest needs a path");
                std::process::exit(2);
            }
        }
    }

    if checking {
        // The drift gate. Exits non-zero and says which numbers moved, because "the world
        // changed" is not actionable and "standard seams: expected 156084, found 156080"
        // is — that exact line is what found the four corner seams this compiler had been
        // throwing away.
        let mut differences = topology::drift(&topology::BASELINE, b);
        differences.extend(disagreements.iter().cloned());
        for (value, count) in &unexpected {
            differences.push(format!(
                "tile value {value} appears {count} times; only {:?} are expected, and a new \
                 value changes what every reader thinks the ground is",
                ao_core::mappack::Tile::EXPECTED_VALUES
            ));
        }

        let hash = manifest.content_hash();
        if hash != ao_core::manifest::CONTENT_HASH {
            differences.push(format!(
                "manifest content hash: expected {}, found {hash}",
                ao_core::manifest::CONTENT_HASH
            ));
        }
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

    // Which squares are clean in *all eight* directed crossings, which is the only
    // standard that matters for a seamless region: a player walks both ways. The first
    // acceptance quad passes four directions and fails one of the other four, which is
    // exactly why four crossings were never four seams' worth of evidence.
    let eight_way: Vec<&topology::Quad> = quads
        .iter()
        .filter(|quad| {
            let corners = [quad.north_west, quad.north_east, quad.south_west, quad.south_east];
            if !corners.iter().all(|map| placed.contains_key(map)) {
                return false;
            }
            let by_id: std::collections::BTreeMap<u16, &ao_core::mappack::PackedMap> =
                maps.iter().map(|map| (map.map_id, map)).collect();
            [
                (quad.north_west, topology::Side::East, quad.north_east),
                (quad.south_west, topology::Side::East, quad.south_east),
                (quad.north_west, topology::Side::South, quad.south_west),
                (quad.north_east, topology::Side::South, quad.south_east),
            ]
            .iter()
            .all(|(from, side, to)| {
                [(from, side, to, false), (to, side, from, true)].iter().all(
                    |(a, side, b, flipped)| {
                        let side = if *flipped { side.opposite() } else { **side };
                        let (Some(one), Some(two)) = (by_id.get(a), by_id.get(b)) else {
                            return false;
                        };
                        let evidence = ao_core::seam::evidence(
                            one,
                            two,
                            side,
                            placed[a],
                            placed[b],
                            &atlases[&region_of[a]],
                        );
                        evidence.defects().is_empty() && evidence.accounting_closes()
                    },
                )
            })
        })
        .collect();
    println!("  squares clean in all eight directions: {} of {}", eight_way.len(), quads.len());
    for quad in eight_way.iter().take(6) {
        println!(
            "    {} {} / {} {}",
            quad.north_west, quad.north_east, quad.south_west, quad.south_east
        );
    }

    // One quad, end to end: the acceptance artifact. Every check this compiler can make,
    // for four real maps, in *both* directions across each physical seam -- eight directed
    // crossings, not four. A seam that works one way and not the other is a seam that works
    // until a player walks back.
    // Reported for a square that passes in every direction, not merely the first square
    // with reciprocal seams. `199 274 / 573 570` is the latter: four directions clean, and
    // `573 North 199` transfers two characters into solid rock.
    if let Some(quad) = eight_way.first().copied().or_else(|| {
        quads.iter().find(|quad| {
            [quad.north_west, quad.north_east, quad.south_west, quad.south_east]
                .iter()
                .all(|map| placed.contains_key(map))
        })
    }) {
        println!(
            "\n  acceptance quad {} {} / {} {}",
            quad.north_west, quad.north_east, quad.south_west, quad.south_east
        );
        let by_id: std::collections::BTreeMap<u16, &ao_core::mappack::PackedMap> =
            maps.iter().map(|map| (map.map_id, map)).collect();

        let physical = [
            (quad.north_west, topology::Side::East, quad.north_east),
            (quad.south_west, topology::Side::East, quad.south_east),
            (quad.north_west, topology::Side::South, quad.south_west),
            (quad.north_east, topology::Side::South, quad.south_east),
        ];
        let mut directed = Vec::new();
        for (from, side, to) in physical {
            directed.push((from, side, to));
            directed.push((to, side.opposite(), from));
        }

        let mut all_clean = true;
        for (from, side, to) in &directed {
            let evidence = ao_core::seam::evidence(
                by_id[from],
                by_id[to],
                *side,
                placed[from],
                placed[to],
                &atlases[&region_of[from]],
            );
            let defects = evidence.defects();
            all_clean &= defects.is_empty() && evidence.accounting_closes();
            println!(
                "    {from} {side:?} {to}: {} pairs = {} foot + {} boat + {} wall + {} strand \
                 + {} beach, gutter {}%, {}{}",
                evidence.pairs.len(),
                evidence.count(ao_core::seam::Crossing::OnFoot),
                evidence.count(ao_core::seam::Crossing::ByBoat),
                evidence.count(ao_core::seam::Crossing::Blocked),
                evidence.count(ao_core::seam::Crossing::StrandsWalker),
                evidence.count(ao_core::seam::Crossing::BeachesBoat),
                evidence
                    .gutter_continuity_over_non_solid()
                    .map(|percent| percent.to_string())
                    .unwrap_or_else(|| "n/a".to_string()),
                if defects.is_empty() { "no defects".to_string() } else { defects.join("; ") },
                if evidence.accounting_closes() { "" } else { ", ACCOUNTING DOES NOT CLOSE" },
            );
        }

        // One real route in each cardinal direction, named to the tile. The square is
        // 54/80 navigable water east-west, so "the seams are sound" is not the same claim as
        // "a person can walk through it".
        let mut routes: Vec<ao_core::walk::Step> = Vec::new();
        for (from, side, to) in &directed {
            let (Some(a), Some(b)) = (by_id.get(from), by_id.get(to)) else { continue };
            let evidence = ao_core::seam::evidence(
                a,
                b,
                *side,
                placed[from],
                placed[to],
                &atlases[&region_of[from]],
            );
            if routes.iter().any(|step| step.direction == *side) {
                continue;
            }
            if let Some(step) = ao_core::walk::first_step(&evidence, placed[from], placed[to]) {
                routes.push(step);
            }
        }
        routes.sort_by_key(|step| format!("{:?}", step.direction));
        println!("    walking routes, one per direction:");
        for step in &routes {
            println!("      {}", step.encode());
        }
        let on_foot = routes
            .iter()
            .filter(|step| step.locomotion == ao_core::walk::Locomotion::OnFoot)
            .count();
        println!(
            "      {} of {} routes are on foot; all advance one tile: {}; all hand off: {}",
            on_foot,
            routes.len(),
            routes.iter().all(|step| step.advances_one_tile()),
            routes.iter().all(|step| step.hands_off()),
        );

        if let Some(index) = args.iter().position(|arg| arg == "--walks") {
            match args.get(index + 1) {
                Some(path) => {
                    let header = format!(
                        "# One real route across each seam of {} {} / {} {}, named to the tile.\n\
                         # Regenerate: ao-topology <pack> --walks <path>\n\
                         # Feet are preferred over boats: W-0099's first slice is a person walking.\n\
                         # columns: direction locomotion from <map> <x,y> band <map> <x,y> \
                         to <map> <x,y> global <x,y> -> <x,y> authority <map> -> <map>\n",
                        quad.north_west, quad.north_east, quad.south_west, quad.south_east
                    );
                    let body: String =
                        routes.iter().map(|step| format!("{}\n", step.encode())).collect();
                    match std::fs::write(path, header + &body) {
                        Ok(()) => println!("      wrote {path}"),
                        Err(error) => {
                            eprintln!("{path}: {error}");
                            std::process::exit(1);
                        }
                    }
                }
                None => {
                    eprintln!("--walks needs a path");
                    std::process::exit(2);
                }
            }
        }

        // The pinned routes must still be the routes the corpus produces.
        let pinned = ao_core::walk::pinned_steps();
        if !pinned.is_empty() && pinned != routes {
            println!("      PINNED ROUTES DIFFER from the corpus");
            for step in &pinned {
                if !routes.contains(step) {
                    println!("        pinned but not found: {}", step.encode());
                }
            }
        }

        let corner = ao_core::seam::corner_evidence(
            (quad.north_west, placed[&quad.north_west]),
            (quad.north_east, placed[&quad.north_east]),
            (quad.south_west, placed[&quad.south_west]),
            (quad.south_east, placed[&quad.south_east]),
        );
        println!(
            "    corner: tiles {:?}, contiguous {}, distinct {}",
            corner.tiles, corner.contiguous, corner.distinct
        );

        // One walk, one tile, in all four cardinal directions, each resolved through the
        // atlas rather than by inverting the origin that produced it.
        let centre = placed[&quad.north_west];
        let mid_row = topology::CORE_Y.0 + 40;
        let mid_col = topology::CORE_X.0 + 40;
        let walks = [
            (
                "east",
                (centre.x + topology::PITCH_X, centre.y + 40),
                quad.north_east,
                (topology::CORE_X.0, mid_row),
            ),
            ("west", (centre.x - 1, centre.y + 40), quad.north_west, (topology::CORE_X.1, mid_row)),
            (
                "south",
                (centre.x + 40, centre.y + topology::PITCH_Y),
                quad.south_west,
                (mid_col, topology::CORE_Y.0),
            ),
            (
                "north",
                (centre.x + 40, centre.y - 1),
                quad.north_west,
                (mid_col, topology::CORE_Y.1),
            ),
        ];
        for (name, global, expected_map, expected_local) in walks {
            let resolved = atlases[&region_of[&quad.north_west]].resolve(global);
            let want = topology::Resolved::Unique {
                map: expected_map,
                x: expected_local.0,
                y: expected_local.1,
            };
            // West and north leave the quad, so they land on whatever the wider world has
            // there; what matters is that the answer is unique, and that it is the expected
            // map wherever the quad itself supplies the neighbour.
            println!(
                "    one walk {name:<5} -> {resolved:?}{}",
                if resolved == want { "  [as expected]" } else { "" }
            );
        }
        println!("    all eight directed crossings clean: {all_clean}");
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
