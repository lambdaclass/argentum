//! The application shell and every screen inside it.
//!
//! Bevy owns all of it. The roadmap states this as an architecture invariant:
//! JavaScript and CSS are limited to the canvas host page, the pre-WASM
//! fallback and thin adapters for browser capabilities. There is no DOM version
//! of any screen here, and therefore no second source of UI state to keep in
//! sync with this one.

pub mod hotbar;
pub mod layout;
pub mod rail;
pub mod shell;
pub mod tokens;
pub mod topbar;

use bevy::prelude::*;

/// Everything that makes up the shell.
pub struct UiPlugin;

impl Plugin for UiPlugin {
    fn build(&self, app: &mut App) {
        app.add_plugins((
            shell::ShellPlugin,
            topbar::TopBarPlugin,
            rail::RailPlugin,
            hotbar::HotbarPlugin,
        ));
    }
}
