//! Real Argentum graphics: the grh index and the sprite sheets it points into.
//!
//! A "grh" is one drawable region. `resources/indices/graficos_full.json` maps a
//! grh id to either
//!
//! - a static region: `{id, grafico, offX, offY, width, height}` where `grafico`
//!   is the sheet file number served at `/graficos/<grafico>.png`, or
//! - an animation: `{id, frames: [grh, ...], velocidad}` referring to other ids.
//!
//! The sheets are large (1024x1024) and shared by hundreds of regions, so they
//! are fetched once and reused as Bevy `Image` assets with per-sprite `rect`s.

use bevy::prelude::*;
use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

/// One drawable region within a sheet.
///
/// `sheet` is the full asset path because the two indices name sheets
/// differently: map tiles use numeric files under `/graficos`, characters use
/// short string names like `a1` under `/graficos_char`. Carrying the resolved
/// path removes that distinction from every call site.
#[derive(Debug, Clone)]
pub struct Grh {
    pub sheet: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// A multi-frame animation: the frames themselves plus how long one full cycle
/// takes. `velocidad` in the index is the whole cycle, not one frame.
#[derive(Debug, Clone)]
pub struct GrhAnimation {
    pub frames: Vec<Grh>,
    pub cycle_ms: f32,
}

#[derive(Default)]
pub struct GrhIndex {
    statics: HashMap<i32, Grh>,
    animations: HashMap<i32, (Vec<i32>, f32)>,
}

impl GrhIndex {
    pub fn len(&self) -> usize {
        self.statics.len()
    }

    /// Resolve a grh to a drawable region, following one level of animation.
    pub fn resolve(&self, id: i32) -> Option<Grh> {
        if let Some(grh) = self.statics.get(&id) {
            return Some(grh.clone());
        }
        let first = *self.animations.get(&id)?.0.first()?;
        self.statics.get(&first).cloned()
    }

    /// Full animation for a grh, if it has one.
    ///
    /// Walking is the difference between a sliding cardboard cutout and a
    /// character, so the frames matter as much as the first one.
    pub fn animation(&self, id: i32) -> Option<GrhAnimation> {
        let (ids, cycle_ms) = self.animations.get(&id)?;
        let frames: Vec<Grh> =
            ids.iter().filter_map(|frame| self.statics.get(frame).cloned()).collect();
        if frames.is_empty() {
            return None;
        }
        Some(GrhAnimation { frames, cycle_ms: *cycle_ms })
    }

    /// Parse an index. Hand-rolled rather than serde to keep the wasm payload
    /// down; the shape is fixed and flat, and the map index is 5.9 MB of it.
    ///
    /// `base` is the asset directory the sheet names belong to, which differs
    /// between the map and character indices.
    pub fn parse(json: &str, base: &str) -> Self {
        let mut index = GrhIndex::default();

        for object in split_objects(json) {
            let Some(id) = number_field(object, "id").map(|v| v as i32) else {
                continue;
            };

            if let Some(grafico) = sheet_field(object) {
                index.statics.insert(
                    id,
                    Grh {
                        sheet: format!("{base}/{grafico}.png"),
                        x: number_field(object, "offX").unwrap_or(0.0) as f32,
                        y: number_field(object, "offY").unwrap_or(0.0) as f32,
                        width: number_field(object, "width").unwrap_or(32.0) as f32,
                        height: number_field(object, "height").unwrap_or(32.0) as f32,
                    },
                );
            } else if let Some(frames) = int_array_field(object, "frames") {
                // Bodies without a stated speed fall back to the web client's
                // default of 210ms per cycle.
                let cycle = number_field(object, "velocidad").unwrap_or(210.0) as f32;
                index.animations.insert(id, (frames, cycle));
            }
        }

        index
    }
}

/// Yield each top-level `{...}` object body in a flat JSON array.
fn split_objects(json: &str) -> impl Iterator<Item = &str> {
    let bytes = json.as_bytes();
    let mut start = None;
    let mut depth = 0usize;
    let mut out = Vec::new();

    for (i, &b) in bytes.iter().enumerate() {
        match b {
            b'{' => {
                if depth == 0 {
                    start = Some(i + 1);
                }
                depth += 1;
            }
            b'}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    if let Some(s) = start.take() {
                        out.push(&json[s..i]);
                    }
                }
            }
            _ => {}
        }
    }

    out.into_iter()
}

/// Sheet name, which is a bare number in the map index and a quoted string in
/// the character index.
fn sheet_field(object: &str) -> Option<String> {
    let needle = "\"grafico\"";
    let at = object.find(needle)? + needle.len();
    let rest = object[at..].trim_start().strip_prefix(':')?.trim_start();

    if let Some(quoted) = rest.strip_prefix('"') {
        let end = quoted.find('"')?;
        return Some(quoted[..end].to_string());
    }

    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    Some(rest[..end].to_string())
}

fn number_field(object: &str, key: &str) -> Option<f64> {
    let needle = format!("\"{key}\"");
    let at = object.find(&needle)? + needle.len();
    let rest = object[at..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let end =
        rest.find(|c: char| !(c.is_ascii_digit() || c == '-' || c == '.')).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn int_array_field(object: &str, key: &str) -> Option<Vec<i32>> {
    let needle = format!("\"{key}\"");
    let at = object.find(&needle)? + needle.len();
    let rest = object[at..].trim_start().strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('[')?;
    let end = rest.find(']')?;
    Some(rest[..end].split(',').filter_map(|part| part.trim().parse::<i32>().ok()).collect())
}

/// Directional grh ids for a body or head, plus where a body carries its head.
#[derive(Debug, Clone, Copy, Default)]
pub struct Directional {
    pub north: i32,
    pub east: i32,
    pub south: i32,
    pub west: i32,
    pub head_offset: Vec2,
}

impl Directional {
    pub fn for_heading(&self, heading: Heading) -> i32 {
        match heading {
            Heading::North => self.north,
            Heading::East => self.east,
            Heading::South => self.south,
            Heading::West => self.west,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Heading {
    North,
    East,
    South,
    West,
}

/// Parse `cuerpos.json` / `cabezas.json`, both `{id, up, right, down, left}`
/// with bodies additionally carrying `offHeadX` / `offHeadY`.
pub fn parse_directional(json: &str) -> HashMap<i32, Directional> {
    let mut out = HashMap::new();
    for object in split_objects(json) {
        let Some(id) = number_field(object, "id").map(|v| v as i32) else {
            continue;
        };
        out.insert(
            id,
            Directional {
                north: number_field(object, "up").unwrap_or(0.0) as i32,
                east: number_field(object, "right").unwrap_or(0.0) as i32,
                south: number_field(object, "down").unwrap_or(0.0) as i32,
                west: number_field(object, "left").unwrap_or(0.0) as i32,
                head_offset: Vec2::new(
                    number_field(object, "offHeadX").unwrap_or(0.0) as f32,
                    number_field(object, "offHeadY").unwrap_or(0.0) as f32,
                ),
            },
        );
    }
    out
}

/// An NPC's appearance from `npcs.json`.
#[derive(Debug, Clone, Copy, Default)]
pub struct NpcLook {
    pub body: i32,
    pub head: i32,
    pub heading: i32,
}

/// Parse `npcs.json`: `{name, body, head, heading}` keyed by npc id. Entries are
/// sparse — the array has nulls where ids are unused.
pub fn parse_npcs(json: &str) -> HashMap<i32, NpcLook> {
    // npcs.json has no id field: the array position is the id, and nulls
    // occupy positions. split_objects cannot be used here because skipping the
    // nulls would shift every later npc's appearance.
    let mut out = HashMap::new();
    let mut id = 0i32;
    let mut depth = 0usize;
    let mut start = None;
    let bytes = json.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b'[' if depth == 0 => depth = 1,
            b'{' => {
                if depth == 1 {
                    start = Some(i + 1);
                }
                depth += 1;
            }
            b'}' => {
                depth -= 1;
                if depth == 1 {
                    if let Some(s) = start.take() {
                        let object = &json[s..i];
                        out.insert(
                            id,
                            NpcLook {
                                body: number_field(object, "body").unwrap_or(0.0) as i32,
                                head: number_field(object, "head").unwrap_or(0.0) as i32,
                                heading: number_field(object, "heading").unwrap_or(3.0) as i32,
                            },
                        );
                    }
                    id += 1;
                }
            }
            b'n' if depth == 1 && json[i..].starts_with("null") => {
                id += 1;
                i += 3;
            }
            _ => {}
        }
        i += 1;
    }
    out
}

/// Parse `objs.json`: `{name, grh}` positionally, same sparse-array shape.
pub fn parse_objects(json: &str) -> HashMap<i32, i32> {
    let mut out = HashMap::new();
    let mut id = 0i32;
    let mut depth = 0usize;
    let mut start = None;
    let bytes = json.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b'[' if depth == 0 => depth = 1,
            b'{' => {
                if depth == 1 {
                    start = Some(i + 1);
                }
                depth += 1;
            }
            b'}' => {
                depth -= 1;
                if depth == 1 {
                    if let Some(s) = start.take() {
                        if let Some(grh) = number_field(&json[s..i], "grh") {
                            out.insert(id, grh as i32);
                        }
                    }
                    id += 1;
                }
            }
            b'n' if depth == 1 && json[i..].starts_with("null") => {
                id += 1;
                i += 3;
            }
            _ => {}
        }
        i += 1;
    }
    out
}

/// Loading state for the index and sheets, shared with the async fetcher.
#[derive(Resource, Clone)]
pub struct Graphics {
    inner: Arc<Mutex<GraphicsInner>>,
}

#[derive(Default)]
pub struct GraphicsInner {
    pub index: Option<Arc<GrhIndex>>,
    /// Characters resolve against a different index with different sheet names.
    pub char_index: Option<Arc<GrhIndex>>,
    pub bodies: Option<Arc<HashMap<i32, Directional>>>,
    pub heads: Option<Arc<HashMap<i32, Directional>>>,
    pub npcs: Option<Arc<HashMap<i32, NpcLook>>>,
    pub objects: Option<Arc<HashMap<i32, i32>>>,
    /// Sheet file number -> decoded RGBA, awaiting upload as a Bevy image.
    pub pending_sheets: Vec<(String, u32, u32, Vec<u8>)>,
    pub failed: Option<String>,
    /// Every sheet this load decided it needs, recorded before any of them is fetched.
    ///
    /// The loader has always computed this set — it is what it iterates over — and then
    /// dropped it, so nothing outside could tell "no sheets yet" from "all the sheets
    /// there will ever be". `None` means the loader has not got that far.
    pub required_sheets: Option<BTreeSet<String>>,
    /// Sheets that will not arrive, with the reason.
    ///
    /// Previously a `log::warn!` and nothing else, on the principle that one unreadable
    /// sheet must not stop the rest of the world drawing. That is right for an optional
    /// sheet and wrong for one the visible scene needs: the world then draws with a hole
    /// in it and no way to say so.
    pub failed_sheets: Vec<(String, String)>,
}

impl Default for Graphics {
    fn default() -> Self {
        Self { inner: Arc::new(Mutex::new(GraphicsInner::default())) }
    }
}

impl Graphics {
    pub fn index(&self) -> Option<Arc<GrhIndex>> {
        self.inner.lock().ok().and_then(|g| g.index.clone())
    }

    pub fn char_index(&self) -> Option<Arc<GrhIndex>> {
        self.inner.lock().ok().and_then(|g| g.char_index.clone())
    }

    pub fn set_char_index(&self, index: GrhIndex) {
        if let Ok(mut g) = self.inner.lock() {
            g.char_index = Some(Arc::new(index));
        }
    }

    pub fn take_pending_sheets(&self) -> Vec<(String, u32, u32, Vec<u8>)> {
        self.inner.lock().map(|mut g| std::mem::take(&mut g.pending_sheets)).unwrap_or_default()
    }

    pub fn failure(&self) -> Option<String> {
        self.inner.lock().ok().and_then(|g| g.failed.clone())
    }

    /// Record what this load is going to need, before it starts fetching.
    pub fn set_required_sheets(&self, sheets: BTreeSet<String>) {
        if let Ok(mut g) = self.inner.lock() {
            g.required_sheets = Some(sheets);
        }
    }

    pub fn required_sheets(&self) -> Option<BTreeSet<String>> {
        self.inner.lock().ok().and_then(|g| g.required_sheets.clone())
    }

    /// Record a sheet that will not arrive.
    pub fn sheet_failed(&self, sheet: String, reason: String) {
        if let Ok(mut g) = self.inner.lock() {
            g.failed_sheets.push((sheet, reason));
        }
    }

    pub fn failed_sheets(&self) -> Vec<(String, String)> {
        self.inner.lock().map(|g| g.failed_sheets.clone()).unwrap_or_default()
    }

    pub fn bodies(&self) -> Option<Arc<HashMap<i32, Directional>>> {
        self.inner.lock().ok().and_then(|g| g.bodies.clone())
    }

    pub fn heads(&self) -> Option<Arc<HashMap<i32, Directional>>> {
        self.inner.lock().ok().and_then(|g| g.heads.clone())
    }

    pub fn npcs(&self) -> Option<Arc<HashMap<i32, NpcLook>>> {
        self.inner.lock().ok().and_then(|g| g.npcs.clone())
    }

    pub fn objects(&self) -> Option<Arc<HashMap<i32, i32>>> {
        self.inner.lock().ok().and_then(|g| g.objects.clone())
    }

    pub fn set_npcs(&self, npcs: HashMap<i32, NpcLook>) {
        if let Ok(mut g) = self.inner.lock() {
            g.npcs = Some(Arc::new(npcs));
        }
    }

    pub fn set_objects(&self, objects: HashMap<i32, i32>) {
        if let Ok(mut g) = self.inner.lock() {
            g.objects = Some(Arc::new(objects));
        }
    }

    pub fn set_bodies(&self, bodies: HashMap<i32, Directional>) {
        if let Ok(mut g) = self.inner.lock() {
            g.bodies = Some(Arc::new(bodies));
        }
    }

    pub fn set_heads(&self, heads: HashMap<i32, Directional>) {
        if let Ok(mut g) = self.inner.lock() {
            g.heads = Some(Arc::new(heads));
        }
    }

    pub fn set_index(&self, index: GrhIndex) {
        if let Ok(mut g) = self.inner.lock() {
            g.index = Some(Arc::new(index));
        }
    }

    pub fn push_sheet(&self, sheet: String, width: u32, height: u32, rgba: Vec<u8>) {
        if let Ok(mut g) = self.inner.lock() {
            g.pending_sheets.push((sheet, width, height, rgba));
        }
    }

    pub fn fail(&self, message: String) {
        if let Ok(mut g) = self.inner.lock() {
            g.failed = Some(message);
        }
    }
}

/// Sheet file number -> uploaded texture.
#[derive(Resource, Default)]
pub struct SheetTextures(pub HashMap<String, Handle<Image>>);

/// Decode a PNG into raw RGBA plus its dimensions.
pub fn decode_png(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let decoded = image::load_from_memory_with_format(bytes, image::ImageFormat::Png)
        .map_err(|e| e.to_string())?
        .to_rgba8();
    let (w, h) = decoded.dimensions();
    Ok((w, h, decoded.into_raw()))
}

/// Build a nearest-sampled texture. Argentum art is pixel art; the default
/// linear filter blurs it and makes atlas neighbours bleed into each other.
pub fn make_image(width: u32, height: u32, rgba: Vec<u8>) -> Image {
    use bevy::asset::RenderAssetUsages;
    use bevy::image::ImageSampler;
    use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};

    let mut image = Image::new(
        Extent3d { width, height, depth_or_array_layers: 1 },
        TextureDimension::D2,
        rgba,
        TextureFormat::Rgba8UnormSrgb,
        RenderAssetUsages::RENDER_WORLD,
    );
    image.sampler = ImageSampler::nearest();
    image
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_static_and_animated_entries() {
        let json = r#"[
            {"id": 1, "grafico": 1, "offX": 64, "offY": 0, "width": 32, "height": 32},
            {"id": 91, "frames": [85, 86, 87], "velocidad": 333.0},
            {"id": 85, "grafico": 7, "offX": 10, "offY": 20, "width": 27, "height": 47}
        ]"#;
        let index = GrhIndex::parse(json, "graficos");
        assert_eq!(index.len(), 2);

        let one = index.resolve(1).expect("static grh");
        assert_eq!(one.sheet, "graficos/1.png");
        assert_eq!((one.x, one.y, one.width, one.height), (64.0, 0.0, 32.0, 32.0));

        // An animation resolves through to its first frame rather than
        // rendering nothing.
        let animated = index.resolve(91).expect("animated grh");
        assert_eq!(animated.sheet, "graficos/7.png");
        assert_eq!(animated.height, 47.0);
    }

    #[test]
    fn parses_directional_bodies_with_head_offsets() {
        let bodies = parse_directional(
            r#"[{"right": 4584, "up": 4582, "down": 4581, "offHeadY": -4, "offHeadX": 2, "id": 1, "left": 4583}]"#,
        );
        let body = bodies.get(&1).copied().expect("body 1");
        assert_eq!(body.for_heading(Heading::South), 4581);
        assert_eq!(body.for_heading(Heading::North), 4582);
        assert_eq!(body.for_heading(Heading::East), 4584);
        assert_eq!(body.for_heading(Heading::West), 4583);
        assert_eq!(body.head_offset, Vec2::new(2.0, -4.0));
    }

    #[test]
    fn heads_have_no_offsets_and_that_is_fine() {
        let heads = parse_directional(
            r#"[{"id": 1, "up": 3003, "right": 3001, "down": 3000, "left": 3002}]"#,
        );
        let head = heads.get(&1).copied().expect("head 1");
        assert_eq!(head.for_heading(Heading::South), 3000);
        assert_eq!(head.head_offset, Vec2::ZERO);
    }

    #[test]
    fn animations_expose_every_frame_and_the_cycle_time() {
        let index = GrhIndex::parse(
            r#"[
                {"id": 91, "frames": [85, 86], "velocidad": 333.0},
                {"id": 85, "grafico": "a1", "offX": 0, "offY": 0, "width": 25, "height": 45},
                {"id": 86, "grafico": "a1", "offX": 25, "offY": 0, "width": 25, "height": 45}
            ]"#,
            "graficos_char",
        );
        let animation = index.animation(91).expect("animation");
        assert_eq!(animation.frames.len(), 2);
        assert_eq!(animation.cycle_ms, 333.0);
        // velocidad is the whole cycle, so a two-frame walk advances every 166ms.
        assert_eq!(animation.frames[1].x, 25.0);
    }

    #[test]
    fn animation_missing_its_frames_yields_none_rather_than_an_empty_cycle() {
        let index = GrhIndex::parse(r#"[{"id": 5, "frames": [999], "velocidad": 1.0}]"#, "g");
        assert!(index.animation(5).is_none());
    }

    #[test]
    fn character_sheets_are_named_with_strings() {
        // The character index names sheets "a1", the map index names them 7.
        // Treating both as numbers silently dropped every character graphic.
        let index = GrhIndex::parse(
            r#"[{"id": 3000, "grafico": "a1", "offX": 2729, "offY": 1734, "width": 17, "height": 50}]"#,
            "graficos_char",
        );
        let head = index.resolve(3000).expect("head grh");
        assert_eq!(head.sheet, "graficos_char/a1.png");
        assert_eq!((head.width, head.height), (17.0, 50.0));
    }

    #[test]
    fn npcs_are_keyed_by_array_position_including_nulls() {
        // npcs.json has no id field; the index is the position, and nulls
        // occupy positions. Skipping them shifts every later npc's appearance.
        let npcs = parse_npcs(
            r#"[null, {"name":"Sacerdote","body":117,"head":3,"heading":3}, null, {"name":"X","body":9,"head":1,"heading":1}]"#,
        );
        assert_eq!(npcs.get(&1).map(|n| n.body), Some(117));
        assert_eq!(npcs.get(&3).map(|n| n.body), Some(9));
        assert!(npcs.get(&0).is_none());
        assert!(npcs.get(&2).is_none());
    }

    #[test]
    fn objects_are_keyed_by_array_position_too() {
        let objs = parse_objects(r#"[null, {"name":"Manzana Roja","grh":506}]"#);
        assert_eq!(objs.get(&1), Some(&506));
        assert!(objs.get(&0).is_none());
    }

    #[test]
    fn unknown_ids_resolve_to_none() {
        assert!(GrhIndex::parse("[]", "graficos").resolve(42).is_none());
    }

    #[test]
    fn ignores_entries_without_an_id() {
        let index = GrhIndex::parse(r#"[{"grafico": 3, "width": 32}]"#, "graficos");
        assert_eq!(index.len(), 0);
    }

    #[test]
    fn animation_pointing_at_a_missing_frame_is_not_a_panic() {
        let index =
            GrhIndex::parse(r#"[{"id": 5, "frames": [999], "velocidad": 1.0}]"#, "graficos");
        assert!(index.resolve(5).is_none());
    }
}
