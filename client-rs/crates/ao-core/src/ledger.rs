//! The region allocation ledger: which `RegionId`s were issued, which are live, which are spent.
//!
//! `W-0098` defined `RegionId` as a unit of runtime authority that survives process restarts and
//! topology releases, and nothing made it survive anything. The manifest emitted no regions, so
//! every id in those contracts is a number a person typed into a fixture, and the four-region MVP
//! would have promoted fixture numbers into production identity by accident.
//!
//! What makes identity durable is retained history, not derivation. A region id computed from
//! graph traversal order, a map number, or the current corpus changes when the corpus changes —
//! which is exactly when it must not. So the ledger is a version-controlled file, it is compiler
//! *input*, and a normal compile never writes to it. There is no runtime allocator, no ETS table,
//! no PID registry, no database sequence and no movement-time lookup: by the time anything is
//! moving, every region already has its name.
//!
//! `client-rs/crates/ao-core/fixtures/ledger_contract.txt` is the specification, hand-authored so
//! neither language defines the answers by having been written first, and it fixes the order the
//! checks run in — two implementations reporting different faults for one broken file would each
//! look wrong to the other.

use crate::identity::RegionId;
use crate::position::{MapId, WorldSpaceId};
use std::collections::{BTreeMap, BTreeSet};

/// The one format this compiler understands. Reading a newer ledger with older rules is how a
/// tombstone gets silently dropped, so the version is refused rather than tolerated.
pub const FORMAT: u32 = 1;

/// Why an id stopped being live. A tombstone is permanent: the reason explains the history, and
/// no reason permits reuse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Retirement {
    /// The authority no longer exists and nothing replaced it.
    Removed,
    /// It became several authorities, named by a `split` line.
    Split,
    /// It became part of one authority, named by a `merge` line.
    Merge,
}

impl Retirement {
    pub fn parse(text: &str) -> Option<Retirement> {
        match text {
            "removed" => Some(Retirement::Removed),
            "split" => Some(Retirement::Split),
            "merge" => Some(Retirement::Merge),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Retirement::Removed => "removed",
            Retirement::Split => "split",
            Retirement::Merge => "merge",
        }
    }
}

/// A live authority: which space it is in, and which maps it owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Active {
    pub space: WorldSpaceId,
    /// Strictly ascending. The ledger is compared byte for byte across releases, so each state
    /// has exactly one spelling; two orderings of one region would read as a change.
    pub maps: Vec<MapId>,
}

/// A spent id, and the release *after* which it was spent.
///
/// The parent's hash, never this release's. The ledger is an input to the topology content hash,
/// so a tombstone naming the hash it is part of would make that hash depend on itself — there is
/// no order in which such a file can be written. "Retired after A" is a fact about the past, is
/// known while B is still compiling, and lets B compute its own hash the ordinary way.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tombstone {
    pub retired_after: String,
    pub reason: Retirement,
}

/// One authority becoming several.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Split {
    pub from: RegionId,
    pub into: Vec<RegionId>,
    /// The parent release, for the reason [`Tombstone::retired_after`] gives.
    pub after: String,
}

/// Several authorities becoming one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Merge {
    pub from: Vec<RegionId>,
    pub into: RegionId,
    /// The parent release, for the reason [`Tombstone::retired_after`] gives.
    pub after: String,
}

/// Why a ledger is not one.
///
/// Each names the id or map at fault, because "the ledger is invalid" sends a reader to a file
/// and not to a line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LedgerFault {
    /// A format this compiler does not know.
    UnknownFormat(u32),
    /// A line this compiler cannot read, or a missing `format`/`next_region_id`.
    Unreadable(String),
    /// Zero is not a region. An uninitialised field reads as zero, and a record nobody filled in
    /// must not name a live authority — the rule the wire contract applies to transition kind 0.
    NotARegion(u32),
    /// One id declared active twice. Whichever the loader read second would win, and every
    /// position in the other's maps would answer to an owner that is somewhere else.
    DuplicateRegion(RegionId),
    /// An id at or past the high-water mark: never issued, and already in use.
    PastHighWater(RegionId),
    /// Both live and spent. A tombstone is permanent; reusing the id gives one name to two
    /// authorities separated only by time.
    Reused(RegionId),
    /// One map with two owners, or claimed twice by one region.
    DuplicateMap(MapId),
    /// A region's maps are not strictly ascending.
    Unsorted(RegionId),
    /// An authority over nothing: a name with no referent that still consumes an id.
    Empty(RegionId),
    /// A `split` line that disagrees with the tombstones around it.
    DanglingSplit(RegionId),
    /// A `merge` line that disagrees with the tombstones around it.
    DanglingMerge(RegionId),
    /// Below the high-water mark and neither live nor spent. An id was issued and then lost from
    /// the record, so the next release cannot tell whether it is free or was somebody's authority.
    Unaccounted(RegionId),
}

impl LedgerFault {
    /// The fault as the contract writes it.
    pub fn name(&self) -> String {
        match self {
            LedgerFault::UnknownFormat(n) => format!("unknown-format {n}"),
            LedgerFault::Unreadable(what) => format!("unreadable {what}"),
            LedgerFault::NotARegion(id) => format!("not-a-region {id}"),
            LedgerFault::DuplicateRegion(id) => format!("duplicate-region {}", id.0),
            LedgerFault::PastHighWater(id) => format!("past-high-water {}", id.0),
            LedgerFault::Reused(id) => format!("reused {}", id.0),
            LedgerFault::DuplicateMap(map) => format!("duplicate-map {}", map.0),
            LedgerFault::Unsorted(id) => format!("unsorted {}", id.0),
            LedgerFault::Empty(id) => format!("empty {}", id.0),
            LedgerFault::DanglingSplit(id) => format!("dangling-split {}", id.0),
            LedgerFault::DanglingMerge(id) => format!("dangling-merge {}", id.0),
            LedgerFault::Unaccounted(id) => format!("unaccounted {}", id.0),
        }
    }
}

/// A parsed, unvalidated ledger. [`RegionLedger::parse`] validates before returning one, so every
/// value of this type has already satisfied every rule.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RegionLedger {
    next_region_id: u32,
    active: BTreeMap<RegionId, Active>,
    tombstones: BTreeMap<RegionId, Tombstone>,
    splits: Vec<Split>,
    merges: Vec<Merge>,
}

impl RegionLedger {
    /// Read and validate a ledger.
    ///
    /// The check order is part of the contract: format, then per-line faults, then dispositions,
    /// then accounting. Dispositions before accounting because a split naming an id that was
    /// never issued is a statement about *that line*, and reporting it as a hole in the numbering
    /// would send a reader to the high-water mark instead of to the disposition that is wrong.
    pub fn parse(text: &str) -> Result<RegionLedger, LedgerFault> {
        let mut ledger = RegionLedger::default();
        let mut format_seen = false;
        let mut high_water_seen = false;
        let mut order: Vec<RegionId> = Vec::new();

        for (number, line) in text.lines().enumerate() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let at = number + 1;
            let word: Vec<&str> = line.split_whitespace().collect();

            match word.as_slice() {
                ["format", version] => {
                    let version = number_at(version, at, "format")?;
                    if version != FORMAT {
                        return Err(LedgerFault::UnknownFormat(version));
                    }
                    format_seen = true;
                }
                ["next_region_id", mark] => {
                    ledger.next_region_id = number_at(mark, at, "next_region_id")?;
                    high_water_seen = true;
                }
                ["active", id, "space", space, "maps", maps @ ..] => {
                    let id = number_at(id, at, "region")?;
                    let space: u128 = space
                        .parse()
                        .map_err(|_| LedgerFault::Unreadable(format!("line {at}: space")))?;
                    let maps = maps
                        .first()
                        .map(|list| map_list(list, at))
                        .transpose()?
                        .unwrap_or_default();
                    order.push(RegionId(id));
                    ledger.active.insert(RegionId(id), Active { space: WorldSpaceId(space), maps });
                }
                ["tombstone", id, "retired_after", release, "reason", reason] => {
                    let id = number_at(id, at, "region")?;
                    let reason = Retirement::parse(reason).ok_or_else(|| {
                        LedgerFault::Unreadable(format!("line {at}: reason {reason:?}"))
                    })?;
                    order.push(RegionId(id));
                    ledger.tombstones.insert(
                        RegionId(id),
                        Tombstone { retired_after: (*release).to_string(), reason },
                    );
                }
                ["split", from, "into", into, "after", release] => {
                    let from = number_at(from, at, "region")?;
                    ledger.splits.push(Split {
                        from: RegionId(from),
                        into: region_list(into, at)?,
                        after: (*release).to_string(),
                    });
                }
                ["merge", from, "into", into, "after", release] => {
                    let into = number_at(into, at, "region")?;
                    ledger.merges.push(Merge {
                        from: region_list(from, at)?,
                        into: RegionId(into),
                        after: (*release).to_string(),
                    });
                }
                _ => return Err(LedgerFault::Unreadable(format!("line {at}: {line:?}"))),
            }
        }

        if !format_seen {
            return Err(LedgerFault::Unreadable("no format line".to_string()));
        }
        if !high_water_seen {
            return Err(LedgerFault::Unreadable("no next_region_id".to_string()));
        }

        ledger.check_declarations(&order)?;
        ledger.check_dispositions()?;
        ledger.check_accounting()?;
        Ok(ledger)
    }

    /// Per-line faults, in the order a reader meets them.
    fn check_declarations(&self, order: &[RegionId]) -> Result<(), LedgerFault> {
        let mut seen: BTreeSet<RegionId> = BTreeSet::new();
        for id in order {
            if id.0 == 0 {
                return Err(LedgerFault::NotARegion(0));
            }
            if !seen.insert(*id) {
                return Err(LedgerFault::DuplicateRegion(*id));
            }
            if id.0 >= self.next_region_id {
                return Err(LedgerFault::PastHighWater(*id));
            }
            if self.active.contains_key(id) && self.tombstones.contains_key(id) {
                return Err(LedgerFault::Reused(*id));
            }
        }

        let mut owned: BTreeSet<MapId> = BTreeSet::new();
        for (id, region) in &self.active {
            for map in &region.maps {
                // Duplicates before sortedness: `330,330` is non-descending, and calling it a
                // sorting problem would send a reader looking for the wrong edit.
                if !owned.insert(*map) {
                    return Err(LedgerFault::DuplicateMap(*map));
                }
            }
            if region.maps.windows(2).any(|pair| pair[0] >= pair[1]) {
                return Err(LedgerFault::Unsorted(*id));
            }
            if region.maps.is_empty() {
                return Err(LedgerFault::Empty(*id));
            }
        }

        Ok(())
    }

    /// A split's old id must be spent *as a split*, and each new id must have been issued. Same
    /// for a merge. The tombstone and the disposition must tell the same story, or the history
    /// explains a change that never happened.
    fn check_dispositions(&self) -> Result<(), LedgerFault> {
        for split in &self.splits {
            match self.tombstones.get(&split.from) {
                Some(stone) if stone.reason == Retirement::Split => {}
                _ => return Err(LedgerFault::DanglingSplit(split.from)),
            }
            for id in &split.into {
                if !self.issued(*id) || *id == split.from {
                    return Err(LedgerFault::DanglingSplit(*id));
                }
            }
        }

        for merge in &self.merges {
            for id in &merge.from {
                match self.tombstones.get(id) {
                    Some(stone) if stone.reason == Retirement::Merge => {}
                    _ => return Err(LedgerFault::DanglingMerge(*id)),
                }
            }
            if !self.issued(merge.into) || merge.from.contains(&merge.into) {
                return Err(LedgerFault::DanglingMerge(merge.into));
            }
        }

        Ok(())
    }

    /// Every id below the high-water mark is live or spent.
    ///
    /// This is what makes "never reused" provable rather than hoped for: the ledger is a complete
    /// record of every id ever issued, so a gap means one was lost, and a lost id is one nobody
    /// can prove is free.
    fn check_accounting(&self) -> Result<(), LedgerFault> {
        for id in 1..self.next_region_id {
            if !self.issued(RegionId(id)) {
                return Err(LedgerFault::Unaccounted(RegionId(id)));
            }
        }
        Ok(())
    }

    fn issued(&self, id: RegionId) -> bool {
        self.active.contains_key(&id) || self.tombstones.contains_key(&id)
    }

    /// Which region owns a map, in the space that claims it.
    ///
    /// The space is checked, not assumed: a map belongs to one space, and answering from the map
    /// alone would hand a caller an owner from a different world if the two ever disagreed.
    pub fn owner(&self, space: WorldSpaceId, map: MapId) -> Option<RegionId> {
        self.active
            .iter()
            .find(|(_, region)| region.space == space && region.maps.contains(&map))
            .map(|(id, _)| *id)
    }

    pub fn next_region_id(&self) -> u32 {
        self.next_region_id
    }

    pub fn active(&self) -> &BTreeMap<RegionId, Active> {
        &self.active
    }

    pub fn tombstones(&self) -> &BTreeMap<RegionId, Tombstone> {
        &self.tombstones
    }

    /// The next id to issue, or `None` if `u32` is exhausted.
    ///
    /// Always the recorded high-water mark, never a count of the live regions and never a scan
    /// for a hole: counting hands out an id a split already spent, and scanning hands out one a
    /// tombstone is holding. Exhaustion is an explicit refusal because the alternative is
    /// wrapping to 1, and id 1 belonged to somebody.
    pub fn next_available(&self) -> Option<RegionId> {
        if self.next_region_id == u32::MAX {
            return None;
        }
        Some(RegionId(self.next_region_id))
    }

    /// Issue an id to a new authority. The only thing that moves the high-water mark.
    ///
    /// Called by the explicit review command, never by a compile or a check: a build that can
    /// renumber the world when the corpus changes is a build that decides identity, and identity
    /// is what this file exists to keep out of the build's hands.
    pub fn allocate(
        &mut self,
        space: WorldSpaceId,
        maps: Vec<MapId>,
    ) -> Result<RegionId, LedgerFault> {
        let id = self.next_available().ok_or(LedgerFault::PastHighWater(RegionId(u32::MAX)))?;
        let mut maps = maps;
        maps.sort_unstable();
        maps.dedup();
        self.active.insert(id, Active { space, maps });
        self.next_region_id += 1;
        Ok(id)
    }

    /// The ledger as bytes: sorted, line-oriented, identical for identical state.
    ///
    /// Re-encoding a parsed ledger must reproduce it exactly, or a release pair cannot be
    /// compared byte for byte and "unchanged" stops being checkable.
    pub fn encode(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("format {FORMAT}\n"));
        out.push_str(&format!("next_region_id {}\n", self.next_region_id));

        for (id, region) in &self.active {
            let maps: Vec<String> = region.maps.iter().map(|map| map.0.to_string()).collect();
            out.push_str(&format!(
                "active {} space {} maps {}\n",
                id.0,
                region.space.0,
                maps.join(",")
            ));
        }

        for (id, stone) in &self.tombstones {
            out.push_str(&format!(
                "tombstone {} retired_after {} reason {}\n",
                id.0,
                stone.retired_after,
                stone.reason.name()
            ));
        }

        for split in &self.splits {
            let into: Vec<String> = split.into.iter().map(|id| id.0.to_string()).collect();
            out.push_str(&format!(
                "split {} into {} after {}\n",
                split.from.0,
                into.join(","),
                split.after
            ));
        }

        for merge in &self.merges {
            let from: Vec<String> = merge.from.iter().map(|id| id.0.to_string()).collect();
            out.push_str(&format!(
                "merge {} into {} after {}\n",
                from.join(","),
                merge.into.0,
                merge.after
            ));
        }

        out
    }
}

fn number_at(text: &str, at: usize, what: &str) -> Result<u32, LedgerFault> {
    text.parse().map_err(|_| LedgerFault::Unreadable(format!("line {at}: {what} {text:?}")))
}

fn map_list(text: &str, at: usize) -> Result<Vec<MapId>, LedgerFault> {
    text.split(',')
        .filter(|part| !part.is_empty())
        .map(|part| {
            part.parse::<u16>()
                .map(MapId)
                .map_err(|_| LedgerFault::Unreadable(format!("line {at}: map {part:?}")))
        })
        .collect()
}

fn region_list(text: &str, at: usize) -> Result<Vec<RegionId>, LedgerFault> {
    text.split(',')
        .filter(|part| !part.is_empty())
        .map(|part| {
            part.parse::<u32>()
                .map(RegionId)
                .map_err(|_| LedgerFault::Unreadable(format!("line {at}: region {part:?}")))
        })
        .collect()
}

/// The contract file, and the cases it declares.
pub mod contract {
    pub fn text() -> &'static str {
        include_str!("../fixtures/ledger_contract.txt")
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use std::collections::BTreeMap;

    /// Every `ledger <name> = ...` line, expanded back into ledger text.
    fn ledgers() -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        for line in contract::text().lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            let Some(rest) = line.strip_prefix("ledger ") else { continue };
            let (name, body) = rest.split_once('=').expect("a ledger needs a body");
            let text: Vec<&str> = body.split('|').map(str::trim).collect();
            out.insert(name.trim().to_string(), text.join("\n"));
        }
        out
    }

    fn cases() -> Vec<Vec<String>> {
        contract::text()
            .lines()
            .map(|line| line.split('#').next().unwrap_or("").trim().to_string())
            .filter(|line| !line.is_empty() && !line.starts_with("ledger "))
            .map(|line| line.split_whitespace().map(str::to_string).collect())
            .collect()
    }

    #[test]
    fn rust_satisfies_every_case_in_the_ledger_contract() {
        let ledgers = ledgers();
        let cases = cases();
        assert!(ledgers.len() >= 12, "the contract should declare real ledgers");
        assert!(cases.len() >= 25, "the contract should be worth checking: {}", cases.len());

        let mut checked = 0;
        for case in &cases {
            let word: Vec<&str> = case.iter().map(String::as_str).collect();
            match word.as_slice() {
                ["valid", name, "->", expect @ ..] => {
                    let text = &ledgers[*name];
                    let found = match RegionLedger::parse(text) {
                        Ok(_) => "ok".to_string(),
                        Err(fault) => fault.name(),
                    };
                    assert_eq!(found, expect.join(" "), "valid {name}");
                }
                ["owner", name, space, map, "->", expect] => {
                    let ledger = RegionLedger::parse(&ledgers[*name]).expect("a valid ledger");
                    let found = ledger
                        .owner(
                            WorldSpaceId(space.parse().expect("space")),
                            MapId(map.parse().expect("map")),
                        )
                        .map(|id| id.0.to_string())
                        .unwrap_or_else(|| "none".to_string());
                    assert_eq!(&found, expect, "owner {name} {space} {map}");
                }
                ["allocate", name, "space", space, "maps", maps, "->", expect] => {
                    let mut ledger = RegionLedger::parse(&ledgers[*name]).expect("a valid ledger");
                    let before = ledger.next_region_id();
                    let issued = ledger
                        .allocate(
                            WorldSpaceId(space.parse().expect("space")),
                            maps.split(',')
                                .map(|m| MapId(m.parse().expect("map")))
                                .collect::<Vec<_>>(),
                        )
                        .expect("an id");
                    assert_eq!(issued.0.to_string(), *expect, "allocate {name}");
                    assert_eq!(issued.0, before, "an id comes from the mark, not from a count");
                    assert_eq!(
                        ledger.next_region_id(),
                        before + 1,
                        "allocation moves the mark exactly once"
                    );
                    // And the result is still a ledger: allocating must not create the very
                    // faults the file exists to prevent.
                    RegionLedger::parse(&ledger.encode()).expect("still valid after allocation");
                }
                ["exhausted-at", mark] => {
                    let mark: u32 = mark.parse().expect("a mark");
                    let text = format!("format 1\nnext_region_id {mark}\n");
                    // Built directly rather than through a `ledger` line: accounting requires
                    // every id below the mark to be live or spent, so a valid ledger here would
                    // need four billion entries. What is under test is the allocator's refusal.
                    let mut ledger = RegionLedger::default();
                    ledger.next_region_id = mark;
                    assert_eq!(ledger.next_available(), None, "the mark is exhausted");
                    assert!(
                        ledger.allocate(WorldSpaceId(199), vec![MapId(330)]).is_err(),
                        "allocation must refuse rather than wrap to 1"
                    );
                    assert_eq!(ledger.next_region_id(), mark, "a refusal moves nothing");
                    assert!(text.contains(&mark.to_string()));
                }
                other => panic!("cannot read contract line {other:?}"),
            }
            checked += 1;
        }
        assert!(checked >= 25, "only {checked} cases ran");
    }

    #[test]
    fn a_parsed_ledger_re_encodes_to_the_same_bytes() {
        // A release pair is compared byte for byte, so "unchanged" is only checkable if one
        // state has one spelling. Round-tripping every valid ledger in the contract proves the
        // encoder and the parser agree about what that spelling is.
        for (name, text) in ledgers() {
            let Ok(ledger) = RegionLedger::parse(&text) else { continue };
            let again = RegionLedger::parse(&ledger.encode()).expect("re-encoded is readable");
            assert_eq!(ledger, again, "{name} did not survive a round trip");
            assert_eq!(ledger.encode(), again.encode(), "{name} encodes two ways");
        }
    }
}
