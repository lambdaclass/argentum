//! Deterministic snapshots for every state the interface has to survive.
//!
//! These drive the component gallery, the golden screenshots and most UI tests.
//! They exist because the happy path is the easy half: a client is judged on
//! what it does when the pack is empty, the session died mid-action or the
//! server sent something impossible.
//!
//! Two properties are load-bearing:
//!
//! **Deterministic.** No clock, no randomness, no iteration over a hash map.
//! A golden screenshot is worthless if the same scenario renders differently on
//! the next run.
//!
//! **Not a parallel API.** Fixtures build the same [`UiSnapshot`] the live
//! adapter will, through the same constructors. A fixture-only field would be a
//! widget contract that production never exercises.

use crate::view::*;
/// The states every screen must handle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scenario {
    /// A mid-level character, mid-session, with things in the pack.
    Populated,
    /// Connected and alive, but nothing acquired yet.
    Empty,
    /// Connected, waiting for the first snapshot.
    Loading,
    /// Alive but unable to act: out of mana, on cooldown, safe mode on.
    Disabled,
    /// The last action was refused, and the reason is on screen.
    Rejected,
    /// The socket is gone and the values are stale.
    Disconnected,
    /// A ghost. Most interactions are closed.
    DeadGhost,
    /// Values the server should never send. Nothing here may panic.
    Malformed,
}

impl Scenario {
    pub const ALL: [Scenario; 8] = [
        Scenario::Populated,
        Scenario::Empty,
        Scenario::Loading,
        Scenario::Disabled,
        Scenario::Rejected,
        Scenario::Disconnected,
        Scenario::DeadGhost,
        Scenario::Malformed,
    ];

    /// Stable identifier, used to name golden screenshots.
    pub fn key(self) -> &'static str {
        match self {
            Scenario::Populated => "populated",
            Scenario::Empty => "empty",
            Scenario::Loading => "loading",
            Scenario::Disabled => "disabled",
            Scenario::Rejected => "rejected",
            Scenario::Disconnected => "disconnected",
            Scenario::DeadGhost => "dead-ghost",
            Scenario::Malformed => "malformed",
        }
    }
}

/// Columns in the inventory grid, matching the reference composition.
const INVENTORY_COLUMNS: usize = 6;

/// Slots a starting character has, of a larger grid that is mostly padlocks.
const UNLOCKED_SLOTS: usize = 18;
const TOTAL_SLOTS: usize = 30;

fn item(item_id: i32, name_key: &str, quantity: i32, rarity: Rarity) -> ItemView {
    ItemView {
        item_id,
        name_key: name_key.to_string(),
        quantity,
        equipped: false,
        rarity,
        icon_grh: 1000 + item_id,
    }
}

/// A grid with `filled` items, the rest empty, and the tail locked.
fn grid(filled: Vec<ItemView>) -> InventoryState {
    let mut slots = Vec::with_capacity(TOTAL_SLOTS);
    for item in filled {
        slots.push(SlotState::Filled(item));
    }
    while slots.len() < UNLOCKED_SLOTS {
        slots.push(SlotState::Empty);
    }
    while slots.len() < TOTAL_SLOTS {
        slots.push(SlotState::Locked);
    }
    InventoryState { slots, columns: INVENTORY_COLUMNS }
}

fn hotbar(bound: usize, cooldown_on: Option<usize>) -> HotbarState {
    let mut slots = vec![HotbarSlotState::default(); 10];
    for (index, slot) in slots.iter_mut().enumerate().take(bound) {
        slot.binding = Some(HotbarBinding::Spell {
            spell_id: index as i32 + 1,
            icon_grh: 2000 + index as i32,
        });
    }
    if let Some(index) = cooldown_on {
        if let Some(slot) = slots.get_mut(index) {
            slot.cooldown = 0.6;
        }
    }
    HotbarState { slots, page: 0, page_count: 2 }
}

fn chat(lines: Vec<ChatLine>) -> ChatState {
    ChatState { lines, active_channel: Some(ChatChannel::Say), composing: false }
}

fn line(channel: ChatChannel, speaker: &str, body: &str) -> ChatLine {
    ChatLine { channel, speaker: speaker.to_string(), body: body.to_string() }
}

/// Build the snapshot for a scenario.
pub fn snapshot(scenario: Scenario) -> UiSnapshot {
    match scenario {
        Scenario::Populated => populated(),
        Scenario::Empty => empty(),
        Scenario::Loading => loading(),
        Scenario::Disabled => disabled(),
        Scenario::Rejected => rejected(),
        Scenario::Disconnected => disconnected(),
        Scenario::DeadGhost => dead_ghost(),
        Scenario::Malformed => malformed(),
    }
}

fn base_progression(name: &str, level: u16) -> ProgressionState {
    ProgressionState {
        name: name.to_string(),
        class_key: "mage".to_string(),
        level,
        experience: Gauge::new(80, 1000),
        gold: 1_250,
    }
}

fn populated() -> UiSnapshot {
    UiSnapshot {
        progression: base_progression("Aldar", 14),
        vitals: PlayerVitals {
            health: Gauge::new(148, 220),
            mana: Gauge::new(130, 150),
            stamina: Gauge::new(41, 60),
            hunger: Gauge::new(72, 100),
            thirst: Gauge::new(64, 100),
        },
        inventory: grid(vec![
            item(1, "item.potion.red", 498, Rarity::Common),
            item(2, "item.potion.blue", 150, Rarity::Common),
            item(3, "item.scroll.teleport", 15, Rarity::Uncommon),
            item(4, "item.apple", 50, Rarity::Common),
            item(5, "item.staff.oak", 1, Rarity::Rare),
            item(6, "item.robe.apprentice", 1, Rarity::Uncommon),
        ]),
        equipment: EquipmentState {
            worn: vec![
                (EquipSlot::Weapon, item(5, "item.staff.oak", 1, Rarity::Rare)),
                (EquipSlot::Armour, item(6, "item.robe.apprentice", 1, Rarity::Uncommon)),
            ],
        },
        spellbook: SpellbookState {
            spells: vec![
                SpellView {
                    spell_id: 1,
                    name_key: "spell.missile".to_string(),
                    mana_cost: 12,
                    required_skill: 5,
                    icon_grh: 2001,
                    blockers: Vec::new(),
                },
                SpellView {
                    spell_id: 2,
                    name_key: "spell.heal".to_string(),
                    mana_cost: 25,
                    required_skill: 10,
                    icon_grh: 2002,
                    blockers: Vec::new(),
                },
            ],
        },
        hotbar: hotbar(3, None),
        target: TargetState::Selected {
            name: "Wolf".to_string(),
            kind: TargetKind::Hostile,
            health: Some(Gauge::new(30, 60)),
        },
        chat: chat(vec![
            line(ChatChannel::System, "", "chat.welcome"),
            line(ChatChannel::Say, "Borzug", "chat.sample.greeting"),
        ]),
        skills: SkillsState {
            skills: vec![
                SkillView { skill_id: 1, name_key: "skill.magic".to_string(), points: 42 },
                SkillView { skill_id: 2, name_key: "skill.meditate".to_string(), points: 18 },
            ],
            unspent_points: 5,
        },
        safety: SafetyState { safe_mode: true, party_safe: true, secure_trade: false },
        service: ServiceState {
            phase: ConnectionPhase::Playing,
            latency_ms: Some(8),
            population: Some(417),
        },
        feedback: Vec::new(),
        loading: false,
    }
}

fn empty() -> UiSnapshot {
    UiSnapshot {
        progression: base_progression("Novato", 1),
        vitals: PlayerVitals {
            health: Gauge::new(20, 20),
            mana: Gauge::new(0, 0),
            stamina: Gauge::new(60, 60),
            hunger: Gauge::new(100, 100),
            thirst: Gauge::new(100, 100),
        },
        inventory: grid(Vec::new()),
        hotbar: hotbar(0, None),
        chat: chat(vec![line(ChatChannel::System, "", "chat.welcome")]),
        service: ServiceState {
            phase: ConnectionPhase::Playing,
            latency_ms: Some(12),
            population: Some(417),
        },
        ..Default::default()
    }
}

fn loading() -> UiSnapshot {
    UiSnapshot {
        service: ServiceState {
            phase: ConnectionPhase::Authenticating,
            latency_ms: None,
            population: None,
        },
        loading: true,
        ..Default::default()
    }
}

fn disabled() -> UiSnapshot {
    let mut snapshot = populated();
    snapshot.vitals.mana = Gauge::new(2, 150);
    snapshot.vitals.stamina = Gauge::new(0, 60);
    snapshot.hotbar = hotbar(3, Some(0));
    for spell in &mut snapshot.spellbook.spells {
        spell.blockers = vec![SpellBlocker::InsufficientMana];
    }
    snapshot.safety = SafetyState { safe_mode: true, party_safe: true, secure_trade: true };
    snapshot
}

fn rejected() -> UiSnapshot {
    let mut snapshot = disabled();
    snapshot.feedback = vec![
        Feedback::new(FeedbackKey::NotEnoughStamina),
        Feedback {
            key: FeedbackKey::TooFarAway,
            params: vec![FeedbackParam::Name("Wolf".to_string())],
            literal: None,
        },
        // The wire still carries inherited prose in places; it is shown, but
        // marked so nothing branches on it.
        Feedback::untranslated("No puedes hacer eso ahora."),
    ];
    snapshot
}

fn disconnected() -> UiSnapshot {
    let mut snapshot = populated();
    snapshot.service =
        ServiceState { phase: ConnectionPhase::Failed, latency_ms: None, population: None };
    snapshot.target = TargetState::None;
    // Values stay: they are the last thing known to be true, and blanking them
    // loses information the player may still want.
    snapshot
}

fn dead_ghost() -> UiSnapshot {
    let mut snapshot = populated();
    snapshot.vitals.health = Gauge::new(0, 220);
    snapshot.vitals.mana = Gauge::new(0, 150);
    snapshot.vitals.stamina = Gauge::new(0, 60);
    snapshot.target = TargetState::None;
    snapshot.feedback = vec![Feedback::new(FeedbackKey::Died)];
    for spell in &mut snapshot.spellbook.spells {
        spell.blockers = vec![SpellBlocker::Dead];
    }
    snapshot
}

/// Values the server should never send.
///
/// Every one of these has a plausible cause: a stat the character has not
/// unlocked, a desynchronised stack count, a transient mid-buff overshoot, a
/// grid resized under a drag. The interface must render all of them without
/// panicking, dividing by zero or drawing outside its own bounds.
fn malformed() -> UiSnapshot {
    UiSnapshot {
        progression: ProgressionState {
            name: String::new(),
            class_key: String::new(),
            level: 0,
            experience: Gauge::new(500, 0),
            gold: i64::MIN,
        },
        vitals: PlayerVitals {
            health: Gauge::new(-40, 0),
            mana: Gauge::new(i32::MAX, 1),
            stamina: Gauge::new(0, -10),
            hunger: Gauge::new(i32::MIN, i32::MAX),
            thirst: Gauge::new(5, 0),
        },
        inventory: InventoryState {
            slots: vec![
                SlotState::Filled(item(-1, "", -7, Rarity::Common)),
                SlotState::Filled(item(0, "", i32::MAX, Rarity::Legendary)),
                SlotState::Locked,
            ],
            // Zero columns: a grid that cannot be laid out.
            columns: 0,
        },
        hotbar: HotbarState {
            slots: vec![HotbarSlotState {
                binding: Some(HotbarBinding::Item { item_id: -1, icon_grh: -1 }),
                cooldown: f32::NAN,
            }],
            page: 99,
            page_count: 0,
        },
        spellbook: SpellbookState {
            spells: vec![SpellView {
                spell_id: -1,
                name_key: String::new(),
                mana_cost: -5,
                required_skill: i32::MIN,
                icon_grh: -1,
                blockers: vec![SpellBlocker::OnCooldown, SpellBlocker::OnCooldown],
            }],
        },
        target: TargetState::Selected {
            name: String::new(),
            kind: TargetKind::Item,
            health: Some(Gauge::new(10, 0)),
        },
        chat: ChatState {
            lines: vec![line(ChatChannel::Say, "", "")],
            active_channel: None,
            composing: false,
        },
        service: ServiceState {
            phase: ConnectionPhase::Playing,
            latency_ms: Some(u32::MAX),
            population: Some(u32::MAX),
        },
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_scenario_has_a_snapshot_and_a_stable_key() {
        // Golden screenshots are named by the key, so a duplicate silently
        // overwrites another scenario's baseline.
        let mut keys = Vec::new();
        for scenario in Scenario::ALL {
            let key = scenario.key();
            assert!(!keys.contains(&key), "{key} is used twice");
            keys.push(key);
            let _ = snapshot(scenario);
        }
        assert_eq!(keys.len(), Scenario::ALL.len());
    }

    #[test]
    fn fixtures_are_deterministic() {
        // A golden screenshot is worthless if the same scenario renders
        // differently on the next run. No clock, no randomness, no hash-map
        // iteration order.
        //
        // Compared through Debug rather than PartialEq because the malformed
        // fixture carries a NaN cooldown, and NaN is not equal to itself. The
        // formatting is stable, so this still catches real variation.
        for scenario in Scenario::ALL {
            assert_eq!(
                format!("{:?}", snapshot(scenario)),
                format!("{:?}", snapshot(scenario)),
                "{} varies between builds",
                scenario.key()
            );
        }
    }

    #[test]
    fn a_snapshot_carrying_nan_is_not_equal_to_itself() {
        // Not a curiosity: change detection written as `if next == current {
        // return }` would treat such a snapshot as changed every single frame
        // and rebuild the whole rail forever. Recorded here so the trap is
        // found by a test rather than by a frame-rate report.
        let bad = snapshot(Scenario::Malformed);
        assert_ne!(bad, bad.clone(), "the malformed fixture no longer exercises NaN");

        // Everything else does compare equal, so equality-based change
        // detection is safe for well-formed data.
        for scenario in Scenario::ALL {
            if scenario == Scenario::Malformed {
                continue;
            }
            let snapshot = snapshot(scenario);
            assert_eq!(snapshot, snapshot.clone(), "{} is not self-equal", scenario.key());
        }
    }

    #[test]
    fn every_scenario_is_distinguishable_from_every_other() {
        // Two scenarios producing identical snapshots means one of them is not
        // being exercised at all.
        for (i, a) in Scenario::ALL.iter().enumerate() {
            for b in &Scenario::ALL[i + 1..] {
                assert_ne!(
                    format!("{:?}", snapshot(*a)),
                    format!("{:?}", snapshot(*b)),
                    "{} and {} are the same snapshot",
                    a.key(),
                    b.key()
                );
            }
        }
    }

    #[test]
    fn loading_is_not_merely_empty() {
        // The distinction the interface has to draw differently.
        let loading = snapshot(Scenario::Loading);
        let empty = snapshot(Scenario::Empty);

        assert!(loading.loading);
        assert!(!empty.loading);
    }

    #[test]
    fn the_empty_scenario_still_shows_its_locked_slots() {
        // An empty pack is not a blank panel: the padlocks are what tell a
        // player the pack can grow.
        let empty = snapshot(Scenario::Empty);
        assert_eq!(empty.inventory.used_slots(), 0);
        assert!(
            empty.inventory.unlocked_slots() < empty.inventory.slots.len(),
            "no locked slots are visible"
        );
    }

    #[test]
    fn the_disconnected_scenario_keeps_the_last_known_values() {
        // Blanking them loses information the player may still want, and an
        // empty rail looks like a rendering failure rather than a dropped
        // connection.
        let disconnected = snapshot(Scenario::Disconnected);
        assert_eq!(disconnected.service.phase, ConnectionPhase::Failed);
        assert!(disconnected.inventory.used_slots() > 0);
        assert!(disconnected.vitals.health.max > 0);
        assert!(disconnected.service.latency_ms.is_none(), "stale latency must not be shown");
    }

    #[test]
    fn the_ghost_scenario_closes_the_actions_a_ghost_cannot_take() {
        let ghost = snapshot(Scenario::DeadGhost);
        assert!(ghost.is_dead());
        assert!(ghost.spellbook.spells.iter().all(|s| !s.is_castable()));
        assert_eq!(ghost.target, TargetState::None);
    }

    #[test]
    fn the_rejected_scenario_explains_itself_in_keys_not_prose() {
        // At least one localisable key, so the interface is exercised on the
        // path that can actually be translated.
        let rejected = snapshot(Scenario::Rejected);
        assert!(!rejected.feedback.is_empty());
        assert!(
            rejected.feedback.iter().any(|f| f.is_localisable()),
            "the rejected scenario must exercise the translatable path"
        );
        assert!(
            rejected.feedback.iter().any(|f| !f.is_localisable()),
            "and the inherited-prose path, which still exists on the wire"
        );
    }

    #[test]
    fn the_disabled_scenario_says_why_each_thing_is_unavailable() {
        let disabled = snapshot(Scenario::Disabled);
        assert!(disabled.spellbook.spells.iter().all(|s| !s.blockers.is_empty()));
        assert!(disabled.hotbar.slots.iter().any(|s| s.cooldown_fraction() > 0.0));
    }

    #[test]
    fn the_malformed_scenario_survives_every_accessor() {
        // The point of the fixture. Each of these has a plausible cause and
        // each would previously have divided by zero, overflowed or panicked.
        let bad = snapshot(Scenario::Malformed);

        for gauge in [
            bad.vitals.health,
            bad.vitals.mana,
            bad.vitals.stamina,
            bad.vitals.hunger,
            bad.vitals.thirst,
            bad.progression.experience,
        ] {
            let fraction = gauge.fraction();
            assert!(fraction.is_finite(), "{gauge:?} produced {fraction}");
            assert!((0.0..=1.0).contains(&fraction), "{gauge:?} produced {fraction}");
        }

        assert_eq!(bad.inventory.rows(), 0, "a grid with no columns needs no rows");
        assert_eq!(bad.inventory.slot(9_999), &SlotState::Empty);

        for slot in &bad.inventory.slots {
            if let Some(item) = slot.item() {
                assert!(item.display_quantity() >= 0);
            }
        }

        for index in 0..12 {
            let fraction = bad.hotbar.slot(index).cooldown_fraction();
            assert!((0.0..=1.0).contains(&fraction), "slot {index} produced {fraction}");
        }
    }

    #[test]
    fn the_populated_scenario_exercises_every_region_of_the_rail() {
        // A fixture that leaves a panel empty means that panel is never seen
        // in the gallery or in a golden screenshot.
        let populated = snapshot(Scenario::Populated);

        assert!(!populated.progression.name.is_empty());
        assert!(populated.inventory.used_slots() > 0);
        assert!(!populated.equipment.worn.is_empty());
        assert!(!populated.spellbook.spells.is_empty());
        assert!(populated.hotbar.slots.iter().any(|s| s.binding.is_some()));
        assert!(!populated.chat.lines.is_empty());
        assert!(!populated.skills.skills.is_empty());
        assert_ne!(populated.target, TargetState::None);
        assert!(populated.service.latency_ms.is_some());
    }

    #[test]
    fn no_fixture_carries_presentation_ready_prose_where_a_key_would_do() {
        // Names and bodies are keys, so the gallery exercises the localisation
        // path rather than baking Spanish into the fixtures.
        for scenario in Scenario::ALL {
            let snapshot = snapshot(scenario);
            for slot in &snapshot.inventory.slots {
                if let Some(item) = slot.item() {
                    assert!(
                        item.name_key.is_empty() || item.name_key.contains('.'),
                        "{} has a literal item name: {:?}",
                        scenario.key(),
                        item.name_key
                    );
                }
            }
            for spell in &snapshot.spellbook.spells {
                assert!(
                    spell.name_key.is_empty() || spell.name_key.contains('.'),
                    "{} has a literal spell name: {:?}",
                    scenario.key(),
                    spell.name_key
                );
            }
        }
    }
}
