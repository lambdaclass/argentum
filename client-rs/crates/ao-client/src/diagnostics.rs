//! What the client has actually loaded, published for automation to read.
//!
//! This exists because a capture harness cannot tell a painted world from an
//! unpainted one by waiting. It waited four seconds, assumed the map and the
//! sprite sheets had arrived, and filed twenty-four screenshots of a bare green
//! grid as evidence — the asset server was down and nothing in the pipeline
//! said so. A timer is not a readiness check.
//!
//! Read-only, and deliberately small: it reports counts the client already
//! keeps, and offers nothing that could change state. It is not application UI
//! and no screen depends on it; Bevy still owns every screen.
//!
//! It also publishes the interface's control rectangles and the last activation,
//! which is what lets a browser test click a control by its actual position and
//! check that the control it clicked is the one that fired. Headless Bevy cannot
//! answer that: its UI picking backend has no render target to map a pointer
//! through, and it reports a hit on the root node whatever the position. The
//! question is about real hit testing, so it is asked in a real browser.
//!
//! The discriminating signal is `painted`, counted from `world::SceneTile` —
//! "tiles drawn from the real graphics, as opposed to the placeholder grid", in
//! that type's own words. The green-grid captures were the placeholder grid:
//! plenty of tiles, no artwork. Counting tiles indiscriminately would have
//! called them loaded.

use bevy::prelude::*;

use crate::graphics::SheetTextures;
use crate::ui::controls::{Activated, Control, ControlKey};

/// How far the world has actually got.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LoadedScene {
    /// Sprite sheets decoded into textures. Zero means nothing can be drawn
    /// from the real artwork, whatever else is on screen.
    pub sheets: usize,
    /// Tiles painted from the real graphics.
    pub painted: usize,
    /// Tiles of the placeholder grid. Present from the first frame and no
    /// evidence of anything, but reported so a reader can see the difference
    /// between an empty world and an unloaded one.
    pub placeholders: usize,
}

/// The last control activated, by key.
///
/// Keys rather than entities: an entity means nothing outside this process, and
/// panels rebuild constantly so the number would change under a test that
/// recorded it.
#[derive(Resource, Debug, Clone, Default)]
pub struct LastActivation {
    pub key: Option<String>,
    /// How many activations have happened, ever.
    ///
    /// A counter as well as the key, because a reader cannot otherwise tell a
    /// fresh activation from the previous one still being reported. A browser test
    /// clearing the field from JavaScript achieved nothing — the client
    /// republishes the resource every frame — so every "this should not activate"
    /// check saw the last thing that did.
    pub count: u64,
}

pub struct DiagnosticsPlugin;

impl Plugin for DiagnosticsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<LoadedScene>()
            .init_resource::<LastActivation>()
            // Registered here so this plugin stands alone: without ControlsPlugin
            // the message is uninitialised and the reader fails validation rather
            // than simply seeing nothing.
            .add_message::<Activated>()
            .add_systems(Update, (collect, record_activation));

        #[cfg(target_arch = "wasm32")]
        app.add_systems(Update, publish.after(collect));
    }
}

/// Count what is loaded, once per frame.
fn collect(
    sheets: Res<SheetTextures>,
    painted: Query<(), With<crate::world::SceneTile>>,
    placeholders: Query<(), With<crate::world::TileSprite>>,
    mut scene: ResMut<LoadedScene>,
) {
    let next = LoadedScene {
        sheets: sheets.0.len(),
        painted: painted.iter().count(),
        placeholders: placeholders.iter().count(),
    };
    // Only on a real change: this is a resource other systems may watch, and a
    // write every frame makes change detection useless for all of them.
    if *scene != next {
        *scene = next;
    }
}

/// Remember what was activated, so a browser test can check that the control it
/// clicked is the one that fired.
fn record_activation(
    mut activated: MessageReader<Activated>,
    keys: Query<&ControlKey>,
    mut last: ResMut<LastActivation>,
) {
    for message in activated.read() {
        last.key = keys.get(message.entity).ok().map(|key| key.as_str().to_string());
        last.count += 1;
    }
}

/// Mirror it onto the page for automation.
#[cfg(target_arch = "wasm32")]
fn publish(
    scene: Res<LoadedScene>,
    player: Res<crate::world::LocalPlayer>,
    last: Res<LastActivation>,
    controls: Query<(&ControlKey, &Control, &ComputedNode, &UiGlobalTransform)>,
) {
    // Republished every frame: `hovered` changes with the pointer and nothing
    // else here tracks it, so gating on the other resources would freeze it.

    let Some(window) = web_sys::window() else {
        return;
    };

    let report = js_sys::Object::new();
    let set = |key: &str, value: f64| {
        let _ = js_sys::Reflect::set(
            &report,
            &wasm_bindgen::JsValue::from_str(key),
            &wasm_bindgen::JsValue::from_f64(value),
        );
    };
    set("sheets", scene.sheets as f64);
    set("painted", scene.painted as f64);
    set("placeholders", scene.placeholders as f64);
    set("playerX", player.x as f64);
    set("playerY", player.y as f64);
    let _ = js_sys::Reflect::set(
        &report,
        &wasm_bindgen::JsValue::from_str("build"),
        &wasm_bindgen::JsValue::from_str(option_env!("AO_BUILD").unwrap_or("unknown")),
    );

    set("activations", last.count as f64);
    if let Some(key) = last.key.as_deref() {
        let _ = js_sys::Reflect::set(
            &report,
            &wasm_bindgen::JsValue::from_str("lastActivated"),
            &wasm_bindgen::JsValue::from_str(key),
        );
    }

    // Where every keyed control actually is, in CSS pixels of the canvas, so a
    // test can click a control by position rather than by guessing at layout.
    let rects = js_sys::Array::new();
    for (key, control, computed, transform) in &controls {
        let half = computed.size() / 2.0;
        let centre = transform.translation;
        let entry = js_sys::Object::new();
        let set_num = |name: &str, value: f32| {
            let _ = js_sys::Reflect::set(
                &entry,
                &wasm_bindgen::JsValue::from_str(name),
                &wasm_bindgen::JsValue::from_f64(value as f64),
            );
        };
        let _ = js_sys::Reflect::set(
            &entry,
            &wasm_bindgen::JsValue::from_str("key"),
            &wasm_bindgen::JsValue::from_str(key.as_str()),
        );
        set_num("x", centre.x - half.x);
        set_num("y", centre.y - half.y);
        set_num("w", computed.size().x);
        set_num("h", computed.size().y);
        let _ = js_sys::Reflect::set(
            &entry,
            &wasm_bindgen::JsValue::from_str("enabled"),
            &wasm_bindgen::JsValue::from_bool(control.enabled),
        );
        rects.push(&entry);
    }
    let _ = js_sys::Reflect::set(&report, &wasm_bindgen::JsValue::from_str("controls"), &rects);

    // What the interaction pipeline believes is under the pointer right now.
    let hovered = js_sys::Array::new();
    for (key, control, _, _) in &controls {
        if control.hovered {
            hovered.push(&wasm_bindgen::JsValue::from_str(key.as_str()));
        }
    }
    let _ = js_sys::Reflect::set(&report, &wasm_bindgen::JsValue::from_str("hovered"), &hovered);

    let _ = js_sys::Reflect::set(&window, &wasm_bindgen::JsValue::from_str("aoLoaded"), &report);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unpainted_world_is_distinguishable_from_a_painted_one() {
        // The exact confusion that let the green-grid captures through: tiles
        // present, no artwork. A readiness check that only counts tiles calls
        // this loaded.
        let grid_only = LoadedScene { sheets: 0, painted: 0, placeholders: 900 };
        let real = LoadedScene { sheets: 12, painted: 900, placeholders: 900 };
        assert_ne!(grid_only, real);
        assert_eq!(
            grid_only.placeholders, real.placeholders,
            "the placeholder grid is present either way, so counting it proves nothing"
        );
        assert_eq!(grid_only.painted, 0);
        assert!(real.painted > 0 && real.sheets > 0);
    }

    #[test]
    fn the_scene_counts_what_is_in_the_world() {
        let mut app = App::new();
        app.init_resource::<SheetTextures>().add_plugins(DiagnosticsPlugin);
        app.update();
        assert_eq!(*app.world().resource::<LoadedScene>(), LoadedScene::default());

        app.world_mut().spawn(crate::world::SceneTile);
        app.world_mut().spawn(crate::world::SceneTile);
        app.world_mut().spawn(crate::world::TileSprite);
        app.update();
        let scene = *app.world().resource::<LoadedScene>();
        assert_eq!(scene.painted, 2);
        assert_eq!(scene.placeholders, 1);
    }
}
