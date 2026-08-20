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
use crate::ui::controls::{Activated, ControlKey};

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
    /// The last few activations, as `key/source/entity`.
    ///
    /// A count alone says a click activated something twice; it cannot say whether the
    /// two came from one entity — a deduplication failure between the event and the
    /// polled path — or from two entities, which is a pointer event bubbling to an
    /// ancestor that is also a control. Those need opposite fixes, and guessing between
    /// them cost several rounds.
    pub recent: Vec<String>,
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
        let key = keys.get(message.entity).ok().map(|key| key.as_str().to_string());
        last.recent.push(format!(
            "{}/{:?}/{}",
            key.as_deref().unwrap_or("unkeyed"),
            message.source,
            message.entity
        ));
        // Bounded: this is a rolling window for a reader, not a log.
        if last.recent.len() > 6 {
            let excess = last.recent.len() - 6;
            last.recent.drain(0..excess);
        }
        last.key = key;
        last.count += 1;
    }
}

/// Mirror it onto the page for automation.
#[cfg(target_arch = "wasm32")]
fn publish(
    scene: Res<LoadedScene>,
    player: Res<crate::world::LocalPlayer>,
    last: Res<LastActivation>,
    controls: Query<(
        &ControlKey,
        &crate::ui::controls::Control,
        &ComputedNode,
        &UiGlobalTransform,
    )>,
    pointer: Res<crate::ui::pointer::PointerState>,
    geometry: Res<crate::ui::shell::AppliedGeometry>,
    windows: Query<&Window>,
    state: Res<crate::ui::state::UiState>,
    drag: Res<crate::ui::character::DragState>,
    map_open: Res<crate::ui::worldmap::WorldMapOpen>,
    map_camera: Res<crate::ui::worldmap::WorldMapCamera>,
    map_markers: Query<(), With<crate::ui::worldmap::WorldMapMarker>>,
    mut frames: Local<u64>,
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
    // Frames, so automation can tell a client that is running from one that is
    // merely loaded. A harness that starts clicking as soon as the controls appear is
    // aiming at a client still decoding its graphics, where a single frame can take
    // seconds: the click lands, but the activation is republished long after the probe
    // gave up, and the result is then charged to the *next* probe. Published from this
    // system's own invocation count, which is once per frame by construction.
    *frames += 1;
    set("frames", *frames as f64);
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
    let _ = js_sys::Reflect::set(
        &report,
        &wasm_bindgen::JsValue::from_str("recentActivations"),
        &wasm_bindgen::JsValue::from_str(&last.recent.join(" ")),
    );
    if let Some(key) = last.key.as_deref() {
        let _ = js_sys::Reflect::set(
            &report,
            &wasm_bindgen::JsValue::from_str("lastActivated"),
            &wasm_bindgen::JsValue::from_str(key),
        );
    }

    // What is in each inventory slot, as object ids with zero for empty.
    //
    // A drag has no other observable outcome: the gesture is a pointer sequence and
    // its whole result is that two slots exchanged contents. Without this the only
    // browser-side evidence available is that the client did not crash, which is not
    // evidence that anything moved.
    let slots = js_sys::Array::new();
    for slot in state.get().inventory.slots.iter() {
        let id = slot.item().map(|item| item.item_id).unwrap_or(0);
        slots.push(&wasm_bindgen::JsValue::from_f64(id as f64));
    }
    let _ =
        js_sys::Reflect::set(&report, &wasm_bindgen::JsValue::from_str("inventorySlots"), &slots);

    // The whole-world map: whether it is open, where it is looking and how many markers
    // it drew. Published because the questions this task has to answer in a browser are
    // about clamping and filtering, and neither is visible from outside without the
    // numbers the client is using.
    let _ = js_sys::Reflect::set(
        &report,
        &wasm_bindgen::JsValue::from_str("worldMapOpen"),
        &wasm_bindgen::JsValue::from_bool(map_open.0),
    );
    set("worldMapScale", map_camera.view.scale as f64);
    set("worldMapCentreX", map_camera.view.centre.x as f64);
    set("worldMapCentreY", map_camera.view.centre.y as f64);
    set("worldMapMarkers", map_markers.iter().count() as f64);

    // Whether a drag is in progress, and over what. Published because a drag that
    // produced no move has two very different causes — the client never saw the gesture
    // as a drag at all, or it saw it and the destination refused — and the slots alone
    // cannot tell them apart. `-1` for absent, since these are indices.
    let dragging = drag.from.map(|from| from as f64).unwrap_or(-1.0);
    set("dragFrom", dragging);
    set("dragOver", drag.over.map(|over| over as f64).unwrap_or(-1.0));

    // Where every keyed control actually is, in CSS pixels of the canvas, so a test
    // can click a control by position rather than by guessing at layout.
    //
    // `ComputedNode` is in *physical* pixels, so it is divided by the scale factor
    // here. Published raw, the rectangles matched CSS coordinates only at ratio 1 —
    // and every click at 1.25x and above missed by a quarter of the distance from
    // the origin, which looked exactly like a hit-testing bug in the client.
    let scale = windows.iter().next().map(|w| w.scale_factor()).unwrap_or(1.0).max(0.001);
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
        set_num("x", (centre.x - half.x) / scale);
        set_num("y", (centre.y - half.y) / scale);
        set_num("w", computed.size().x / scale);
        set_num("h", computed.size().y / scale);
        let _ = js_sys::Reflect::set(
            &entry,
            &wasm_bindgen::JsValue::from_str("enabled"),
            &wasm_bindgen::JsValue::from_bool(control.enabled),
        );
        rects.push(&entry);
    }
    let _ = js_sys::Reflect::set(&report, &wasm_bindgen::JsValue::from_str("controls"), &rects);

    // The world's rectangle, from the shell's own geometry. A test that derived it
    // from a control's position instead measured into the rail and off the top bar,
    // and then blamed the client for the tiles it got back.
    if let Some(shell) = geometry.0 {
        set("worldX", shell.world.min.x as f64);
        set("worldY", shell.world.min.y as f64);
        set("worldW", shell.world.width() as f64);
        set("worldH", shell.world.height() as f64);
        // Which rail the shell chose. Automation needs it to know *which* controls
        // ought to exist: the compact navigation strip is deliberately absent from the
        // full rail, where those actions live in the top bar. Without this a harness
        // either hard-codes the breakpoint — a copy of client logic that can drift — or
        // treats a control's absence as unremarkable, which is how a shrinking sample
        // passes a "the sample is available" check.
        let _ = js_sys::Reflect::set(
            &report,
            &wasm_bindgen::JsValue::from_str("railCompact"),
            &wasm_bindgen::JsValue::from_bool(matches!(
                shell.rail_mode,
                crate::ui::layout::RailMode::Compact
            )),
        );
    }

    // Where the pointer resolves in the world, so a test can check that clicking
    // the centre of the viewport selects the tile that is drawn there rather than
    // one next to it.
    let _ = js_sys::Reflect::set(
        &report,
        &wasm_bindgen::JsValue::from_str("pointerTarget"),
        &wasm_bindgen::JsValue::from_str(match pointer.target {
            Some(crate::ui::pointer::PointerTarget::World) => "world",
            Some(crate::ui::pointer::PointerTarget::Interface) => "interface",
            Some(crate::ui::pointer::PointerTarget::Outside) => "outside",
            None => "none",
        }),
    );
    // The position the client currently believes the pointer is at, so a test can
    // wait for the move it just made to arrive rather than reading whatever was
    // published for the previous one. Without this, every reading was one move
    // stale and the world mapping looked inverted.
    if let Some(position) = pointer.position {
        set("pointerX", position.x as f64);
        set("pointerY", position.y as f64);
    }
    if let Some(tile) = pointer.tile {
        let pair = js_sys::Array::new();
        pair.push(&wasm_bindgen::JsValue::from_f64(tile.x as f64));
        pair.push(&wasm_bindgen::JsValue::from_f64(tile.y as f64));
        let _ =
            js_sys::Reflect::set(&report, &wasm_bindgen::JsValue::from_str("pointerTile"), &pair);
    }

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
