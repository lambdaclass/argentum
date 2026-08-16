//! World view: camera, a placeholder tile grid, and held-key movement driven by
//! the shared `ao-core` walk gate.

use crate::config::ClientConfig;
use crate::graphics::{make_image, Graphics, Heading, SheetTextures};
use crate::net::{start_graphics_load, LoadState, MapLoader};
use crate::net::{DEFAULT_BODY, DEFAULT_HEAD};
use crate::session::{ConnectionState, Session};
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

/// Where the client is in its own startup, as distinct from where the
/// connection is.
///
/// The two are deliberately separate. The world is playable before — and
/// without — a session: map data comes over HTTP, and a client that failed to
/// log in still renders and walks locally. Gating gameplay on the socket would
/// make a login problem look like a dead renderer, which is the confusion this
/// state machine exists to prevent. Connection state lives in `Session` and is
/// surfaced in the status row.
///
/// `Authenticate`, `SelectCharacter`, `Handoff` and `Reconnecting` from the
/// roadmap are not here yet: none of them has a transition to make until real
/// login exists, and a state nothing enters is not a state machine, it is a
/// comment that can go stale.
#[derive(States, Default, Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AppState {
    /// Before the first frame has run. Capability probing will go here.
    #[default]
    Boot,
    /// Map requested, not yet applied. The placeholder grid is on screen.
    LoadingWorld,
    /// A world exists — real or placeholder — and input is accepted.
    Playing,
}

pub struct WorldPlugin;

impl Plugin for WorldPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(ClearColor(Color::srgb(0.04, 0.05, 0.08)))
            .insert_resource(Blockmap::demo())
            .insert_resource(LocalPlayer::default())
            .insert_resource(Walk::default())
            .insert_resource(HeldDirections::default())
            .insert_resource(MapLoader::default())
            .insert_resource(Graphics::default())
            .insert_resource(SheetTextures::default())
            .insert_resource(LoadedMap(None))
            .insert_resource(MapLoadTimeout::default())
            .insert_resource(DrawnTiles::default())
            .insert_resource(CharacterDrawn(false))
            .insert_resource(DrawnEntities::default())
            .insert_resource(SceneDirty::default())
            .insert_resource(Motion::default())
            .insert_resource(Session::default())
            .insert_resource(SheetAtlases::default())
            .init_state::<AppState>()
            .add_systems(Startup, (setup, start_map_load, connect_to_server))
            .add_systems(Update, leave_boot.run_if(in_state(AppState::Boot)))
            // Runs only while a load is outstanding, which is what makes the
            // apply-once behaviour structural. It was previously a `reported`
            // boolean that also served as the log-once guard, so the two
            // concerns could not be changed independently.
            .add_systems(Update, apply_loaded_map.run_if(in_state(AppState::LoadingWorld)))
            .add_systems(
                Update,
                (
                    upload_sheets,
                    paint_scene,
                    paint_entities,
                    paint_character,
                    apply_server_messages,
                    handle_input,
                    animate_character,
                    follow_camera,
                )
                    .chain()
                    .run_if(in_state(AppState::Playing)),
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
        Self { width: map.width as i32, height: map.height as i32, values: map.tiles.clone() }
    }

    /// Tile value at a **1-based** coordinate, as the game and the map pack
    /// both address tiles. Out of bounds reads as solid, matching the server.
    pub fn value_at(&self, x: i32, y: i32) -> u8 {
        if x < 1 || y < 1 || x > self.width || y > self.height {
            return 1;
        }
        self.values.get(((y - 1) * self.width + (x - 1)) as usize).copied().unwrap_or(1)
    }
}

#[derive(Resource)]
pub struct LocalPlayer {
    pub x: i32,
    pub y: i32,
    pub speed: f64,
    pub navigating: bool,
    pub heading: Heading,
}

impl Default for LocalPlayer {
    fn default() -> Self {
        Self { x: 50, y: 50, speed: 1.0, navigating: false, heading: Heading::South }
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

/// Which keys mean which direction. Two keys per direction, and either one
/// holds it: releasing the arrow while W is still down keeps you walking north.
const DIRECTION_KEYS: [(Heading, [KeyCode; 2]); 4] = [
    (Heading::North, [KeyCode::ArrowUp, KeyCode::KeyW]),
    (Heading::South, [KeyCode::ArrowDown, KeyCode::KeyS]),
    (Heading::West, [KeyCode::ArrowLeft, KeyCode::KeyA]),
    (Heading::East, [KeyCode::ArrowRight, KeyCode::KeyD]),
];

/// Direction keys currently held, most recently pressed first.
///
/// Movement follows the newest key, not a fixed priority. This used to be an
/// if/else chain in key order, which meant north always beat west: holding up
/// and then pressing left kept you walking up until you let go of up. Every
/// change of direction needed a release first, so turning a corner at speed
/// dropped a step.
///
/// Keeping the whole held set, rather than just the latest key, is what makes
/// the release case work too — let go of left while still holding up and you
/// resume north immediately, with no second press.
#[derive(Resource, Default)]
struct HeldDirections(Vec<Heading>);

impl HeldDirections {
    /// Read the keyboard and reorder.
    ///
    /// A newly pressed key goes to the front even if it was already held under
    /// another binding, so the most recent intent always wins.
    fn update(&mut self, keys: &ButtonInput<KeyCode>) {
        for (heading, codes) in DIRECTION_KEYS {
            let held = codes.iter().any(|code| keys.pressed(*code));
            if codes.iter().any(|code| keys.just_pressed(*code)) {
                self.press(heading);
            } else if !held {
                self.release(heading);
            }
        }
    }

    fn press(&mut self, heading: Heading) {
        self.0.retain(|held| *held != heading);
        self.0.insert(0, heading);
    }

    fn release(&mut self, heading: Heading) {
        self.0.retain(|held| *held != heading);
    }

    /// The direction to walk: the newest key still held, if any.
    fn current(&self) -> Option<Heading> {
        self.0.first().copied()
    }
}

/// Tile step for a heading, in map coordinates. Y grows southward.
fn heading_delta(heading: Heading) -> (i32, i32) {
    match heading {
        Heading::North => (0, -1),
        Heading::South => (0, 1),
        Heading::West => (-1, 0),
        Heading::East => (1, 0),
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

#[allow(clippy::too_many_arguments)]
fn handle_input(
    keys: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
    blockmap: Res<Blockmap>,
    mut player: ResMut<LocalPlayer>,
    mut walk: ResMut<Walk>,
    mut character: ResMut<CharacterDrawn>,
    mut scene: ResMut<SceneDirty>,
    mut motion: ResMut<Motion>,
    mut held: ResMut<HeldDirections>,
    session: Res<Session>,
) {
    // Held keys drive movement from the frame loop, never from key auto-repeat.
    // The web client originally stepped at the OS repeat rate, which meant a
    // ~500ms stall on a default Linux desktop before the second step.
    held.update(&keys);

    // Newest key wins, so a new direction takes effect on the next step rather
    // than waiting for the previous key to be released.
    let Some(facing) = held.current() else { return };
    let (dx, dy) = heading_delta(facing);

    // Face the way we are trying to go, even if the step is refused. VB6 turns
    // on a blocked step rather than ignoring the key.
    if facing != player.heading {
        player.heading = facing;
        character.0 = false;
    }

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

    // Tell the server, then move locally. The walk gate above already refused
    // anything the server would reject, so this should not draw a correction.
    session.send(&ao_core::encode_walk(
        match facing {
            Heading::North => ao_core::Direction::North,
            Heading::East => ao_core::Direction::East,
            Heading::South => ao_core::Direction::South,
            Heading::West => ao_core::Direction::West,
        },
        session.next_walk_count(),
    ));

    // Slide from wherever the sprite currently is — not from the old tile — so
    // steps taken back-to-back chain smoothly instead of jerking.
    let now_f32 = now_ms as f32;
    let interval = walk.gate.min_interval_ms(player.speed) as f32;
    let from = if motion.duration_ms > 0.0 {
        motion.sample(now_f32)
    } else {
        tile_to_world(player.x, player.y)
    };
    *motion = Motion {
        from,
        to: tile_to_world(nx, ny),
        started_at: now_f32,
        duration_ms: (interval * VISUAL_WALK_SCALE).max(MIN_VISUAL_WALK_MS),
    };

    player.x = nx;
    player.y = ny;
    // The painted window is relative to the player, so moving exposes new tiles.
    scene.0 = true;
}

/// World-space position of a 1-based tile coordinate.
fn tile_to_world(x: i32, y: i32) -> Vec2 {
    Vec2::new((x - 1) as f32 * TILE_SIZE, -((y - 1) as f32) * TILE_SIZE)
}

/// Follow the character's *drawn* position, not its logical tile.
///
/// Snapping the camera a whole tile while the sprite interpolates makes the
/// character appear to slide backwards and then jump, which reads as far worse
/// jitter than no interpolation at all.
fn follow_camera(
    time: Res<Time>,
    motion: Res<Motion>,
    player: Res<LocalPlayer>,
    mut cameras: Query<&mut Transform, (With<Camera2d>, Without<PlayerSprite>)>,
) {
    let now_ms = time.elapsed_secs_f64() as f32 * 1000.0;
    let position = if motion.duration_ms > 0.0 {
        motion.sample_snapped(now_ms)
    } else {
        tile_to_world(player.x, player.y)
    };

    for mut transform in &mut cameras {
        transform.translation.x = position.x;
        transform.translation.y = position.y;
    }
}

/// How long to wait for map data before starting on the placeholder grid.
///
/// A fetch that fails resolves quickly and is handled. A fetch that never
/// resolves — a hung proxy, a server that accepted the connection and then went
/// quiet — has no error to report, and would otherwise hold the client in
/// `LoadingWorld` forever with input disabled. That presents as a frozen client
/// rather than as a network problem, which is the more expensive diagnosis.
///
/// A resource rather than a constant so the timeout path itself is testable.
#[derive(Resource)]
struct MapLoadTimeout(f32);

impl Default for MapLoadTimeout {
    fn default() -> Self {
        Self(15.0)
    }
}

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
    layouts: HashMap<String, Handle<TextureAtlasLayout>>,
    indices: HashMap<(String, URect), usize>,
}

/// Tiles drawn from the real graphics, as opposed to the placeholder grid.
#[derive(Component)]
struct SceneTile;

/// Whether the player's body and head sprites are current. Cleared when the
/// heading changes so the character is redrawn facing the new way.
#[derive(Resource)]
struct CharacterDrawn(bool);

/// Visual duration of one step, as a fraction of the walk interval.
///
/// The web client uses 0.84, so its sprite finishes early and then sits still
/// for the remaining 16% of every step. At roughly five steps a second that
/// dead time reads as a repeated micro-pause rather than as walking.
///
/// 1.0 makes the slide continuous: the sprite arrives exactly as the next step
/// begins, so held-key movement is one unbroken glide. The cost is that a step
/// no longer "lands" before the next starts, which is the deliberate feel the
/// 0.84 was presumably chosen for — worth revisiting if walking ever looks too
/// floaty, but a constant stutter is the worse of the two.
const VISUAL_WALK_SCALE: f32 = 1.0;
const MIN_VISUAL_WALK_MS: f32 = 55.0;

/// Interpolation between two tiles.
///
/// Without this the character teleports 32px per step. Tile positions stay
/// authoritative; only the drawn position is smoothed.
#[derive(Resource, Default)]
struct Motion {
    from: Vec2,
    to: Vec2,
    started_at: f32,
    duration_ms: f32,
}

impl Motion {
    fn sample(&self, now_ms: f32) -> Vec2 {
        if self.duration_ms <= 0.0 {
            return self.to;
        }
        let t = ((now_ms - self.started_at) / self.duration_ms).clamp(0.0, 1.0);
        self.from.lerp(self.to, t)
    }

    /// Sampled position snapped to whole pixels.
    ///
    /// This is pixel art: a camera on a fractional coordinate puts every sprite
    /// on a different texel alignment each frame, which shows up as a constant
    /// low-amplitude shimmer. Rounding only the camera is worse still — the
    /// character then wobbles half a pixel against a world that snaps — so the
    /// character and the camera must round the *same* value, which is why this
    /// lives here rather than in either system.
    fn sample_snapped(&self, now_ms: f32) -> Vec2 {
        let p = self.sample(now_ms);
        Vec2::new(p.x.round(), p.y.round())
    }

    fn is_moving(&self, now_ms: f32) -> bool {
        self.duration_ms > 0.0 && now_ms - self.started_at < self.duration_ms
    }
}

/// The body's walk cycle, advanced only while moving.
#[derive(Component)]
struct WalkCycle {
    /// Atlas indices for each frame, already registered in the sheet layout.
    frames: Vec<usize>,
    cycle_ms: f32,
    index: usize,
    last_advance_ms: f32,
}

/// Set when the player moves, so the painted window is extended around the new
/// position instead of leaving black beyond the original spawn area.
#[derive(Resource, Default)]
struct SceneDirty(bool);

/// A body or head sprite belonging to the local character. `offset` is the
/// head's `offHead` displacement, zero for the body.
#[derive(Component)]
struct CharacterPart {
    offset: Vec2,
}

/// NPCs and ground objects already spawned, keyed by (kind, x, y).
#[derive(Resource, Default)]
struct DrawnEntities(HashSet<(u8, u8, u8)>);

#[derive(Component)]
struct WorldEntity;

/// Map loaded on boot. 1 is the newbie start map.
const INITIAL_MAP: u16 = 1;

/// Boot lasts exactly one frame today: `Startup` has run, so the map request is
/// already in flight. It exists as the seam for capability probing, which must
/// happen before anything touches the GPU.
fn leave_boot(mut next: ResMut<NextState<AppState>>) {
    next.set(AppState::LoadingWorld);
}

fn start_map_load(loader: Res<MapLoader>, config: Res<ClientConfig>) {
    info!("fetching map {INITIAL_MAP} from {}", config.asset_origin);
    loader.start(config.asset_origin.clone(), INITIAL_MAP);
}

/// Swap the demo grid for the real map once it arrives.
#[allow(clippy::too_many_arguments)]
fn apply_loaded_map(
    loader: Res<MapLoader>,
    graphics: Res<Graphics>,
    mut blockmap: ResMut<Blockmap>,
    mut loaded: ResMut<LoadedMap>,
    mut commands: Commands,
    tiles: Query<Entity, With<TileSprite>>,
    player: Res<LocalPlayer>,
    config: Res<ClientConfig>,
    mut next: ResMut<NextState<AppState>>,
    time: Res<Time>,
    timeout: Res<MapLoadTimeout>,
    mut waited: Local<f32>,
) {
    match loader.state() {
        LoadState::Ready(map) => {
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
            start_graphics_load(graphics.clone(), config.asset_origin.clone(), wanted);

            loaded.0 = Some(map);
            next.set(AppState::Playing);
        }
        LoadState::Failed(message) => {
            // Still playable: the generated grid stays, and the player can move
            // around it. A failed map fetch must not leave a frozen window with
            // no explanation.
            error!("map load failed: {message} — keeping the generated map");
            next.set(AppState::Playing);
        }
        LoadState::Fetching(_) | LoadState::Idle => {
            *waited += time.delta_secs();
            if *waited >= timeout.0 {
                error!(
                    "map data did not arrive within {}s — starting on the generated map",
                    timeout.0
                );
                next.set(AppState::Playing);
            }
        }
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
    for (sheet, width, height, rgba) in graphics.take_pending_sheets() {
        let handle = images.add(make_image(width, height, rgba));
        sheets.0.insert(sheet, handle);
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
    mut dirty: ResMut<SceneDirty>,
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
            let Some(image) = sheets.0.get(&grh.sheet) else {
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
                .entry(grh.sheet.clone())
                .or_insert_with(|| layouts.add(TextureAtlasLayout::new_empty(UVec2::splat(1024))))
                .clone();

            let atlas_index = match atlases.indices.get(&(grh.sheet.clone(), rect)) {
                Some(index) => *index,
                None => {
                    let Some(layout) = layouts.get_mut(&layout_handle) else {
                        continue;
                    };
                    let index = layout.add_texture(rect);
                    atlases.indices.insert((grh.sheet.clone(), rect), index);
                    index
                }
            };

            let size = Vec2::new(grh.width, grh.height);
            commands.spawn((
                Sprite {
                    image: image.clone(),
                    texture_atlas: Some(TextureAtlas { layout: layout_handle, index: atlas_index }),
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

    dirty.0 = false;

    let _ = painted;
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
        (graphics.char_index(), graphics.bodies(), graphics.heads())
    else {
        return;
    };
    let (Some(body), Some(head)) = (bodies.get(&DEFAULT_BODY), heads.get(&DEFAULT_HEAD)) else {
        return;
    };

    let heading = player.heading;
    let Some(body_grh) = index.resolve(body.for_heading(heading)) else {
        return;
    };
    let Some(head_grh) = index.resolve(head.for_heading(heading)) else {
        return;
    };

    // Both halves need their sheets before drawing, or the character appears
    // headless for a frame or two.
    if !sheets.0.contains_key(&body_grh.sheet) || !sheets.0.contains_key(&head_grh.sheet) {
        return;
    }

    // Despawn whatever is there now: on the first pass that is the placeholder
    // box, on later passes the previous facing's body and head.
    for entity in &placeholder {
        commands.entity(entity).despawn();
    }

    let base = Vec2::new((player.x - 1) as f32 * TILE_SIZE, -((player.y - 1) as f32) * TILE_SIZE);

    // Body first (with its walk cycle), then head at the body's offHead point.
    for (grh_id, offset, z, animated) in [
        (body.for_heading(heading), Vec2::ZERO, 10.0f32, true),
        (head.for_heading(heading), body.head_offset, 10.1f32, false),
    ] {
        let Some(grh) = index.resolve(grh_id) else {
            continue;
        };
        let Some(image) = sheets.0.get(&grh.sheet) else {
            return;
        };

        let layout_handle = atlases
            .layouts
            .entry(grh.sheet.clone())
            .or_insert_with(|| layouts.add(TextureAtlasLayout::new_empty(UVec2::splat(1024))))
            .clone();

        // Register every frame up front so animating is just an index change,
        // never an asset mutation mid-frame.
        let mut frame_indices = Vec::new();
        let frames = if animated {
            index.animation(grh_id).map(|a| a.frames).unwrap_or_else(|| vec![grh.clone()])
        } else {
            vec![grh.clone()]
        };
        let cycle_ms = if animated {
            index.animation(grh_id).map(|a| a.cycle_ms).unwrap_or(210.0)
        } else {
            210.0
        };

        for frame in &frames {
            let rect = URect::new(
                frame.x as u32,
                frame.y as u32,
                (frame.x + frame.width) as u32,
                (frame.y + frame.height) as u32,
            );
            let atlas_index = match atlases.indices.get(&(frame.sheet.clone(), rect)) {
                Some(index) => *index,
                None => {
                    let Some(layout) = layouts.get_mut(&layout_handle) else {
                        return;
                    };
                    let index = layout.add_texture(rect);
                    atlases.indices.insert((frame.sheet.clone(), rect), index);
                    index
                }
            };
            frame_indices.push(atlas_index);
        }

        let size = Vec2::new(grh.width, grh.height);
        let mut entity = commands.spawn((
            Sprite {
                image: image.clone(),
                texture_atlas: Some(TextureAtlas {
                    layout: layout_handle,
                    index: frame_indices[0],
                }),
                custom_size: Some(size),
                ..default()
            },
            Anchor(Vec2::new(
                (size.x - TILE_SIZE) / (2.0 * size.x) - 0.5,
                0.5 - (size.y - TILE_SIZE) / size.y,
            )),
            Transform::from_xyz(base.x + offset.x, base.y - offset.y, z),
            PlayerSprite,
            CharacterPart { offset },
        ));

        if animated && frame_indices.len() > 1 {
            entity.insert(WalkCycle {
                frames: frame_indices,
                cycle_ms,
                index: 0,
                last_advance_ms: 0.0,
            });
        }
    }

    done.0 = true;
}

/// Spawn one grh at a tile, with AO anchoring and atlas bookkeeping.
///
/// Every drawable in the world goes through here so anchoring, the 1-based tile
/// origin and atlas index reuse stay consistent. Returns false when the sheet
/// has not arrived yet, so the caller can retry on a later pass.
#[allow(clippy::too_many_arguments)]
fn spawn_grh(
    commands: &mut Commands,
    sheets: &SheetTextures,
    atlases: &mut SheetAtlases,
    layouts: &mut Assets<TextureAtlasLayout>,
    grh: crate::graphics::Grh,
    tile_x: i32,
    tile_y: i32,
    z: f32,
    pixel_offset: Vec2,
    marker: impl Bundle,
) -> bool {
    let Some(image) = sheets.0.get(&grh.sheet) else {
        return false;
    };

    let rect = URect::new(
        grh.x as u32,
        grh.y as u32,
        (grh.x + grh.width) as u32,
        (grh.y + grh.height) as u32,
    );
    let layout_handle = atlases
        .layouts
        .entry(grh.sheet.clone())
        .or_insert_with(|| layouts.add(TextureAtlasLayout::new_empty(UVec2::splat(1024))))
        .clone();
    let atlas_index = match atlases.indices.get(&(grh.sheet.clone(), rect)) {
        Some(index) => *index,
        None => {
            let Some(layout) = layouts.get_mut(&layout_handle) else {
                return false;
            };
            let index = layout.add_texture(rect);
            atlases.indices.insert((grh.sheet.clone(), rect), index);
            index
        }
    };

    let size = Vec2::new(grh.width, grh.height);
    commands.spawn((
        Sprite {
            image: image.clone(),
            texture_atlas: Some(TextureAtlas { layout: layout_handle, index: atlas_index }),
            custom_size: Some(size),
            ..default()
        },
        // Pixi anchors run 0..1 from the top-left with y down; Bevy's run
        // -0.5..0.5 from the centre with y up. This is applyAoAnchor converted
        // between the two, so tall art hangs above and left of its tile.
        Anchor(Vec2::new(
            (size.x - TILE_SIZE) / (2.0 * size.x) - 0.5,
            0.5 - (size.y - TILE_SIZE) / size.y,
        )),
        Transform::from_xyz(
            (tile_x - 1) as f32 * TILE_SIZE + pixel_offset.x,
            -((tile_y - 1) as f32) * TILE_SIZE - pixel_offset.y,
            z,
        ),
        marker,
    ));

    true
}

/// Draw the map's NPCs and ground objects.
///
/// Map 1 alone carries 27 npcs and 131 objects; without these the world reads
/// as scenery rather than a place.
#[allow(clippy::too_many_arguments)]
fn paint_entities(
    graphics: Res<Graphics>,
    sheets: Res<SheetTextures>,
    loaded: Res<LoadedMap>,
    player: Res<LocalPlayer>,
    mut atlases: ResMut<SheetAtlases>,
    mut layouts: ResMut<Assets<TextureAtlasLayout>>,
    mut drawn: ResMut<DrawnEntities>,
    mut commands: Commands,
) {
    if sheets.0.is_empty() {
        return;
    }
    let (Some(index), Some(map)) = (graphics.index(), loaded.0.as_ref()) else {
        return;
    };

    let Some(char_index) = graphics.char_index() else {
        return;
    };

    if let (Some(looks), Some(bodies), Some(heads)) =
        (graphics.npcs(), graphics.bodies(), graphics.heads())
    {
        for npc in &map.npcs {
            let key = (0u8, npc.x, npc.y);
            if drawn.0.contains(&key) {
                continue;
            }
            let (x, y) = (npc.x as i32, npc.y as i32);
            if (x - player.x).abs() > VIEW_RADIUS_X || (y - player.y).abs() > VIEW_RADIUS_Y {
                continue;
            }
            let Some(look) = looks.get(&(npc.npc_id as i32)) else {
                drawn.0.insert(key);
                continue;
            };

            let heading = heading_from_id(look.heading);
            let mut placed = false;

            if let Some(body) = bodies.get(&look.body) {
                if let Some(grh) = char_index.resolve(body.for_heading(heading)) {
                    placed |= spawn_grh(
                        &mut commands,
                        &sheets,
                        &mut atlases,
                        &mut layouts,
                        grh,
                        x,
                        y,
                        5.0,
                        Vec2::ZERO,
                        WorldEntity,
                    );
                }
                // head 0 means the body art already includes a head.
                if look.head > 0 {
                    if let Some(head) = heads.get(&look.head) {
                        if let Some(grh) = char_index.resolve(head.for_heading(heading)) {
                            spawn_grh(
                                &mut commands,
                                &sheets,
                                &mut atlases,
                                &mut layouts,
                                grh,
                                x,
                                y,
                                5.1,
                                body.head_offset,
                                WorldEntity,
                            );
                        }
                    }
                }
            }

            if placed {
                drawn.0.insert(key);
            }
        }
    }

    if let Some(objects) = graphics.objects() {
        for object in &map.objects {
            let key = (1u8, object.x, object.y);
            if drawn.0.contains(&key) {
                continue;
            }
            let (x, y) = (object.x as i32, object.y as i32);
            if (x - player.x).abs() > VIEW_RADIUS_X || (y - player.y).abs() > VIEW_RADIUS_Y {
                continue;
            }
            let Some(grh) =
                objects.get(&(object.obj_id as i32)).and_then(|grh| index.resolve(*grh))
            else {
                drawn.0.insert(key);
                continue;
            };
            if spawn_grh(
                &mut commands,
                &sheets,
                &mut atlases,
                &mut layouts,
                grh,
                x,
                y,
                4.0,
                Vec2::ZERO,
                WorldEntity,
            ) {
                drawn.0.insert(key);
            }
        }
    }
}

/// AO heading ids: 1 north, 2 east, 3 south, 4 west.
fn heading_from_id(id: i32) -> Heading {
    match id {
        1 => Heading::North,
        2 => Heading::East,
        4 => Heading::West,
        _ => Heading::South,
    }
}

fn connect_to_server(session: Res<Session>, config: Res<ClientConfig>) {
    // No credentials means no connection. Connecting anyway would send packet
    // 74, which creates a character on the server for whoever opened the page.
    let Some(credentials) = &config.credentials else {
        return;
    };

    info!("connecting to {} as {}", config.gateway_url, credentials.name);
    session.connect(
        &config.gateway_url,
        credentials.name.clone(),
        credentials.password.clone(),
        config.client_hash.clone(),
    );
}

/// Apply authoritative updates from the server.
///
/// The server is the authority on position. When it disagrees with prediction
/// it wins — but because the client runs the server's own walk gate from
/// ao-core, it should rarely need to.
fn apply_server_messages(
    session: Res<Session>,
    mut player: ResMut<LocalPlayer>,
    mut scene: ResMut<SceneDirty>,
    mut motion: ResMut<Motion>,
    mut reported: Local<bool>,
) {
    if let ConnectionState::Failed(message) = session.state() {
        if !*reported {
            *reported = true;
            error!("connection failed: {message}");
        }
        return;
    }

    for message in session.drain() {
        match message {
            ao_core::ServerMessage::PosUpdate { x, y } => {
                // First position update is the server's only acknowledgement
                // that login succeeded; there is no explicit accept packet.
                session.mark_playing();
                let (x, y) = (x as i32, y as i32);
                if (player.x, player.y) != (x, y) {
                    player.x = x;
                    player.y = y;
                    scene.0 = true;
                    // Move the sprite by retargeting the interpolation, never by
                    // respawning it: a respawn resets the walk cycle to frame 0,
                    // so a correction on every step would freeze the legs.
                    let to = tile_to_world(x, y);
                    *motion = Motion { from: to, to, started_at: 0.0, duration_ms: 0.0 };
                }
            }
            // Latency is handled inside the session; it never reaches gameplay.
            ao_core::ServerMessage::Pong { .. } => {}
        }
    }
}

/// Slide the character between tiles and advance its walk cycle.
///
/// Both halves matter: interpolation alone gives a sliding cutout, frames alone
/// give a marching statue. Together they read as walking.
fn animate_character(
    time: Res<Time>,
    motion: Res<Motion>,
    mut parts: Query<(&mut Transform, Option<&mut Sprite>, Option<&mut WalkCycle>, &CharacterPart)>,
) {
    let now_ms = time.elapsed_secs_f64() as f32 * 1000.0;
    let position = motion.sample_snapped(now_ms);
    let moving = motion.is_moving(now_ms);

    for (mut transform, sprite, cycle, part) in &mut parts {
        transform.translation.x = position.x + part.offset.x;
        transform.translation.y = position.y - part.offset.y;

        let (Some(mut sprite), Some(mut cycle)) = (sprite, cycle) else {
            continue;
        };
        if cycle.frames.is_empty() {
            continue;
        }

        if moving {
            // velocidad is the whole cycle, so one frame is cycle / frames.
            let per_frame = (cycle.cycle_ms / cycle.frames.len() as f32).max(1.0);
            if now_ms - cycle.last_advance_ms >= per_frame {
                cycle.index = (cycle.index + 1) % cycle.frames.len();
                cycle.last_advance_ms = now_ms;
                if let Some(atlas) = sprite.texture_atlas.as_mut() {
                    atlas.index = cycle.frames[cycle.index];
                }
            }
        } else if cycle.index != 0 {
            // Standing still shows the neutral pose, not a frozen mid-stride.
            cycle.index = 0;
            cycle.last_advance_ms = now_ms;
            if let Some(atlas) = sprite.texture_atlas.as_mut() {
                atlas.index = cycle.frames[0];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::state::app::StatesPlugin;

    fn headless() -> App {
        let mut app = App::new();
        app.add_plugins((MinimalPlugins, StatesPlugin));
        app.init_state::<AppState>();
        app
    }

    /// One frame of keyboard state.
    ///
    /// `just_pressed` is edge-triggered and cleared between frames, so a test
    /// that never clears would report every held key as newly pressed forever.
    fn frame(keys: &mut ButtonInput<KeyCode>, held: &mut HeldDirections) {
        held.update(keys);
        keys.clear();
    }

    #[test]
    fn a_new_key_takes_over_from_the_one_already_held() {
        // The reported bug: walking up, press left, keep walking up.
        let mut keys = ButtonInput::<KeyCode>::default();
        let mut held = HeldDirections::default();

        keys.press(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);
        assert_eq!(held.current(), Some(Heading::North));

        keys.press(KeyCode::ArrowLeft);
        frame(&mut keys, &mut held);
        assert_eq!(held.current(), Some(Heading::West));
    }

    #[test]
    fn releasing_the_newer_key_falls_back_to_the_one_still_held() {
        // Why the whole held set is kept rather than just the latest key:
        // letting go of left must resume north without pressing up again.
        let mut keys = ButtonInput::<KeyCode>::default();
        let mut held = HeldDirections::default();

        keys.press(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);
        keys.press(KeyCode::ArrowLeft);
        frame(&mut keys, &mut held);
        assert_eq!(held.current(), Some(Heading::West));

        keys.release(KeyCode::ArrowLeft);
        frame(&mut keys, &mut held);
        assert_eq!(held.current(), Some(Heading::North));
    }

    #[test]
    fn releasing_everything_stops() {
        let mut keys = ButtonInput::<KeyCode>::default();
        let mut held = HeldDirections::default();

        keys.press(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);
        keys.release(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);

        assert_eq!(held.current(), None);
    }

    #[test]
    fn a_direction_survives_releasing_one_of_its_two_keys() {
        // W and ArrowUp both mean north. Releasing one while the other is held
        // must not stop movement, which a per-key model would get wrong.
        let mut keys = ButtonInput::<KeyCode>::default();
        let mut held = HeldDirections::default();

        keys.press(KeyCode::KeyW);
        frame(&mut keys, &mut held);
        keys.press(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);
        keys.release(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);

        assert_eq!(held.current(), Some(Heading::North));
    }

    #[test]
    fn re_pressing_a_held_direction_moves_it_back_to_the_front() {
        // Tapping up again while left is held is an unambiguous request to go
        // up, even though up never stopped being held.
        let mut keys = ButtonInput::<KeyCode>::default();
        let mut held = HeldDirections::default();

        keys.press(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);
        keys.press(KeyCode::ArrowLeft);
        frame(&mut keys, &mut held);
        assert_eq!(held.current(), Some(Heading::West));

        // A second binding for a direction already held.
        keys.press(KeyCode::KeyW);
        frame(&mut keys, &mut held);
        assert_eq!(held.current(), Some(Heading::North));
    }

    #[test]
    fn holding_a_key_does_not_reorder_on_later_frames() {
        // Only an edge reorders. If a held key counted as pressed every frame,
        // whichever direction came last in DIRECTION_KEYS would win — the same
        // fixed-priority bug, just with a different winner.
        let mut keys = ButtonInput::<KeyCode>::default();
        let mut held = HeldDirections::default();

        keys.press(KeyCode::ArrowLeft);
        frame(&mut keys, &mut held);
        keys.press(KeyCode::ArrowUp);
        frame(&mut keys, &mut held);

        for _ in 0..5 {
            frame(&mut keys, &mut held);
            assert_eq!(held.current(), Some(Heading::North));
        }
    }

    #[test]
    fn every_direction_maps_to_a_single_tile_step() {
        assert_eq!(heading_delta(Heading::North), (0, -1));
        assert_eq!(heading_delta(Heading::South), (0, 1));
        assert_eq!(heading_delta(Heading::West), (-1, 0));
        assert_eq!(heading_delta(Heading::East), (1, 0));
    }

    #[test]
    fn the_client_starts_in_boot() {
        // Not Playing: input must not be accepted before a world exists, and
        // the default is what decides that.
        let app = headless();
        assert_eq!(*app.world().resource::<State<AppState>>().get(), AppState::Boot);
    }

    /// Advance far enough for a queued state change to be applied.
    ///
    /// `NextState` is consumed by the `StateTransition` schedule, which runs
    /// before `Update` — so a system that queues a change during frame N sees
    /// it take effect at the start of frame N+1, not within its own frame.
    fn step(app: &mut App) {
        app.update();
        app.update();
    }

    #[test]
    fn boot_hands_over_to_loading() {
        let mut app = headless();
        app.add_systems(Update, leave_boot.run_if(in_state(AppState::Boot)));

        step(&mut app);
        assert_eq!(*app.world().resource::<State<AppState>>().get(), AppState::LoadingWorld);

        // And does not run again: leaving Boot is not something to repeat.
        step(&mut app);
        assert_eq!(*app.world().resource::<State<AppState>>().get(), AppState::LoadingWorld);
    }

    #[test]
    fn a_failed_map_load_still_reaches_playing() {
        // The generated grid remains, so the player can move. Staying in
        // LoadingWorld would present a frozen window with no explanation, and
        // would also stop input, which is how a map-server problem gets
        // mistaken for a dead client.
        let mut app = headless();
        app.insert_resource(MapLoader::default())
            .insert_resource(Graphics::default())
            .insert_resource(Blockmap::demo())
            .insert_resource(LoadedMap(None))
            .insert_resource(LocalPlayer::default())
            .insert_resource(MapLoadTimeout(f32::MAX))
            .insert_resource(ClientConfig {
                asset_origin: "http://test".into(),
                gateway_url: "ws://test/ao".into(),
                credentials: None,
                client_hash: "test".into(),
            })
            .add_systems(Update, apply_loaded_map.run_if(in_state(AppState::LoadingWorld)));
        app.insert_state(AppState::LoadingWorld);

        // A long deadline, so reaching Playing can only be the failure path.
        app.world().resource::<MapLoader>().fail_for_test("no route to host");
        step(&mut app);

        assert_eq!(*app.world().resource::<State<AppState>>().get(), AppState::Playing);
    }

    #[test]
    fn an_outstanding_load_stays_in_loading_world() {
        // Idle and Fetching are not decisions. Transitioning on either would
        // start accepting input against a world that is not there yet.
        let mut app = headless();
        app.insert_resource(MapLoader::default())
            .insert_resource(Graphics::default())
            .insert_resource(Blockmap::demo())
            .insert_resource(LoadedMap(None))
            .insert_resource(LocalPlayer::default())
            .insert_resource(MapLoadTimeout(f32::MAX))
            .insert_resource(ClientConfig {
                asset_origin: "http://test".into(),
                gateway_url: "ws://test/ao".into(),
                credentials: None,
                client_hash: "test".into(),
            })
            .add_systems(Update, apply_loaded_map.run_if(in_state(AppState::LoadingWorld)));
        app.insert_state(AppState::LoadingWorld);

        step(&mut app);
        step(&mut app);

        assert_eq!(*app.world().resource::<State<AppState>>().get(), AppState::LoadingWorld);
    }

    #[test]
    fn a_load_that_never_resolves_gives_up_and_starts_anyway() {
        // A hung fetch produces no error to react to. Without a deadline the
        // client stays in LoadingWorld with input disabled, which reads as a
        // frozen client rather than as a network problem.
        let mut app = headless();
        app.insert_resource(MapLoader::default())
            .insert_resource(Graphics::default())
            .insert_resource(Blockmap::demo())
            .insert_resource(LoadedMap(None))
            .insert_resource(LocalPlayer::default())
            .insert_resource(MapLoadTimeout(0.0))
            .insert_resource(ClientConfig {
                asset_origin: "http://test".into(),
                gateway_url: "ws://test/ao".into(),
                credentials: None,
                client_hash: "test".into(),
            })
            .add_systems(Update, apply_loaded_map.run_if(in_state(AppState::LoadingWorld)));
        app.insert_state(AppState::LoadingWorld);

        // The loader never leaves Idle.
        step(&mut app);

        assert_eq!(*app.world().resource::<State<AppState>>().get(), AppState::Playing);
    }
}
