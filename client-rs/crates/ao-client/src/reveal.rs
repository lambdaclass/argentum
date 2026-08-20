//! When the world may first be shown, and what has to be true for that.
//!
//! Today the boot screen is a page element that lifts two frames after `init()`
//! resolves — which is when the wasm module *starts*, not when there is anything
//! worth looking at. A player therefore watches the world assemble: a placeholder
//! grid, then sheets appearing one at a time, then item icons replacing their own
//! names. The screenshot that prompted this showed flat green tiles and text where
//! artwork belongs, and nothing on screen admitted it was still loading.
//!
//! This module owns the decision instead. It is deliberately pure — no Bevy systems,
//! no asset handles, no rendering — because the questions that have gone wrong here
//! are questions about *order and identity*: which members are required, which load
//! generation a completion belongs to, whether progress can go backwards, and whether
//! a late answer from an abandoned load can reveal a scene nobody is waiting for. All
//! of those can be tested exhaustively without a GPU, and none of them can be tested
//! honestly through a screenshot.
//!
//! ## Why a named set rather than "everything"
//!
//! "Wait for everything" has two failure modes and no upside. Interpreted widely it
//! waits for the entire archive, so the first frame arrives minutes late; interpreted
//! narrowly it waits for whatever the loader happens to track, which is how a sheet
//! that the visible tiles need gets left out and pops in afterwards. [`RevealSet`]
//! names its members, so the set is reviewable and a member added later is a visible
//! change rather than a silent one.
//!
//! ## Why load generations
//!
//! A retry, a character switch, a reconnect, a resize or a new map all abandon the
//! candidate scene in flight. The work already dispatched cannot be recalled, so its
//! answers keep arriving; a loader that accepts them reveals a world built for a
//! request nobody made. Every completion carries the generation that asked for it and
//! anything older is dropped.

use std::collections::BTreeMap;

/// A required part of the first playable frame.
///
/// Named rather than numbered so a failure says what is missing, and ordered so the
/// progress readout is stable between runs — a list that reorders itself looks like
/// progress going backwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Member {
    /// The current map's validated tile data.
    MapData,
    /// Every sprite sheet the initial viewport needs, including its bounded prefetch
    /// margin.
    ///
    /// One member rather than one per sheet, because which sheets those are is not known
    /// until the map data has been read — and a set that gains members once it finds out
    /// is a set nobody reviewed. The graphics layer owns the list; a failure names the
    /// individual sheet in its payload.
    Sheets,
    /// The local player's body, head and equipment composition.
    Character,
    /// The fallback sprites a missing optional asset is drawn with.
    Fallbacks,
    /// The interface font. Without it every label measures as nothing.
    Font,
    /// HUD and icon atlases.
    HudAtlas,
    /// The first typed HUD snapshot, so the bars and slots have values.
    Snapshot,
    /// Render pipelines compiled and the first frame's uploads finished, where the
    /// platform can be asked.
    GpuReady,
}

impl Member {
    /// The stage this member is reported under.
    ///
    /// Members are what readiness is computed from; stages are what a player reads.
    /// Keeping them separate means adding a sheet does not add a line to the screen.
    pub fn stage(self) -> Stage {
        match self {
            Member::MapData => Stage::Map,
            Member::Sheets | Member::Fallbacks | Member::Font | Member::HudAtlas => Stage::Assets,
            Member::Character | Member::Snapshot => Stage::World,
            Member::GpuReady => Stage::Gpu,
        }
    }

    /// A key for the interface to translate. Never a sentence: this is shown to a
    /// player who may not read English.
    pub fn name_key(self) -> &'static str {
        match self {
            Member::MapData => "reveal.member.map-data",
            Member::Sheets => "reveal.member.sheets",
            Member::Character => "reveal.member.character",
            Member::Fallbacks => "reveal.member.fallbacks",
            Member::Font => "reveal.member.font",
            Member::HudAtlas => "reveal.member.hud-atlas",
            Member::Snapshot => "reveal.member.snapshot",
            Member::GpuReady => "reveal.member.gpu",
        }
    }
}

/// What a player is told is happening.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Stage {
    Map,
    Assets,
    World,
    Gpu,
}

impl Stage {
    pub fn name_key(self) -> &'static str {
        match self {
            Stage::Map => "reveal.stage.map",
            Stage::Assets => "reveal.stage.assets",
            Stage::World => "reveal.stage.world",
            Stage::Gpu => "reveal.stage.gpu",
        }
    }

    /// Every stage, in the order they are reported.
    pub const ALL: [Stage; 4] = [Stage::Map, Stage::Assets, Stage::World, Stage::Gpu];
}

/// Why a member did not arrive.
///
/// Each one leads somewhere different for the player, which is the only reason to
/// distinguish them: a timeout invites another attempt, a texture too large for the
/// device never will, and a corrupt asset is a fault to report rather than retry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// Never answered inside its budget.
    TimedOut,
    /// The transport failed. Worth another attempt.
    Unreachable(String),
    /// It arrived and was not what it claimed to be.
    Corrupt(String),
    /// Larger than this device can hold — a texture beyond the maximum dimension, or
    /// a set beyond the memory budget. Retrying changes nothing.
    TooLarge { needed: u64, allowed: u64 },
}

impl Failure {
    /// Whether offering "try again" is honest.
    pub fn is_worth_retrying(&self) -> bool {
        matches!(self, Failure::TimedOut | Failure::Unreachable(_))
    }

    pub fn explanation_key(&self) -> &'static str {
        match self {
            Failure::TimedOut => "reveal.failed.timed-out",
            Failure::Unreachable(_) => "reveal.failed.unreachable",
            Failure::Corrupt(_) => "reveal.failed.corrupt",
            Failure::TooLarge { .. } => "reveal.failed.too-large",
        }
    }
}

/// How far one member has got.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemberState {
    Waiting,
    /// Underway, with bytes or items where the loader actually knows them.
    ///
    /// `None` means "no number to report", which is different from zero. A loader that
    /// reports zero of zero for something it cannot measure produces a bar that sits
    /// at 100% while nothing has happened.
    Loading {
        done: Option<u64>,
        total: Option<u64>,
    },
    Ready,
    Failed(Failure),
}

/// Which load this belongs to.
///
/// Monotonic. A retry, character switch, reconnect, resize or new map takes the next
/// one, and every completion is checked against the current value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct Generation(pub u64);

/// The candidate first scene: what it needs, and how far each part has got.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevealSet {
    generation: Generation,
    members: BTreeMap<Member, MemberState>,
    /// Set once and never cleared: a scene that has been shown cannot un-reveal.
    committed: bool,
}

impl RevealSet {
    /// A set that requires exactly `members`.
    pub fn new(generation: Generation, members: impl IntoIterator<Item = Member>) -> Self {
        Self {
            generation,
            members: members.into_iter().map(|m| (m, MemberState::Waiting)).collect(),
            committed: false,
        }
    }

    pub fn generation(&self) -> Generation {
        self.generation
    }

    pub fn is_committed(&self) -> bool {
        self.committed
    }

    /// Everything this set is waiting for, in report order.
    pub fn members(&self) -> impl Iterator<Item = (Member, &MemberState)> {
        self.members.iter().map(|(member, state)| (*member, state))
    }

    /// Record progress or completion, if it belongs to this load.
    ///
    /// Returns whether the report was accepted. A report from an older generation is
    /// refused: its work was abandoned, and letting it through is how a scene built
    /// for an abandoned request gets revealed. A report for a member this set does not
    /// require is also refused rather than silently added — a set that grows at runtime
    /// is not a reviewable contract.
    pub fn report(&mut self, generation: Generation, member: Member, state: MemberState) -> bool {
        if generation != self.generation {
            return false;
        }
        let Some(slot) = self.members.get_mut(&member) else {
            return false;
        };

        // Readiness never regresses within a generation. A loader that reports
        // `Loading` after `Ready` — a second handle for the same sheet, a re-entered
        // system — would otherwise take a finished bar backwards, which reads as the
        // client losing work it had already done.
        if matches!(slot, MemberState::Ready) && !matches!(state, MemberState::Failed(_)) {
            return false;
        }

        *slot = state;
        true
    }

    /// Whether every member is ready.
    pub fn is_ready(&self) -> bool {
        !self.members.is_empty()
            && self.members.values().all(|state| matches!(state, MemberState::Ready))
    }

    /// The first failure, if any, with the member it belongs to.
    ///
    /// First in member order rather than first in time, so the message a player sees
    /// does not depend on which of two simultaneous failures was processed first.
    pub fn failure(&self) -> Option<(Member, &Failure)> {
        self.members.iter().find_map(|(member, state)| match state {
            MemberState::Failed(failure) => Some((*member, failure)),
            _ => None,
        })
    }

    /// Show the scene. Fails unless everything is ready, because the whole point of
    /// this type is that the decision cannot be made anywhere else.
    pub fn commit(&mut self) -> bool {
        if self.is_ready() {
            self.committed = true;
        }
        self.committed
    }

    /// Progress, as a fraction of members ready.
    ///
    /// Deliberately counted from *completion*, not from dispatch: the loader this
    /// replaces treated creating an asset handle as progress, so the bar reached the
    /// end while the decode had not started. Bytes, where members report them, are
    /// carried separately for the readout rather than folded into this number — one
    /// sheet's bytes say nothing about how many sheets remain.
    pub fn fraction_ready(&self) -> f32 {
        if self.members.is_empty() {
            return 0.0;
        }
        let ready = self.members.values().filter(|s| matches!(s, MemberState::Ready)).count();
        ready as f32 / self.members.len() as f32
    }

    /// Bytes done and known-total across every member that reports them.
    ///
    /// `total` is `None` until every reporting member knows its own total: a partial
    /// sum presented as the total makes the number shrink as more members report,
    /// which is progress going backwards in the one place a player is watching.
    pub fn bytes(&self) -> (u64, Option<u64>) {
        let mut done = 0;
        let mut total = Some(0);
        let mut reporting = 0;

        for state in self.members.values() {
            match state {
                MemberState::Loading { done: d, total: t } => {
                    reporting += 1;
                    done += d.unwrap_or(0);
                    total = match (total, t) {
                        (Some(sum), Some(t)) => Some(sum + t),
                        _ => None,
                    };
                }
                MemberState::Ready => {}
                _ => {}
            }
        }

        if reporting == 0 {
            return (done, None);
        }
        (done, total)
    }

    /// How far each stage has got, for the readout.
    pub fn stages(&self) -> Vec<(Stage, StageProgress)> {
        Stage::ALL
            .iter()
            .filter_map(|stage| {
                let members: Vec<&MemberState> = self
                    .members
                    .iter()
                    .filter(|(member, _)| member.stage() == *stage)
                    .map(|(_, state)| state)
                    .collect();

                if members.is_empty() {
                    return None;
                }

                let ready = members.iter().filter(|s| matches!(s, MemberState::Ready)).count();
                let failed = members.iter().any(|s| matches!(s, MemberState::Failed(_)));
                Some((*stage, StageProgress { ready, total: members.len(), failed }))
            })
            .collect()
    }
}

/// One line of the loading readout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StageProgress {
    pub ready: usize,
    pub total: usize,
    pub failed: bool,
}

impl StageProgress {
    pub fn is_complete(&self) -> bool {
        self.ready == self.total && !self.failed
    }
}

/// What the barrier is showing.
///
/// No `Eq`: it carries the progress fraction, and a float has no total equality. The
/// fraction is here rather than recomputed by the interface so the screen and the
/// decision cannot disagree about how far along the load is.
#[derive(Debug, Clone, PartialEq)]
pub enum Barrier {
    /// Loading, with the stages to show and how far they have got.
    Loading { fraction: f32, stages: Vec<(Stage, StageProgress)> },
    /// Stopped on something the player has to answer.
    Failed { member: Member, failure: Failure, may_retry: bool },
    /// Gone: the world is on screen.
    Revealed,
}

/// What the barrier should show for `set`.
///
/// A function of the set rather than a state machine with its own memory, so it cannot
/// disagree with the thing it is describing.
pub fn barrier_for(set: &RevealSet) -> Barrier {
    if set.is_committed() {
        return Barrier::Revealed;
    }
    if let Some((member, failure)) = set.failure() {
        return Barrier::Failed {
            member,
            failure: failure.clone(),
            may_retry: failure.is_worth_retrying(),
        };
    }
    Barrier::Loading { fraction: set.fraction_ready(), stages: set.stages() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_set(generation: u64) -> RevealSet {
        RevealSet::new(
            Generation(generation),
            [
                Member::MapData,
                Member::Sheets,
                Member::Character,
                Member::Fallbacks,
                Member::Font,
                Member::HudAtlas,
                Member::Snapshot,
                Member::GpuReady,
            ],
        )
    }

    /// Drive every member to ready. Reports on an already-ready member are refused by
    /// design, so the result is not asserted here — the assertion that matters is
    /// `is_ready` afterwards.
    fn ready_everything(set: &mut RevealSet, generation: u64) {
        let members: Vec<Member> = set.members().map(|(member, _)| member).collect();
        for member in members {
            set.report(Generation(generation), member, MemberState::Ready);
        }
        assert!(set.is_ready(), "a set did not reach ready");
    }

    #[test]
    fn nothing_is_revealed_until_everything_is_ready() {
        let mut set = full_set(1);
        assert!(!set.is_ready());

        let members: Vec<Member> = set.members().map(|(member, _)| member).collect();
        let last = *members.last().expect("members");

        for member in &members {
            if *member == last {
                continue;
            }
            set.report(Generation(1), *member, MemberState::Ready);
            assert!(!set.is_ready(), "ready with {member:?} outstanding");
            assert!(!set.commit(), "committed with {member:?} outstanding");
            assert_eq!(barrier_for(&set), {
                Barrier::Loading { fraction: set.fraction_ready(), stages: set.stages() }
            });
        }

        set.report(Generation(1), last, MemberState::Ready);
        assert!(set.is_ready());
        assert!(set.commit());
        assert_eq!(barrier_for(&set), Barrier::Revealed);
    }

    #[test]
    fn completion_order_does_not_matter() {
        // The loader has no control over the order answers arrive in, so the decision
        // must not either. Every rotation of the same set has to reach the same place.
        let members: Vec<Member> = full_set(1).members().map(|(member, _)| member).collect();

        for rotation in 0..members.len() {
            let mut set = full_set(1);
            for offset in 0..members.len() {
                let member = members[(rotation + offset) % members.len()];
                set.report(Generation(1), member, MemberState::Ready);
            }
            assert!(set.is_ready(), "rotation {rotation} did not finish");
            assert!(set.commit());
        }
    }

    #[test]
    fn one_slow_member_holds_the_whole_scene() {
        // The two-second delayed texture from this task's contract. Everything else
        // being ready must not reveal a world with a hole in it.
        let mut set = full_set(1);
        let members: Vec<Member> = set.members().map(|(member, _)| member).collect();

        for member in members {
            if member == Member::Sheets {
                continue;
            }
            set.report(Generation(1), member, MemberState::Ready);
        }

        assert!(!set.is_ready());
        assert!(!set.commit());
        match barrier_for(&set) {
            Barrier::Loading { fraction, .. } => {
                assert!(fraction > 0.8 && fraction < 1.0, "fraction {fraction}");
            }
            other => panic!("expected loading, got {other:?}"),
        }

        // And it is exactly the missing member that is still waiting.
        let waiting: Vec<Member> = set
            .members()
            .filter(|(_, state)| matches!(state, MemberState::Waiting))
            .map(|(member, _)| member)
            .collect();
        assert_eq!(waiting, vec![Member::Sheets]);
    }

    #[test]
    fn an_answer_from_an_abandoned_load_cannot_reveal_anything() {
        // A retry, a character switch, a reconnect or a resize abandons the candidate,
        // but the work already dispatched keeps answering. Accepting those answers is
        // how a client shows a scene assembled for a request nobody made.
        let mut set = full_set(2);

        for member in [Member::MapData, Member::Sheets, Member::Character] {
            assert!(!set.report(Generation(1), member, MemberState::Ready), "{member:?} accepted");
        }
        assert_eq!(set.fraction_ready(), 0.0);

        // The current generation still works, so the refusal is about identity rather
        // than a set that has stopped listening.
        assert!(set.report(Generation(2), Member::MapData, MemberState::Ready));

        // And a newer one is refused too: this set is not the one being built.
        assert!(!set.report(Generation(3), Member::Sheets, MemberState::Ready));
    }

    #[test]
    fn a_member_that_is_not_required_is_refused_rather_than_added() {
        // A set that grows at runtime is not a contract anybody reviewed, and it means
        // "wait for everything" has quietly come back.
        let mut set = RevealSet::new(Generation(1), [Member::MapData, Member::Font]);

        assert!(!set.report(Generation(1), Member::Sheets, MemberState::Ready));
        assert_eq!(set.members().count(), 2);

        set.report(Generation(1), Member::MapData, MemberState::Ready);
        set.report(Generation(1), Member::Font, MemberState::Ready);
        assert!(set.is_ready(), "an unrequired member changed readiness");
    }

    #[test]
    fn progress_never_goes_backwards_within_a_generation() {
        // Two handles for one sheet, or a system that re-enters, would otherwise take a
        // finished bar backwards — which reads as the client losing work it had done.
        let mut set = full_set(1);
        set.report(Generation(1), Member::Sheets, MemberState::Ready);
        let after_ready = set.fraction_ready();

        assert!(!set.report(
            Generation(1),
            Member::Sheets,
            MemberState::Loading { done: Some(1), total: Some(10) }
        ));
        assert_eq!(set.fraction_ready(), after_ready);

        assert!(!set.report(Generation(1), Member::Sheets, MemberState::Waiting));
        assert_eq!(set.fraction_ready(), after_ready);

        // A failure does get through: something that was ready can still break, and
        // hiding that would leave a scene claiming a member it no longer has.
        assert!(set.report(
            Generation(1),
            Member::Sheets,
            MemberState::Failed(Failure::Corrupt("truncated".into()))
        ));
        assert!(set.failure().is_some());
    }

    #[test]
    fn a_failure_says_which_part_and_whether_trying_again_is_honest() {
        let mut set = full_set(1);
        set.report(
            Generation(1),
            Member::Sheets,
            MemberState::Failed(Failure::TooLarge { needed: 33_554_432, allowed: 16_777_216 }),
        );

        match barrier_for(&set) {
            Barrier::Failed { member, failure, may_retry } => {
                assert_eq!(member, Member::Sheets);
                assert!(!may_retry, "offered a retry for a device limit");
                assert_eq!(failure.explanation_key(), "reveal.failed.too-large");
            }
            other => panic!("expected a failure, got {other:?}"),
        }

        // And the retryable ones do offer it.
        let mut set = full_set(1);
        set.report(
            Generation(1),
            Member::MapData,
            MemberState::Failed(Failure::Unreachable("socket closed".into())),
        );
        assert!(matches!(barrier_for(&set), Barrier::Failed { may_retry: true, .. }));
    }

    #[test]
    fn a_failure_outranks_the_progress_bar() {
        // A bar at 90% next to a dead load is a screen that says "nearly there" about
        // something that will never finish.
        let mut set = full_set(1);
        let members: Vec<Member> = set.members().map(|(member, _)| member).collect();
        for member in members.iter().take(members.len() - 1) {
            set.report(Generation(1), *member, MemberState::Ready);
        }
        set.report(
            Generation(1),
            *members.last().expect("members"),
            MemberState::Failed(Failure::TimedOut),
        );

        assert!(matches!(barrier_for(&set), Barrier::Failed { .. }));
        assert!(!set.commit(), "committed a set with a failed member");
    }

    #[test]
    fn a_revealed_scene_stays_revealed() {
        // Un-revealing is a black frame in the middle of play. Whatever happens to the
        // loader afterwards, the scene that was shown stays shown; a new candidate is
        // a new generation, not an edit to this one.
        let mut set = full_set(1);
        ready_everything(&mut set, 1);
        assert!(set.commit());

        assert!(set.report(Generation(1), Member::Sheets, MemberState::Failed(Failure::TimedOut)));
        assert!(set.is_committed());
        assert_eq!(barrier_for(&set), Barrier::Revealed);
    }

    #[test]
    fn an_empty_set_is_never_ready() {
        // Otherwise "no members" is indistinguishable from "everything is done", and a
        // loader that has not been told what to wait for reveals immediately — the exact
        // bug this task exists to remove, in its most embarrassing form.
        let mut set = RevealSet::new(Generation(1), []);
        assert!(!set.is_ready());
        assert!(!set.commit());
        assert_eq!(set.fraction_ready(), 0.0);
    }

    #[test]
    fn bytes_are_only_totalled_when_every_reporter_knows_its_own_total() {
        // A partial sum shown as the total shrinks as more members report, which is
        // progress going backwards in the one place a player is watching.
        let mut set = full_set(1);
        set.report(
            Generation(1),
            Member::Sheets,
            MemberState::Loading { done: Some(100), total: Some(400) },
        );
        assert_eq!(set.bytes(), (100, Some(400)));

        // A second reporter that cannot measure itself. The known bytes still add up;
        // the total becomes unknown rather than becoming the partial sum.
        set.report(
            Generation(1),
            Member::MapData,
            MemberState::Loading { done: Some(50), total: None },
        );
        assert_eq!(set.bytes(), (150, None), "an unknown total was folded into a number");
    }

    #[test]
    fn stages_are_what_a_player_reads_and_members_are_what_readiness_counts() {
        // Adding a sheet must not add a line to the screen; four sheets are one
        // "assets" line that is three quarters done.
        let mut set = full_set(1);
        set.report(Generation(1), Member::Sheets, MemberState::Ready);
        set.report(Generation(1), Member::Font, MemberState::Ready);
        set.report(Generation(1), Member::HudAtlas, MemberState::Ready);

        let stages = set.stages();
        assert_eq!(stages.len(), 4, "{stages:?}");

        let assets = stages
            .iter()
            .find(|(stage, _)| *stage == Stage::Assets)
            .map(|(_, progress)| *progress)
            .expect("an assets stage");
        assert_eq!(assets.ready, 3);
        assert_eq!(assets.total, 4, "sheets, fallbacks, font and atlas");
        assert!(!assets.is_complete());

        let map = stages
            .iter()
            .find(|(stage, _)| *stage == Stage::Map)
            .map(|(_, progress)| *progress)
            .expect("a map stage");
        assert_eq!((map.ready, map.total), (0, 1));
    }

    #[test]
    fn every_member_stage_and_failure_can_be_translated() {
        // The barrier is the first thing a player sees. A raw key or an English
        // sentence on it is the worst possible place for either.
        for member in [
            Member::MapData,
            Member::Sheets,
            Member::Character,
            Member::Fallbacks,
            Member::Font,
            Member::HudAtlas,
            Member::Snapshot,
            Member::GpuReady,
        ] {
            let key = member.name_key();
            assert!(key.starts_with("reveal.member."), "{member:?}: {key}");
            assert!(!key.ends_with('.'), "{member:?} has an empty segment");
        }

        for stage in Stage::ALL {
            assert!(stage.name_key().starts_with("reveal.stage."));
        }

        for failure in [
            Failure::TimedOut,
            Failure::Unreachable(String::new()),
            Failure::Corrupt(String::new()),
            Failure::TooLarge { needed: 1, allowed: 0 },
        ] {
            assert!(failure.explanation_key().starts_with("reveal.failed."));
        }
    }

    #[test]
    fn a_thousand_load_and_cancel_cycles_leave_one_set_and_no_growth() {
        // The contract asks for a thousand cycles with cleanup checked. In this layer
        // "cleanup" means the set does not accumulate: a generation counter that grows
        // is fine, a member list that grows is a leak, and a stale generation that can
        // still be reported into is a correctness bug rather than a memory one.
        let mut generation = 0;
        let mut set = full_set(0);
        let member_count = set.members().count();

        for cycle in 1..=1_000 {
            generation = cycle;
            set = full_set(generation);

            // Half the cycles get partway and are abandoned; the others complete.
            set.report(Generation(generation), Member::MapData, MemberState::Ready);
            if cycle % 2 == 0 {
                ready_everything(&mut set, generation);
                assert!(set.commit());
            }

            assert_eq!(set.members().count(), member_count, "the set grew on cycle {cycle}");
            // Answers from every previous generation are still refused, however many
            // there have been.
            assert!(!set.report(Generation(generation - 1), Member::Font, MemberState::Ready));
        }

        assert_eq!(set.generation(), Generation(1_000));
    }
}
