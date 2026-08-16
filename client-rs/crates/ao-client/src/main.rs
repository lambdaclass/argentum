//! Argentum client — one Bevy codebase for the browser (wasm/WebGL2) and for
//! native Linux, macOS and Windows.
//!
//! This is an alternative to the TypeScript/Pixi client, not a replacement. The
//! reason it exists in Rust is that gameplay rules the server enforces can be
//! shared verbatim through `ao-core` instead of being re-implemented, which is
//! what caused predicted steps to disagree with the server and snap the player
//! backwards in the web client.

mod config;
mod graphics;
mod hud;
mod net;
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
                        resolution: WindowResolution::new(VIEWPORT_WIDTH, VIEWPORT_HEIGHT),
                        // Vsync. The renderer has nothing to gain from running
                        // ahead of the display, and uncapped frames on a laptop
                        // just burn battery.
                        present_mode: PresentMode::AutoVsync,
                        #[cfg(target_arch = "wasm32")]
                        canvas: Some(CANVAS_SELECTOR.into()),
                        // Track the element. The shell lays out against the
                        // whole window — top bar, world viewport, character
                        // rail — so a window narrower than the page puts the
                        // rail off the right-hand edge and clips the status
                        // bar. Stretching is not a risk here: `ui::scale`
                        // keeps the world on a whole-number pixel grid
                        // independently of the window size.
                        #[cfg(target_arch = "wasm32")]
                        fit_canvas_to_parent: true,
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
        .insert_resource(WinitSettings {
            focused_mode: UpdateMode::Continuous,
            // Also continuous while unfocused. Throttling to 10Hz saves power
            // but stalls the world: an unfocused window is still being watched
            // — alt-tabbed to a guide, second monitor — and the frame rate
            // visibly collapsing is worse than the battery it saves. The
            // browser throttles a *hidden* tab on its own, which is the case
            // that genuinely wants throttling, and the latency probe already
            // pauses there.
            unfocused_mode: UpdateMode::Continuous,
        })
        .add_plugins((world::WorldPlugin, ui::UiPlugin, hud::HudPlugin))
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
