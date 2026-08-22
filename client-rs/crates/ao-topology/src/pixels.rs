//! Comparing what a seam actually renders, pixel by pixel.
//!
//! Every art check so far compared *graphic ids*: the transition band names the same tile
//! graphic as its neighbour's core edge, 899 of 931 seams agreeing at 95% or better. That is
//! evidence about the index, not about the picture. Two ids can name regions that look
//! identical, and one id can be drawn from a sheet that changed underneath it.
//!
//! So this decodes the sheets and compares the pixels. It is the last of `W-0097`'s evidence
//! items, and it stays what the others are: a review signal that promotes nothing. Ground art
//! reached 100% identity on a boundary that walks a character into the sea, and pixels are no
//! wiser about locomotion than ids were.
//!
//! Sheet files are resolved case-insensitively on purpose. Four of the 2,330 sheets are named
//! `1000.PNG`, `1001.PNG`, `1002.PNG` and `1471.PNG` while the rest are lowercase, which
//! broke spawn-point ground art in both clients until the server grew the same fallback.

use ao_core::grh;
use image::RgbaImage;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Decoded sheets, loaded once each.
///
/// A failed load is remembered as a failure rather than retried: a missing sheet is a fact
/// about the corpus worth reporting once, not once per tile.
pub struct Sheets {
    dir: PathBuf,
    loaded: BTreeMap<String, Option<RgbaImage>>,
    pub missing: BTreeMap<String, usize>,
}

impl Sheets {
    pub fn new(dir: impl AsRef<Path>) -> Sheets {
        Sheets {
            dir: dir.as_ref().to_path_buf(),
            loaded: BTreeMap::new(),
            missing: BTreeMap::new(),
        }
    }

    fn sheet(&mut self, name: &str) -> Option<&RgbaImage> {
        if !self.loaded.contains_key(name) {
            // The extension case is the only thing retried, and only when the exact name is
            // absent: guessing more than that would hide a genuinely missing sheet.
            let candidates = [format!("{name}.png"), format!("{name}.PNG")];
            let found = candidates
                .iter()
                .map(|file| self.dir.join(file))
                .find(|path| path.exists())
                .and_then(|path| image::open(path).ok())
                .map(|image| image.to_rgba8());

            if found.is_none() {
                *self.missing.entry(name.to_string()).or_default() += 1;
            }
            self.loaded.insert(name.to_string(), found);
        }
        self.loaded.get(name).and_then(|sheet| sheet.as_ref())
    }

    /// The pixels one drawable region covers, or `None` if the sheet or the region is absent.
    pub fn region(&mut self, index: &grh::Index, id: i32) -> Option<Vec<[u8; 4]>> {
        let region = index.resolve(id)?.clone();
        let sheet = self.sheet(&region.sheet)?;

        // A region reaching past the edge of its sheet is a broken index entry, and cropping
        // it silently would compare a different picture than the game draws.
        if region.x < 0
            || region.y < 0
            || (region.x + region.width) as u32 > sheet.width()
            || (region.y + region.height) as u32 > sheet.height()
        {
            return None;
        }

        let mut pixels = Vec::with_capacity((region.width * region.height) as usize);
        for y in 0..region.height {
            for x in 0..region.width {
                let pixel = sheet.get_pixel((region.x + x) as u32, (region.y + y) as u32);
                pixels.push(pixel.0);
            }
        }
        Some(pixels)
    }
}

/// How two drawable regions compare.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Agreement {
    /// Pairs where both regions were decodable and every pixel matched.
    pub identical: usize,
    /// Pairs where both decoded and something differed.
    pub different: usize,
    /// Pairs where at least one region could not be decoded, so nothing is claimed.
    pub unknown: usize,
    /// Total pixels compared, and how many of them matched.
    pub pixels: usize,
    pub matching_pixels: usize,
}

impl Agreement {
    pub fn compared(&self) -> usize {
        self.identical + self.different
    }

    /// Share of decodable pairs that are pixel-identical, or `None` if nothing decoded.
    ///
    /// Reported per seam by callers that summarise; the acceptance report prints the counts
    /// and the pixel share instead, because "78 of 80 tiles identical" and "99% of pixels
    /// match" answer different questions and the second hides a wholly wrong tile.
    #[allow(dead_code)]
    pub fn tile_percent(&self) -> Option<usize> {
        if self.compared() == 0 {
            return None;
        }
        Some(self.identical * 100 / self.compared())
    }

    /// Share of compared pixels that matched.
    pub fn pixel_percent(&self) -> Option<usize> {
        if self.pixels == 0 {
            return None;
        }
        Some(self.matching_pixels * 100 / self.pixels)
    }

    pub fn add(&mut self, sheets: &mut Sheets, index: &grh::Index, left: i32, right: i32) {
        let (Some(left), Some(right)) = (sheets.region(index, left), sheets.region(index, right))
        else {
            self.unknown += 1;
            return;
        };

        if left.len() != right.len() {
            self.different += 1;
            return;
        }

        let matching = left.iter().zip(right.iter()).filter(|(a, b)| a == b).count();
        self.pixels += left.len();
        self.matching_pixels += matching;
        if matching == left.len() {
            self.identical += 1;
        } else {
            self.different += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index_of(entries: &str) -> grh::Index {
        grh::Index::parse(entries)
    }

    #[test]
    fn a_region_outside_its_sheet_is_unknown_rather_than_cropped() {
        // An index entry pointing past the edge of its sheet is broken data. Cropping it
        // would compare a picture the game never draws, and reporting it as a difference
        // would blame the seam for the index's mistake.
        let mut sheets = Sheets::new("/nonexistent");
        let index = index_of(
            r#"[0, {"id": 1, "grafico": 9999, "offX": 0, "offY": 0, "width": 32, "height": 32}]"#,
        );

        let mut agreement = Agreement::default();
        agreement.add(&mut sheets, &index, 1, 1);
        assert_eq!(agreement.unknown, 1);
        assert_eq!(agreement.compared(), 0);
        assert_eq!(agreement.tile_percent(), None);
        assert_eq!(sheets.missing.get("9999"), Some(&1));
    }

    #[test]
    fn a_missing_sheet_is_reported_once_not_once_per_tile() {
        let mut sheets = Sheets::new("/nonexistent");
        let index = index_of(r#"[0, {"id": 1, "grafico": 4242, "offX": 0, "offY": 0}]"#);

        let mut agreement = Agreement::default();
        for _ in 0..10 {
            agreement.add(&mut sheets, &index, 1, 1);
        }
        assert_eq!(agreement.unknown, 10);
        assert_eq!(sheets.missing.get("4242"), Some(&1), "loaded once, failed once");
    }

    #[test]
    fn percentages_are_none_until_something_is_actually_compared() {
        let agreement = Agreement::default();
        assert_eq!(agreement.tile_percent(), None);
        assert_eq!(agreement.pixel_percent(), None);

        let counted = Agreement {
            identical: 3,
            different: 1,
            unknown: 5,
            pixels: 4096,
            matching_pixels: 3072,
        };
        assert_eq!(counted.tile_percent(), Some(75));
        assert_eq!(counted.pixel_percent(), Some(75));
        assert_eq!(counted.compared(), 4, "unknown pairs are not in the denominator");
    }
}
