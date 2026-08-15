//! World view: camera, a placeholder tile grid, and held-key movement driven by
//! the shared `ao-core` walk gate.

use crate::graphics::{make_image, Graphics, Heading, SheetTextures};
use crate::net::{DEFAULT_BODY, DEFAULT_HEAD};
use crate::net::{start_graphics_load, LoadState, MapLoader};
use ao_core::{is_walkable, TileFlags, WalkGate, WalkGateConfig, WalkOutcome};
use bevy::prelude::*;
use bevy::sprite::Anchor;
use std::collections::{HashMap, HashSet};

pub const TILE_SIZE: f32 = 32.0;
const MAP_WIDTH: i32 = 100;
const MAP_HEIGHT: i32 = 100;

/// How far the camera can see, in tiles. Only this window is spawned; a full
/// 100x100 map of individual sprites is 10,000 entities for no benefit.
const VIEW_RADIUS_X: i32 = 22;
const VIEW_RADIUS_Y: i32 = 15;

pub struct WorldPlugin;

impl Plugin for WorldPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(ClearColor(Color::srgb(0.04, 0.05, 0.08)))
            .insert_resource(Blockmap::demo())
            .insert_resource(LocalPlayer::default())
            .insert_resource(Walk::default())
            .insert_resource(MapLoader::default())
            .insert_resource(Graphics::default())
            .insert_resource(SheetTextures::default())
            .insert_resource(LoadedMap(None))
            .insert_resource(MapLoadReported(false))
            .insert_resource(DrawnTiles::default())
            .insert_resource(CharacterDrawn(false))
            .insert_resource(SheetAtlases::default())
            .add_systems(Startup, (setup, start_map_load))
            .add_systems(
                Update,
                (
                    apply_loaded_map,
                    upload_sheets,
                    paint_scene,
                    paint_character,
                    handle_input,
                    follow_camera,
                )
                    .chain(),
            );
    }
}

/// Static collision data. Replaced by the server's map pack once networking
/// lands; the shape is what matters here.
#[derive(Resource)]
pub struct Blockmap {
    width: i32,
    height: i32,
    values: Vec<u8>,
}

impl Blockmap {
    fn demo() -> Self {
        let mut values = vec![0u8; (MAP_WIDTH * MAP_HEIGHT) as usize];
        // A ring of solid tiles so collision is visible before real maps load.
        for x in 1..=MAP_WIDTH {
            for y in 1..=MAP_HEIGHT {
                let edge = x == 1 || y == 1 || x == MAP_WIDTH || y == MAP_HEIGHT;
                let wall = x % 17 == 0 && y % 13 != 0;
                if edge || wall {
                    values[((y - 1) * MAP_WIDTH + (x - 1)) as usize] = 1;
                }
            }
        }
        Self { width: MAP_WIDTH, height: MAP_HEIGHT, values }
    }

    /// Build from a decoded server map. Pack coordinates are 1-based.
    pub fn from_packed(map: &ao_core::PackedMap) -> Self {
        Self {
            width: map.width as i32,
            height: map.height as i32,
            values: map.tiles.clone(),
        }
    }

    /// Tile value at a **1-based** coordinate, as the game and the map pack
    /// both address tiles. Out of bounds reads as solid, matching the server.
    pub fn value_at(&self, x: i32, y: i32) -> u8 {
        if x < 1 || y < 1 || x > self.width || y > self.height {
            return 1;
        }
        self.values
            .get(((y - 1) * self.width + (x - 1)) as usize)
            .copied()
            .unwrap_or(1)
    }
}

#[derive(Resource)]
pub struct LocalPlayer {
    pub x: i32,
    pub y: i32,
    pub speed: f64,
    pub navigating: bool,
}

impl Default for LocalPlayer {
    fn default() -> Self {
        Self { x: 50, y: 50, speed: 1.0, navigating: false }
    }
}

/// Wraps the shared walk gate so the client refuses steps the server would
/// reject rather than sending them and being snapped back.
#[derive(Resource)]
pub struct Walk {
    gate: WalkGate,
}

impl Default for Walk {
    fn default() -> Self {
        Self { gate: WalkGate::new(WalkGateConfig::default()) }
    }
}

#[derive(Component)]
struct PlayerSprite;

#[derive(Component)]
struct TileSprite;

fn setup(mut commands: Commands, player: Res<LocalPlayer>, blockmap: Res<Blockmap>) {
    // Place the camera on the player immediately. Leaving it at the origin for
    // frame 0 shows an empty grey viewport, which is indistinguishable from a
    // renderer failure while debugging.
    commands.spawn((
        Camera2d,
        Transform::from_xyz(
            (player.x - 1) as f32 * TILE_SIZE,
            -((player.y - 1) as f32) * TILE_SIZE,
            0.0,
        ),
    ));

    spawn_tile_window(&mut commands, &player, &blockmap);

    commands.spawn((
        Sprite::from_color(
            Color::srgb(0.95, 0.85, 0.55),
            Vec2::new(TILE_SIZE * 0.7, TILE_SIZE * 0.9),
        ),
        Transform::from_xyz(
            (player.x - 1) as f32 * TILE_SIZE,
            -((player.y - 1) as f32) * TILE_SIZE,
            10.0,
        ),
        PlayerSprite,
    ));
}

fn handle_input(
    keys: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
    blockmap: Res<Blockmap>,
    mut player: ResMut<LocalPlayer>,
    mut walk: ResMut<Walk>,
    mut sprites: Query<&mut Transform, With<PlayerSprite>>,
) {
    // Held keys drive movement from the frame loop, never from key auto-repeat.
    // The web client originally stepped at the OS repeat rate, which meant a
    // ~500ms stall on a default Linux desktop before the second step.
    let direction = if keys.pressed(KeyCode::ArrowUp) || keys.pressed(KeyCode::KeyW) {
        Some((0, -1))
    } else if keys.pressed(KeyCode::ArrowDown) || keys.pressed(KeyCode::KeyS) {
        Some((0, 1))
    } else if keys.pressed(KeyCode::ArrowLeft) || keys.pressed(KeyCode::KeyA) {
        Some((-1, 0))
    } else if keys.pressed(KeyCode::ArrowRight) || keys.pressed(KeyCode::KeyD) {
        Some((1, 0))
    } else {
        None
    };

    let Some((dx, dy)) = direction else { return };

    let now_ms = time.elapsed_secs_f64() * 1000.0;
    match walk.gate.evaluate(now_ms, player.speed) {
        // Silently ignored by the server; nothing to do and no correction comes.
        WalkOutcome::TooEarly => return,
        // Sending this would earn a snap-back. Declining costs a few ms.
        WalkOutcome::SpeedHack => return,
        WalkOutcome::Allowed => {}
    }

    let (nx, ny) = (player.x + dx, player.y + dy);
    let flags = TileFlags { navigating: player.navigating };
    if !is_walkable(blockmap.value_at(nx, ny), flags) {
        return;
    }

    // Only commit to the gate once the step is genuinely taken, so blocked
    // attempts do not consume the cooldown.
    if walk.gate.try_step(now_ms, player.speed) != WalkOutcome::Allowed {
        return;
    }

    player.x = nx;
    player.y = ny;

    for mut transform in &mut sprites {
        transform.translation.x = (player.x - 1) as f32 * TILE_SIZE;
        transform.translation.y = -((player.y - 1) as f32) * TILE_SIZE;
    }
}

fn follow_camera(
    player: Res<LocalPlayer>,
    mut cameras: Query<&mut Transform, (With<Camera2d>, Without<PlayerSprite>)>,
) {
    for mut transform in &mut cameras {
        transform.translation.x = (player.x - 1) as f32 * TILE_SIZE;
        transform.translation.y = -((player.y - 1) as f32) * TILE_SIZE;
    }
}


/// Tracks whether the current load state has been logged, so polling does not
/// spam the console every frame.
#[derive(Resource)]
struct MapLoadReported(bool);

/// The decoded map, retained so the scene can be drawn once sheets arrive.
#[derive(Resource)]
struct LoadedMap(Option<Box<ao_core::PackedMap>>);

/// Tiles already spawned, keyed by (layer, x, y).
///
/// Sheets stream in one at a time, so painting is incremental: each pass draws
/// whatever has become drawable and records it. Painting once on the first
/// sheet drew only that sheet's tiles and left the rest of the map black, and
/// which sheet won the race varied per load.
#[derive(Resource, Default)]
struct DrawnTiles(HashSet<(usize, u8, u8)>);

/// Atlas layout per sheet, plus the index assigned to each region in it.
#[derive(Resource, Default)]
struct SheetAtlases {
    layouts: HashMap<u32, Handle<TextureAtlasLayout>>,
    indices: HashMap<(u32, URect), usize>,
}

/// Tiles drawn from the real graphics, as opposed to the placeholder grid.
#[derive(Component)]
struct SceneTile;

/// Whether the player's body and head sprites have replaced the placeholder.
#[derive(Resource)]
struct CharacterDrawn(bool);

#[derive(Component)]
struct CharacterPart;

/// Origin the world data is fetched from.
///
/// The page is served separately from the game server during development, so
/// this cannot be inferred from `window.location`.
const SERVER_ORIGIN: &str = "http://127.0.0.1:4000";

/// Map loaded on boot. 1 is the newbie start map.
const INITIAL_MAP: u16 = 1;

fn start_map_load(loader: Res<MapLoader>) {
    info!("fetching map {INITIAL_MAP} from {SERVER_ORIGIN}");
    loader.start(SERVER_ORIGIN.to_string(), INITIAL_MAP);
}

/// Swap the demo grid for the real map once it arrives.
#[allow(clippy::too_many_arguments)]
fn apply_loaded_map(
    loader: Res<MapLoader>,
    graphics: Res<Graphics>,
    mut reported: ResMut<MapLoadReported>,
    mut blockmap: ResMut<Blockmap>,
    mut loaded: ResMut<LoadedMap>,
    mut commands: Commands,
    tiles: Query<Entity, With<TileSprite>>,
    player: Res<LocalPlayer>,
) {
    match loader.state() {
        LoadState::Ready(map) => {
            if reported.0 {
                return;
            }
            reported.0 = true;

            info!(
                "map {} \"{}\" {}x{} loaded: {} ground tiles, {} npcs, {} objects",
                map.map_id,
                map.name,
                map.width,
                map.height,
                map.layers[0].len(),
                map.npcs.len(),
                map.objects.len()
            );

            *blockmap = Blockmap::from_packed(&map);

            // Placeholder grid goes away; real tiles replace it once sheets land.
            for entity in &tiles {
                commands.entity(entity).despawn();
            }

            // Only the visible window's graphics are fetched. Requesting every
            // grh on a 100x100 map would pull far more sheet data than can be
            // shown at once.
            let mut wanted = Vec::new();
            for layer in &map.layers {
                for tile in layer {
                    let (x, y) = (tile.x as i32, tile.y as i32);
                    if (x - player.x).abs() <= VIEW_RADIUS_X + 2
                        && (y - player.y).abs() <= VIEW_RADIUS_Y + 2
                    {
                        wanted.push(tile.grh);
                    }
                }
            }
            wanted.sort_unstable();
            wanted.dedup();
            info!("requesting graphics for {} distinct grh ids", wanted.len());
            start_graphics_load(graphics.clone(), SERVER_ORIGIN.to_string(), wanted);

            loaded.0 = Some(map);
        }
        LoadState::Failed(message) => {
            if !reported.0 {
                reported.0 = true;
                error!("map load failed: {message} — keeping the generated map");
            }
        }
        LoadState::Fetching(_) | LoadState::Idle => {}
    }
}


/// Spawn the tiles around the player. Only the visible window is created; a
/// full 100x100 map would be 10,000 entities for no visual gain.
fn spawn_tile_window(commands: &mut Commands, player: &LocalPlayer, blockmap: &Blockmap) {
    for dy in -VIEW_RADIUS_Y..=VIEW_RADIUS_Y {
        for dx in -VIEW_RADIUS_X..=VIEW_RADIUS_X {
            let (x, y) = (player.x + dx, player.y + dy);
            let value = blockmap.value_at(x, y);
            let color = match ao_core::TileKind::from_value(value) {
                ao_core::TileKind::Open | ao_core::TileKind::OpenSpecial => {
                    Color::srgb(0.10, 0.22, 0.12)
                }
                ao_core::TileKind::Water => Color::srgb(0.09, 0.20, 0.38),
                ao_core::TileKind::Blocked => Color::srgb(0.18, 0.15, 0.13),
            };

            commands.spawn((
                // from_color, not `Sprite { color, .. }`: a bare Sprite keeps
                // `image: Handle::default()`, which is not a valid texture, and
                // the quad silently never draws.
                Sprite::from_color(color, Vec2::splat(TILE_SIZE - 1.0)),
                Transform::from_xyz(x as f32 * TILE_SIZE, -(y as f32) * TILE_SIZE, 0.0),
                TileSprite,
            ));
        }
    }
}


/// Move decoded sheets onto the GPU as they arrive.
fn upload_sheets(
    graphics: Res<Graphics>,
    mut images: ResMut<Assets<Image>>,
    mut sheets: ResMut<SheetTextures>,
) {
    for (file, width, height, rgba) in graphics.take_pending_sheets() {
        let handle = images.add(make_image(width, height, rgba));
        sheets.0.insert(file, handle);
    }
}

/// Draw whatever is currently drawable, incrementally.
///
/// Runs every frame but does almost nothing once the map is fully painted: the
/// only per-frame cost is a lookup per visible tile against the drawn set.
#[allow(clippy::too_many_arguments)]
fn paint_scene(
    graphics: Res<Graphics>,
    sheets: Res<SheetTextures>,
    loaded: Res<LoadedMap>,
    player: Res<LocalPlayer>,
    mut atlases: ResMut<SheetAtlases>,
    mut layouts: ResMut<Assets<TextureAtlasLayout>>,
    mut drawn: ResMut<DrawnTiles>,
    mut commands: Commands,
) {
    if sheets.0.is_empty() {
        return;
    }
    let (Some(index), Some(map)) = (graphics.index(), loaded.0.as_ref()) else {
        return;
    };

    let mut painted = 0usize;

    for (depth, layer) in map.layers.iter().enumerate() {
        for tile in layer {
            let key = (depth, tile.x, tile.y);
            if drawn.0.contains(&key) {
                continue;
            }

            let (x, y) = (tile.x as i32, tile.y as i32);
            if (x - player.x).abs() > VIEW_RADIUS_X || (y - player.y).abs() > VIEW_RADIUS_Y {
                continue;
            }

            let Some(grh) = index.resolve(tile.grh) else {
                // Unknown grh will never become drawable; stop reconsidering it.
                drawn.0.insert(key);
                continue;
            };
            // Sheet may simply not have arrived yet — leave it for a later pass.
            let Some(image) = sheets.0.get(&grh.file) else {
                continue;
            };

            let rect = URect::new(
                grh.x as u32,
                grh.y as u32,
                (grh.x + grh.width) as u32,
                (grh.y + grh.height) as u32,
            );

            let layout_handle = atlases
                .layouts
                .entry(grh.file)
                .or_insert_with(|| layouts.add(TextureAtlasLayout::new_empty(UVec2::splat(1024))))
                .clone();

            let atlas_index = match atlases.indices.get(&(grh.file, rect)) {
                Some(index) => *index,
                None => {
                    let Some(layout) = layouts.get_mut(&layout_handle) else {
                        continue;
                    };
                    let index = layout.add_texture(rect);
                    atlases.indices.insert((grh.file, rect), index);
                    index
                }
            };

            let size = Vec2::new(grh.width, grh.height);
            commands.spawn((
                Sprite {
                    image: image.clone(),
                    texture_atlas: Some(TextureAtlas {
                        layout: layout_handle,
                        index: atlas_index,
                    }),
                    custom_size: Some(size),
                    ..default()
                },
                // Tall art (trees, buildings) hangs above and left of its tile,
                // so the tile marks the sprite's bottom centre rather than its
                // middle. This is applyAoAnchor from the web client, converted
                // between coordinate systems: Pixi anchors run 0..1 from the
                // top-left with y down, Bevy's run -0.5..0.5 from the centre
                // with y up, so x shifts by half and y both flips and shifts.
                Anchor(Vec2::new(
                    (size.x - TILE_SIZE) / (2.0 * size.x) - 0.5,
                    0.5 - (size.y - TILE_SIZE) / size.y,
                )),
                // Tiles are addressed from 1, so tile (1,1) sits at the origin.
                Transform::from_xyz(
                    (x - 1) as f32 * TILE_SIZE,
                    -((y - 1) as f32) * TILE_SIZE,
                    depth as f32 * 0.1,
                ),
                SceneTile,
            ));

            drawn.0.insert(key);
            painted += 1;
        }
    }

    if painted > 0 {
        info!("painted {painted} more tiles ({} total)", drawn.0.len());
    }
}


/// Replace the placeholder box with the real body and head artwork.
///
/// Bodies carry `offHead`, the point the head is drawn at, so the two sprites
/// are separate rather than one composed image — which is also what makes
/// equipment and head swaps possible later.
#[allow(clippy::too_many_arguments)]
fn paint_character(
    graphics: Res<Graphics>,
    sheets: Res<SheetTextures>,
    player: Res<LocalPlayer>,
    mut atlases: ResMut<SheetAtlases>,
    mut layouts: ResMut<Assets<TextureAtlasLayout>>,
    mut done: ResMut<CharacterDrawn>,
    placeholder: Query<Entity, With<PlayerSprite>>,
    mut commands: Commands,
) {
    if done.0 {
        return;
    }
    let (Some(index), Some(bodies), Some(heads)) =
        (graphics.index(), graphics.bodies(), graphics.heads())
    else {
        return;
    };
    let (Some(body), Some(head)) = (bodies.get(&DEFAULT_BODY), heads.get(&DEFAULT_HEAD)) else {
        return;
    };

    let heading = Heading::South;
    let Some(body_grh) = index.resolve(body.for_heading(heading)) else {
        return;
    };
    let Some(head_grh) = index.resolve(head.for_heading(heading)) else {
        return;
    };
    // Both halves need their sheets before drawing, or the character appears
    // headless for a frame or two.
    if !sheets.0.contains_key(&body_grh.file) || !sheets.0.contains_key(&head_grh.file) {
        return;
    }

    for entity in &placeholder {
        commands.entity(entity).despawn();
    }

    let base = Vec2::new(
        (player.x - 1) as f32 * TILE_SIZE,
        -((player.y - 1) as f32) * TILE_SIZE,
    );

    for (grh, offset, z) in [
        (body_grh, Vec2::ZERO, 10.0f32),
        (head_grh, body.head_offset, 10.1f32),
    ] {
        let rect = URect::new(
            grh.x as u32,
            grh.y as u32,
            (grh.x + grh.width) as u32,
            (grh.y + grh.height) as u32,
        );
        let layout_handle = atlases
            .layouts
            .entry(grh.file)
            .or_insert_with(|| layouts.add(TextureAtlasLayout::new_empty(UVec2::splat(1024))))
            .clone();
        let atlas_index = match atlases.indices.get(&(grh.file, rect)) {
            Some(index) => *index,
            None => {
                let Some(layout) = layouts.get_mut(&layout_handle) else {
                    return;
                };
                let index = layout.add_texture(rect);
                atlases.indices.insert((grh.file, rect), index);
                index
            }
        };

        let size = Vec2::new(grh.width, grh.height);
        commands.spawn((
            Sprite {
                image: sheets.0[&grh.file].clone(),
                texture_atlas: Some(TextureAtlas { layout: layout_handle, index: atlas_index }),
                custom_size: Some(size),
                ..default()
            },
            Anchor(Vec2::new(
                (size.x - TILE_SIZE) / (2.0 * size.x) - 0.5,
                0.5 - (size.y - TILE_SIZE) / size.y,
            )),
            Transform::from_xyz(base.x + offset.x, base.y - offset.y, z),
            PlayerSprite,
            CharacterPart,
        ));
    }

    done.0 = true;
    info!("character drawn: body {DEFAULT_BODY}, head {DEFAULT_HEAD}");
}
