//! The numbered hotbar, anchored to the bottom centre of the world viewport.
//!
//! Centred on the *viewport*, not the window. With a 420px rail, centring on
//! the window pushes the bar visibly right of the world it belongs to — the
//! roadmap calls this out specifically because it is easy to get wrong and
//! looks subtly off rather than obviously broken.

use super::shell::{label, Hotbar};
use super::tokens::{focus, ink, size, space, surface, type_scale};
use bevy::prelude::*;

/// Slots on one page.
///
/// Ten, keyed 1-9 then 0, which is the row of number keys and the convention
/// every AO client uses.
pub const SLOTS_PER_PAGE: usize = 10;

/// A hotbar slot and the key that triggers it.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct HotbarSlot {
    pub index: usize,
}

/// The key label for a slot: 1-9 then 0.
pub fn slot_key_label(index: usize) -> String {
    match index {
        9 => "0".to_string(),
        other => (other + 1).to_string(),
    }
}

/// The keyboard key that fires a slot.
pub fn slot_key_code(index: usize) -> Option<KeyCode> {
    Some(match index {
        0 => KeyCode::Digit1,
        1 => KeyCode::Digit2,
        2 => KeyCode::Digit3,
        3 => KeyCode::Digit4,
        4 => KeyCode::Digit5,
        5 => KeyCode::Digit6,
        6 => KeyCode::Digit7,
        7 => KeyCode::Digit8,
        8 => KeyCode::Digit9,
        9 => KeyCode::Digit0,
        _ => return None,
    })
}

pub struct HotbarPlugin;

impl Plugin for HotbarPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, populate.after(super::shell::spawn_shell));
    }
}

fn slot(index: usize) -> impl Bundle {
    (
        Node {
            width: Val::Px(size::HOTBAR_SLOT),
            height: Val::Px(size::HOTBAR_SLOT),
            border: UiRect::all(Val::Px(size::BORDER)),
            padding: UiRect::all(Val::Px(space::HAIR)),
            ..default()
        },
        BackgroundColor(surface::WELL),
        BorderColor::all(surface::EDGE),
        HotbarSlot { index },
        // A real control. These slots carried no interaction components at all,
        // so clicking one did nothing and Tab passed straight over them — the
        // keys worked and the slots themselves were decoration.
        super::controls::interactive(200 + index as u32, true),
        super::controls::ControlKey::indexed("hotbar.slot", index),
        // The key label sits in the slot's top-left, as in every AO client: it is
        // a reminder, not a caption, so it must not take slot area from the icon.
        // Drawn by the shared prompt rather than a second copy of it here.
        children![super::controls::hotkey_prompt(&slot_key_label(index))],
    )
}

fn populate(mut commands: Commands, bars: Query<Entity, With<Hotbar>>) {
    for bar in &bars {
        commands.entity(bar).with_children(|bar| {
            for index in 0..SLOTS_PER_PAGE {
                bar.spawn(slot(index));
            }
            // Page arrow. A second page exists in the reference client; until
            // W-0007 gives it behaviour it is drawn disabled rather than
            // pretending to work.
            bar.spawn((
                Node {
                    width: Val::Px(size::HOTBAR_SLOT * 0.55),
                    height: Val::Px(size::HOTBAR_SLOT),
                    justify_content: JustifyContent::Center,
                    align_items: AlignItems::Center,
                    border: UiRect::all(Val::Px(size::BORDER)),
                    ..default()
                },
                BackgroundColor(surface::WELL),
                BorderColor::all(surface::EDGE),
                children![label(">", type_scale::BODY, ink::DISABLED)],
            ));
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots_are_keyed_one_through_nine_then_zero() {
        // The number row's order, not its numeric order. Labelling the tenth
        // slot "10" would be correct arithmetic and the wrong key.
        let labels: Vec<String> = (0..SLOTS_PER_PAGE).map(slot_key_label).collect();
        assert_eq!(labels, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]);
    }

    #[test]
    fn every_slot_has_a_key_and_no_two_share_one() {
        // A duplicate binding silently makes one slot unreachable.
        let mut seen = Vec::new();
        for index in 0..SLOTS_PER_PAGE {
            let key = slot_key_code(index).expect("every slot on a page is bound");
            assert!(!seen.contains(&key), "slot {index} reuses a key");
            seen.push(key);
        }
    }

    #[test]
    fn the_tenth_slot_is_the_zero_key() {
        assert_eq!(slot_key_code(9), Some(KeyCode::Digit0));
        assert_eq!(slot_key_label(9), "0");
    }

    #[test]
    fn a_slot_beyond_the_page_has_no_key() {
        // Pages beyond the first are reached by the page control, not by
        // inventing keys that do not exist on the number row.
        assert_eq!(slot_key_code(SLOTS_PER_PAGE), None);
        assert_eq!(slot_key_code(99), None);
    }
}
