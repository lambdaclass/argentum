//! Argentum client — one Bevy codebase for the browser (wasm/WebGL2) and for
//! native Linux, macOS and Windows.
//!
//! This is an alternative to the TypeScript/Pixi client, not a replacement. The
//! reason it exists in Rust is that gameplay rules the server enforces can be
//! shared verbatim through `ao-core` instead of being re-implemented, which is
//! what caused predicted steps to disagree with the server and snap the player
//! backwards in the web client.

mod graphics;
mod net;
mod world;

use bevy::prelude::*;
use bevy::window::{PresentMode, WindowResolution};

/// Logical viewport, matching the web client so both show the same area.
const VIEWPORT_WIDTH: u32 = 1280;
const VIEWPORT_HEIGHT: u32 = 832;

/// The canvas the browser build binds to. `web/index.html` provides it.
#[cfg(target_arch = "wasm32")]
const CANVAS_SELECTOR: &str = "#ao-canvas";

fn main() {
    init_logging();

    App::new()
        .add_plugins(
            DefaultPlugins
                .set(WindowPlugin {
                    primary_window: Some(Window {
                        title: "Argentum".into(),
                        resolution: WindowResolution::new(VIEWPORT_WIDTH, VIEWPORT_HEIGHT),
                        // Vsync. The renderer has nothing to gain from running
                        // ahead of the display, and uncapped frames on a laptop
                        // just burn battery.
                        present_mode: PresentMode::AutoVsync,
                        #[cfg(target_arch = "wasm32")]
                        canvas: Some(CANVAS_SELECTOR.into()),
                        // Keep the logical viewport fixed. Letting the canvas
                        // grow to its parent stretches the world and defeats
                        // integer pixel scaling.
                        #[cfg(target_arch = "wasm32")]
                        fit_canvas_to_parent: false,
                        // The browser's own shortcuts stay usable.
                        #[cfg(target_arch = "wasm32")]
                        prevent_default_event_handling: false,
                        ..default()
                    }),
                    ..default()
                })
                // Pixel art: sample nearest, never blur.
                .set(ImagePlugin::default_nearest()),
        )
        .add_plugins(world::WorldPlugin)
        .run();
}

#[cfg(target_arch = "wasm32")]
fn init_logging() {
    console_error_panic_hook::set_once();
    let _ = console_log::init_with_level(log::Level::Info);
}

#[cfg(not(target_arch = "wasm32"))]
fn init_logging() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
}
