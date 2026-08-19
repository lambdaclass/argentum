//! The application shell and every screen inside it.
//!
//! Bevy owns all of it. The roadmap states this as an architecture invariant:
//! JavaScript and CSS are limited to the canvas host page, the pre-WASM
//! fallback and thin adapters for browser capabilities. There is no DOM version
//! of any screen here, and therefore no second source of UI state to keep in
//! sync with this one.

pub mod authority;
pub mod character;
pub mod chat;
pub mod controls;
pub mod fonts;
pub mod hotbar;
pub mod icons;
pub mod labels;
pub mod layout;
pub mod pointer;
pub mod rail;
pub mod scale;
pub mod shell;
pub mod spells;
pub mod state;
pub mod target;
pub mod telemetry;
#[cfg(test)]
pub mod testing;
pub mod tokens;
pub mod topbar;

use bevy::prelude::*;

/// A readable label for a localisation key, until a catalogue exists.
///
/// Every user-visible string in this client is a key — `action.settings`,
/// `item.potion.red` — so that translation is a lookup rather than a rewrite.
/// Until the catalogue lands something has to be drawn, and the choice is
/// between the raw key and a label derived from it.
///
/// Derived, because a raw key is not a translation and must not be presented as
/// one: a player reading `action.settings` in a tooltip is reading our source
/// code. Derived rather than hard-coded for the opposite reason — a table of
/// English strings here would bypass the localisation path the keys exist to
/// exercise, and would be the thing nobody remembers to delete.
pub fn fallback_label(key: &str) -> String {
    let last = key.rsplit('.').next().unwrap_or_default();
    let spaced = last.replace(['_', '-'], " ");
    let mut characters = spaced.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

/// Everything that makes up the shell.
pub struct UiPlugin;

impl Plugin for UiPlugin {
    fn build(&self, app: &mut App) {
        app.add_plugins((
            fonts::FontPlugin,
            controls::ControlsPlugin,
            pointer::PointerPlugin,
            icons::TooltipPlugin,
            state::UiStatePlugin,
            authority::SimulatedAuthorityPlugin,
            shell::ShellPlugin,
            topbar::TopBarPlugin,
            rail::RailPlugin,
            character::CharacterPanelPlugin,
            spells::SpellPanelPlugin,
            chat::ChatPanelPlugin,
            target::TargetPanelPlugin,
            labels::LabelPlugin,
            hotbar::HotbarPlugin,
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_becomes_something_a_player_can_read() {
        assert_eq!(fallback_label("action.settings"), "Settings");
        assert_eq!(fallback_label("action.toggle_fullscreen"), "Toggle fullscreen");
        assert_eq!(fallback_label("item.potion.red"), "Red");
    }

    #[test]
    fn a_label_never_contains_the_key_structure_it_came_from() {
        // The failure this exists for: a tooltip reading `action.settings`,
        // which is our source code shown to a player and was being described as
        // localised.
        for key in [
            "action.settings",
            "action.support",
            "action.language",
            "topbar.close",
            "inventory.slot.3",
        ] {
            let label = fallback_label(key);
            assert!(!label.contains('.'), "{key} rendered as {label}");
            assert!(!label.contains('_'), "{key} rendered as {label}");
            assert_ne!(label, key);
            assert!(!label.is_empty(), "{key} rendered as nothing at all");
        }
    }

    #[test]
    fn a_key_with_no_segments_or_no_content_does_not_panic() {
        assert_eq!(fallback_label(""), "");
        assert_eq!(fallback_label("."), "");
        assert_eq!(fallback_label("settings"), "Settings");
    }
}
