//! Draw the world's tiles, so a placement can be judged by looking at it.
//!
//! Counts say a seam is standard; only the ground says whether two maps belong side by
//! side. One pixel per tile: pale where a character can walk, dark where the map blocks,
//! near-black where the map has no ground at all, and a line on every map's edge so seams
//! are visible rather than guessed.
//!
//! Five pictures, each answering a question that a number cannot:
//!
//! - `continent.png` — the largest run of maps that agree with each other, laid out from the
//!   seams alone. Nothing here is authored by hand: if the coastlines and roads line up
//!   across map boundaries, the 74 x 80 pitch and the band-to-core-edge seam rule are right.
//! - `agreement-*.png` — a 2x2 square of it, close enough to see a seam not interrupting the
//!   ground.
//! - `dungeon-torus.png` — the four Newbie Dungeon maps, whose claims are each doubled with
//!   their opposite: 37 has 168 to its West *and* East. That is a 2x2 world that loops, and
//!   `wrap.rs` confirms it closes exactly as a 148 x 160 torus.
//! - `bridge-*.png` — a coastline map beside the open-sea map it claims as a neighbour. The
//!   sea is a single blocked expanse authored as its own strip, which is why no plane holds
//!   both it and the coast it is bolted onto.
//!
//! Usage: `cargo run -p ao-topology --example render -- <pack> <out-dir>`

use ao_core::mappack::PackedMap;
use ao_core::topology::{self, Adjacency, Origin, CORE_X, CORE_Y, PITCH_X, PITCH_Y};
use image::{Rgb, RgbImage};
use std::collections::{BTreeMap, BTreeSet};

/// Matches `wrap.rs`: a map this blocked has no land to walk on, so it is open water.
const WATER_BLOCKED_PERCENT: usize = 95;

const WALKABLE: Rgb<u8> = Rgb([214, 205, 178]);
const BLOCKED: Rgb<u8> = Rgb([44, 38, 30]);
const VOID: Rgb<u8> = Rgb([12, 12, 16]);
const EDGE: Rgb<u8> = Rgb([120, 96, 48]);
const GHOST: Rgb<u8> = Rgb([90, 150, 200]);
const NOTHING: Rgb<u8> = Rgb([6, 6, 9]);

/// Draw one map's core into `image` at `origin`, tinted if it is there to be told apart.
fn draw_map(
    image: &mut RgbImage,
    map: &PackedMap,
    origin: Origin,
    min: (i64, i64),
    tint: Option<Rgb<u8>>,
) {
    // A map with no ground graphic on a tile has nothing there at all — the difference
    // between a dungeon's surrounding rock and its unreachable outside.
    let ground: BTreeSet<(u8, u8)> = map.layers[0].iter().map(|t| (t.x, t.y)).collect();

    for y in CORE_Y.0..=CORE_Y.1 {
        for x in CORE_X.0..=CORE_X.1 {
            let px = origin.x + (x - CORE_X.0) as i64 - min.0;
            let py = origin.y + (y - CORE_Y.0) as i64 - min.1;
            if px < 0 || py < 0 || px >= image.width() as i64 || py >= image.height() as i64 {
                continue;
            }

            let base = if !ground.contains(&(x, y)) {
                VOID
            } else if map.tile_at(x as i32, y as i32) != 0 {
                BLOCKED
            } else {
                WALKABLE
            };
            let colour = match tint {
                // Tinted, not replaced: the map's own shape stays readable, because it is
                // the shape that decides whether the placement is believable.
                Some(tint) => Rgb([
                    ((base.0[0] as u16 * 2 + tint.0[0] as u16) / 3) as u8,
                    ((base.0[1] as u16 * 2 + tint.0[1] as u16) / 3) as u8,
                    ((base.0[2] as u16 * 2 + tint.0[2] as u16) / 3) as u8,
                ]),
                None => base,
            };

            let on_edge = x == CORE_X.0 || x == CORE_X.1 || y == CORE_Y.0 || y == CORE_Y.1;
            image.put_pixel(px as u32, py as u32, if on_edge { EDGE } else { colour });
        }
    }
}

fn render(
    path: &str,
    maps: &BTreeMap<u16, &PackedMap>,
    placements: &[(u16, Origin, Option<Rgb<u8>>)],
) {
    let minx = placements.iter().map(|(_, o, _)| o.x).min().unwrap_or(0);
    let miny = placements.iter().map(|(_, o, _)| o.y).min().unwrap_or(0);
    let maxx = placements.iter().map(|(_, o, _)| o.x).max().unwrap_or(0) + PITCH_X;
    let maxy = placements.iter().map(|(_, o, _)| o.y).max().unwrap_or(0) + PITCH_Y;

    let mut image = RgbImage::from_pixel((maxx - minx) as u32, (maxy - miny) as u32, NOTHING);
    for (id, origin, tint) in placements {
        if let Some(map) = maps.get(id) {
            draw_map(&mut image, map, *origin, (minx, miny), *tint);
        }
    }

    image.save(path).expect("write png");
    println!("  wrote {path} ({}x{} tiles)", image.width(), image.height());
}

fn main() {
    let mut args = std::env::args().skip(1);
    let pack = args.next().expect("pack path");
    let out = args.next().unwrap_or_else(|| ".".to_string());
    std::fs::create_dir_all(&out).expect("out dir");

    let bytes = std::fs::read(&pack).expect("read pack");
    let decoded = ao_core::mappack::decode_all(&bytes).expect("decode");
    let maps: BTreeMap<u16, &PackedMap> = decoded.iter().map(|m| (m.map_id, m)).collect();
    let found = topology::evidence(&decoded);

    let water: BTreeSet<u16> = decoded
        .iter()
        .filter(|map| {
            map.tiles.iter().filter(|t| **t != 0).count() * 100 / map.tiles.len().max(1)
                >= WATER_BLOCKED_PERCENT
        })
        .map(|map| map.map_id)
        .collect();

    // The land, with the open sea set aside. `wrap.rs` measures every piece of this as
    // internally consistent, so laying it out should produce a coherent picture — and if it
    // does not, the seam model is wrong no matter what the counts say.
    let dry: BTreeSet<Adjacency> = found
        .adjacencies
        .iter()
        .copied()
        .filter(|e| !water.contains(&e.from_map) && !water.contains(&e.to_map))
        .collect();
    let dry_ids: BTreeSet<u16> = dry.iter().flat_map(|e| [e.from_map, e.to_map]).collect();
    let component = topology::component_of(&dry_ids, &dry);
    let mut sizes: BTreeMap<u16, usize> = BTreeMap::new();
    for name in component.values() {
        *sizes.entry(*name).or_default() += 1;
    }
    let largest = sizes.iter().max_by_key(|(_, size)| **size).map(|(name, _)| *name).unwrap_or(1);

    let (origins, contradictions) = topology::lay_out(largest, &dry);
    println!(
        "continent from map {largest}: {} maps placed, {} contradicting seams",
        origins.len(),
        contradictions.len()
    );
    let placements: Vec<(u16, Origin, Option<Rgb<u8>>)> =
        origins.iter().map(|(id, origin)| (*id, *origin, None)).collect();
    render(&format!("{out}/continent.png"), &maps, &placements);

    // A 2x2 of the same layout, big enough on screen to see a seam not interrupting the
    // ground.
    if let Some(quad) = topology::conflict_free_quads(&found).into_iter().find(|q| {
        [q.north_west, q.north_east, q.south_west, q.south_east].iter().all(|m| !water.contains(m))
    }) {
        println!(
            "clean square {} {} / {} {}",
            quad.north_west, quad.north_east, quad.south_west, quad.south_east
        );
        render(
            &format!("{out}/agreement-{}.png", quad.north_west),
            &maps,
            &[
                (quad.north_west, Origin { x: 0, y: 0 }, None),
                (quad.north_east, Origin { x: PITCH_X, y: 0 }, None),
                (quad.south_west, Origin { x: 0, y: PITCH_Y }, None),
                (quad.south_east, Origin { x: PITCH_X, y: PITCH_Y }, None),
            ],
        );
    }

    // The Newbie Dungeon torus. Each pair claims both opposite sides of the other, so one
    // claim from each pair lays it out and the other is the wrap.
    println!("newbie dungeon claims:");
    for edge in found.adjacencies.iter().filter(|e| [37u16, 167, 168, 264].contains(&e.from_map)) {
        println!("  {} has {} to its {:?}", edge.from_map, edge.to_map, edge.side);
    }
    render(
        &format!("{out}/dungeon-torus.png"),
        &maps,
        &[
            (168u16, Origin { x: 0, y: 0 }, None),
            (37u16, Origin { x: PITCH_X, y: 0 }, None),
            (167u16, Origin { x: 0, y: PITCH_Y }, None),
            (264u16, Origin { x: PITCH_X, y: PITCH_Y }, None),
        ],
    );

    // Coast beside the open sea it claims as a neighbour.
    for (land, sea) in [(10u16, 495u16), (17u16, 103u16)] {
        let Some(side) = found
            .adjacencies
            .iter()
            .find(|e| e.from_map == land && e.to_map == sea)
            .map(|e| e.side)
        else {
            continue;
        };
        let (dx, dy) = side.step();
        println!("{land} claims {sea} to its {side:?}");
        render(
            &format!("{out}/bridge-{land}-{sea}.png"),
            &maps,
            &[
                (land, Origin { x: 0, y: 0 }, None),
                (sea, Origin { x: dx as i64 * PITCH_X, y: dy as i64 * PITCH_Y }, Some(GHOST)),
            ],
        );
    }
}
