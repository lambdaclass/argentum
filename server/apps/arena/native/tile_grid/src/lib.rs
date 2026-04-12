use rustler::{Atom, NifStruct};
use std::collections::{BinaryHeap, HashMap};
use std::cmp::Ordering;
use std::sync::RwLock;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        blocked,
        north,
        south,
        east,
        west,
    }
}

/// Tile flags stored per tile.
/// 0 = walkable, 1 = blocked, 2 = water, 3 = lava, 4 = exit
///
/// All coordinates are 1-based (1..=100) to match VB6 Argentum Online.
/// Array storage is 0-based internally: index = (y-1)*WIDTH + (x-1).
const MAP_WIDTH: usize = 100;
const MAP_HEIGHT: usize = 100;
const MAP_SIZE: usize = MAP_WIDTH * MAP_HEIGHT;

static MAPS: std::sync::LazyLock<RwLock<HashMap<u16, [u8; MAP_SIZE]>>> =
    std::sync::LazyLock::new(|| RwLock::new(HashMap::new()));

#[inline]
fn idx(x: u32, y: u32) -> usize {
    (y as usize - 1) * MAP_WIDTH + (x as usize - 1)
}

#[inline]
fn valid(x: u32, y: u32) -> bool {
    x >= 1 && x <= MAP_WIDTH as u32 && y >= 1 && y <= MAP_HEIGHT as u32
}

#[derive(Debug, NifStruct)]
#[module = "TileGrid.Position"]
struct Position {
    x: u32,
    y: u32,
}

/// Load a map's tile data into memory.
/// `map_id`: unique map identifier
/// `tiles`: flat list of 10000 u8 values (100x100 grid, row-major)
#[rustler::nif]
fn load_map(map_id: u16, tiles: Vec<u8>) -> Atom {
    if tiles.len() != MAP_SIZE {
        return atoms::error();
    }

    let mut grid = [0u8; MAP_SIZE];
    grid.copy_from_slice(&tiles);

    let mut maps = MAPS.write().unwrap();
    maps.insert(map_id, grid);

    atoms::ok()
}

/// Unload a map from memory.
#[rustler::nif]
fn unload_map(map_id: u16) -> Atom {
    let mut maps = MAPS.write().unwrap();
    maps.remove(&map_id);
    atoms::ok()
}

/// Check if a tile is walkable (walkable=0 or exit=4).
/// Coordinates are 1-based (1..=100).
#[rustler::nif]
fn is_walkable(map_id: u16, x: u32, y: u32) -> bool {
    if !valid(x, y) {
        return false;
    }

    let maps = MAPS.read().unwrap();
    match maps.get(&map_id) {
        Some(grid) => {
            let v = grid[idx(x, y)];
            v == 0 || v == 4
        }
        None => false,
    }
}

/// Get the tile value at a position. Coordinates are 1-based.
#[rustler::nif]
fn get_tile(map_id: u16, x: u32, y: u32) -> u8 {
    if !valid(x, y) {
        return 1; // blocked
    }

    let maps = MAPS.read().unwrap();
    match maps.get(&map_id) {
        Some(grid) => grid[idx(x, y)],
        None => 1,
    }
}

/// Try to move one tile in a direction. Returns new position or :blocked.
/// Coordinates are 1-based (1..=100).
#[rustler::nif]
fn move_entity(map_id: u16, x: u32, y: u32, direction: Atom) -> Result<Position, Atom> {
    let (nx, ny) = if direction == atoms::north() {
        if y <= 1 { return Err(atoms::blocked()); }
        (x, y - 1)
    } else if direction == atoms::south() {
        if y >= MAP_HEIGHT as u32 { return Err(atoms::blocked()); }
        (x, y + 1)
    } else if direction == atoms::east() {
        if x >= MAP_WIDTH as u32 { return Err(atoms::blocked()); }
        (x + 1, y)
    } else if direction == atoms::west() {
        if x <= 1 { return Err(atoms::blocked()); }
        (x - 1, y)
    } else {
        return Err(atoms::blocked());
    };

    let maps = MAPS.read().unwrap();
    match maps.get(&map_id) {
        Some(grid) => {
            let v = grid[idx(nx, ny)];
            if v == 0 || v == 2 || v == 4 {
                Ok(Position { x: nx, y: ny })
            } else {
                Err(atoms::blocked())
            }
        }
        None => Err(atoms::blocked()),
    }
}

/// Check line of sight between two points using Bresenham's line algorithm.
/// Returns true if all tiles along the line are walkable (tile value 0).
/// Coordinates are 1-based.
#[rustler::nif]
fn line_of_sight(map_id: u16, x1: i32, y1: i32, x2: i32, y2: i32) -> bool {
    let maps = MAPS.read().unwrap();
    let grid = match maps.get(&map_id) {
        Some(g) => g,
        None => return false,
    };

    let dx = (x2 - x1).abs();
    let dy = -(y2 - y1).abs();
    let sx: i32 = if x1 < x2 { 1 } else { -1 };
    let sy: i32 = if y1 < y2 { 1 } else { -1 };
    let mut err = dx + dy;
    let mut cx = x1;
    let mut cy = y1;

    loop {
        if cx < 1 || cy < 1 || cx > MAP_WIDTH as i32 || cy > MAP_HEIGHT as i32 {
            return false;
        }

        if grid[(cy as usize - 1) * MAP_WIDTH + (cx as usize - 1)] != 0 {
            return false;
        }

        if cx == x2 && cy == y2 {
            return true;
        }

        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            cx += sx;
        }
        if e2 <= dx {
            err += dx;
            cy += sy;
        }
    }
}

/// A* pathfinding on the tile grid.
/// Returns a list of positions from start to end (exclusive of start, inclusive of end),
/// or an empty list if no path exists.
/// Coordinates are 1-based (1..=100).
#[rustler::nif]
fn a_star(map_id: u16, x1: u32, y1: u32, x2: u32, y2: u32) -> Vec<Position> {
    if !valid(x1, y1) || !valid(x2, y2) {
        return vec![];
    }

    let maps = MAPS.read().unwrap();
    let grid = match maps.get(&map_id) {
        Some(g) => g,
        None => return vec![],
    };

    // Check destination is walkable
    if grid[idx(x2, y2)] != 0 {
        return vec![];
    }

    let start = (x1 as usize, y1 as usize);
    let goal = (x2 as usize, y2 as usize);

    if start == goal {
        return vec![];
    }

    #[derive(Eq, PartialEq)]
    struct Node {
        cost: u32,
        pos: (usize, usize),
    }

    impl Ord for Node {
        fn cmp(&self, other: &Self) -> Ordering {
            other.cost.cmp(&self.cost) // min-heap
        }
    }

    impl PartialOrd for Node {
        fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
            Some(self.cmp(other))
        }
    }

    fn heuristic(a: (usize, usize), b: (usize, usize)) -> u32 {
        let dx = (a.0 as i32 - b.0 as i32).unsigned_abs();
        let dy = (a.1 as i32 - b.1 as i32).unsigned_abs();
        dx + dy // Manhattan distance
    }

    let mut open = BinaryHeap::new();
    let mut g_score: HashMap<(usize, usize), u32> = HashMap::new();
    let mut came_from: HashMap<(usize, usize), (usize, usize)> = HashMap::new();

    g_score.insert(start, 0);
    open.push(Node {
        cost: heuristic(start, goal),
        pos: start,
    });

    let directions: [(i32, i32); 4] = [(0, -1), (0, 1), (1, 0), (-1, 0)];

    while let Some(Node { pos, .. }) = open.pop() {
        if pos == goal {
            // Reconstruct path
            let mut path = vec![];
            let mut current = goal;
            while current != start {
                path.push(Position {
                    x: current.0 as u32,
                    y: current.1 as u32,
                });
                current = came_from[&current];
            }
            path.reverse();
            return path;
        }

        let current_g = g_score[&pos];

        for (ddx, ddy) in &directions {
            let nx = pos.0 as i32 + ddx;
            let ny = pos.1 as i32 + ddy;

            if nx < 1 || ny < 1 || nx > MAP_WIDTH as i32 || ny > MAP_HEIGHT as i32 {
                continue;
            }

            let next = (nx as usize, ny as usize);

            if grid[(next.1 - 1) * MAP_WIDTH + (next.0 - 1)] != 0 {
                continue;
            }

            let tentative_g = current_g + 1;

            if tentative_g < *g_score.get(&next).unwrap_or(&u32::MAX) {
                came_from.insert(next, pos);
                g_score.insert(next, tentative_g);
                open.push(Node {
                    cost: tentative_g + heuristic(next, goal),
                    pos: next,
                });
            }
        }
    }

    vec![] // No path found
}

rustler::init!("Elixir.TileGrid");
