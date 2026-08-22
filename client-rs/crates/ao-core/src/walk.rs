//! One step across a seam, written out in full.
//!
//! Aggregate seam quality says a boundary is sound. It does not say that a player can walk
//! there: a square can pass every check while its only crossable tiles are open water, and
//! the acceptance square `330 269 / 274 287` is 54/80 navigable water on its east-west seams.
//! What `W-0099` needs is narrower and more concrete — one real *walking* route in each
//! cardinal direction, named down to the tile.
//!
//! So each step records everything that changes as it is taken: the direction, the tile left
//! behind, the transition band tile that fires the exit, the tile arrived on, the locomotion
//! it requires, the global position before and after, and the authority before and after.
//! Authority is the owning MapServer, which is per map today, so crossing a seam always hands
//! the player from one owner to another — and that handoff is the thing `W-0096` has to make
//! atomic. A step that did not change authority would not be exercising it.
//!
//! These are pinned as a fixture rather than left as a report line, because "the seam is
//! fine" is not a claim anybody can check later and "walking east from map 330 tile (87, 34)
//! arrives at map 269 tile (14, 34), global (220, 33) to (221, 33), authority 330 to 269" is.

use crate::mappack::Tile;
use crate::seam::{Crossing, SeamEvidence};
use crate::topology::{to_global, Origin, Side};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Locomotion {
    OnFoot,
    ByBoat,
}

impl Locomotion {
    pub fn name(self) -> &'static str {
        match self {
            Locomotion::OnFoot => "walking",
            Locomotion::ByBoat => "sailing",
        }
    }
}

/// One traversal of a seam, with everything it changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Step {
    pub direction: Side,
    pub locomotion: Locomotion,
    /// Map and tile the step starts on.
    pub from: (u16, u8, u8),
    /// The transition band tile stepped onto, which is what fires the exit.
    pub band: (u16, u8, u8),
    /// Map and tile arrived on.
    pub to: (u16, u8, u8),
    pub global_before: (i64, i64),
    pub global_after: (i64, i64),
    /// Owning MapServer before and after. One per map today, so a seam crossing is always a
    /// handoff.
    pub authority_before: u16,
    pub authority_after: u16,
}

impl Step {
    /// Whether the step moves exactly one global tile in its own direction.
    pub fn advances_one_tile(&self) -> bool {
        let (dx, dy) = self.direction.step();
        self.global_after == (self.global_before.0 + dx as i64, self.global_before.1 + dy as i64)
    }

    /// Whether the step hands the player to a different owner, which a seam crossing must.
    pub fn hands_off(&self) -> bool {
        self.authority_before != self.authority_after
    }

    /// A line of the fixture. Sorted fields, one step per line, so a change is a readable
    /// diff rather than a re-render.
    pub fn encode(&self) -> String {
        format!(
            "{} {} from {} {},{} band {} {},{} to {} {},{} global {},{} -> {},{} authority {} -> {}",
            side_name(self.direction),
            self.locomotion.name(),
            self.from.0,
            self.from.1,
            self.from.2,
            self.band.0,
            self.band.1,
            self.band.2,
            self.to.0,
            self.to.1,
            self.to.2,
            self.global_before.0,
            self.global_before.1,
            self.global_after.0,
            self.global_after.1,
            self.authority_before,
            self.authority_after,
        )
    }

    pub fn parse(line: &str) -> Option<Step> {
        let word: Vec<&str> = line.split_whitespace().collect();
        let pair = |text: &str| -> Option<(i64, i64)> {
            let (left, right) = text.split_once(',')?;
            Some((left.parse().ok()?, right.parse().ok()?))
        };
        let place = |id: &str, at: &str| -> Option<(u16, u8, u8)> {
            let (x, y) = at.split_once(',')?;
            Some((id.parse().ok()?, x.parse().ok()?, y.parse().ok()?))
        };

        Some(Step {
            direction: match *word.first()? {
                "west" => Side::West,
                "east" => Side::East,
                "north" => Side::North,
                "south" => Side::South,
                _ => return None,
            },
            locomotion: match *word.get(1)? {
                "walking" => Locomotion::OnFoot,
                "sailing" => Locomotion::ByBoat,
                _ => return None,
            },
            from: place(word.get(3)?, word.get(4)?)?,
            band: place(word.get(6)?, word.get(7)?)?,
            to: place(word.get(9)?, word.get(10)?)?,
            global_before: pair(word.get(12)?)?,
            global_after: pair(word.get(14)?)?,
            authority_before: word.get(16)?.parse().ok()?,
            authority_after: word.get(18)?.parse().ok()?,
        })
    }
}

fn side_name(side: Side) -> &'static str {
    match side {
        Side::West => "west",
        Side::East => "east",
        Side::North => "north",
        Side::South => "south",
    }
}

/// The first step across this seam that a character can actually take, preferring feet.
///
/// Preferring feet is the point: a seam whose only passable tiles are water proves sailing
/// works and says nothing about walking, and `W-0099`'s first slice is a person on foot.
/// Requires the exit in both directions, because a route a player cannot come back along is
/// not a route.
pub fn first_step(evidence: &SeamEvidence, origin: Origin, neighbour: Origin) -> Option<Step> {
    let usable = |wanted: Crossing| {
        evidence
            .pairs
            .iter()
            .find(|pair| pair.crossing == wanted && pair.exit_out && pair.exit_back)
    };

    let (pair, locomotion) = usable(Crossing::OnFoot)
        .map(|pair| (pair, Locomotion::OnFoot))
        .or_else(|| usable(Crossing::ByBoat).map(|pair| (pair, Locomotion::ByBoat)))?;

    Some(Step {
        direction: evidence.seam.side,
        locomotion,
        from: (evidence.seam.from_map, pair.departure.0, pair.departure.1),
        band: (evidence.seam.from_map, pair.band.0, pair.band.1),
        to: (evidence.seam.to_map, pair.arrival.0, pair.arrival.1),
        global_before: to_global(origin, pair.departure.0, pair.departure.1)?,
        global_after: to_global(neighbour, pair.arrival.0, pair.arrival.1)?,
        authority_before: evidence.seam.from_map,
        authority_after: evidence.seam.to_map,
    })
}

/// What a step requires of the tiles it touches, for a caller holding the maps.
pub fn required_tiles(locomotion: Locomotion) -> Tile {
    match locomotion {
        Locomotion::OnFoot => Tile::Walkable,
        Locomotion::ByBoat => Tile::Water,
    }
}

/// The pinned walking routes, compiled in.
pub fn pinned_steps() -> Vec<Step> {
    include_str!("../fixtures/walking_paths.txt")
        .lines()
        .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
        .filter_map(Step::parse)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::topology::{CORE_X, CORE_Y, PITCH_X};

    fn eastward() -> Step {
        Step {
            direction: Side::East,
            locomotion: Locomotion::OnFoot,
            from: (330, CORE_X.1, 34),
            band: (330, 88, 34),
            to: (269, CORE_X.0, 34),
            global_before: (PITCH_X - 1, 34 - CORE_Y.0 as i64),
            global_after: (PITCH_X, 34 - CORE_Y.0 as i64),
            authority_before: 330,
            authority_after: 269,
        }
    }

    #[test]
    fn a_step_advances_one_tile_and_changes_owner() {
        let step = eastward();
        assert!(step.advances_one_tile());
        assert!(step.hands_off());
        assert_eq!(required_tiles(step.locomotion), Tile::Walkable);
    }

    #[test]
    fn a_step_that_teleports_is_not_a_step() {
        // Two maps placed on 100-tile centres instead of 74 give this: the right map, the
        // right tile, and 27 tiles of nothing crossed on the way.
        let mut step = eastward();
        step.global_after = (100, step.global_before.1);
        assert!(!step.advances_one_tile());
    }

    #[test]
    fn a_step_that_keeps_its_owner_is_not_exercising_a_handoff() {
        let mut step = eastward();
        step.authority_after = step.authority_before;
        assert!(!step.hands_off());
    }

    #[test]
    fn a_step_survives_being_written_down_and_read_back() {
        let step = eastward();
        let line = step.encode();
        assert_eq!(Step::parse(&line), Some(step), "{line}");
        assert!(line.contains("east walking from 330 87,34"));
        assert!(line.contains("authority 330 -> 269"));
    }

    #[test]
    fn the_pinned_routes_are_one_walk_in_each_direction() {
        // The fixture is the claim `W-0099` inherits, so it is checked here rather than only
        // where the corpus happens to be present: four directions, all on foot, each one
        // tile, each a handoff.
        let steps = pinned_steps();
        assert_eq!(steps.len(), 4, "one route per cardinal direction");

        for step in &steps {
            assert_eq!(step.locomotion, Locomotion::OnFoot, "{}", step.encode());
            assert!(step.advances_one_tile(), "{}", step.encode());
            assert!(step.hands_off(), "{}", step.encode());
            // The band tile belongs to the map being left, and is outside its core.
            assert_eq!(step.band.0, step.from.0);
            let outside_core = step.band.1 < CORE_X.0
                || step.band.1 > CORE_X.1
                || step.band.2 < CORE_Y.0
                || step.band.2 > CORE_Y.1;
            assert!(outside_core, "the band is not in the core: {}", step.encode());
        }

        let directions: Vec<Side> = steps.iter().map(|step| step.direction).collect();
        for side in [Side::West, Side::East, Side::North, Side::South] {
            assert!(directions.contains(&side), "no route going {side:?}");
        }
    }
}
