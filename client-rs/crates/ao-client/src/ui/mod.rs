//! The application shell and every screen inside it.
//!
//! Bevy owns all of it. The roadmap states this as an architecture invariant:
//! JavaScript and CSS are limited to the canvas host page, the pre-WASM
//! fallback and thin adapters for browser capabilities. There is no DOM version
//! of any screen here, and therefore no second source of UI state to keep in
//! sync with this one.

pub mod character;
pub mod controls;
pub mod fonts;
pub mod hotbar;
pub mod layout;
pub mod rail;
pub mod scale;
pub mod shell;
pub mod spells;
pub mod state;
pub mod tokens;
pub mod topbar;

use bevy::prelude::*;

/// Everything that makes up the shell.
pub struct UiPlugin;

impl Plugin for UiPlugin {
    fn build(&self, app: &mut App) {
        app.add_plugins((
            fonts::FontPlugin,
            controls::ControlsPlugin,
            state::UiStatePlugin,
            shell::ShellPlugin,
            topbar::TopBarPlugin,
            rail::RailPlugin,
            character::CharacterPanelPlugin,
            spells::SpellPanelPlugin,
            hotbar::HotbarPlugin,
        ));
    }
}
