//! Which tiles of a map are actually part of the world.
//!
//! A map is stored as a 100x100 rectangle and simulated on a 74x80 core, but neither shape is
//! the shape of the *place*. A dungeon draws corridors and leaves the rest of its rectangle
//! empty: map 37 has ground on 7,163 of its 10,000 tiles, and the other 2,837 are not floor,
//! not wall, and not anywhere. `W-0097` states the requirement precisely — a bounding
//! rectangle must never make a void tile walkable — and this measures whether it does.
//!
//! It does. The blocked layer says nothing about whether a tile exists, so a tile with no
//! ground graphic and a blocked byte of `0` reads as perfectly good walkable ground to
//! anything that consults only the rectangle.
//!
//! This module reports that and changes nothing. `Arena.Map.Movement` consults the same
//! blocked layer and would allow the step, so a client that quietly treated void as solid
//! would predict a refusal the server does not make, and desynchronise on exactly the tiles
//! where a player is most likely to be lost. The fix belongs on the server, in one change
//! that moves the rule, the fixture and the client together — the same argument as
//! `Tile::enterable`. Until then it is an observation with a count attached.

use crate::mappack::{PackedMap, Tile};
use crate::topology::{CORE_X, CORE_Y};
use std::collections::BTreeSet;

/// What a map's core is made of, counted over the simulated area only.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Mask {
    /// Core tiles with ground drawn on them: the map's real extent.
    pub simulated: usize,
    /// Core tiles with no ground at all.
    pub void: usize,
    /// Void tiles whose blocked byte says walkable. The requirement's failure case, counted.
    pub void_walkable: usize,
    /// Void tiles already blocked, which need nothing.
    pub void_solid: usize,
    /// Void tiles marked navigable water, which is stranger still: sailable nothing.
    pub void_water: usize,
}

impl Mask {
    /// The share of the core that is really there, as a percentage.
    pub fn coverage(&self) -> usize {
        let total = self.simulated + self.void;
        if total == 0 {
            return 0;
        }
        self.simulated * 100 / total
    }

    /// Whether the bounding rectangle lies about this map.
    pub fn rectangle_lies(&self) -> bool {
        self.void_walkable > 0
    }
}

/// The core tiles a map has ground drawn on.
pub fn simulated_tiles(map: &PackedMap) -> BTreeSet<(u8, u8)> {
    map.layers[0]
        .iter()
        .filter(|tile| {
            (CORE_X.0..=CORE_X.1).contains(&tile.x) && (CORE_Y.0..=CORE_Y.1).contains(&tile.y)
        })
        .map(|tile| (tile.x, tile.y))
        .collect()
}

/// Measure one map's core.
pub fn mask_of(map: &PackedMap) -> Mask {
    let ground = simulated_tiles(map);
    let mut mask = Mask::default();

    for y in CORE_Y.0..=CORE_Y.1 {
        for x in CORE_X.0..=CORE_X.1 {
            if ground.contains(&(x, y)) {
                mask.simulated += 1;
                continue;
            }
            mask.void += 1;
            match Tile::of(map.tile_at(x as i32, y as i32)) {
                Tile::Walkable => mask.void_walkable += 1,
                Tile::Solid => mask.void_solid += 1,
                Tile::Water => mask.void_water += 1,
            }
        }
    }

    mask
}

/// Every map's mask, summed, with the worst offenders named.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Coverage {
    pub total: Mask,
    /// Maps where a void tile reads as walkable, worst first, with each map's count.
    pub lying_rectangles: Vec<(u16, usize)>,
    /// Maps whose core is entirely drawn: no void at all.
    pub fully_drawn: usize,
}

pub fn coverage(maps: &[PackedMap]) -> Coverage {
    let mut found = Coverage::default();

    for map in maps {
        let mask = mask_of(map);
        found.total.simulated += mask.simulated;
        found.total.void += mask.void;
        found.total.void_walkable += mask.void_walkable;
        found.total.void_solid += mask.void_solid;
        found.total.void_water += mask.void_water;

        if mask.void == 0 {
            found.fully_drawn += 1;
        }
        if mask.rectangle_lies() {
            found.lying_rectangles.push((map.map_id, mask.void_walkable));
        }
    }

    found.lying_rectangles.sort_by_key(|(map, count)| (std::cmp::Reverse(*count), *map));
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mappack::LayerTile;
    use crate::topology::{PITCH_X, PITCH_Y, STORAGE};

    fn map_with_ground(map_id: u16, ground: Vec<(u8, u8)>) -> PackedMap {
        PackedMap {
            map_id,
            name: format!("map {map_id}"),
            width: STORAGE as u16,
            height: STORAGE as u16,
            music_hi: 0,
            music_low: 0,
            tiles: vec![0; STORAGE as usize * STORAGE as usize],
            layers: [
                ground.into_iter().map(|(x, y)| LayerTile { x, y, grh: 1 }).collect(),
                Vec::new(),
                Vec::new(),
                Vec::new(),
            ],
            npcs: Vec::new(),
            objects: Vec::new(),
            exits: Vec::new(),
        }
    }

    fn every_core_tile() -> Vec<(u8, u8)> {
        (CORE_Y.0..=CORE_Y.1).flat_map(|y| (CORE_X.0..=CORE_X.1).map(move |x| (x, y))).collect()
    }

    #[test]
    fn a_fully_drawn_map_has_no_void() {
        let mask = mask_of(&map_with_ground(1, every_core_tile()));
        assert_eq!(mask.simulated, (PITCH_X * PITCH_Y) as usize);
        assert_eq!(mask.void, 0);
        assert_eq!(mask.coverage(), 100);
        assert!(!mask.rectangle_lies());
    }

    #[test]
    fn the_bounding_rectangle_makes_undrawn_tiles_look_walkable() {
        // The requirement's exact failure case. One corridor is drawn; the rest of the core
        // has no ground and a blocked byte of zero, so anything reading the rectangle alone
        // sees 5,910 tiles of perfectly good floor that do not exist.
        let corridor: Vec<(u8, u8)> = (CORE_X.0..=CORE_X.1).map(|x| (x, 50)).collect();
        let mask = mask_of(&map_with_ground(1, corridor));

        assert_eq!(mask.simulated, PITCH_X as usize);
        assert_eq!(mask.void, (PITCH_X * PITCH_Y) as usize - PITCH_X as usize);
        assert_eq!(mask.void_walkable, mask.void, "every void tile reads as walkable");
        assert!(mask.rectangle_lies());
        assert_eq!(mask.coverage(), 1);
    }

    #[test]
    fn void_that_is_already_blocked_needs_nothing() {
        let corridor: Vec<(u8, u8)> = (CORE_X.0..=CORE_X.1).map(|x| (x, 50)).collect();
        let mut map = map_with_ground(1, corridor);
        map.tiles = vec![1; STORAGE as usize * STORAGE as usize];
        // Redraw the corridor as walkable so only the void is solid.
        for x in CORE_X.0..=CORE_X.1 {
            let index = (50 - 1) * map.width as usize + (x as usize - 1);
            map.tiles[index] = 0;
        }

        let mask = mask_of(&map);
        assert_eq!(mask.void_walkable, 0);
        assert_eq!(mask.void_solid, mask.void);
        assert!(!mask.rectangle_lies());
    }

    #[test]
    fn sailable_nothing_is_counted_apart() {
        // Void marked as navigable water. Stranger than void marked walkable, and worth its
        // own count rather than being folded in with it.
        let mut map = map_with_ground(1, Vec::new());
        map.tiles = vec![2; STORAGE as usize * STORAGE as usize];
        let mask = mask_of(&map);
        assert_eq!(mask.void_water, (PITCH_X * PITCH_Y) as usize);
        assert_eq!(mask.void_walkable, 0);
    }

    #[test]
    fn ground_outside_the_core_does_not_count_as_simulated() {
        // The transition bands and the storage margin are drawn -- that is what the gutters
        // are -- and none of it is simulated area.
        let mask =
            mask_of(&map_with_ground(1, vec![(1, 1), (13, 50), (88, 50), (50, 10), (99, 99)]));
        assert_eq!(mask.simulated, 0);
        assert_eq!(mask.void, (PITCH_X * PITCH_Y) as usize);
    }

    #[test]
    fn coverage_names_the_worst_maps_first() {
        let corridor: Vec<(u8, u8)> = (CORE_X.0..=CORE_X.1).map(|x| (x, 50)).collect();
        let mostly_void = map_with_ground(7, corridor);
        let complete = map_with_ground(3, every_core_tile());

        let found = coverage(&[complete, mostly_void]);
        assert_eq!(found.fully_drawn, 1);
        assert_eq!(found.lying_rectangles.len(), 1);
        assert_eq!(found.lying_rectangles[0].0, 7);
    }
}
