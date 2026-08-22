//! The world topology, written down: what was measured, what a person signed off, and what
//! is allowed to be geography.
//!
//! Four statuses, and the distinction between them is the whole point of this module:
//!
//! - **Unresolved** — the evidence says this cannot hold. A seam whose tile pairs are not one
//!   tile apart, whose arrivals resolve to two maps, or which strands a walker.
//! - **Candidate** — the evidence found nothing wrong. That is *not* permission. 1,656 of the
//!   corpus's 2,219 seams are candidates, and no compiler is entitled to turn a clean
//!   measurement into live geography.
//! - **Reviewed** — a person recorded a disposition in `assets/world-topology/reviews.txt`,
//!   and it was something other than "this is geography": a door, a portal, a teleport, an
//!   instance entrance, or geography this compiler will not support.
//! - **Active** — a person recorded that it *is* geography, and the evidence agrees. Both
//!   halves are required. A review cannot activate a seam the measurements reject, and clean
//!   measurements cannot activate a seam nobody reviewed.
//!
//! Ground art never promotes anything. `gutter_continuity_over_non_solid` is recorded in the
//! manifest because a reviewer wants to see it, and it is deliberately not an input to any
//! status: it reached 100% on a boundary that walks a character into the sea, and it was
//! silent for a week while the blocked layer was read as two states instead of three.
//!
//! The encoding is line-oriented text in sorted order, so the same corpus produces the same
//! bytes and a change to the world shows up as a diff a person can read. Its content hash
//! names that byte sequence; it is FNV-1a, chosen for being short and exactly reproducible
//! rather than for being cryptographic — it detects change, it does not resist forgery.

use crate::mappack::PackedMap;
use crate::seam::{self, Crossing, SeamEvidence};
use crate::topology::{Adjacency, Atlas, Evidence, Geometry, Origin, Region, Side, Surface};
use std::collections::{BTreeMap, BTreeSet};

pub const FORMAT: u32 = 1;

/// The content hash the pinned corpus and the checked-in reviews produce.
///
/// Gated by `ao-topology --check`, so a change to the world, to the review file, or to how
/// either is encoded fails the build until somebody says which of those they meant. This is
/// the determinism proof with teeth: a test can show two runs agree with each other, and only
/// a pinned value shows they agree with what was reviewed.
pub const CONTENT_HASH: &str = "62e5f93a530bf656";

/// The hand-recorded dispositions, compiled in.
///
/// `include_str!` rather than a runtime read: the reviews are part of the build, so the
/// pinned hash covers them and a missing file is a compile error rather than a silently empty
/// set of permissions.
pub fn reviews() -> Reviews {
    Reviews::parse(include_str!("../../../assets/world-topology/reviews.txt"))
        .expect("the checked-in review file must parse")
}

/// What a person decided about a boundary. Recorded by hand; never inferred.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Disposition {
    /// It is geography: two maps genuinely adjacent, to be walked across seamlessly.
    Geographic,
    Door,
    Portal,
    Teleport,
    InstanceEntrance,
    /// Real, and this compiler will not model it. Says so instead of guessing.
    Unsupported,
}

impl Disposition {
    fn parse(word: &str) -> Option<Disposition> {
        match word {
            "geographic" => Some(Disposition::Geographic),
            "door" => Some(Disposition::Door),
            "portal" => Some(Disposition::Portal),
            "teleport" => Some(Disposition::Teleport),
            "instance" => Some(Disposition::InstanceEntrance),
            "unsupported" => Some(Disposition::Unsupported),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Disposition::Geographic => "geographic",
            Disposition::Door => "door",
            Disposition::Portal => "portal",
            Disposition::Teleport => "teleport",
            Disposition::InstanceEntrance => "instance",
            Disposition::Unsupported => "unsupported",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Unresolved,
    Candidate,
    Reviewed,
    Active,
}

impl Status {
    pub fn name(self) -> &'static str {
        match self {
            Status::Unresolved => "unresolved",
            Status::Candidate => "candidate",
            Status::Reviewed => "reviewed",
            Status::Active => "active",
        }
    }
}

/// Hand-recorded dispositions, parsed from `assets/world-topology/reviews.txt`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Reviews {
    seams: BTreeMap<(u16, Side, u16), Disposition>,
    /// Spaces whose measured geometry a person has confirmed. A torus stays a candidate
    /// shape until somebody has looked at what wrapping means for its content.
    confirmed_spaces: BTreeSet<u16>,
}

impl Reviews {
    /// Parse the review file. Unknown lines are an error rather than a shrug: a typo in a
    /// disposition would otherwise silently leave a seam unreviewed.
    pub fn parse(text: &str) -> Result<Reviews, String> {
        let mut reviews = Reviews::default();

        for (number, line) in text.lines().enumerate() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let word: Vec<&str> = line.split_whitespace().collect();
            let at = number + 1;

            match word.as_slice() {
                ["seam", from, side, to, verdict, ..] => {
                    let side = match *side {
                        "west" => Side::West,
                        "east" => Side::East,
                        "north" => Side::North,
                        "south" => Side::South,
                        other => return Err(format!("line {at}: unknown side {other:?}")),
                    };
                    let disposition = Disposition::parse(verdict)
                        .ok_or_else(|| format!("line {at}: unknown disposition {verdict:?}"))?;
                    let from: u16 =
                        from.parse().map_err(|_| format!("line {at}: bad map {from:?}"))?;
                    let to: u16 = to.parse().map_err(|_| format!("line {at}: bad map {to:?}"))?;
                    reviews.seams.insert((from, side, to), disposition);
                }
                ["space", id, "geometry-confirmed", ..] => {
                    let id: u16 = id.parse().map_err(|_| format!("line {at}: bad space {id:?}"))?;
                    reviews.confirmed_spaces.insert(id);
                }
                _ => return Err(format!("line {at}: cannot read {line:?}")),
            }
        }

        Ok(reviews)
    }

    pub fn len(&self) -> usize {
        self.seams.len() + self.confirmed_spaces.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// One coordinate space in the manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpaceEntry {
    pub id: u16,
    pub geometry: Geometry,
    pub status: Status,
    pub sea_maps: usize,
    /// Cells claimed by more than one map. Any at all makes the space unresolved: a position
    /// that means two places is worse than one that means the wrong place.
    pub overlapping_cells: usize,
    pub unresolved_claims: usize,
    pub origins: BTreeMap<u16, Origin>,
    /// Whether every map in this space can be addressed as `map_id + u8 x/y` by the retained
    /// legacy adapter.
    pub legacy_representable: bool,
}

/// One boundary in the manifest, with the evidence a reviewer needs beside it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeamEntry {
    pub seam: Adjacency,
    pub status: Status,
    pub disposition: Option<Disposition>,
    pub pairs: usize,
    pub on_foot: usize,
    pub by_boat: usize,
    pub blocked: usize,
    pub strands_walker: usize,
    pub beaches_boat: usize,
    /// Recorded for the reviewer, and never an input to `status`.
    pub gutter_continuity: Option<usize>,
    pub defects: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub format: u32,
    pub corpus: String,
    pub spaces: Vec<SpaceEntry>,
    pub seams: Vec<SeamEntry>,
}

impl Manifest {
    pub fn count(&self, status: Status) -> usize {
        self.seams.iter().filter(|entry| entry.status == status).count()
    }

    /// The manifest as bytes: sorted, line-oriented, and identical for identical input.
    pub fn encode(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("world-topology {}\n", self.format));
        out.push_str(&format!("corpus {}\n", self.corpus));

        for space in &self.spaces {
            out.push_str(&format!(
                "space {} geometry {} status {} sea {} overlapping {} unresolved {} legacy {}\n",
                space.id,
                geometry_name(space.geometry),
                space.status.name(),
                space.sea_maps,
                space.overlapping_cells,
                space.unresolved_claims,
                space.legacy_representable,
            ));
            for (map, origin) in &space.origins {
                out.push_str(&format!("  map {} at {},{}\n", map, origin.x, origin.y));
            }
        }

        for entry in &self.seams {
            out.push_str(&format!(
                "seam {} {} {} status {} disposition {} pairs {} foot {} boat {} wall {} \
                 strand {} beach {} gutter {}\n",
                entry.seam.from_map,
                side_name(entry.seam.side),
                entry.seam.to_map,
                entry.status.name(),
                entry.disposition.map(|d| d.name()).unwrap_or("none"),
                entry.pairs,
                entry.on_foot,
                entry.by_boat,
                entry.blocked,
                entry.strands_walker,
                entry.beaches_boat,
                entry.gutter_continuity.map(|p| p.to_string()).unwrap_or("na".to_string()),
            ));
            for defect in &entry.defects {
                out.push_str(&format!("  defect {defect}\n"));
            }
        }

        out
    }

    /// Content hash of the encoded bytes.
    ///
    /// FNV-1a, for being short and exactly reproducible. It answers "is this the same
    /// topology" and nothing else; it is not a cryptographic commitment and must not be
    /// treated as one.
    pub fn content_hash(&self) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in self.encode().as_bytes() {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("{hash:016x}")
    }
}

fn geometry_name(geometry: Geometry) -> String {
    match geometry {
        Geometry::Plane => "plane".to_string(),
        Geometry::Discrete => "discrete".to_string(),
        Geometry::Cylinder { axis, period } => format!("cylinder-{axis:?}:{period}").to_lowercase(),
        Geometry::Torus { width, height } => format!("torus:{width}x{height}"),
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

/// Build the manifest from measured evidence and hand-recorded reviews.
///
/// The status rules live here, in one place, so they can be read in full:
///
/// - a seam with defects is `Unresolved`, whatever the review file says;
/// - a seam in an unresolved space is `Unresolved`, because its coordinates do not mean
///   anything yet;
/// - a seam reviewed as geography, with no defects, is `Active`;
/// - a seam reviewed as anything else is `Reviewed` — classified, and not live geography;
/// - anything else clean is a `Candidate`, which is a request for review and not a result.
pub fn build(maps: &[PackedMap], evidence: &Evidence, reviews: &Reviews) -> Manifest {
    let surfaces = crate::topology::surfaces(maps);
    let (_, per_seam) = seam::summarise(maps, &evidence.adjacencies, &evidence.regions, &surfaces);

    let mut spaces = Vec::new();
    let mut space_of: BTreeMap<u16, u16> = BTreeMap::new();
    let mut unresolved_spaces: BTreeSet<u16> = BTreeSet::new();

    for region in &evidence.regions {
        let atlas = Atlas::of(region);
        let overlapping = atlas.ambiguous_cells();
        let unresolved_claims = region.unresolved.len();
        let legacy_representable = region
            .origins
            .keys()
            .filter_map(|id| maps.iter().find(|map| map.map_id == *id))
            .all(|map| map.width <= 255 && map.height <= 255);

        for map in region.origins.keys() {
            space_of.insert(*map, region.id);
        }

        let status = if overlapping > 0 || unresolved_claims > 0 {
            unresolved_spaces.insert(region.id);
            Status::Unresolved
        } else if reviews.confirmed_spaces.contains(&region.id) {
            // A confirmed shape is reviewed, not active: a space is not geography, its seams
            // are, and each of those needs its own disposition.
            Status::Reviewed
        } else {
            Status::Candidate
        };

        spaces.push(SpaceEntry {
            id: region.id,
            geometry: region.geometry,
            status,
            sea_maps: region.sea_maps,
            overlapping_cells: overlapping,
            unresolved_claims,
            origins: region.origins.clone(),
            legacy_representable,
        });
    }

    let mut seams: Vec<SeamEntry> = per_seam
        .iter()
        .map(|found: &SeamEvidence| {
            let defects = found.defects();
            let disposition =
                reviews.seams.get(&(found.seam.from_map, found.seam.side, found.seam.to_map));
            let in_unresolved_space =
                space_of.get(&found.seam.from_map).is_some_and(|id| unresolved_spaces.contains(id));

            let status = if !defects.is_empty() || in_unresolved_space {
                Status::Unresolved
            } else {
                match disposition {
                    Some(Disposition::Geographic) => Status::Active,
                    Some(_) => Status::Reviewed,
                    None => Status::Candidate,
                }
            };

            SeamEntry {
                seam: found.seam,
                status,
                disposition: disposition.copied(),
                pairs: found.pairs.len(),
                on_foot: found.count(Crossing::OnFoot),
                by_boat: found.count(Crossing::ByBoat),
                blocked: found.count(Crossing::Blocked),
                strands_walker: found.count(Crossing::StrandsWalker),
                beaches_boat: found.count(Crossing::BeachesBoat),
                gutter_continuity: found.gutter_continuity_over_non_solid(),
                defects,
            }
        })
        .collect();

    // Sorted by the seam itself, so the bytes do not depend on the order maps were decoded.
    seams.sort_by_key(|entry| (entry.seam.from_map, entry.seam.side, entry.seam.to_map));
    spaces.sort_by_key(|space| space.id);

    Manifest { format: FORMAT, corpus: crate::topology::CORPUS.to_string(), spaces, seams }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mappack::{LayerTile, MapExit};
    use crate::topology::{CORE_X, PITCH_X, PITCH_Y, STORAGE};

    fn map_with(map_id: u16, exits: Vec<MapExit>) -> PackedMap {
        PackedMap {
            map_id,
            name: format!("map {map_id}"),
            width: STORAGE as u16,
            height: STORAGE as u16,
            music_hi: 0,
            music_low: 0,
            tiles: vec![0; STORAGE as usize * STORAGE as usize],
            layers: [
                (1..=STORAGE)
                    .flat_map(|y| (1..=STORAGE).map(move |x| LayerTile { x, y, grh: 1 }))
                    .collect(),
                Vec::new(),
                Vec::new(),
                Vec::new(),
            ],
            npcs: Vec::new(),
            objects: Vec::new(),
            exits,
        }
    }

    /// Two maps joined west-east by reciprocal seam exits on every row.
    fn two_maps() -> Vec<PackedMap> {
        let east_exits = (11..=90)
            .map(|y| MapExit { x: 88, y, target_map: 2, target_x: 14, target_y: y })
            .collect();
        let west_exits = (11..=90)
            .map(|y| MapExit { x: 13, y, target_map: 1, target_x: 87, target_y: y })
            .collect();
        vec![map_with(1, east_exits), map_with(2, west_exits)]
    }

    #[test]
    fn a_clean_seam_is_a_candidate_and_not_active() {
        // The rule that matters most: measuring nothing wrong is not permission. A compiler
        // that promoted its own clean measurements would be deciding geography, which is the
        // one thing this module exists to prevent.
        let maps = two_maps();
        let evidence = crate::topology::evidence(&maps);
        let manifest = build(&maps, &evidence, &Reviews::default());

        assert!(!manifest.seams.is_empty());
        assert!(manifest.seams.iter().all(|entry| entry.defects.is_empty()));
        assert_eq!(manifest.count(Status::Candidate), manifest.seams.len());
        assert_eq!(manifest.count(Status::Active), 0);
    }

    #[test]
    fn perfect_ground_art_does_not_activate_anything() {
        // Every tile of these maps carries grh 1, so the gutter continuity is 100% and the
        // art is as continuous as art can be. It buys nothing.
        let maps = two_maps();
        let evidence = crate::topology::evidence(&maps);
        let manifest = build(&maps, &evidence, &Reviews::default());

        assert_eq!(manifest.seams[0].gutter_continuity, Some(100));
        assert_eq!(manifest.seams[0].status, Status::Candidate);
        assert_eq!(manifest.count(Status::Active), 0);
    }

    #[test]
    fn a_review_activates_only_what_the_evidence_agrees_with() {
        let maps = two_maps();
        let evidence = crate::topology::evidence(&maps);

        let reviews = Reviews::parse("seam 1 east 2 geographic\n").expect("parses");
        let manifest = build(&maps, &evidence, &reviews);
        let entry = manifest
            .seams
            .iter()
            .find(|entry| entry.seam.from_map == 1 && entry.seam.side == Side::East)
            .expect("the reviewed seam");
        assert_eq!(entry.status, Status::Active);
        assert_eq!(entry.disposition, Some(Disposition::Geographic));

        // Its reciprocal was not reviewed, so it stays a candidate. Activation is per
        // directed claim, because that is what a player traverses.
        let back = manifest
            .seams
            .iter()
            .find(|entry| entry.seam.from_map == 2 && entry.seam.side == Side::West)
            .expect("the other direction");
        assert_eq!(back.status, Status::Candidate);
    }

    #[test]
    fn a_review_cannot_activate_a_seam_the_evidence_rejects() {
        // A person says this is geography; the maps say the arrival is not one tile away.
        // The evidence wins, and the manifest says unresolved.
        let mut maps = two_maps();
        maps[1].map_id = 2;
        let mut evidence = crate::topology::evidence(&maps);

        // Force a defect by moving map 2 a tile off its pitch.
        if let Some(region) = evidence.regions.first_mut() {
            if let Some(origin) = region.origins.get_mut(&2) {
                origin.x += 1;
            }
        }

        let reviews = Reviews::parse("seam 1 east 2 geographic\n").expect("parses");
        let manifest = build(&maps, &evidence, &reviews);
        let entry = manifest
            .seams
            .iter()
            .find(|entry| entry.seam.from_map == 1 && entry.seam.side == Side::East)
            .expect("the reviewed seam");
        assert_eq!(entry.status, Status::Unresolved);
        assert!(!entry.defects.is_empty());
    }

    #[test]
    fn a_non_geographic_disposition_is_reviewed_and_still_not_active() {
        let maps = two_maps();
        let evidence = crate::topology::evidence(&maps);
        let reviews = Reviews::parse("seam 1 east 2 door\n").expect("parses");
        let manifest = build(&maps, &evidence, &reviews);

        let entry = manifest.seams.iter().find(|entry| entry.seam.from_map == 1).expect("entry");
        assert_eq!(entry.status, Status::Reviewed);
        assert_eq!(manifest.count(Status::Active), 0);
    }

    #[test]
    fn the_same_corpus_encodes_to_the_same_bytes_whatever_order_it_arrives_in() {
        let maps = two_maps();
        let mut shuffled = maps.clone();
        shuffled.reverse();

        let first = build(&maps, &crate::topology::evidence(&maps), &Reviews::default());
        let second = build(&shuffled, &crate::topology::evidence(&shuffled), &Reviews::default());

        assert_eq!(first.encode(), second.encode());
        assert_eq!(first.content_hash(), second.content_hash());
        // And encoding is stable across calls, which a hash of a HashMap iteration would not
        // be.
        assert_eq!(first.encode(), first.encode());
        assert_eq!(first.content_hash().len(), 16);
    }

    #[test]
    fn a_different_world_gets_a_different_hash() {
        let maps = two_maps();
        let evidence = crate::topology::evidence(&maps);
        let plain = build(&maps, &evidence, &Reviews::default());
        let reviewed =
            build(&maps, &evidence, &Reviews::parse("seam 1 east 2 geographic\n").expect("parses"));

        assert_ne!(plain.content_hash(), reviewed.content_hash());
    }

    #[test]
    fn a_typo_in_the_review_file_is_an_error_not_a_shrug() {
        assert!(Reviews::parse("seam 1 east 2 geografic\n").is_err());
        assert!(Reviews::parse("seam 1 up 2 geographic\n").is_err());
        assert!(Reviews::parse("seam x east 2 geographic\n").is_err());
        assert!(Reviews::parse("nonsense\n").is_err());

        // Comments and blank lines are fine.
        let reviews = Reviews::parse("# a note\n\nseam 1 east 2 door  # why\n").expect("parses");
        assert_eq!(reviews.len(), 1);
    }

    #[test]
    fn a_space_whose_claims_do_not_close_makes_its_seams_unresolved() {
        // Coordinates in a contradictory space do not mean anything yet, so no seam inside it
        // can be promoted even if that seam's own tile pairs look fine.
        let maps = two_maps();
        let mut evidence = crate::topology::evidence(&maps);
        if let Some(region) = evidence.regions.first_mut() {
            region.unresolved.push(Adjacency { from_map: 1, side: Side::East, to_map: 2 });
        }

        let reviews = Reviews::parse("seam 1 east 2 geographic\n").expect("parses");
        let manifest = build(&maps, &evidence, &reviews);
        assert_eq!(manifest.spaces[0].status, Status::Unresolved);
        assert_eq!(manifest.count(Status::Active), 0);
        assert!(manifest.seams.iter().all(|entry| entry.status == Status::Unresolved));
    }

    #[test]
    fn the_legacy_adapter_flag_reports_what_it_can_address() {
        let maps = two_maps();
        let evidence = crate::topology::evidence(&maps);
        let manifest = build(&maps, &evidence, &Reviews::default());
        assert!(manifest.spaces[0].legacy_representable);
        assert_eq!(CORE_X.0, 14);
        assert_eq!((PITCH_X, PITCH_Y), (74, 80));
    }
}
