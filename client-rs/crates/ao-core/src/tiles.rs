//! Tile walkability.
//!
//! Mirrors the rules the TS client applies in `GameRuntime.isTileBlocked` and
//! the server enforces through the `TileGrid` NIF plus the water check in
//! `Arena.Map.Movement`.

/// Meaning of a tile value in the blockmap.
///
/// Values come straight from the VB6 `.csm` blocked layer, so the numbers are
/// fixed by the source data rather than chosen here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TileKind {
    /// Freely walkable.
    Open,
    /// Water. Passable only while navigating (in a boat).
    Water,
    /// Walkable despite a non-zero value — VB6 uses 4 for tiles that block
    /// projectiles//sight but not movement.
    OpenSpecial,
    /// Anything else: solid.
    Blocked,
}

impl TileKind {
    pub fn from_value(value: u8) -> Self {
        match value {
            0 => TileKind::Open,
            2 => TileKind::Water,
            4 => TileKind::OpenSpecial,
            _ => TileKind::Blocked,
        }
    }
}

/// Per-entity state that affects what it may walk on.
#[derive(Debug, Clone, Copy, Default)]
pub struct TileFlags {
    /// In a boat: water becomes passable and land does not.
    pub navigating: bool,
}

/// Whether `value` may be entered by an entity with `flags`.
///
/// Out-of-bounds tiles are the caller's problem — pass the blocked value.
pub fn is_walkable(value: u8, flags: TileFlags) -> bool {
    match TileKind::from_value(value) {
        TileKind::Open | TileKind::OpenSpecial => true,
        TileKind::Water => flags.navigating,
        TileKind::Blocked => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on_foot() -> TileFlags {
        TileFlags { navigating: false }
    }

    fn sailing() -> TileFlags {
        TileFlags { navigating: true }
    }

    #[test]
    fn open_tiles_are_walkable() {
        assert!(is_walkable(0, on_foot()));
        assert!(is_walkable(0, sailing()));
    }

    #[test]
    fn value_four_is_walkable_despite_being_non_zero() {
        // The TS client special-cases this and a naive `value != 0` port would
        // wall off tiles the server happily lets you walk onto.
        assert!(is_walkable(4, on_foot()));
    }

    #[test]
    fn water_needs_a_boat() {
        assert!(!is_walkable(2, on_foot()));
        assert!(is_walkable(2, sailing()));
    }

    #[test]
    fn everything_else_is_solid() {
        for value in [1u8, 3, 5, 17, 255] {
            assert!(!is_walkable(value, on_foot()), "value {value} should block");
            assert!(!is_walkable(value, sailing()), "value {value} should block");
        }
    }
}
