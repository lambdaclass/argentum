//! Fetching world data from the running server.
//!
//! The Elixir server already serves everything the web client needs, so this
//! client consumes the same endpoints rather than inventing new ones:
//!
//! - `GET /api/meta/world-pack` — JSON manifest naming the current pack file
//! - `GET /data/packs/<filename>` — the `AOMP` pack itself
//!
//! Bevy systems are synchronous, so the fetch runs as a detached task that
//! publishes into a shared slot which a system polls. On native there is no
//! fetch yet; the client falls back to a generated map so it still runs.

#[cfg(target_arch = "wasm32")]
use crate::graphics::{decode_png, parse_directional, parse_npcs, parse_objects, GrhIndex};
use crate::graphics::Graphics;
use bevy::prelude::Resource;
#[cfg(target_arch = "wasm32")]
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

/// Origin the client fetches world data and status from.
pub const SERVER_ORIGIN: &str = "http://127.0.0.1:4000";

/// Appearance used until a real character is logged in.
///
/// Taken from the game's own race table (`resources/raw/init/HeadAndBodyData.json`):
/// a human male is body 21 with heads 1-41. Body 1 is not a player body — it
/// belongs to another set entirely, which is why the character looked wrong.
pub const DEFAULT_BODY: i32 = 21;
pub const DEFAULT_HEAD: i32 = 1;

/// Where a load has got to. Polled by `world::apply_loaded_map`.
#[derive(Debug, Clone)]
pub enum LoadState {
    Idle,
    Fetching(&'static str),
    Ready(Box<ao_core::PackedMap>),
    Failed(String),
}

#[derive(Resource, Clone)]
pub struct MapLoader {
    slot: Arc<Mutex<LoadState>>,
}

impl Default for MapLoader {
    fn default() -> Self {
        Self { slot: Arc::new(Mutex::new(LoadState::Idle)) }
    }
}

impl MapLoader {
    pub fn state(&self) -> LoadState {
        self.slot.lock().map(|s| s.clone()).unwrap_or(LoadState::Idle)
    }

    fn set(&self, state: LoadState) {
        if let Ok(mut slot) = self.slot.lock() {
            *slot = state;
        }
    }

    /// Begin loading `map_id` from `origin` (e.g. `http://127.0.0.1:4000`).
    pub fn start(&self, origin: String, map_id: u16) {
        self.set(LoadState::Fetching("manifest"));
        spawn_load(self.clone(), origin, map_id);
    }
}

#[cfg(target_arch = "wasm32")]
fn spawn_load(loader: MapLoader, origin: String, map_id: u16) {
    wasm_bindgen_futures::spawn_local(async move {
        match load_map(&loader, &origin, map_id).await {
            Ok(Some(map)) => loader.set(LoadState::Ready(Box::new(map))),
            Ok(None) => loader.set(LoadState::Failed(format!("map {map_id} not in pack"))),
            Err(message) => loader.set(LoadState::Failed(message)),
        }
    });
}

#[cfg(not(target_arch = "wasm32"))]
fn spawn_load(loader: MapLoader, _origin: String, _map_id: u16) {
    // Native networking is not wired yet. Say so rather than hanging on a
    // "Fetching" state that never resolves.
    loader.set(LoadState::Failed("native map fetch not implemented yet".into()));
}

#[cfg(target_arch = "wasm32")]
async fn load_map(
    loader: &MapLoader,
    origin: &str,
    map_id: u16,
) -> Result<Option<ao_core::PackedMap>, String> {
    let manifest_url = format!("{origin}/api/meta/world-pack");
    let manifest = fetch_text(&manifest_url).await?;

    // The manifest is small and its shape is fixed, so a targeted extraction
    // avoids pulling in a JSON dependency for one field.
    let filename = json_string_field(&manifest, "filename")
        .ok_or_else(|| format!("no filename in manifest: {manifest}"))?;

    loader.set(LoadState::Fetching("map pack"));
    let pack_url = format!("{origin}/data/packs/{filename}");
    let bytes = fetch_bytes(&pack_url).await?;

    loader.set(LoadState::Fetching("decoding"));
    ao_core::decode_map(&bytes, map_id).map_err(|e| format!("{pack_url}: {e}"))
}

/// Minimal extractor for `"key":"value"` in flat JSON.
#[cfg(target_arch = "wasm32")]
fn json_string_field(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let start = json.find(&needle)? + needle.len();
    let rest = &json[start..];
    let colon = rest.find(':')? + 1;
    let rest = &rest[colon..];
    let open = rest.find('"')? + 1;
    let rest = &rest[open..];
    let close = rest.find('"')?;
    Some(rest[..close].to_string())
}

#[cfg(target_arch = "wasm32")]
async fn fetch_response(url: &str) -> Result<web_sys::Response, String> {
    use wasm_bindgen::JsCast;

    let window = web_sys::window().ok_or("no window")?;
    let value = wasm_bindgen_futures::JsFuture::from(window.fetch_with_str(url))
        .await
        .map_err(|e| format!("fetch {url} failed: {e:?}"))?;
    let response: web_sys::Response =
        value.dyn_into().map_err(|_| format!("fetch {url}: not a Response"))?;

    if !response.ok() {
        return Err(format!("{url} returned HTTP {}", response.status()));
    }

    Ok(response)
}

/// `fetch_text` for callers outside this module.
#[cfg(target_arch = "wasm32")]
pub async fn fetch_text_public(url: &str) -> Result<String, String> {
    fetch_text(url).await
}

#[cfg(target_arch = "wasm32")]
async fn fetch_text(url: &str) -> Result<String, String> {
    let response = fetch_response(url).await?;
    let text = wasm_bindgen_futures::JsFuture::from(
        response.text().map_err(|e| format!("{url}: {e:?}"))?,
    )
    .await
    .map_err(|e| format!("{url}: {e:?}"))?;
    text.as_string().ok_or_else(|| format!("{url}: body was not text"))
}

#[cfg(target_arch = "wasm32")]
async fn fetch_bytes(url: &str) -> Result<Vec<u8>, String> {
    let response = fetch_response(url).await?;
    let buffer = wasm_bindgen_futures::JsFuture::from(
        response.array_buffer().map_err(|e| format!("{url}: {e:?}"))?,
    )
    .await
    .map_err(|e| format!("{url}: {e:?}"))?;
    Ok(js_sys::Uint8Array::new(&buffer).to_vec())
}


/// Fetch the grh index and every sheet the given grh ids need.
///
/// Sheets are fetched once per file even though hundreds of regions share one,
/// which is the whole reason the index carries a file number plus a rect.
#[cfg(target_arch = "wasm32")]
pub fn start_graphics_load(graphics: Graphics, origin: String, grh_ids: Vec<i32>) {
    wasm_bindgen_futures::spawn_local(async move {
        let index_url = format!("{origin}/indices/graficos_full.json");
        let json = match fetch_text(&index_url).await {
            Ok(json) => json,
            Err(message) => return graphics.fail(message),
        };

        let index = GrhIndex::parse(&json, "graficos");

        // Characters resolve against a different index whose sheets live under
        // /graficos_char and are named with strings ("a1"), not numbers.
        match fetch_text(&format!("{origin}/indices/graficos.json")).await {
            Ok(json) => {
                let char_index = GrhIndex::parse(&json, "graficos_char");
                graphics.set_char_index(char_index);
            }
            Err(e) => log::warn!("character index: {e}"),
        }

        // Character bodies and heads. Small files, and the player is a coloured
        // box until they arrive.
        if let Ok(json) = fetch_text(&format!("{origin}/indices/cuerpos.json")).await {
            let bodies = parse_directional(&json);
            graphics.set_bodies(bodies);
        }
        if let Ok(json) = fetch_text(&format!("{origin}/indices/cabezas.json")).await {
            let heads = parse_directional(&json);
            graphics.set_heads(heads);
        }
        if let Ok(json) = fetch_text(&format!("{origin}/indices/npcs.json")).await {
            let npcs = parse_npcs(&json);
            graphics.set_npcs(npcs);
        }
        if let Ok(json) = fetch_text(&format!("{origin}/indices/objs.json")).await {
            let objects = parse_objects(&json);
            graphics.set_objects(objects);
        }

        let mut files = HashSet::new();
        for id in &grh_ids {
            if let Some(grh) = index.resolve(*id) {
                files.insert(grh.sheet);
            }
        }

        // Character art: every body and head referenced by the player and by
        // the npcs on this map.
        if let (Some(char_index), Some(bodies), Some(heads), Some(npcs)) = (
            graphics.char_index(),
            graphics.bodies(),
            graphics.heads(),
            graphics.npcs(),
        ) {
            let mut looks: Vec<(i32, i32)> = vec![(DEFAULT_BODY, DEFAULT_HEAD)];
            looks.extend(npcs.values().map(|n| (n.body, n.head)));

            for (body_id, head_id) in looks {
                if let Some(body) = bodies.get(&body_id) {
                    for grh in [body.north, body.east, body.south, body.west] {
                        if let Some(grh) = char_index.resolve(grh) {
                            files.insert(grh.sheet);
                        }
                    }
                }
                if head_id > 0 {
                    if let Some(head) = heads.get(&head_id) {
                        for grh in [head.north, head.east, head.south, head.west] {
                            if let Some(grh) = char_index.resolve(grh) {
                                files.insert(grh.sheet);
                            }
                        }
                    }
                }
            }
        }
        graphics.set_index(index);

        for sheet in files {
            let url = format!("{origin}/{sheet}");
            match fetch_bytes(&url).await {
                Ok(bytes) => match decode_png(&bytes) {
                    Ok((w, h, rgba)) => graphics.push_sheet(sheet.clone(), w, h, rgba),
                    // One unreadable sheet must not stop the rest of the world
                    // from drawing.
                    Err(e) => log::warn!("sheet {sheet}: {e}"),
                },
                Err(e) => log::warn!("sheet {sheet}: {e}"),
            }
        }
    });
}

#[cfg(not(target_arch = "wasm32"))]
pub fn start_graphics_load(graphics: Graphics, _origin: String, _grh_ids: Vec<i32>) {
    graphics.fail("native graphics fetch not implemented yet".into());
}
