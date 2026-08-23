//! Who and what, kept apart from where and when.
//!
//! Four things in this system look like "an id" and are not interchangeable, and conflating
//! any two of them is a bug that only shows up under restart, reshard or a content release:
//!
//! - **content identity** — which map, which space, which instance template. Stable across
//!   everything, because it names authored content.
//! - **world version** — which compiled release of that content. The same tile has different
//!   global coordinates under two topology releases, so a position without a version is a
//!   number without a meaning.
//! - **runtime ownership** — which process is authoritative for an entity right now. Changes
//!   on every seam crossing and every restart, and must never be persisted or shown.
//! - **dynamic instance identity** — which live copy of an instance template somebody is in.
//!   Exists only while that copy does.
//!
//! The types here make those four distinct at compile time. None of them can be built from
//! another by accident, none is a PID or an array index, and none carries a map number into
//! player-facing identity — a save file or a protocol field that embedded one would pin the
//! 2001 file layout into everything downstream of it.
//!
//! `W-0098` asks for the extension points to be specified without building their breadth, so
//! the shapes are here and the mechanisms are not: one authoritative owner per entity,
//! read-only cross-space observation, commands routed to the owner, instance templates
//! separate from runtime spaces, and a versioned lookup rather than a per-movement service.

use crate::position::{MapId, Space, TopologyVersion, WorldSpaceId};
use crate::topology::Origin;

/// A region: one unit of runtime authority, stable across restarts and topology releases.
///
/// Authority belongs here, not to a world space. Several regions occupy one space — today one
/// per map, tomorrow perhaps a spatial partition of a crowded one — so a seamless crossing
/// changes the region that owns a character while the space they are in does not change at
/// all. `Ownership` keyed by space could not express that, and would have made the central
/// event of the seamless world invisible to the type that exists to describe it.
///
/// Stable means stable: never a PID, never an array index, never a position in a boot order.
/// A region that restarts is the same region, and an entity's saved home survives a reshard.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RegionId(pub u32);

/// Where a region sits, and what it owns.
///
/// One region owns one map today, which is what a MapServer is. The origin is that map's core
/// in the space's coordinates, so a caller holding a placement can do its own arithmetic
/// without consulting anything: that is the point of publishing placements rather than
/// answering coordinate questions per movement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RegionPlacement {
    pub region: RegionId,
    pub space: WorldSpaceId,
    pub map: MapId,
    pub origin: Origin,
}

/// How a boundary is crossed.
///
/// The same vocabulary `W-0097`'s manifest reviews, carried into the position contract so the
/// two cannot drift into different words for the same thing. A geographic seam is the only
/// kind a player walks across without noticing; the rest are deliberate discontinuities, and
/// a client that treated a teleport as a seam would try to animate a journey that never
/// happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum TransitionKind {
    GeographicSeam,
    Door,
    Portal,
    Teleport,
    InstanceEntrance,
}

impl TransitionKind {
    /// Whether crossing this should be continuous for the player.
    pub fn is_seamless(self) -> bool {
        matches!(self, TransitionKind::GeographicSeam)
    }

    /// The reviewed disposition this corresponds to, or `None` for a disposition that is not a
    /// transition at all.
    pub fn from_disposition(disposition: crate::manifest::Disposition) -> Option<TransitionKind> {
        match disposition {
            crate::manifest::Disposition::Geographic => Some(TransitionKind::GeographicSeam),
            crate::manifest::Disposition::Door => Some(TransitionKind::Door),
            crate::manifest::Disposition::Portal => Some(TransitionKind::Portal),
            crate::manifest::Disposition::Teleport => Some(TransitionKind::Teleport),
            crate::manifest::Disposition::InstanceEntrance => {
                Some(TransitionKind::InstanceEntrance)
            }
            // Real, and this compiler will not model it: there is no kind to give it.
            crate::manifest::Disposition::Unsupported => None,
        }
    }
}

/// An entity, for as long as it exists anywhere.
///
/// Not a character slot, not a session, not a process. A monster and a player and a dropped
/// sword all get one, and it survives the entity moving between owners — that is the whole
/// point: `AuthorityEpoch` changes when ownership does, and this does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct EntityId(pub u64);

/// One generation of an entity's authoritative owner.
///
/// Bumped when ownership is installed — bootstrap, and each committed handoff. A resnapshot
/// that does not change owner keeps it. Its only job is to make a message from a previous
/// owner recognisable as stale: a command that arrives carrying an older epoch is answering a
/// question nobody is asking any more.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct AuthorityEpoch(pub u64);

/// An epoch that cannot advance again.
///
/// Its own error rather than a wrap or a panic. Wrapping would silently make an ancient
/// message look current, which is the exact failure the epoch exists to prevent; panicking
/// would take down a region for a condition that is recoverable by resharding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EpochExhausted;

impl AuthorityEpoch {
    /// Advance, or say that this epoch cannot.
    ///
    /// `u64::MAX` handoffs is not a reachable number in practice, and that is not the reason
    /// to check: an unchecked `+ 1` here means the one arithmetic error in this file makes
    /// every stale command look current.
    pub fn advance(self) -> Result<AuthorityEpoch, EpochExhausted> {
        self.0.checked_add(1).map(AuthorityEpoch).ok_or(EpochExhausted)
    }

    /// Whether a message stamped `self` is still current against `installed`.
    pub fn current_against(self, installed: AuthorityEpoch) -> bool {
        self == installed
    }
}

/// One attempt to move an entity from one owner to another.
///
/// Carried so that a repeated attempt is recognisable as the same attempt. `W-0105` proves its
/// arrival decision is deterministic, which is not the same as deduplicated; deduplication
/// needs this id and the prepare/commit machine `W-0096` builds around it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TransferId(pub u64);

/// An authored instance: a dungeon design, not a copy of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct InstanceTemplateId(pub u32);

/// One live copy of an instance template.
///
/// Deliberately separate from `WorldSpaceId`. A template can have many copies at once and a
/// copy outlives none of them; letting a runtime copy borrow a content id would make two
/// parties in different dungeons agree they are in the same place.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct InstanceId(pub u64);

/// A live instance: authored content, this copy of it, and the runtime space it occupies.
///
/// The invariant, stated because it is the whole reason these are three types and not one:
/// **every live instance gets its own `WorldSpaceId`.** Two copies of the same dungeon share
/// a template and share nothing else, so positions in one are meaningless in the other. A
/// runtime space reused across copies would let a party in one dungeon see and step on the
/// other's tiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeInstance {
    pub template: InstanceTemplateId,
    pub instance: InstanceId,
    pub space: WorldSpaceId,
}

/// Why a set of live instances is not valid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstanceFault {
    /// Two live instances claim one runtime space.
    SpaceShared { space: WorldSpaceId },
    /// One instance id appears twice.
    InstanceRepeated { instance: InstanceId },
}

/// Check the one-instance-to-one-space relationship over a set of live instances.
///
/// A function rather than a comment, so the invariant is testable and so the eventual registry
/// has something to call rather than restating it.
pub fn check_instances(live: &[RuntimeInstance]) -> Result<(), InstanceFault> {
    let mut spaces = std::collections::BTreeSet::new();
    let mut instances = std::collections::BTreeSet::new();

    for entry in live {
        if !instances.insert(entry.instance) {
            return Err(InstanceFault::InstanceRepeated { instance: entry.instance });
        }
        if !spaces.insert(entry.space) {
            return Err(InstanceFault::SpaceShared { space: entry.space });
        }
    }

    Ok(())
}

/// Which region is authoritative for an entity, and since when.
///
/// Keyed by region, not by space. A seamless crossing hands a character from one region to
/// another *within* the same space, so ownership recorded per space could not tell the two
/// sides of a seam apart — and the handoff across that seam is the entire subject of W-0096.
///
/// The epoch is needed as well as the region: the same region owns an entity many times over a
/// session, and a message from a previous stay would otherwise look current.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ownership {
    pub entity: EntityId,
    pub region: RegionId,
    pub epoch: AuthorityEpoch,
}

/// What a reader is allowed to do with what it can see.
///
/// The extension point, stated rather than built. An entity observed across a *region*
/// boundary is readable and never commandable: the observer is not its owner, so acting on it
/// would be two processes deciding one entity's fate. Commands go to the owner or nowhere.
///
/// Cross-region, not necessarily cross-space: the interesting case is two regions of one space
/// looking at each other across a seam, which is what makes a seamless world visible.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// The reader owns this entity: it may command it.
    Authoritative,
    /// Visible from another space. Read-only, always.
    Observed,
}

impl Reach {
    pub fn may_command(self) -> bool {
        matches!(self, Reach::Authoritative)
    }
}

/// A command addressed to whoever owns an entity, stamped with what the sender believed.
///
/// Routing is not modelled here. What is modelled is the check every route must make: a
/// command is refused unless the recipient is the current owner *and* the sender's epoch
/// matches. Without the epoch, a command queued before a handoff arrives after it and is
/// executed by the new owner as though nothing had changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Addressed<T> {
    pub entity: EntityId,
    pub epoch: AuthorityEpoch,
    pub command: T,
}

/// Why a command was not executed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The recipient does not own this entity.
    NotTheOwner,
    /// The sender's epoch is not the installed one: it was written before a handoff.
    StaleEpoch,
    /// Observed across a space boundary, so read-only.
    ReadOnly,
}

/// Whether a recipient may execute an addressed command.
///
/// One function so the rule cannot be restated differently in two routers.
pub fn may_execute<T>(
    command: &Addressed<T>,
    owner: Ownership,
    reach: Reach,
) -> Result<(), Refusal> {
    if command.entity != owner.entity {
        return Err(Refusal::NotTheOwner);
    }
    if !reach.may_command() {
        return Err(Refusal::ReadOnly);
    }
    if !command.epoch.current_against(owner.epoch) {
        return Err(Refusal::StaleEpoch);
    }
    Ok(())
}

/// A topology lookup, versioned, rather than a service consulted per movement.
///
/// The shape of the extension point: a caller resolves a space *once* against a stated
/// version and then does its own arithmetic. A central coordinate service asked on every step
/// would put a network round trip inside movement and make the whole world's geometry a single
/// point of failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TopologyRequest {
    pub space: WorldSpaceId,
    pub version: TopologyVersion,
}

/// What a versioned lookup can answer.
///
/// `Resolved` carries the space itself — geometry and placements — because that is the only
/// answer a caller can use. A bare "yes, it exists" marker would force a second question per
/// movement, which is exactly the central coordinate service this shape exists to avoid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TopologyAnswer {
    /// The space exists in that version, and here it is: enough to do local arithmetic
    /// without asking anything else.
    Resolved { space: Space, regions: Vec<RegionPlacement> },
    /// The version is not the one loaded. The caller must not fall back to another: positions
    /// computed against a different release are not comparable.
    WrongVersion { loaded: TopologyVersion },
    /// No such space in that version.
    NoSuchSpace,
}

impl TopologyAnswer {
    /// The resolved space, if the lookup succeeded.
    pub fn space(&self) -> Option<&Space> {
        match self {
            TopologyAnswer::Resolved { space, .. } => Some(space),
            _ => None,
        }
    }

    /// Which region owns a position, if any placement covers it.
    ///
    /// The cross-region question a seam poses: two regions of one space, and a position that
    /// belongs to exactly one of them.
    pub fn region_at(&self, x: i32, y: i32) -> Option<RegionId> {
        let TopologyAnswer::Resolved { space, regions } = self else { return None };
        let local = space.to_local(crate::position::WorldPosition { space: space.id, x, y })?;
        regions
            .iter()
            .find(|placement| placement.map == local.map)
            .map(|placement| placement.region)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::position::LocalPosition;
    use crate::topology::{Geometry, CORE_X, PITCH_X};
    use std::collections::BTreeMap;

    fn owner() -> Ownership {
        Ownership { entity: EntityId(7), region: RegionId(330), epoch: AuthorityEpoch(3) }
    }

    /// Two regions of one space, side by side across a seam: the case the whole contract is
    /// about, and the one `Ownership` keyed by space could not express.
    fn two_regions() -> (Space, Vec<RegionPlacement>) {
        let space = Space {
            id: WorldSpaceId(199),
            version: TopologyVersion(1),
            geometry: Geometry::Plane,
            placements: BTreeMap::from([
                (MapId(330), Origin { x: 0, y: 0 }),
                (MapId(269), Origin { x: PITCH_X, y: 0 }),
            ]),
        };
        let regions = vec![
            RegionPlacement {
                region: RegionId(330),
                space: space.id,
                map: MapId(330),
                origin: Origin { x: 0, y: 0 },
            },
            RegionPlacement {
                region: RegionId(269),
                space: space.id,
                map: MapId(269),
                origin: Origin { x: PITCH_X, y: 0 },
            },
        ];
        (space, regions)
    }

    #[test]
    fn a_seam_crossing_changes_region_and_not_space() {
        // The reason authority is keyed by region. Both sides of this seam are the same world
        // space, so ownership recorded per space would show nothing happening at the exact
        // moment the handoff happens.
        let (space, regions) = two_regions();
        let answer = TopologyAnswer::Resolved { space: space.clone(), regions };

        let west_edge = space
            .to_global(LocalPosition { map: MapId(330), x: CORE_X.1, y: 50 })
            .expect("east column of the western map");
        let east_edge = space
            .to_global(LocalPosition { map: MapId(269), x: CORE_X.0, y: 50 })
            .expect("west column of the eastern map");

        assert_eq!(east_edge.x - west_edge.x, 1, "one tile apart");
        assert_eq!(west_edge.space, east_edge.space, "and the same space");

        assert_eq!(answer.region_at(west_edge.x, west_edge.y), Some(RegionId(330)));
        assert_eq!(answer.region_at(east_edge.x, east_edge.y), Some(RegionId(269)));
    }

    #[test]
    fn a_resolved_answer_carries_enough_to_do_arithmetic_without_asking_again() {
        let (space, regions) = two_regions();
        let answer = TopologyAnswer::Resolved { space, regions };

        let resolved = answer.space().expect("a resolved answer has a space");
        let at = resolved
            .to_global(LocalPosition { map: MapId(269), x: 40, y: 40 })
            .expect("inside the core");
        assert_eq!(resolved.to_local(at).map(|local| local.map), Some(MapId(269)));

        // Nothing covers this, so no region owns it.
        assert_eq!(answer.region_at(100_000, 0), None);
    }

    #[test]
    fn an_epoch_advances_and_recognises_a_stale_stamp() {
        let installed = AuthorityEpoch(3);
        assert!(AuthorityEpoch(3).current_against(installed));
        assert!(!AuthorityEpoch(2).current_against(installed));
        assert!(!AuthorityEpoch(4).current_against(installed));
        assert_eq!(installed.advance(), Ok(AuthorityEpoch(4)));
    }

    #[test]
    fn an_exhausted_epoch_says_so_rather_than_wrapping() {
        // Wrapping would turn the oldest possible message into the newest, which is the one
        // thing the epoch exists to prevent. Unreachable in practice; cheap to be sure of.
        assert_eq!(AuthorityEpoch(u64::MAX).advance(), Err(EpochExhausted));
        assert_eq!(AuthorityEpoch(u64::MAX - 1).advance(), Ok(AuthorityEpoch(u64::MAX)));

        // And an exhausted epoch is still comparable, so a region in that state keeps
        // refusing stale commands rather than accepting everything.
        let installed = AuthorityEpoch(u64::MAX);
        assert!(installed.current_against(installed));
        assert!(!AuthorityEpoch(0).current_against(installed));
    }

    #[test]
    fn a_command_from_before_a_handoff_is_refused_by_the_new_owner() {
        let command = Addressed { entity: EntityId(7), epoch: AuthorityEpoch(2), command: "walk" };
        assert_eq!(may_execute(&command, owner(), Reach::Authoritative), Err(Refusal::StaleEpoch));

        let current = Addressed { epoch: AuthorityEpoch(3), ..command };
        assert_eq!(may_execute(&current, owner(), Reach::Authoritative), Ok(()));
    }

    #[test]
    fn an_observed_entity_is_readable_and_never_commandable() {
        let command = Addressed { entity: EntityId(7), epoch: AuthorityEpoch(3), command: "walk" };
        assert_eq!(may_execute(&command, owner(), Reach::Observed), Err(Refusal::ReadOnly));
        assert!(!Reach::Observed.may_command());
        assert!(Reach::Authoritative.may_command());
    }

    #[test]
    fn a_command_for_somebody_elses_entity_is_refused_before_anything_else_is_checked() {
        // Checked first on purpose: "you do not own this" is the honest answer, and reporting
        // a stale epoch for an entity the recipient never owned would send somebody looking
        // at the wrong problem.
        let command = Addressed { entity: EntityId(9), epoch: AuthorityEpoch(1), command: "walk" };
        assert_eq!(may_execute(&command, owner(), Reach::Authoritative), Err(Refusal::NotTheOwner));
    }

    #[test]
    fn every_live_instance_gets_its_own_runtime_space() {
        // Two parties in the same dungeon design. Same template, different copies, and their
        // positions must not be comparable -- so different runtime spaces.
        let live = [
            RuntimeInstance {
                template: InstanceTemplateId(4),
                instance: InstanceId(1),
                space: WorldSpaceId(9001),
            },
            RuntimeInstance {
                template: InstanceTemplateId(4),
                instance: InstanceId(2),
                space: WorldSpaceId(9002),
            },
        ];
        assert_eq!(check_instances(&live), Ok(()));
        assert_eq!(live[0].template, live[1].template, "one authored dungeon");
        assert_ne!(live[0].space, live[1].space, "two places");
    }

    #[test]
    fn two_live_instances_sharing_a_runtime_space_is_a_fault() {
        let shared = [
            RuntimeInstance {
                template: InstanceTemplateId(4),
                instance: InstanceId(1),
                space: WorldSpaceId(9001),
            },
            RuntimeInstance {
                template: InstanceTemplateId(4),
                instance: InstanceId(2),
                space: WorldSpaceId(9001),
            },
        ];
        assert_eq!(
            check_instances(&shared),
            Err(InstanceFault::SpaceShared { space: WorldSpaceId(9001) })
        );

        let repeated = [
            RuntimeInstance {
                template: InstanceTemplateId(4),
                instance: InstanceId(1),
                space: WorldSpaceId(9001),
            },
            RuntimeInstance {
                template: InstanceTemplateId(5),
                instance: InstanceId(1),
                space: WorldSpaceId(9002),
            },
        ];
        assert_eq!(
            check_instances(&repeated),
            Err(InstanceFault::InstanceRepeated { instance: InstanceId(1) })
        );
    }

    #[test]
    fn only_a_geographic_seam_is_crossed_without_noticing() {
        assert!(TransitionKind::GeographicSeam.is_seamless());
        for kind in [
            TransitionKind::Door,
            TransitionKind::Portal,
            TransitionKind::Teleport,
            TransitionKind::InstanceEntrance,
        ] {
            assert!(!kind.is_seamless(), "{kind:?} is a deliberate discontinuity");
        }
    }

    #[test]
    fn the_reviewed_dispositions_map_onto_transition_kinds_without_a_second_vocabulary() {
        use crate::manifest::Disposition;

        assert_eq!(
            TransitionKind::from_disposition(Disposition::Geographic),
            Some(TransitionKind::GeographicSeam)
        );
        assert_eq!(TransitionKind::from_disposition(Disposition::Door), Some(TransitionKind::Door));
        assert_eq!(
            TransitionKind::from_disposition(Disposition::InstanceEntrance),
            Some(TransitionKind::InstanceEntrance)
        );
        // "Real, and this compiler will not model it" has no kind, and inventing one would be
        // the compiler deciding geography after all.
        assert_eq!(TransitionKind::from_disposition(Disposition::Unsupported), None);
    }

    #[test]
    fn the_kinds_of_identity_are_not_interchangeable() {
        // A compile-time property, asserted here as documentation of intent: the same number
        // in two of these types is two different things, and there is no conversion.
        let entity = EntityId(42);
        let instance = InstanceId(42);
        let template = InstanceTemplateId(42);
        let space = WorldSpaceId(42);
        let region = RegionId(42);

        assert_eq!(entity.0, instance.0);
        assert_eq!(template.0 as u128, space.0);
        assert_eq!(region.0 as u128, space.0);

        // Ownership carries a region and an epoch, and neither is the entity's identity: the
        // entity outlives every owner it has.
        let moved = Ownership {
            region: RegionId(269),
            epoch: owner().epoch.advance().expect("room to advance"),
            ..owner()
        };
        assert_eq!(moved.entity, owner().entity, "the entity did not become another entity");
        assert_ne!(moved.region, owner().region, "its owner did");
    }

    #[test]
    fn a_lookup_against_the_wrong_version_says_so_instead_of_falling_back() {
        // Falling back to the loaded version would answer a different question than the one
        // asked, with coordinates that are not comparable to the caller's.
        let answer = TopologyAnswer::WrongVersion { loaded: TopologyVersion(9) };
        assert_eq!(answer.space(), None);
        assert_eq!(answer.region_at(0, 0), None);

        let request = TopologyRequest { space: WorldSpaceId(199), version: TopologyVersion(8) };
        assert_eq!(request.version, TopologyVersion(8));
        assert_eq!(TopologyAnswer::NoSuchSpace.space(), None);
    }
}

/// The hand-authored identity contract, compiled in.
///
/// The same file `Arena.World.Identity` reads. Neither side defines the answers: these are the
/// rules a router applies before letting anything act on an entity, and two implementations
/// that agreed only with themselves would be two different answers to "who may move this
/// player".
pub fn contract() -> &'static str {
    include_str!("../fixtures/identity_contract.txt")
}

#[cfg(test)]
mod contract_tests {
    use super::*;

    fn lines() -> impl Iterator<Item = (&'static str, Vec<&'static str>, Vec<&'static str>)> {
        contract()
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(|line| {
                let (body, expected) = line.split_once("->").expect("every case states a result");
                (
                    line,
                    body.split_whitespace().collect::<Vec<_>>(),
                    expected.split_whitespace().collect::<Vec<_>>(),
                )
            })
    }

    #[test]
    fn rust_satisfies_every_case_in_the_identity_contract() {
        let mut checked = 0;

        for (line, body, expected) in lines() {
            match body.as_slice() {
                ["execute", "owner", entity, region, epoch, "command", command_entity, command_epoch, "reach", reach] =>
                {
                    let owner = Ownership {
                        entity: EntityId(entity.parse().expect("entity")),
                        region: RegionId(region.parse().expect("region")),
                        epoch: AuthorityEpoch(epoch.parse().expect("epoch")),
                    };
                    let command = Addressed {
                        entity: EntityId(command_entity.parse().expect("entity")),
                        epoch: AuthorityEpoch(command_epoch.parse().expect("epoch")),
                        command: (),
                    };
                    let reach = match *reach {
                        "authoritative" => Reach::Authoritative,
                        "observed" => Reach::Observed,
                        other => panic!("unknown reach {other}"),
                    };

                    let want = match expected.as_slice() {
                        ["ok"] => Ok(()),
                        ["not-owner"] => Err(Refusal::NotTheOwner),
                        ["stale-epoch"] => Err(Refusal::StaleEpoch),
                        ["read-only"] => Err(Refusal::ReadOnly),
                        other => panic!("unknown result {other:?}"),
                    };
                    assert_eq!(may_execute(&command, owner, reach), want, "{line}");
                }

                ["advance", epoch] => {
                    let epoch = AuthorityEpoch(epoch.parse().expect("epoch"));
                    let want = match expected.as_slice() {
                        ["exhausted"] => Err(EpochExhausted),
                        [next] => Ok(AuthorityEpoch(next.parse().expect("next"))),
                        other => panic!("unknown result {other:?}"),
                    };
                    assert_eq!(epoch.advance(), want, "{line}");
                }

                ["instances", entries @ ..] => {
                    let live: Vec<RuntimeInstance> = entries
                        .iter()
                        .map(|entry| {
                            let field: Vec<&str> = entry.split(':').collect();
                            RuntimeInstance {
                                template: InstanceTemplateId(field[0].parse().expect("template")),
                                instance: InstanceId(field[1].parse().expect("instance")),
                                space: WorldSpaceId(field[2].parse().expect("space")),
                            }
                        })
                        .collect();

                    let want = match expected.as_slice() {
                        ["ok"] => Ok(()),
                        ["space-shared", space] => Err(InstanceFault::SpaceShared {
                            space: WorldSpaceId(space.parse().expect("space")),
                        }),
                        ["instance-repeated", id] => Err(InstanceFault::InstanceRepeated {
                            instance: InstanceId(id.parse().expect("instance")),
                        }),
                        other => panic!("unknown result {other:?}"),
                    };
                    assert_eq!(check_instances(&live), want, "{line}");
                }

                ["seamless", kind] => {
                    let kind = match *kind {
                        "seam" => TransitionKind::GeographicSeam,
                        "door" => TransitionKind::Door,
                        "portal" => TransitionKind::Portal,
                        "teleport" => TransitionKind::Teleport,
                        "instance" => TransitionKind::InstanceEntrance,
                        other => panic!("unknown kind {other}"),
                    };
                    assert_eq!(kind.is_seamless(), expected == ["yes"], "{line}");
                }

                other => panic!("cannot read contract line {other:?}"),
            }
            checked += 1;
        }

        assert!(checked >= 24, "the contract should be worth checking: {checked}");
    }
}
