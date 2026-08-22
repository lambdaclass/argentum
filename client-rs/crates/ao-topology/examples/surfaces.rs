//! What each map is made of, by tile value.
//!
//! The pack's blocked layer is not a boolean. `Arena.Map.CsmParser` writes 0 for walkable,
//! 1 for solid and 2 for navigable water — water derived from layer-1 GRH ranges, with a
//! layer-2 bridge cancelling it — and `Arena.Map.Movement` lets a character cross a 2 only
//! while `navigating`, in a boat. So water is *space characters occupy*, not absence, and a
//! classifier that counts every nonzero tile as sea calls a solid rock catacomb an ocean.
//!
//! Usage: `cargo run -p ao-topology --example surfaces -- <pack>`

use ao_core::mappack::PackedMap;

fn parts(map: &PackedMap) -> (usize, usize, usize) {
    let total = map.tiles.len().max(1);
    let solid = map.tiles.iter().filter(|t| **t == 1).count() * 100 / total;
    let water = map.tiles.iter().filter(|t| **t == 2).count() * 100 / total;
    (100 - solid - water, solid, water)
}

fn main() {
    let pack = std::env::args().nth(1).expect("pack path");
    let bytes = std::fs::read(&pack).expect("read pack");
    let maps = ao_core::mappack::decode_all(&bytes).expect("decode");

    let mut values = std::collections::BTreeMap::new();
    for map in &maps {
        for tile in &map.tiles {
            *values.entry(*tile).or_insert(0usize) += 1;
        }
    }
    println!("tile values across the corpus: {values:?}\n");

    let mut mostly_water = 0;
    let mut no_land = 0;
    let mut all_solid = 0;
    let mut misread = Vec::new();
    for map in &maps {
        let (walkable, solid, water) = parts(map);
        if water >= 50 {
            mostly_water += 1;
        }
        if walkable == 0 {
            no_land += 1;
        }
        if solid >= 95 {
            all_solid += 1;
        }
        // What the old `!= 0` rule called water: 95% nonzero, whatever the reason.
        if solid + water >= 95 && water < 50 {
            misread.push((map.map_id, map.name.clone(), walkable, solid, water));
        }
    }
    println!("maps at least half navigable water: {mostly_water}");
    println!("maps with no walkable tile at all:  {no_land}");
    println!("maps at least 95% solid:            {all_solid}");
    println!("maps the `!= 0` rule called water but are not: {}", misread.len());
    for (id, name, walkable, solid, water) in misread.iter().take(12) {
        println!("  {id:>4} \"{name}\": {walkable}% walkable, {solid}% solid, {water}% water");
    }

    println!("\nthe maps in the renders:");
    for id in [1u16, 10, 17, 37, 41, 103, 199, 495] {
        if let Some(map) = maps.iter().find(|m| m.map_id == id) {
            let (walkable, solid, water) = parts(map);
            println!(
                "  {id:>4} \"{}\": {walkable}% walkable, {solid}% solid, {water}% water",
                map.name
            );
        }
    }
}
