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
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// One drawable region within a sheet.
#[derive(Debug, Clone, Copy)]
pub struct Grh {
    pub file: u32,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Default)]
pub struct GrhIndex {
    statics: HashMap<i32, Grh>,
    /// Animation id -> its frame grh ids. Frame 0 is used until animation is
    /// wired up, which is still far better than drawing nothing.
    animations: HashMap<i32, Vec<i32>>,
}

impl GrhIndex {
    pub fn len(&self) -> usize {
        self.statics.len()
    }

    /// Resolve a grh to a drawable region, following one level of animation.
    pub fn resolve(&self, id: i32) -> Option<Grh> {
        if let Some(grh) = self.statics.get(&id) {
            return Some(*grh);
        }
        let first = *self.animations.get(&id)?.first()?;
        self.statics.get(&first).copied()
    }

    /// Parse the index. Hand-rolled rather than serde to keep the wasm payload
    /// down; the shape is fixed and flat, and this file is 5.9 MB of it.
    pub fn parse(json: &str) -> Self {
        let mut index = GrhIndex::default();

        for object in split_objects(json) {
            let Some(id) = number_field(object, "id").map(|v| v as i32) else {
                continue;
            };

            if let Some(grafico) = number_field(object, "grafico") {
                index.statics.insert(
                    id,
                    Grh {
                        file: grafico as u32,
                        x: number_field(object, "offX").unwrap_or(0.0) as f32,
                        y: number_field(object, "offY").unwrap_or(0.0) as f32,
                        width: number_field(object, "width").unwrap_or(32.0) as f32,
                        height: number_field(object, "height").unwrap_or(32.0) as f32,
                    },
                );
            } else if let Some(frames) = int_array_field(object, "frames") {
                index.animations.insert(id, frames);
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

fn number_field(object: &str, key: &str) -> Option<f64> {
    let needle = format!("\"{key}\"");
    let at = object.find(&needle)? + needle.len();
    let rest = object[at..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '-' || c == '.'))
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn int_array_field(object: &str, key: &str) -> Option<Vec<i32>> {
    let needle = format!("\"{key}\"");
    let at = object.find(&needle)? + needle.len();
    let rest = object[at..].trim_start().strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('[')?;
    let end = rest.find(']')?;
    Some(
        rest[..end]
            .split(',')
            .filter_map(|part| part.trim().parse::<i32>().ok())
            .collect(),
    )
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

/// Loading state for the index and sheets, shared with the async fetcher.
#[derive(Resource, Clone)]
pub struct Graphics {
    inner: Arc<Mutex<GraphicsInner>>,
}

#[derive(Default)]
pub struct GraphicsInner {
    pub index: Option<Arc<GrhIndex>>,
    pub bodies: Option<Arc<HashMap<i32, Directional>>>,
    pub heads: Option<Arc<HashMap<i32, Directional>>>,
    /// Sheet file number -> decoded RGBA, awaiting upload as a Bevy image.
    pub pending_sheets: Vec<(u32, u32, u32, Vec<u8>)>,
    pub failed: Option<String>,
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

    pub fn take_pending_sheets(&self) -> Vec<(u32, u32, u32, Vec<u8>)> {
        self.inner
            .lock()
            .map(|mut g| std::mem::take(&mut g.pending_sheets))
            .unwrap_or_default()
    }

    pub fn failure(&self) -> Option<String> {
        self.inner.lock().ok().and_then(|g| g.failed.clone())
    }

    pub fn bodies(&self) -> Option<Arc<HashMap<i32, Directional>>> {
        self.inner.lock().ok().and_then(|g| g.bodies.clone())
    }

    pub fn heads(&self) -> Option<Arc<HashMap<i32, Directional>>> {
        self.inner.lock().ok().and_then(|g| g.heads.clone())
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

    pub fn push_sheet(&self, file: u32, width: u32, height: u32, rgba: Vec<u8>) {
        if let Ok(mut g) = self.inner.lock() {
            g.pending_sheets.push((file, width, height, rgba));
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
pub struct SheetTextures(pub HashMap<u32, Handle<Image>>);

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
        let index = GrhIndex::parse(json);
        assert_eq!(index.len(), 2);

        let one = index.resolve(1).expect("static grh");
        assert_eq!(one.file, 1);
        assert_eq!((one.x, one.y, one.width, one.height), (64.0, 0.0, 32.0, 32.0));

        // An animation resolves through to its first frame rather than
        // rendering nothing.
        let animated = index.resolve(91).expect("animated grh");
        assert_eq!(animated.file, 7);
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
        let heads = parse_directional(r#"[{"id": 1, "up": 3003, "right": 3001, "down": 3000, "left": 3002}]"#);
        let head = heads.get(&1).copied().expect("head 1");
        assert_eq!(head.for_heading(Heading::South), 3000);
        assert_eq!(head.head_offset, Vec2::ZERO);
    }

    #[test]
    fn unknown_ids_resolve_to_none() {
        assert!(GrhIndex::parse("[]").resolve(42).is_none());
    }

    #[test]
    fn ignores_entries_without_an_id() {
        let index = GrhIndex::parse(r#"[{"grafico": 3, "width": 32}]"#);
        assert_eq!(index.len(), 0);
    }

    #[test]
    fn animation_pointing_at_a_missing_frame_is_not_a_panic() {
        let index = GrhIndex::parse(r#"[{"id": 5, "frames": [999], "velocidad": 1.0}]"#);
        assert!(index.resolve(5).is_none());
    }
}
