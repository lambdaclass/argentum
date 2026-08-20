//! Argentum client — one Bevy codebase for the browser (wasm/WebGL2) and for
//! native Linux, macOS and Windows.
//!
//! This is an alternative to the TypeScript/Pixi client, not a replacement. The
//! reason it exists in Rust is that gameplay rules the server enforces can be
//! shared verbatim through `ao-core` instead of being re-implemented, which is
//! what caused predicted steps to disagree with the server and snap the player
//! backwards in the web client.

mod config;
mod diagnostics;
mod graphics;
mod hud;
mod net;
mod platform;
mod session;
mod ui;
mod world;

use bevy::prelude::*;
use bevy::window::{PresentMode, WindowResolution};
use bevy::winit::{UpdateMode, WinitSettings};

/// Initial window size. On the web the canvas immediately grows to its parent;
/// this is only the native default and the pre-resize frame.
const VIEWPORT_WIDTH: u32 = 1280;
const VIEWPORT_HEIGHT: u32 = 832;

/// The canvas the browser build binds to. `web/index.html` provides it.
#[cfg(target_arch = "wasm32")]
const CANVAS_SELECTOR: &str = "#ao-canvas";

/// How often the app updates, focused and unfocused.
///
/// Both continuous. Winit's reactive mode is right for a tool and wrong for a
/// game: with it, interpolation and animation advance only when an input event
/// arrives, so movement lags and then jumps a whole tile.
///
/// Unfocused is continuous for a second reason. A visible window that is not
/// focused is still being watched — alt-tabbed to a guide, or on a second
/// monitor — and dropping it to a 10Hz event-driven loop both stalls the world
/// and makes the frame-rate readout report the throttle as game performance.
/// The browser throttles a genuinely *hidden* tab on its own, which is the case
/// that should be throttled, and the readout and the latency probe both stand
/// down there.
fn winit_settings() -> WinitSettings {
    WinitSettings { focused_mode: UpdateMode::Continuous, unfocused_mode: UpdateMode::Continuous }
}

/// The window's starting resolution.
///
/// No scale-factor override any more. Pinning it to 1 made the window report CSS
/// pixels while every input path kept receiving device pixels, and the two only
/// agree at ratio 1 — so on a 125% display, an ordinary Windows setting, clicks
/// landed progressively further from the cursor. `ui::shell::track_host_canvas`
/// keeps logical size, physical size and the device ratio consistent instead.
fn host_resolution() -> WindowResolution {
    WindowResolution::new(VIEWPORT_WIDTH, VIEWPORT_HEIGHT)
}

fn main() {
    init_logging();

    // Resolved before the app is built, so a client with nowhere to connect to
    // says so once, in plain terms, instead of failing later as a stream of
    // fetch and socket errors that look like the server is down.
    let Some(config) = config::load() else {
        error!("{}", config::MISSING_CONFIG_HELP);
        return;
    };
    if config.credentials.is_none() {
        warn!("{}", config::MISSING_CREDENTIALS_HELP);
    }
    info!("assets from {}, gateway {}", config.asset_origin, config.gateway_url);

    App::new()
        .insert_resource(config)
        .add_plugins(
            DefaultPlugins
                .set(WindowPlugin {
                    primary_window: Some(Window {
                        title: "Argentum".into(),
                        resolution: host_resolution(),
                        // Vsync. The renderer has nothing to gain from running
                        // ahead of the display, and uncapped frames on a laptop
                        // just burn battery.
                        present_mode: PresentMode::AutoVsync,
                        #[cfg(target_arch = "wasm32")]
                        canvas: Some(CANVAS_SELECTOR.into()),
                        // Off, because `ui::shell::track_host_canvas` does this
                        // instead. Bevy's fitting installs the parent's *CSS* box
                        // as the window's *physical* size, which leaves the logical
                        // size, the backing store and the cursor in three different
                        // units on any display whose ratio is not 1.
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
        // Run every frame, not only when an input event arrives.
        //
        // Winit's reactive mode is right for a tool and wrong for a game: with
        // it, interpolation and animation only advance when a key is pressed,
        // so movement appears to lag and then jump a whole tile at a time.
        .insert_resource(winit_settings())
        .add_plugins((platform::PlatformPlugin, world::WorldPlugin, ui::UiPlugin, hud::HudPlugin))
        .add_plugins(diagnostics::DiagnosticsPlugin)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unfocused_window_is_not_dropped_to_an_event_driven_loop() {
        // A visible but unfocused window keeps rendering, so its measured frame
        // rate stays real. Reactive mode here would stall the world and make
        // the readout report the throttle as performance.
        let settings = winit_settings();
        assert_eq!(settings.unfocused_mode, UpdateMode::Continuous);
        assert_eq!(settings.focused_mode, UpdateMode::Continuous);
    }
}
