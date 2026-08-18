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
//! The discriminating signal is `painted`, counted from `world::SceneTile` —
//! "tiles drawn from the real graphics, as opposed to the placeholder grid", in
//! that type's own words. The green-grid captures were the placeholder grid:
//! plenty of tiles, no artwork. Counting tiles indiscriminately would have
//! called them loaded.

use bevy::prelude::*;

use crate::graphics::SheetTextures;

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

pub struct DiagnosticsPlugin;

impl Plugin for DiagnosticsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<LoadedScene>().add_systems(Update, collect);

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

/// Mirror it onto the page for automation.
#[cfg(target_arch = "wasm32")]
fn publish(scene: Res<LoadedScene>, player: Res<crate::world::LocalPlayer>) {
    if !scene.is_changed() && !player.is_changed() {
        return;
    }
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
