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

use crate::position::{TopologyVersion, WorldSpaceId};

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

impl AuthorityEpoch {
    pub fn next(self) -> AuthorityEpoch {
        AuthorityEpoch(self.0 + 1)
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

/// Which process is authoritative for an entity, and since when.
///
/// `space` says where the owner is; `epoch` says which generation of ownership this is. Both
/// are needed: the same space owns an entity many times over a session, and a stale message
/// from a previous stay would otherwise look current.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ownership {
    pub entity: EntityId,
    pub space: WorldSpaceId,
    pub epoch: AuthorityEpoch,
}

/// What a reader is allowed to do with what it can see.
///
/// The extension point, stated rather than built. An entity observed across a space boundary
/// is readable and never commandable: the observer is not its owner, so acting on it would be
/// two processes deciding one entity's fate. Commands go to the owner or nowhere.
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TopologyAnswer {
    /// The space exists in that version.
    Known,
    /// The version is not the one loaded. The caller must not fall back to another: positions
    /// computed against a different release are not comparable.
    WrongVersion { loaded: TopologyVersion },
    /// No such space in that version.
    NoSuchSpace,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner() -> Ownership {
        Ownership { entity: EntityId(7), space: WorldSpaceId(199), epoch: AuthorityEpoch(3) }
    }

    #[test]
    fn an_epoch_advances_and_recognises_a_stale_stamp() {
        let installed = AuthorityEpoch(3);
        assert!(AuthorityEpoch(3).current_against(installed));
        assert!(!AuthorityEpoch(2).current_against(installed));
        assert!(!AuthorityEpoch(4).current_against(installed));
        assert_eq!(installed.next(), AuthorityEpoch(4));
    }

    #[test]
    fn a_command_from_before_a_handoff_is_refused_by_the_new_owner() {
        // The case the epoch exists for. The command was legitimate when written; by the time
        // it arrives the entity has a different owner, and executing it would apply an
        // intention formed under a world that no longer holds.
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
    fn the_four_kinds_of_identity_are_not_interchangeable() {
        // A compile-time property, asserted here as documentation of intent: the same number
        // in two of these types is two different things, and there is no conversion.
        let entity = EntityId(42);
        let instance = InstanceId(42);
        let template = InstanceTemplateId(42);
        let space = WorldSpaceId(42);

        assert_eq!(entity.0 as u64, instance.0);
        assert_eq!(template.0 as u64, space.0 as u64);

        // Ownership carries a space and an epoch, and neither is the entity's identity: the
        // entity outlives every owner it has.
        let mut moved = owner();
        moved.space = WorldSpaceId(37);
        moved.epoch = moved.epoch.next();
        assert_eq!(moved.entity, owner().entity, "the entity did not become another entity");
        assert_ne!(moved.space, owner().space);
    }

    #[test]
    fn a_lookup_against_the_wrong_version_says_so_instead_of_falling_back() {
        // Falling back to the loaded version would answer a different question than the one
        // asked, with coordinates that are not comparable to the caller's.
        let answer = TopologyAnswer::WrongVersion { loaded: TopologyVersion(9) };
        assert_ne!(answer, TopologyAnswer::Known);

        let request = TopologyRequest { space: WorldSpaceId(199), version: TopologyVersion(8) };
        assert_eq!(request.version, TopologyVersion(8));
        assert_ne!(TopologyAnswer::NoSuchSpace, TopologyAnswer::Known);
    }
}
