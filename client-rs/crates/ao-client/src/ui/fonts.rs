//! The interface font.
//!
//! Bevy's built-in font is a subset covering little more than ASCII. The game's
//! first language is Spanish, so `año`, `¿` and every accented item name
//! rendered as empty boxes — as did the em dash, middle dot and multiplication
//! sign the interface uses as separators. Those boxes are not a styling
//! problem: they are text the player cannot read.
//!
//! The face is the one this repository already ships and the existing BabelUI
//! client already renders with, so the two clients stay consistent and no new
//! third-party asset is introduced. See `assets/fonts/PROVENANCE.md`.

use bevy::prelude::*;
use bevy::text::Font;

/// Embedded rather than fetched.
///
/// A font arriving over the network leaves the first frames unreadable, and the
/// boot screen is exactly when a player is most likely to be told something
/// important. 388 KB against a ~19 MB payload is not worth deferring.
const FONT_BYTES: &[u8] = include_bytes!("../../../../assets/fonts/alegreya-sans-ao.ttf");

pub struct FontPlugin;

impl Plugin for FontPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(PreStartup, install_default_font);
    }
}

/// Replace the built-in default font.
///
/// Overriding the asset behind `Handle::<Font>::default()` rather than
/// threading a handle through every control: `TextFont::default()` points at
/// that handle, so a single insert covers every piece of text in the client
/// including any added later. Passing a handle around instead guarantees that
/// one label somewhere is eventually built without it and silently renders in a
/// font that cannot spell the language.
fn install_default_font(mut fonts: ResMut<Assets<Font>>) {
    match Font::try_from_bytes(FONT_BYTES.to_vec()) {
        Ok(font) => {
            fonts.insert(&Handle::<Font>::default(), font);
        }
        Err(error) => {
            // Not fatal: the built-in font still renders ASCII, which is enough
            // to read an error message and file a report.
            error!("interface font failed to load, falling back to ASCII-only: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_font_parses() {
        // A truncated or wrong-format file would otherwise show up as boxes at
        // runtime, which is indistinguishable from having no font at all.
        assert!(Font::try_from_bytes(FONT_BYTES.to_vec()).is_ok());
    }

    #[test]
    fn the_embedded_font_is_a_plausible_size() {
        // Guards against a stray empty file or a git-lfs pointer being
        // embedded instead of the font.
        assert!(FONT_BYTES.len() > 100_000, "only {} bytes", FONT_BYTES.len());
        assert!(FONT_BYTES.len() < 2_000_000, "{} bytes is too large to embed", FONT_BYTES.len());
    }

    #[test]
    fn the_embedded_font_covers_the_language_the_game_is_written_in() {
        // The reason it is here. Checked against the file's own character map
        // rather than by rendering, so a font swap that drops coverage fails
        // here instead of in a screenshot.
        let coverage = super::tests::mapped_characters();
        for (name, ch) in [
            ("n-tilde", 'ñ'),
            ("a-acute", 'á'),
            ("i-acute", 'í'),
            ("inverted question", '¿'),
            ("inverted exclamation", '¡'),
            ("em dash", '—'),
            ("middle dot", '·'),
            ("multiplication sign", '×'),
        ] {
            assert!(coverage.contains(&(ch as u32)), "the font has no {name} ({ch:?})");
        }
    }

    /// Characters the embedded font's BMP character map covers.
    ///
    /// Parsed directly from the `cmap` table: a format 4 subtable is a list of
    /// segment ranges, which is all this needs.
    fn mapped_characters() -> Vec<u32> {
        let data = FONT_BYTES;
        let read_u16 = |at: usize| u16::from_be_bytes([data[at], data[at + 1]]) as usize;
        let read_u32 =
            |at: usize| u32::from_be_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]);

        let table_count = read_u16(4);
        let mut cmap = None;
        for index in 0..table_count {
            let record = 12 + index * 16;
            if &data[record..record + 4] == b"cmap" {
                cmap = Some(read_u32(record + 8) as usize);
            }
        }
        let cmap = cmap.expect("the font has a character map");

        let subtable_count = read_u16(cmap + 2);
        let mut format4 = None;
        for index in 0..subtable_count {
            let record = cmap + 4 + index * 8;
            let offset = cmap + read_u32(record + 4) as usize;
            if read_u16(offset) == 4 {
                format4 = Some(offset);
                break;
            }
        }
        let table = format4.expect("the font has a format 4 subtable");

        let segments = read_u16(table + 6) / 2;
        let ends = table + 14;
        let starts = ends + segments * 2 + 2;

        let mut characters = Vec::new();
        for segment in 0..segments {
            let end = read_u16(ends + segment * 2);
            let start = read_u16(starts + segment * 2);
            if end == 0xFFFF {
                continue;
            }
            characters.extend((start as u32)..=(end as u32));
        }
        characters
    }
}
