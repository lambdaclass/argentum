//! Decoder for the server's client map pack (`AOMP` v1).
//!
//! Byte-for-byte port of `Arena.ClientMapPack.encode_map/1` on the server and
//! `client/src/net/mapApi.ts` in the web client. Kept here rather than in the
//! Bevy crate so it can be unit tested natively, without a wasm build.
//!
//! Layout, little-endian throughout:
//!
//! ```text
//! magic  "AOMP"            4 bytes
//! version                  u16   (1)
//! map_count                u16
//! per map:
//!   map_id                 u16
//!   name                   u16 length + that many bytes (UTF-8)
//!   width, height          u16, u16
//!   music_hi, music_low    i32, i32
//!   tiles                  width*height bytes (the blocked layer)
//!   4 x layer:             u16 count, then count * (u8 x, u8 y, i32 grh)
//!   npcs                   u16 count, then count * (u8 x, u8 y, u16 npc_id)
//!   objects                u16 count, then count * (u8 x, u8 y, u16 obj_id, u16 amount)
//!   exits                  u16 count, then count * (u8 x, u8 y, u16 map, u8 x, u8 y)
//! ```

pub const MAGIC: &[u8; 4] = b"AOMP";
pub const VERSION: u16 = 1;

#[derive(Debug, PartialEq)]
pub enum PackError {
    BadMagic([u8; 4]),
    UnsupportedVersion(u16),
    /// Ran off the end of the buffer; carries how far in we were.
    Truncated(usize),
}

impl core::fmt::Display for PackError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            PackError::BadMagic(got) => {
                write!(f, "bad magic {:?}, expected AOMP", core::str::from_utf8(got))
            }
            PackError::UnsupportedVersion(v) => write!(f, "unsupported pack version {v}"),
            PackError::Truncated(at) => write!(f, "pack truncated at byte {at}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LayerTile {
    pub x: u8,
    pub y: u8,
    pub grh: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MapNpc {
    pub x: u8,
    pub y: u8,
    pub npc_id: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MapObject {
    pub x: u8,
    pub y: u8,
    pub obj_id: u16,
    pub amount: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MapExit {
    pub x: u8,
    pub y: u8,
    pub target_map: u16,
    pub target_x: u8,
    pub target_y: u8,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PackedMap {
    pub map_id: u16,
    pub name: String,
    pub width: u16,
    pub height: u16,
    pub music_hi: i32,
    pub music_low: i32,
    /// Blocked layer, row-major, `width * height` bytes.
    pub tiles: Vec<u8>,
    /// Ground, decoration, roof-adjacent and roof layers, in that order.
    pub layers: [Vec<LayerTile>; 4],
    pub npcs: Vec<MapNpc>,
    pub objects: Vec<MapObject>,
    pub exits: Vec<MapExit>,
}

impl PackedMap {
    /// Blocked-layer value at a 1-based tile coordinate, as the game addresses
    /// tiles. Out of bounds reads as solid, matching the server.
    pub fn tile_at(&self, x: i32, y: i32) -> u8 {
        if x < 1 || y < 1 || x > self.width as i32 || y > self.height as i32 {
            return 1;
        }
        let index = (y as usize - 1) * self.width as usize + (x as usize - 1);
        self.tiles.get(index).copied().unwrap_or(1)
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], PackError> {
        let end = self.pos.checked_add(n).ok_or(PackError::Truncated(self.pos))?;
        let slice = self.bytes.get(self.pos..end).ok_or(PackError::Truncated(self.pos))?;
        self.pos = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, PackError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, PackError> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    fn i32(&mut self) -> Result<i32, PackError> {
        let b = self.take(4)?;
        Ok(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    /// Length-prefixed string. The prefix is a little-endian **u16**, not a
    /// byte: the web client's `readString8` is named for its 8-bit characters,
    /// not its length field. Reading it as a u8 desynchronises the stream
    /// immediately after the map name and every following field is garbage.
    fn string(&mut self) -> Result<String, PackError> {
        let len = self.u16()? as usize;
        let bytes = self.take(len)?;
        // Map names come from VB6 data and are not guaranteed valid UTF-8.
        // A mangled name must not fail the whole pack.
        Ok(String::from_utf8_lossy(bytes).into_owned())
    }
}

/// Decode only the map with `wanted_id`, skipping the rest.
///
/// The full pack is ~62 MB across 842 maps; materialising all of it to reach
/// one map wastes both time and memory in the browser.
pub fn decode_map(bytes: &[u8], wanted_id: u16) -> Result<Option<PackedMap>, PackError> {
    let mut r = Reader::new(bytes);
    read_header(&mut r)?;
    let count = r.u16()?;

    for _ in 0..count {
        let map = read_map(&mut r)?;
        if map.map_id == wanted_id {
            return Ok(Some(map));
        }
    }

    Ok(None)
}

/// Map ids present in the pack, without decoding their contents.
pub fn list_map_ids(bytes: &[u8]) -> Result<Vec<u16>, PackError> {
    let mut r = Reader::new(bytes);
    read_header(&mut r)?;
    let count = r.u16()?;
    let mut ids = Vec::with_capacity(count as usize);
    for _ in 0..count {
        ids.push(read_map(&mut r)?.map_id);
    }
    Ok(ids)
}

fn read_header(r: &mut Reader<'_>) -> Result<(), PackError> {
    let magic = r.take(4)?;
    if magic != MAGIC {
        let mut got = [0u8; 4];
        got.copy_from_slice(magic);
        return Err(PackError::BadMagic(got));
    }

    let version = r.u16()?;
    if version != VERSION {
        return Err(PackError::UnsupportedVersion(version));
    }

    Ok(())
}

fn read_map(r: &mut Reader<'_>) -> Result<PackedMap, PackError> {
    let map_id = r.u16()?;
    let name = r.string()?;
    let width = r.u16()?;
    let height = r.u16()?;
    let music_hi = r.i32()?;
    let music_low = r.i32()?;

    let tiles = r.take(width as usize * height as usize)?.to_vec();

    let mut layers: [Vec<LayerTile>; 4] = [Vec::new(), Vec::new(), Vec::new(), Vec::new()];
    for layer in layers.iter_mut() {
        let count = r.u16()?;
        layer.reserve(count as usize);
        for _ in 0..count {
            layer.push(LayerTile { x: r.u8()?, y: r.u8()?, grh: r.i32()? });
        }
    }

    let npc_count = r.u16()?;
    let mut npcs = Vec::with_capacity(npc_count as usize);
    for _ in 0..npc_count {
        npcs.push(MapNpc { x: r.u8()?, y: r.u8()?, npc_id: r.u16()? });
    }

    let object_count = r.u16()?;
    let mut objects = Vec::with_capacity(object_count as usize);
    for _ in 0..object_count {
        objects.push(MapObject {
            x: r.u8()?,
            y: r.u8()?,
            obj_id: r.u16()?,
            amount: r.u16()?,
        });
    }

    let exit_count = r.u16()?;
    let mut exits = Vec::with_capacity(exit_count as usize);
    for _ in 0..exit_count {
        exits.push(MapExit {
            x: r.u8()?,
            y: r.u8()?,
            target_map: r.u16()?,
            target_x: r.u8()?,
            target_y: r.u8()?,
        });
    }

    Ok(PackedMap {
        map_id,
        name,
        width,
        height,
        music_hi,
        music_low,
        tiles,
        layers,
        npcs,
        objects,
        exits,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a one-map pack matching the server's encoder.
    fn sample_pack() -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(MAGIC);
        b.extend_from_slice(&VERSION.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes()); // map count

        b.extend_from_slice(&7u16.to_le_bytes()); // map_id
        let name = "Ullathorpe";
        b.extend_from_slice(&(name.len() as u16).to_le_bytes());
        b.extend_from_slice(name.as_bytes());
        b.extend_from_slice(&2u16.to_le_bytes()); // width
        b.extend_from_slice(&2u16.to_le_bytes()); // height
        b.extend_from_slice(&0i32.to_le_bytes()); // music_hi
        b.extend_from_slice(&3i32.to_le_bytes()); // music_low
        b.extend_from_slice(&[0, 1, 2, 0]); // tiles

        // layer 1 has one tile, layers 2..4 empty
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&[1, 2]);
        b.extend_from_slice(&4242i32.to_le_bytes());
        for _ in 0..3 {
            b.extend_from_slice(&0u16.to_le_bytes());
        }

        b.extend_from_slice(&1u16.to_le_bytes()); // npcs
        b.extend_from_slice(&[3, 4]);
        b.extend_from_slice(&406u16.to_le_bytes());

        b.extend_from_slice(&1u16.to_le_bytes()); // objects
        b.extend_from_slice(&[5, 6]);
        b.extend_from_slice(&11u16.to_le_bytes());
        b.extend_from_slice(&99u16.to_le_bytes());

        b.extend_from_slice(&1u16.to_le_bytes()); // exits
        b.extend_from_slice(&[7, 8]);
        b.extend_from_slice(&34u16.to_le_bytes());
        b.extend_from_slice(&[9, 10]);

        b
    }

    #[test]
    fn decodes_a_map() {
        let map = decode_map(&sample_pack(), 7).unwrap().expect("map 7 present");
        assert_eq!(map.map_id, 7);
        assert_eq!(map.name, "Ullathorpe");
        assert_eq!((map.width, map.height), (2, 2));
        assert_eq!(map.music_low, 3);
        assert_eq!(map.tiles, vec![0, 1, 2, 0]);
        assert_eq!(map.layers[0], vec![LayerTile { x: 1, y: 2, grh: 4242 }]);
        assert!(map.layers[1].is_empty());
        assert_eq!(map.npcs, vec![MapNpc { x: 3, y: 4, npc_id: 406 }]);
        assert_eq!(map.objects, vec![MapObject { x: 5, y: 6, obj_id: 11, amount: 99 }]);
        assert_eq!(
            map.exits,
            vec![MapExit { x: 7, y: 8, target_map: 34, target_x: 9, target_y: 10 }]
        );
    }

    #[test]
    fn tile_lookup_is_one_based_and_clamps() {
        let map = decode_map(&sample_pack(), 7).unwrap().unwrap();
        assert_eq!(map.tile_at(1, 1), 0);
        assert_eq!(map.tile_at(2, 1), 1);
        assert_eq!(map.tile_at(1, 2), 2);
        // Out of bounds must read solid, never panic.
        assert_eq!(map.tile_at(0, 1), 1);
        assert_eq!(map.tile_at(3, 1), 1);
        assert_eq!(map.tile_at(1, 99), 1);
    }

    #[test]
    fn map_name_uses_a_u16_length_prefix() {
        // Regression: this was implemented as a u8 length, which desynced the
        // whole pack after the first map name and produced either nonsense or
        // a truncation error far from the real cause.
        let pack = sample_pack();
        let name_len_offset = 4 + 2 + 2 + 2; // magic, version, count, map_id
        assert_eq!(
            u16::from_le_bytes([pack[name_len_offset], pack[name_len_offset + 1]]),
            "Ullathorpe".len() as u16
        );
        assert_eq!(decode_map(&pack, 7).unwrap().unwrap().name, "Ullathorpe");
    }

    #[test]
    fn missing_map_is_none_not_an_error() {
        assert_eq!(decode_map(&sample_pack(), 999).unwrap(), None);
    }

    #[test]
    fn lists_ids_without_decoding_contents() {
        assert_eq!(list_map_ids(&sample_pack()).unwrap(), vec![7]);
    }

    #[test]
    fn rejects_a_foreign_file() {
        let err = decode_map(b"NOPEnot a pack at all", 1).unwrap_err();
        assert!(matches!(err, PackError::BadMagic(_)));
    }

    #[test]
    fn rejects_a_future_version() {
        let mut b = Vec::from(*MAGIC);
        b.extend_from_slice(&99u16.to_le_bytes());
        assert_eq!(decode_map(&b, 1), Err(PackError::UnsupportedVersion(99)));
    }

    #[test]
    fn truncation_is_reported_not_panicked() {
        let full = sample_pack();
        // Every prefix must fail cleanly rather than panic on a bad index.
        for cut in 0..full.len() {
            let _ = decode_map(&full[..cut], 7);
        }
    }
}
