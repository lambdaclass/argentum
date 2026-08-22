//! Reading the graphics index: which sheet a drawable region lives on, and where.
//!
//! A "grh" is one drawable region — a 32x32 ground tile, or a larger sprite. The index is a
//! flat JSON array where a static region is `{id, grafico, offX, offY, width, height}` and an
//! animation is `{id, frames: [...], velocidad}`. `grafico` names the sheet, and it is a
//! number in the map index and a short string like `a1` in the character index.
//!
//! This lives in `ao-core` and not in the client because two things need it now: the client,
//! to draw, and the topology compiler, to compare what a seam actually renders. The parsing
//! had been in the client, and the compiler was about to grow a second copy — which is the
//! mistake this codebase has already paid for twice, once with the blocked layer read as two
//! states and once with two tile classifiers disagreeing about walkable ground. One parser.
//!
//! Hand-rolled rather than serde: the map index is 5.9 MB, the shape is flat and fixed, and
//! the client ships to wasm where the dependency would be felt.

use std::collections::BTreeMap;

/// One drawable region, as the index states it.
///
/// `sheet` is the raw `grafico` field, not a path. The two indices name sheets differently
/// and resolve to different directories, so turning a name into a path is the caller's
/// decision — the client wants a URL, the compiler wants a file, and neither should be baked
/// in here.
#[derive(Debug, Clone, PartialEq)]
pub struct Region {
    pub id: i32,
    pub sheet: String,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// An animation: the regions it cycles through, and how long a full cycle takes.
#[derive(Debug, Clone, PartialEq)]
pub struct Animation {
    pub id: i32,
    pub frames: Vec<i32>,
    pub cycle_ms: f32,
}

/// Everything a graphics index states.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Index {
    pub regions: BTreeMap<i32, Region>,
    pub animations: BTreeMap<i32, Animation>,
}

impl Index {
    pub fn parse(json: &str) -> Index {
        let mut index = Index::default();

        for object in objects(json) {
            let Some(id) = number(object, "id").map(|value| value as i32) else {
                continue;
            };

            if let Some(sheet) = sheet(object) {
                index.regions.insert(
                    id,
                    Region {
                        id,
                        sheet,
                        x: number(object, "offX").unwrap_or(0.0) as i32,
                        y: number(object, "offY").unwrap_or(0.0) as i32,
                        // 32 is the tile size, and a region without a stated size is one
                        // tile: the same fallback the web client uses.
                        width: number(object, "width").unwrap_or(32.0) as i32,
                        height: number(object, "height").unwrap_or(32.0) as i32,
                    },
                );
            } else if let Some(frames) = int_array(object, "frames") {
                // Bodies without a stated speed fall back to the web client's 210 ms.
                let cycle_ms = number(object, "velocidad").unwrap_or(210.0) as f32;
                index.animations.insert(id, Animation { id, frames, cycle_ms });
            }
        }

        index
    }

    /// The region a grh draws, following one level of animation to its first frame.
    pub fn resolve(&self, id: i32) -> Option<&Region> {
        if let Some(region) = self.regions.get(&id) {
            return Some(region);
        }
        let first = self.animations.get(&id)?.frames.first()?;
        self.regions.get(first)
    }
}

/// Each top-level `{...}` object body in a flat JSON array.
pub fn objects(json: &str) -> impl Iterator<Item = &str> {
    let bytes = json.as_bytes();
    let mut start = None;
    let mut depth = 0usize;
    let mut out = Vec::new();

    for (at, byte) in bytes.iter().enumerate() {
        match byte {
            b'{' => {
                if depth == 0 {
                    start = Some(at + 1);
                }
                depth += 1;
            }
            b'}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    if let Some(from) = start.take() {
                        out.push(&json[from..at]);
                    }
                }
            }
            _ => {}
        }
    }

    out.into_iter()
}

/// The `grafico` field, quoted or bare.
pub fn sheet(object: &str) -> Option<String> {
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

pub fn number(object: &str, key: &str) -> Option<f64> {
    let needle = format!("\"{key}\"");
    let at = object.find(&needle)? + needle.len();
    let rest = object[at..].trim_start().strip_prefix(':')?.trim_start();
    let end =
        rest.find(|c: char| !(c.is_ascii_digit() || c == '-' || c == '.')).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

pub fn int_array(object: &str, key: &str) -> Option<Vec<i32>> {
    let needle = format!("\"{key}\"");
    let at = object.find(&needle)? + needle.len();
    let rest = object[at..].trim_start().strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('[')?;
    let end = rest.find(']')?;
    Some(rest[..end].split(',').filter_map(|part| part.trim().parse::<i32>().ok()).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_numeric_sheet_and_a_named_sheet_both_parse() {
        // The map index numbers its sheets and the character index names them, and both are
        // the same field. A parser that assumed either shape would silently drop half the
        // world's art.
        let index = Index::parse(
            r#"[0,
              {"id": 1, "grafico": 1000, "offX": 64, "offY": 0, "width": 32, "height": 32},
              {"id": 2, "grafico": "a1", "offX": 1273, "offY": 1664, "width": 32, "height": 32}
            ]"#,
        );

        assert_eq!(index.regions[&1].sheet, "1000");
        assert_eq!(index.regions[&1].x, 64);
        assert_eq!(index.regions[&2].sheet, "a1");
        assert_eq!(index.regions[&2].y, 1664);
    }

    #[test]
    fn a_region_without_a_stated_size_is_one_tile() {
        let index = Index::parse(r#"[0, {"id": 5, "grafico": 7, "offX": 0, "offY": 0}]"#);
        assert_eq!((index.regions[&5].width, index.regions[&5].height), (32, 32));
    }

    #[test]
    fn an_animation_resolves_to_its_first_frame() {
        let index = Index::parse(
            r#"[0,
              {"id": 10, "grafico": 3, "offX": 0, "offY": 0, "width": 32, "height": 32},
              {"id": 11, "grafico": 3, "offX": 32, "offY": 0, "width": 32, "height": 32},
              {"id": 99, "frames": [10, 11], "velocidad": 420}
            ]"#,
        );

        assert_eq!(index.animations[&99].frames, vec![10, 11]);
        assert_eq!(index.animations[&99].cycle_ms, 420.0);
        assert_eq!(index.resolve(99).map(|region| region.id), Some(10));
        assert_eq!(index.resolve(10).map(|region| region.id), Some(10));
        assert_eq!(index.resolve(12345), None);
    }

    #[test]
    fn an_animation_without_a_speed_gets_the_web_clients_default() {
        let index = Index::parse(r#"[0, {"id": 99, "frames": [1, 2]}]"#);
        assert_eq!(index.animations[&99].cycle_ms, 210.0);
    }

    #[test]
    fn the_leading_zero_and_trailing_junk_do_not_become_regions() {
        // Both real indices start with a bare `0` before the first object.
        let index = Index::parse(r#"[0, {"id": 1, "grafico": 1, "offX": 0, "offY": 0}]"#);
        assert_eq!(index.regions.len(), 1);
        assert!(index.animations.is_empty());
    }
}
