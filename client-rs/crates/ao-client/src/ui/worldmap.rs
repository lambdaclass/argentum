//! The whole-world map, as an overlay inside the world viewport.
//!
//! Tab opens it and Tab or Escape closes it, which is the reference workflow: the top bar
//! and the character rail stay visible and clickable, because a player opening the map has
//! not stopped being interested in their own health.
//!
//! While it is open the world stops taking commands. That is not a pause of the session —
//! the server keeps running and so does everything happening to the player — it is a
//! refusal to *send*: no step, no cast, no target. An armed spell, a drag and any pointer
//! capture are released as they open it, under the same cancellation rules those states
//! document for themselves.
//!
//! The camera is the interesting part and it is pure. Every path through it is clamped to
//! finite bounds, because the ways a map camera goes wrong are all the same way: a zero
//! width, a zero-sized world, a wheel event with an absurd delta, and what the player gets
//! is a NaN transform and a black rectangle they cannot recover from without restarting.

use super::state::UiState;
use super::tokens::{focus, ink, size, space, surface, type_scale};
use ao_core::view::{MapMarker, MarkerKind, WorldMapState};
use bevy::prelude::*;

/// The overview art the map is allowed to draw, and what it may cost.
///
/// A separate, bounded asset — never the gameplay world pack. The pack is tens of
/// megabytes of per-tile data for one map at a time; the overview is one image of the
/// whole world, and decoding the former to draw the latter would trade a fixed cost for
/// an unbounded one and still be wrong at the edges of maps the player has not loaded.
///
/// Budget, at the maximum profile:
///
/// - **Source**: project-owned, generated offline from the same map data the server
///   already publishes. No third-party art, so no third-party licence: it carries the
///   repository's own licence, which is what makes it shippable in a web bundle.
/// - **Maximum dimension**: 2048 x 2048. That is the smallest limit any WebGL2 device in
///   the support matrix guarantees, so the full profile works everywhere the client runs
///   at all.
/// - **Decoded / GPU cost**: 2048 x 2048 x 4 bytes = 16 MiB resident, once, for as long
///   as the overlay is open.
/// - **Compressed cost**: budgeted at 2 MiB over the wire. A world overview is flat
///   colour and hard edges, which is what PNG is good at; the number is a ceiling the
///   manifest entry is checked against rather than a measurement of art that does not
///   exist yet.
/// - **Below the limit**: a device reporting less than 2048 gets the reduced profile at
///   1024 (4 MiB), and one that cannot manage 1024 gets no art at all and the vector
///   outline instead. The outline is not a degraded mode with a black rectangle in it —
///   it is drawn from the same marker data, and it is what every profile falls back to
///   while the asset is missing.
///
/// The art itself does not exist yet, which is why the client draws the outline today and
/// says so. Phase 7 content-hashes and caches the production asset; this is the entry it
/// will fill, and the budget it has to fit.
pub const OVERVIEW_MAX_DIMENSION: u32 = 2048;

/// The manifest entry for the overview, embedded so a test can check the numbers above
/// against the ones the entry states.
///
/// Two copies of a budget that can drift are one budget and one comment.
///
/// Test-only: checking that the entry and the constants agree is a test's job, and
/// shipping the prose inside the wasm bundle would cost every player a few kilobytes to
/// carry a document nothing reads at runtime.
#[cfg(test)]
pub const OVERVIEW_MANIFEST: &str = include_str!("../../../../assets/world-map/MANIFEST.md");

/// One `key: value` line from the manifest, or `None` if it does not state that key.
#[cfg(test)]
pub fn manifest_field(key: &str) -> Option<&'static str> {
    OVERVIEW_MANIFEST.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        (name.trim() == key).then(|| value.trim())
    })
}

/// The reduced dimension for a device that cannot manage the full one.
pub const OVERVIEW_REDUCED_DIMENSION: u32 = 1024;

/// Bytes per pixel once decoded, which is also what it costs on the GPU.
pub const OVERVIEW_BYTES_PER_PIXEL: u64 = 4;

/// The ceiling the manifest entry is checked against, over the wire.
pub const OVERVIEW_MAX_COMPRESSED_BYTES: u64 = 2 * 1024 * 1024;

/// Which overview a device can be asked to hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverviewProfile {
    /// The full asset.
    Full { dimension: u32 },
    /// A smaller one, for a device that cannot hold the full asset.
    Reduced { dimension: u32 },
    /// No art at all: the outline, drawn from the marker data.
    Outline,
}

impl OverviewProfile {
    /// What this profile costs once decoded, in bytes.
    pub fn decoded_bytes(self) -> u64 {
        match self {
            OverviewProfile::Full { dimension } | OverviewProfile::Reduced { dimension } => {
                dimension as u64 * dimension as u64 * OVERVIEW_BYTES_PER_PIXEL
            }
            OverviewProfile::Outline => 0,
        }
    }
}

/// The profile a device reporting `max_dimension` can be given.
///
/// Keyed off the device's own `max_texture_dimension_2d`, the same number the world
/// render target is bounded by, rather than a guess from the user agent.
pub fn profile_for(max_dimension: u32) -> OverviewProfile {
    if max_dimension >= OVERVIEW_MAX_DIMENSION {
        OverviewProfile::Full { dimension: OVERVIEW_MAX_DIMENSION }
    } else if max_dimension >= OVERVIEW_REDUCED_DIMENSION {
        OverviewProfile::Reduced { dimension: OVERVIEW_REDUCED_DIMENSION }
    } else {
        OverviewProfile::Outline
    }
}

/// What to say about the art the player is not seeing.
///
/// Two different facts, and a player can act on one of them: a device that cannot hold the
/// overview will never show it, while art that has not been published yet will appear when
/// it is. Collapsing them into "no map" would tell someone to go looking for a setting that
/// does not exist.
pub fn overview_note(profile: OverviewProfile) -> &'static str {
    match profile {
        OverviewProfile::Outline => "map.overview.this-device-shows-the-outline-only",
        _ => "map.overview.overview-art-is-not-published-yet",
    }
}

/// How many tiles apart the grid lines are drawn.
///
/// The outline alone tells a player where the world ends and nothing else. Ten-tile lines
/// are what make a pan or a zoom *visible*: without them the map is a black field with
/// dots in it, and the first capture of this overlay was exactly that — the unexplained
/// black rectangle this task forbids, drawn by the code that was supposed to prevent one.
const GRID_TILES: f32 = 10.0;

/// How wide the ring marking the player's own position is.
///
/// Larger than any category marker on purpose. It is the position a player looks for
/// first, and one more dot the same size as the other dots is not an answer.
const SELF_MARK: f32 = size::ICON_BUTTON * 0.5;

/// The world's own rectangle on screen, and the grid lines inside it.
///
/// Returned as plain rectangles so the placement stays testable and the drawing stays
/// dumb. Every one is projected through the same camera as the markers, so they pan and
/// zoom together — a grid that stayed put while the markers moved would be worse than none.
pub fn outline_and_grid(view: MapView, viewport: Vec2, world: Vec2) -> (Rect, Vec<Rect>) {
    let extent = world.max(Vec2::splat(1.0));
    let top_left = project(Vec2::ZERO, view, viewport);
    let bottom_right = project(extent, view, viewport);
    let outline = Rect::from_corners(top_left, bottom_right);

    let mut lines = Vec::new();
    if !outline.min.is_finite() || !outline.max.is_finite() {
        return (outline, lines);
    }

    let mut tile = GRID_TILES;
    while tile < extent.x {
        let x = project(Vec2::new(tile, 0.0), view, viewport).x;
        lines.push(Rect::from_corners(
            Vec2::new(x, outline.min.y),
            Vec2::new(x + 1.0, outline.max.y),
        ));
        tile += GRID_TILES;
    }
    let mut tile = GRID_TILES;
    while tile < extent.y {
        let y = project(Vec2::new(0.0, tile), view, viewport).y;
        lines.push(Rect::from_corners(
            Vec2::new(outline.min.x, y),
            Vec2::new(outline.max.x, y + 1.0),
        ));
        tile += GRID_TILES;
    }
    (outline, lines)
}

/// Categories a player can switch off, in the order the legend shows them.
pub const CATEGORIES: [MarkerKind; 5] = [
    MarkerKind::Party,
    MarkerKind::Merchant,
    MarkerKind::Quest,
    MarkerKind::Dungeon,
    MarkerKind::Landmark,
];

/// The furthest in a player can zoom, in logical pixels per world tile.
///
/// Bounded because the interesting failure is unbounded: a wheel with a large delta, or a
/// held key, and the map is a single tile filling the viewport with no way back except the
/// reset the player has to find first.
const MAX_PIXELS_PER_TILE: f32 = 12.0;

/// How much one wheel notch or one key press changes the zoom.
const ZOOM_STEP: f32 = 1.25;

/// How far one key press pans, as a fraction of the viewport.
const PAN_STEP: f32 = 0.15;

/// Where the map is being looked at, in world tiles and pixels per tile.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MapView {
    /// The world tile at the centre of the viewport.
    pub centre: Vec2,
    /// Logical pixels per world tile.
    pub scale: f32,
}

impl Default for MapView {
    fn default() -> Self {
        Self { centre: Vec2::ZERO, scale: 1.0 }
    }
}

/// The scale at which the whole world fits in the viewport.
///
/// The smaller of the two axes' ratios, so nothing is cropped: the other axis gets
/// letterbox margins, which is the intentional treatment the task asks for. Cropping to
/// fill would hide a corner of the world, and a map that hides part of the world is
/// answering a different question than the one the player asked.
pub fn fit_scale(viewport: Vec2, world: Vec2) -> f32 {
    if !viewport.is_finite() || !world.is_finite() {
        return 1.0;
    }
    let usable = viewport.max(Vec2::splat(1.0));
    // A world with no size cannot be fitted to. One tile per pixel is arbitrary and
    // finite, which is the only property that matters here — the malformed fixture sends a
    // zero-sized world and everything downstream divides by it.
    let extent = world.max(Vec2::splat(1.0));
    (usable / extent).min_element().clamp(f32::MIN_POSITIVE, MAX_PIXELS_PER_TILE)
}

/// The view that shows the whole world.
pub fn fit(viewport: Vec2, world: Vec2) -> MapView {
    let extent = world.max(Vec2::splat(1.0));
    MapView { centre: extent / 2.0, scale: fit_scale(viewport, world) }
}

/// Bring a view back inside what the world and the viewport allow.
///
/// Zoom is clamped between "the whole world fits" and a hard maximum: a player cannot zoom
/// out past the world, because there is nothing out there to see. The centre is clamped so
/// the world's edge cannot be dragged into the middle of the viewport, and an axis where
/// the world is smaller than the viewport is centred instead — that is the letterbox.
pub fn clamp(view: MapView, viewport: Vec2, world: Vec2) -> MapView {
    let extent = world.max(Vec2::splat(1.0));
    let usable = viewport.max(Vec2::splat(1.0));
    let minimum = fit_scale(viewport, world);
    let scale = if view.scale.is_finite() {
        view.scale.clamp(minimum, MAX_PIXELS_PER_TILE.max(minimum))
    } else {
        minimum
    };

    // Half the viewport, in tiles: how far from the centre the visible window reaches.
    let half = usable / (2.0 * scale);
    let centre = if view.centre.is_finite() { view.centre } else { extent / 2.0 };
    let clamped =
        Vec2::new(clamp_axis(centre.x, half.x, extent.x), clamp_axis(centre.y, half.y, extent.y));
    MapView { centre: clamped, scale }
}

/// Clamp one axis of the centre, centring instead when the world is the smaller of the two.
fn clamp_axis(centre: f32, half: f32, extent: f32) -> f32 {
    if half * 2.0 >= extent {
        // The world fits with room to spare: it sits in the middle and the spare room is
        // the letterbox.
        return extent / 2.0;
    }
    centre.clamp(half, extent - half)
}

/// Where a world tile lands inside the viewport, in the overlay's own pixels.
pub fn project(tile: Vec2, view: MapView, viewport: Vec2) -> Vec2 {
    let usable = viewport.max(Vec2::splat(1.0));
    usable / 2.0 + (tile - view.centre) * view.scale
}

/// Which world tile is under a point in the viewport.
pub fn unproject(point: Vec2, view: MapView, viewport: Vec2) -> Vec2 {
    let usable = viewport.max(Vec2::splat(1.0));
    let scale = if view.scale.is_finite() && view.scale > 0.0 { view.scale } else { 1.0 };
    view.centre + (point - usable / 2.0) / scale
}

/// Zoom by `steps` notches, keeping the tile under `anchor` where it is.
///
/// Anchored zoom is what makes a map feel like a map: the thing you pointed at stays under
/// the cursor. Recomputing the centre from the anchor is also what keeps it stable —
/// zooming about the viewport's middle drifts whatever you were looking at off the screen.
pub fn zoom_around(
    view: MapView,
    viewport: Vec2,
    world: Vec2,
    anchor: Vec2,
    steps: f32,
) -> MapView {
    let before = clamp(view, viewport, world);
    if !steps.is_finite() || steps == 0.0 {
        return before;
    }
    let anchor_tile = unproject(anchor, before, viewport);
    let factor = ZOOM_STEP.powf(steps.clamp(-8.0, 8.0));
    let scaled = MapView { centre: before.centre, scale: before.scale * factor };
    let after = clamp(scaled, viewport, world);

    // Move the centre so the anchor tile is back under the anchor point. Clamping again
    // afterwards is what keeps that from pushing the view off the world.
    let usable = viewport.max(Vec2::splat(1.0));
    let offset = (anchor - usable / 2.0) / after.scale;
    clamp(MapView { centre: anchor_tile - offset, scale: after.scale }, viewport, world)
}

/// Pan by a distance in viewport pixels.
pub fn pan_by(view: MapView, viewport: Vec2, world: Vec2, delta: Vec2) -> MapView {
    let current = clamp(view, viewport, world);
    if !delta.is_finite() {
        return current;
    }
    let tiles = delta / current.scale;
    clamp(MapView { centre: current.centre - tiles, scale: current.scale }, viewport, world)
}

/// How far one key press pans, in viewport pixels.
pub fn key_pan(viewport: Vec2) -> f32 {
    (viewport.min_element().max(1.0) * PAN_STEP).max(1.0)
}

/// The camera, kept for the session.
///
/// `last_valid` is what a malformed frame falls back to. Without it, one snapshot with a
/// zero-sized world would replace a view the player had spent time arranging, and the
/// reset action is not the same thing: reset is a deliberate return to the whole world.
#[derive(Resource, Debug, Clone, Copy)]
pub struct WorldMapCamera {
    pub view: MapView,
    pub last_valid: MapView,
    /// False until the map has been opened once, so the first open fits the world rather
    /// than restoring a view nobody chose.
    pub arranged: bool,
}

impl Default for WorldMapCamera {
    fn default() -> Self {
        Self { view: MapView::default(), last_valid: MapView::default(), arranged: false }
    }
}

impl WorldMapCamera {
    /// Adopt a view, remembering it if it is usable.
    pub fn set(&mut self, view: MapView) {
        if view.centre.is_finite() && view.scale.is_finite() && view.scale > 0.0 {
            self.view = view;
            self.last_valid = view;
            self.arranged = true;
        } else {
            self.view = self.last_valid;
        }
    }

    /// Back to the whole world, which is what reset means.
    pub fn reset(&mut self, viewport: Vec2, world: Vec2) {
        self.set(fit(viewport, world));
        // Reset is a deliberate return to the overview, so the next open should fit again
        // rather than restoring the view being abandoned here.
        self.arranged = false;
    }
}

/// Whether the overlay is open, which the client owns.
///
/// Tab is a client key: the server is not asked whether the player may look at their own
/// map. The snapshot's `open` flag is the adapter's view of the same thing and seeds this
/// once, so a session resumed with the map open opens with it.
#[derive(Resource, Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorldMapOpen(pub bool);

/// Which categories are hidden, by position in [`CATEGORIES`].
#[derive(Resource, Debug, Clone, Copy, PartialEq, Eq)]
pub struct CategoryFilters {
    hidden: [bool; CATEGORIES.len()],
}

impl Default for CategoryFilters {
    fn default() -> Self {
        Self { hidden: [false; CATEGORIES.len()] }
    }
}

impl CategoryFilters {
    pub fn shows(&self, kind: MarkerKind) -> bool {
        // A category nobody can switch off is always shown, and the player's own position
        // is the one that matters: a map that can hide where you are is a map you can get
        // lost on while looking at it.
        if !kind.is_filterable() {
            return true;
        }
        match CATEGORIES.iter().position(|candidate| *candidate == kind) {
            Some(index) => !self.hidden[index],
            None => true,
        }
    }

    pub fn toggle(&mut self, kind: MarkerKind) {
        if let Some(index) = CATEGORIES.iter().position(|candidate| *candidate == kind) {
            self.hidden[index] = !self.hidden[index];
        }
    }
}

/// Markers the overlay draws: authorised by the server, then filtered by the player.
///
/// Filtering is presentation only. It changes what is drawn and never what the client
/// believes, so switching a category off and on again cannot lose a marker — and nothing
/// here consults a map asset to find markers the server did not send.
pub fn drawn_markers<'a>(
    state: &'a WorldMapState,
    filters: &CategoryFilters,
) -> Vec<&'a MapMarker> {
    state.markers.iter().filter(|marker| filters.shows(marker.kind)).collect()
}

/// Marks the overlay's root, so it can be despawned as one thing.
#[derive(Component)]
struct OverlayRoot;

/// Marks a category control with the category it toggles.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct CategoryToggle(pub MarkerKind);

/// Marks the two view controls the task asks for by name.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewAction {
    /// Back to the whole world.
    Reset,
    /// Centre on the player without changing the zoom.
    Recenter,
}

pub struct WorldMapPlugin;

impl Plugin for WorldMapPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<WorldMapOpen>()
            .init_resource::<WorldMapCamera>()
            .init_resource::<CategoryFilters>()
            .add_systems(
                Update,
                // Toggling is deliberately *not* in `GameplayInput`: that set is suppressed
                // while the map is open, and a key that could only open the map would be a
                // map that cannot be closed.
                toggle_overlay.after(super::controls::ControlSet::Interact),
            )
            .add_systems(
                Update,
                // The overlay is rebuilt whenever the camera or the filters change, so its
                // own controls have to be read before that.
                (apply_overlay_controls, drive_camera)
                    .chain()
                    .after(toggle_overlay)
                    .in_set(super::controls::ControlSet::Consume),
            )
            .add_systems(Update, present_overlay.in_set(super::controls::ControlSet::Rebuild));
    }
}

/// Tab opens the map; Tab or Escape closes it.
///
/// One toggle per key press, which is what `just_pressed` buys — and suppressed while text
/// owns the keyboard, because Tab in a chat box is a character or a focus move and never a
/// map.
fn toggle_overlay(
    text_input: Res<super::controls::TextInputActive>,
    navigation: Res<super::controls::FocusNavigation>,
    keys: Res<ButtonInput<KeyCode>>,
    mut open: ResMut<WorldMapOpen>,
    mut armed: ResMut<super::spells::ArmedSpell>,
    mut drag: ResMut<super::character::DragState>,
) {
    if text_input.0 {
        return;
    }
    // Focus navigation owns Tab when it is on, which is the documented trade: F6 turns it
    // on and off precisely because Tab is a gameplay key here.
    let tab = !navigation.active && keys.just_pressed(KeyCode::Tab);
    let escape = keys.just_pressed(KeyCode::Escape);

    if open.0 {
        if tab || escape {
            open.0 = false;
        }
        return;
    }
    if !tab {
        return;
    }

    open.0 = true;
    // Released as the map opens, under the rules those states document for themselves: an
    // armed spell with nothing to point at and a drag whose destination is covered are both
    // states the player cannot finish.
    armed.clear();
    drag.cancel();
}

/// The viewport the overlay draws into, in logical pixels.
fn overlay_viewport(geometry: &super::shell::AppliedGeometry) -> Option<Vec2> {
    let shell = geometry.0?;
    let view = super::layout::world_view(shell.world).rect;
    let size = view.size() - Vec2::splat(space::WIDE * 2.0);
    (size.x > 1.0 && size.y > 1.0).then_some(size)
}

/// The world's size in tiles, as the snapshot reports it.
fn world_extent(state: &WorldMapState) -> Vec2 {
    Vec2::new(state.size.0.max(0) as f32, state.size.1.max(0) as f32)
}

fn apply_overlay_controls(
    mut activated: MessageReader<super::controls::Activated>,
    categories: Query<&CategoryToggle>,
    actions: Query<&ViewAction>,
    state: Res<UiState>,
    geometry: Res<super::shell::AppliedGeometry>,
    player: Res<crate::world::LocalPlayer>,
    mut filters: ResMut<CategoryFilters>,
    mut camera: ResMut<WorldMapCamera>,
) {
    let Some(viewport) = overlay_viewport(&geometry) else {
        return;
    };
    let world = world_extent(&state.get().world_map);

    for message in activated.read() {
        if let Ok(toggle) = categories.get(message.entity) {
            filters.toggle(toggle.0);
            continue;
        }
        match actions.get(message.entity) {
            Ok(ViewAction::Reset) => camera.reset(viewport, world),
            Ok(ViewAction::Recenter) => {
                let view = camera.view;
                camera.set(clamp(
                    MapView {
                        centre: Vec2::new(player.x as f32, player.y as f32),
                        scale: view.scale,
                    },
                    viewport,
                    world,
                ));
            }
            Err(_) => {}
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn drive_camera(
    open: Res<WorldMapOpen>,
    state: Res<UiState>,
    geometry: Res<super::shell::AppliedGeometry>,
    keys: Res<ButtonInput<KeyCode>>,
    mut wheel: MessageReader<bevy::input::mouse::MouseWheel>,
    pointer: Res<super::pointer::PointerState>,
    mouse: Res<ButtonInput<MouseButton>>,
    mut camera: ResMut<WorldMapCamera>,
    mut dragging: Local<Option<Vec2>>,
) {
    let Some(viewport) = overlay_viewport(&geometry) else {
        return;
    };
    let world = world_extent(&state.get().world_map);

    if !open.0 {
        // Wheel events that arrived while the map was shut belong to whatever else reads
        // them, and must not be applied the next time it opens.
        wheel.clear();
        *dragging = None;
        return;
    }

    // The first open fits the whole world; a later one restores what the player arranged.
    if !camera.arranged {
        camera.set(fit(viewport, world));
        // `set` marks it arranged, which the first open has not earned: the next open
        // should still fit unless the player has moved the map themselves.
        camera.arranged = false;
    }

    let origin = geometry.0.map(|shell| super::layout::world_view(shell.world).rect.min);
    let local = pointer
        .position
        .zip(origin)
        .map(|(position, min)| position - min - Vec2::splat(space::WIDE));
    let anchor = local.unwrap_or(viewport / 2.0);

    let notches: f32 = wheel.read().map(|event| event.y).sum();
    if notches != 0.0 {
        let zoomed = zoom_around(camera.view, viewport, world, anchor, notches);
        camera.set(zoomed);
    }

    // Keyboard zoom, for a player without a wheel and for anyone who prefers keys.
    let key_notches = keys.just_pressed(KeyCode::Equal) as i32 as f32
        - keys.just_pressed(KeyCode::Minus) as i32 as f32;
    if key_notches != 0.0 {
        let zoomed = zoom_around(camera.view, viewport, world, viewport / 2.0, key_notches);
        camera.set(zoomed);
    }

    let step = key_pan(viewport);
    let mut delta = Vec2::ZERO;
    if keys.just_pressed(KeyCode::ArrowLeft) {
        delta.x -= step;
    }
    if keys.just_pressed(KeyCode::ArrowRight) {
        delta.x += step;
    }
    if keys.just_pressed(KeyCode::ArrowUp) {
        delta.y -= step;
    }
    if keys.just_pressed(KeyCode::ArrowDown) {
        delta.y += step;
    }
    if delta != Vec2::ZERO {
        let panned = pan_by(camera.view, viewport, world, -delta);
        camera.set(panned);
    }

    // Pointer drag, tracked here rather than through picking: the overlay is one surface
    // and what is being dragged is the map itself, not a control on it.
    if mouse.pressed(MouseButton::Left) {
        if let Some(now) = local {
            if let Some(previous) = *dragging {
                let panned = pan_by(camera.view, viewport, world, now - previous);
                camera.set(panned);
            }
            *dragging = Some(now);
        }
    } else {
        *dragging = None;
    }
}

#[allow(clippy::too_many_arguments)]
fn present_overlay(
    open: Res<WorldMapOpen>,
    state: Res<UiState>,
    player: Res<crate::world::LocalPlayer>,
    limits: Res<super::scale::TargetLimits>,
    geometry: Res<super::shell::AppliedGeometry>,
    camera: Res<WorldMapCamera>,
    filters: Res<CategoryFilters>,
    regions: Query<Entity, With<super::shell::Region>>,
    region_kinds: Query<&super::shell::Region>,
    existing: Query<Entity, With<OverlayRoot>>,
    mut commands: Commands,
    mut last: Local<Option<(bool, WorldMapState, MapView, CategoryFilters)>>,
) {
    let snapshot = state.get();
    let map = snapshot.world_map.clone();
    let signature = (open.0, map.clone(), camera.view, *filters);
    if last.as_ref() == Some(&signature) {
        return;
    }
    *last = Some(signature);

    for entity in &existing {
        commands.entity(entity).despawn();
    }
    if !open.0 {
        return;
    }
    let Some(viewport) = overlay_viewport(&geometry) else {
        return;
    };

    let Some(world_region) =
        regions.iter().find(|entity| region_kinds.get(*entity) == Ok(&super::shell::Region::World))
    else {
        return;
    };

    let world = world_extent(&map);
    let view = clamp(camera.view, viewport, world);
    let unavailable = super::minimap::state_key(map.availability).map(super::fallback_label);
    let empty = unavailable.is_none() && map.markers.is_empty();
    let markers: Vec<(Vec2, MarkerKind)> = if unavailable.is_some() {
        Vec::new()
    } else {
        drawn_markers(&map, &filters)
            .into_iter()
            .map(|marker| {
                (project(Vec2::new(marker.x as f32, marker.y as f32), view, viewport), marker.kind)
            })
            .filter(|(at, _)| {
                at.is_finite()
                    && at.x >= 0.0
                    && at.y >= 0.0
                    && at.x <= viewport.x
                    && at.y <= viewport.y
            })
            .collect()
    };

    // Where the player is, on the map rather than only in the heading. "Centre on me"
    // centred the view on nothing you could see: the button worked and there was no way
    // to tell, because the one position a player looks for first was the one position the
    // map did not draw.
    let self_at = (unavailable.is_none())
        .then(|| project(Vec2::new(player.x as f32, player.y as f32), view, viewport))
        .filter(|at| {
            at.is_finite() && at.x >= 0.0 && at.y >= 0.0 && at.x <= viewport.x && at.y <= viewport.y
        });

    // The region and where the player is, in words: a map you cannot read a position off
    // is a map you cannot use to tell a party where to meet.
    // The outline first, so the markers sit on something. Empty when there is no map to
    // describe: an outline around nothing would be a claim that the world is that size.
    let outline: Vec<(Rect, bool)> = if unavailable.is_some() {
        Vec::new()
    } else {
        let (world_rect, grid) = outline_and_grid(view, viewport, world);
        std::iter::once((world_rect, true))
            .chain(grid.into_iter().map(|line| (line, false)))
            .collect()
    };

    let region = if map.region_key.trim().is_empty() {
        format!("map {}", map.focus_map)
    } else {
        super::fallback_label(&map.region_key)
    };
    let heading = format!("{region} — {},{}", player.x, player.y);
    // Which overview this device would be given, and therefore which of the two honest
    // things to say about the art it is not seeing.
    let profile = profile_for(limits.max_dimension);
    let note = super::fallback_label(overview_note(profile));
    let shows: Vec<bool> = CATEGORIES.into_iter().map(|kind| filters.shows(kind)).collect();

    commands.entity(world_region).with_children(|parent| {
        parent.spawn((
            OverlayRoot,
            // A modal, which is what suppresses movement, casting and targeting while it
            // is open — the same rule a dialog uses, and stated once rather than in every
            // gameplay system.
            super::controls::Modal,
            // Above the hotbar and the messages, so the world's own HUD is covered rather
            // than showing through the map.
            GlobalZIndex(10),
            Node {
                position_type: PositionType::Absolute,
                left: Val::Px(space::WIDE),
                top: Val::Px(space::WIDE),
                width: Val::Px(viewport.x),
                height: Val::Px(viewport.y),
                flex_direction: FlexDirection::Column,
                border: UiRect::all(Val::Px(size::BORDER)),
                overflow: Overflow::clip(),
                ..default()
            },
            BackgroundColor(surface::VOID),
            BorderColor::all(surface::EDGE),
            Children::spawn((
                // The heading strip: where this is, and the two view actions.
                Spawn((
                    Node {
                        width: Val::Percent(100.0),
                        flex_direction: FlexDirection::Row,
                        align_items: AlignItems::Center,
                        column_gap: Val::Px(space::TIGHT),
                        padding: UiRect::all(Val::Px(space::SNUG)),
                        ..default()
                    },
                    BackgroundColor(surface::PANEL),
                    Children::spawn((
                        Spawn((
                            Text::new(heading),
                            TextFont { font_size: type_scale::SMALL, ..default() },
                            TextColor(ink::PRIMARY),
                        )),
                        Spawn((
                            Text::new(note),
                            TextFont { font_size: type_scale::MICRO, ..default() },
                            TextColor(ink::MUTED),
                        )),
                        Spawn((
                            super::controls::button(
                                "whole world",
                                super::controls::ControlState::Normal,
                                900,
                            ),
                            super::controls::ControlKey::new("worldmap.reset"),
                            ViewAction::Reset,
                        )),
                        Spawn((
                            super::controls::button(
                                "centre on me",
                                super::controls::ControlState::Normal,
                                901,
                            ),
                            super::controls::ControlKey::new("worldmap.recenter"),
                            ViewAction::Recenter,
                        )),
                    )),
                )),
                // The map itself, with the markers over it.
                Spawn((
                    Node {
                        width: Val::Percent(100.0),
                        flex_grow: 1.0,
                        overflow: Overflow::clip(),
                        ..default()
                    },
                    // Void behind the world, so the world's own fill is what tells you
                    // where the land stops. Filling both the same colour left the edge
                    // legible only through the grid lines crossing it.
                    BackgroundColor(surface::VOID),
                    Children::spawn((
                        // The world's own rectangle and its ten-tile grid, under
                        // everything else: without them this panel is a black field with
                        // dots in it, which is the state this task forbids by name.
                        SpawnIter(outline.into_iter().map(|(rect, is_outline)| {
                            (
                                Node {
                                    position_type: PositionType::Absolute,
                                    left: Val::Px(rect.min.x),
                                    top: Val::Px(rect.min.y),
                                    width: Val::Px(rect.width().max(1.0)),
                                    height: Val::Px(rect.height().max(1.0)),
                                    border: UiRect::all(Val::Px(if is_outline {
                                        size::BORDER
                                    } else {
                                        0.0
                                    })),
                                    ..default()
                                },
                                BackgroundColor(if is_outline {
                                    surface::RAISED
                                } else {
                                    surface::EDGE.with_alpha(0.35)
                                }),
                                BorderColor::all(surface::EDGE),
                                Pickable::IGNORE,
                                WorldMapOutline,
                            )
                        })),
                        SpawnIter(
                            unavailable
                                .clone()
                                .or_else(|| empty.then(|| super::fallback_label("map.empty")))
                                .map(|text| {
                                    (
                                        Node {
                                            position_type: PositionType::Absolute,
                                            left: Val::Px(space::BASE),
                                            top: Val::Px(space::BASE),
                                            ..default()
                                        },
                                        Text::new(text),
                                        TextFont { font_size: type_scale::SMALL, ..default() },
                                        TextColor(ink::MUTED),
                                    )
                                })
                                .into_iter(),
                        ),
                        SpawnIter(markers.into_iter().enumerate().map(|(index, (at, kind))| {
                            (
                                Node {
                                    position_type: PositionType::Absolute,
                                    left: Val::Px(at.x),
                                    top: Val::Px(at.y),
                                    // Big enough to point at. The shape inside is small
                                    // on purpose; the target does not have to be.
                                    width: Val::Px(size::ICON_BUTTON * 0.6),
                                    height: Val::Px(size::ICON_BUTTON * 0.6),
                                    margin: UiRect::axes(
                                        Val::Px(-size::ICON_BUTTON * 0.3),
                                        Val::Px(-size::ICON_BUTTON * 0.3),
                                    ),
                                    align_items: AlignItems::Center,
                                    justify_content: JustifyContent::Center,
                                    ..default()
                                },
                                // A control, so it has hover and focus states and a
                                // tooltip that says what it is. A marker a player cannot
                                // interrogate is a coloured dot.
                                super::controls::interactive(920 + index as u32, true),
                                super::icons::AccessibleName::new(kind.name_key()),
                                super::icons::ShowsTooltip,
                                super::controls::ControlKey::indexed("worldmap.marker", index),
                                WorldMapMarker(kind),
                                children![super::minimap::marker_node(kind)],
                            )
                        })),
                        SpawnIter(self_at.into_iter().map(|at| {
                            (
                                Node {
                                    position_type: PositionType::Absolute,
                                    left: Val::Px(at.x),
                                    top: Val::Px(at.y),
                                    width: Val::Px(SELF_MARK),
                                    height: Val::Px(SELF_MARK),
                                    margin: UiRect::axes(
                                        Val::Px(-SELF_MARK / 2.0),
                                        Val::Px(-SELF_MARK / 2.0),
                                    ),
                                    border: UiRect::all(Val::Px(focus::RING_WIDTH)),
                                    border_radius: BorderRadius::all(Val::Px(SELF_MARK / 2.0)),
                                    ..default()
                                },
                                // A gold ring, larger than any marker and the only unfilled
                                // circle on the map: "where am I" has to be answerable
                                // without reading a legend.
                                BackgroundColor(Color::NONE),
                                BorderColor::all(ink::GOLD),
                                Pickable::IGNORE,
                                SelfMark,
                            )
                        })),
                    )),
                )),
                // The legend, which is also the filter strip: a category with no way to
                // switch it off is a category a player cannot read past.
                Spawn((
                    Node {
                        width: Val::Percent(100.0),
                        flex_direction: FlexDirection::Row,
                        flex_wrap: FlexWrap::Wrap,
                        column_gap: Val::Px(space::TIGHT),
                        row_gap: Val::Px(space::HAIR),
                        padding: UiRect::all(Val::Px(space::SNUG)),
                        ..default()
                    },
                    BackgroundColor(surface::PANEL),
                    Children::spawn(SpawnIter(CATEGORIES.into_iter().enumerate().map(
                        move |(index, kind)| {
                            (
                                legend_toggle(kind, 910 + index as u32),
                                super::controls::Selected(shows[index]),
                                CategoryToggle(kind),
                            )
                        },
                    ))),
                )),
            )),
        ));
    });
}

/// One category in the legend, which is also the filter for it.
///
/// Built here rather than from `controls::button` because it carries the category's own
/// marker beside its name. Five buttons reading "Party", "Merchant", "Quest", "Dungeon"
/// and "Landmark" tell you the categories exist and not which dot on the map is which,
/// which is the one thing a legend is for. `present_controls` owns the fill and the
/// border of anything carrying `Control`, so hover, focus and selection still look
/// exactly like every other control.
fn legend_toggle(kind: MarkerKind, tab_index: u32) -> impl Bundle {
    (
        Node {
            padding: UiRect::axes(Val::Px(space::BASE), Val::Px(space::SNUG)),
            column_gap: Val::Px(space::TIGHT),
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(size::BORDER)),
            ..default()
        },
        super::controls::interactive(tab_index, true),
        super::controls::ControlKey::new(format!(
            "worldmap.filter.{}",
            kind.name_key().rsplit('.').next().unwrap_or_default()
        )),
        children![
            (
                Node {
                    width: Val::Px(size::ICON_BUTTON * 0.4),
                    height: Val::Px(size::ICON_BUTTON * 0.4),
                    align_items: AlignItems::Center,
                    justify_content: JustifyContent::Center,
                    ..default()
                },
                Pickable::IGNORE,
                LegendSwatch(kind),
                children![super::minimap::marker_node(kind)],
            ),
            (
                Text::new(super::fallback_label(kind.name_key())),
                TextFont { font_size: type_scale::SMALL, ..default() },
                TextColor(ink::PRIMARY),
                Pickable::IGNORE,
            ),
        ],
    )
}

/// Marks the world's rectangle or one of its grid lines.
#[derive(Component, Debug, Clone, Copy)]
pub struct WorldMapOutline;

/// Marks where the player is on the map.
#[derive(Component, Debug, Clone, Copy)]
pub struct SelfMark;

/// Marks a legend entry's colour sample, so a test can say the legend and the map agree.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct LegendSwatch(pub MarkerKind);

/// Marks a marker drawn on the world map.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorldMapMarker(pub MarkerKind);

#[cfg(test)]
mod tests {
    use super::*;
    use ao_core::fixtures::{self, Scenario};
    use ao_core::view::MapAvailability;

    const VIEWPORT: Vec2 = Vec2::new(900.0, 600.0);
    const WORLD: Vec2 = Vec2::new(100.0, 100.0);

    fn map_app() -> App {
        let mut app = super::super::testing::shell_app(Vec2::new(1280.0, 832.0));
        app.init_resource::<Asked>()
            .add_systems(Update, record.after(super::super::controls::ControlSet::Present));
        for _ in 0..4 {
            app.update();
        }
        app
    }

    #[derive(Resource, Default)]
    struct Asked(Vec<ao_core::view::Intent>);

    fn record(
        mut messages: MessageReader<super::super::state::IntentMessage>,
        mut asked: ResMut<Asked>,
    ) {
        for message in messages.read() {
            asked.0.push(message.0.clone());
        }
    }

    fn overlay_exists(app: &mut App) -> bool {
        app.world_mut()
            .query_filtered::<Entity, With<OverlayRoot>>()
            .iter(app.world())
            .next()
            .is_some()
    }

    fn overlay_text(app: &mut App) -> Vec<String> {
        let Some(root) =
            app.world_mut().query_filtered::<Entity, With<OverlayRoot>>().iter(app.world()).next()
        else {
            return Vec::new();
        };
        super::super::testing::descendants(app, root)
            .into_iter()
            .filter_map(|entity| app.world().get::<Text>(entity).map(|text| text.0.clone()))
            .collect()
    }

    fn markers_drawn(app: &mut App) -> Vec<MarkerKind> {
        app.world_mut()
            .query::<&WorldMapMarker>()
            .iter(app.world())
            .map(|marker| marker.0)
            .collect()
    }

    #[test]
    fn tab_opens_the_map_and_tab_or_escape_closes_it_once_per_press() {
        use super::super::testing;

        let mut app = map_app();
        assert!(!overlay_exists(&mut app), "the map is open before anyone asked");

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        assert!(app.world().resource::<WorldMapOpen>().0, "Tab did not open the map");
        assert!(overlay_exists(&mut app), "the map is open and nothing was drawn");

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        assert!(!app.world().resource::<WorldMapOpen>().0, "Tab did not close the map");
        assert!(!overlay_exists(&mut app), "the overlay outlived the state that owns it");

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        testing::tap_key(&mut app, KeyCode::Escape);
        app.update();
        assert!(!app.world().resource::<WorldMapOpen>().0, "Escape did not close the map");
    }

    #[test]
    fn focus_navigation_owns_tab_while_it_is_on() {
        // Input-context priority, and the documented trade: F6 turns focus navigation on
        // precisely because Tab is a gameplay key here. While it is on, Tab walks the focus
        // ring and must not also open a map over the control the player is walking to.
        use super::super::testing;

        let mut app = map_app();
        app.world_mut().resource_mut::<super::super::controls::FocusNavigation>().active = true;

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();

        assert!(
            !app.world().resource::<WorldMapOpen>().0,
            "Tab opened the map while focus navigation owned it"
        );

        // And with it off again, Tab is the map's.
        app.world_mut().resource_mut::<super::super::controls::FocusNavigation>().active = false;
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        assert!(app.world().resource::<WorldMapOpen>().0, "Tab stopped opening the map");
    }

    #[test]
    fn closing_and_reopening_keeps_the_view_the_player_arranged() {
        // The session persistence the task asks for, and the reason it is separate from
        // reset: a player who zoomed into a corner and closed the map to fight did not ask
        // to lose the corner.
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let viewport =
            overlay_viewport(app.world().resource::<super::super::shell::AppliedGeometry>())
                .expect("the overlay has a viewport");
        let world = Vec2::new(100.0, 100.0);
        {
            let mut camera = app.world_mut().resource_mut::<WorldMapCamera>();
            let zoomed = zoom_around(camera.view, viewport, world, viewport / 2.0, 4.0);
            camera.set(pan_by(zoomed, viewport, world, Vec2::new(60.0, 40.0)));
        }
        let arranged = app.world().resource::<WorldMapCamera>().view;
        assert!(arranged.scale > fit_scale(viewport, world), "the arrangement did not take");

        // Close and open twice: repeated cycles must not quietly reset it either.
        for _ in 0..2 {
            testing::tap_key(&mut app, KeyCode::Escape);
            app.update();
            app.update();
            testing::tap_key(&mut app, KeyCode::Tab);
            app.update();
            app.update();
        }

        assert_eq!(
            app.world().resource::<WorldMapCamera>().view,
            arranged,
            "reopening the map threw away the view the player had arranged"
        );
    }

    #[test]
    fn tab_while_typing_is_a_character_and_not_a_map() {
        use super::super::testing;

        let mut app = map_app();
        let mut composing = app.world().resource::<UiState>().get().clone();
        composing.chat.composing = true;
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), composing);
        app.update();
        assert!(app.world().resource::<super::super::controls::TextInputActive>().0);

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();

        assert!(!app.world().resource::<WorldMapOpen>().0, "Tab opened the map from a chat box");
    }

    #[test]
    fn nothing_reaches_the_world_while_the_map_is_open() {
        // The suppression this task asks for, checked through a hotbar key: the overlay is
        // a modal, and the gameplay set is gated on that.
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Digit1);
        app.update();
        let before = app.world().resource::<Asked>().0.len();
        assert!(before > 0, "a hotbar key did nothing before the map was involved");

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();
        testing::tap_key(&mut app, KeyCode::Digit1);
        app.update();

        assert_eq!(
            app.world().resource::<Asked>().0.len(),
            before,
            "a hotbar key fired while the map was open: {:?}",
            app.world().resource::<Asked>().0
        );
    }

    #[test]
    fn opening_the_map_releases_an_armed_spell_and_a_drag() {
        use super::super::testing;

        let mut app = map_app();
        app.world_mut().resource_mut::<super::super::spells::ArmedSpell>().0 = Some(3);
        app.world_mut().resource_mut::<super::super::character::DragState>().from = Some(0);

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();

        assert!(
            app.world().resource::<super::super::spells::ArmedSpell>().0.is_none(),
            "a spell stayed armed behind the map"
        );
        assert!(
            !app.world().resource::<super::super::character::DragState>().is_dragging(),
            "a drag survived the map opening over it"
        );
    }

    #[test]
    fn the_rail_is_still_there_to_click_while_the_map_is_open() {
        // The reference workflow: the map covers the world, not the character. A player who
        // opens it has not stopped being interested in their own health.
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let (tab_entity, rect) = app
            .world_mut()
            .query::<(Entity, &super::super::character::RailTabButton)>()
            .iter(app.world())
            .map(|(entity, _)| entity)
            .collect::<Vec<_>>()
            .into_iter()
            .filter_map(|entity| testing::solved_rect(&app, entity).map(|rect| (entity, rect)))
            .next()
            .expect("the rail still has its tabs");
        assert!(rect.width() > 0.0, "a rail control was laid out to nothing");

        let world = testing::settled(&app).world;
        assert!(
            rect.min.x >= world.max.x - 1.0,
            "a rail control moved under the map: {rect:?} against a world ending at {}",
            world.max.x
        );

        // And it still activates.
        app.world_mut().write_message(super::super::controls::Activated {
            entity: tab_entity,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();
        assert!(overlay_exists(&mut app), "activating a rail control closed the map");
    }

    #[test]
    fn the_map_draws_the_region_the_position_and_a_marker_for_each_category() {
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let texts = overlay_text(&mut app);
        assert!(
            texts.iter().any(|text| text.to_lowercase().contains("nix")),
            "the map does not say which region this is: {texts:?}"
        );
        assert!(
            texts.iter().any(|text| text.contains("50,50")),
            "the map does not say where the player is: {texts:?}"
        );

        let drawn = markers_drawn(&mut app);
        for kind in CATEGORIES {
            assert!(drawn.contains(&kind), "{kind:?} was not drawn: {drawn:?}");
        }
        assert!(drawn.contains(&MarkerKind::Player), "the player is not on their own map");
    }

    #[test]
    fn switching_a_category_off_removes_only_its_markers() {
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();
        let before = markers_drawn(&mut app);

        let toggle = app
            .world_mut()
            .query::<(Entity, &CategoryToggle)>()
            .iter(app.world())
            .find(|(_, toggle)| toggle.0 == MarkerKind::Merchant)
            .map(|(entity, _)| entity)
            .expect("the legend has a merchant filter");
        app.world_mut().write_message(super::super::controls::Activated {
            entity: toggle,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();
        app.update();

        let after = markers_drawn(&mut app);
        assert!(!after.contains(&MarkerKind::Merchant), "the merchant filter did nothing");
        assert_eq!(
            after.len(),
            before.len() - 1,
            "switching one category off changed {} markers",
            before.len() - after.len()
        );
    }

    #[test]
    fn reset_and_recentre_are_controls_a_player_can_reach() {
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let reset = app
            .world_mut()
            .query::<(Entity, &ViewAction)>()
            .iter(app.world())
            .find(|(_, action)| **action == ViewAction::Reset)
            .map(|(entity, _)| entity)
            .expect("the map offers a way back to the whole world");

        // Zoom in first, so reset has something to undo.
        let viewport =
            overlay_viewport(app.world().resource::<super::super::shell::AppliedGeometry>())
                .expect("the overlay has a viewport");
        let world = Vec2::new(100.0, 100.0);
        {
            let mut camera = app.world_mut().resource_mut::<WorldMapCamera>();
            let zoomed = zoom_around(camera.view, viewport, world, viewport / 2.0, 4.0);
            camera.set(zoomed);
        }
        let zoomed_scale = app.world().resource::<WorldMapCamera>().view.scale;
        assert!(zoomed_scale > fit_scale(viewport, world), "the zoom did not take");

        app.world_mut().write_message(super::super::controls::Activated {
            entity: reset,
            source: super::super::controls::ActivationSource::Pointer,
        });
        app.update();

        assert_eq!(
            app.world().resource::<WorldMapCamera>().view.scale,
            fit_scale(viewport, world),
            "reset did not return the whole world"
        );
    }

    #[test]
    fn the_map_draws_where_the_player_is_and_the_recentre_button_agrees_with_it() {
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let mark = app
            .world_mut()
            .query_filtered::<&Node, With<SelfMark>>()
            .iter(app.world())
            .map(|node| (node.left, node.top))
            .collect::<Vec<_>>();
        assert_eq!(mark.len(), 1, "the map drew {} marks for one player", mark.len());

        // And it is where the camera says the player is, not a fixed spot on the panel:
        // "centre on me" centred on nothing visible before this existed.
        let player = app.world().resource::<crate::world::LocalPlayer>();
        let at = Vec2::new(player.x as f32, player.y as f32);
        let view = app.world().resource::<WorldMapCamera>().view;
        let viewport =
            overlay_viewport(app.world().resource::<super::super::shell::AppliedGeometry>())
                .expect("a viewport");
        let expected = project(at, view, viewport);
        assert_eq!(mark[0], (Val::Px(expected.x), Val::Px(expected.y)));
    }

    #[test]
    fn the_legend_shows_each_category_in_the_colour_the_map_draws_it() {
        // Five buttons reading "Party", "Merchant", "Quest", "Dungeon" and "Landmark"
        // say the categories exist, not which dot on the map is which.
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let mut swatches = app
            .world_mut()
            .query::<&LegendSwatch>()
            .iter(app.world())
            .map(|swatch| swatch.0)
            .collect::<Vec<_>>();
        swatches.sort_by_key(|kind| format!("{kind:?}"));
        let mut expected = CATEGORIES.to_vec();
        expected.sort_by_key(|kind| format!("{kind:?}"));
        assert_eq!(swatches, expected, "the legend does not sample every category");

        // Every swatch carries the same marker the map draws, so the two cannot drift.
        let drawn = app
            .world_mut()
            .query::<&super::super::minimap::MinimapMarker>()
            .iter(app.world())
            .map(|marker| marker.0)
            .collect::<Vec<_>>();
        for kind in CATEGORIES {
            assert!(drawn.contains(&kind), "no {kind:?} glyph anywhere on the overlay");
        }
    }

    #[test]
    fn the_world_has_an_outline_and_a_grid_that_move_with_the_camera() {
        // The first capture of this overlay was a black field with six dots in it — the
        // unexplained black rectangle this task forbids, drawn by the code meant to prevent
        // one. The outline says where the world is and the grid is what makes a pan or a
        // zoom visible at all.
        let (outline, grid) = outline_and_grid(fit(VIEWPORT, WORLD), VIEWPORT, WORLD);
        assert!(outline.width() > 1.0 && outline.height() > 1.0, "no outline: {outline:?}");
        assert!(grid.len() >= 18, "a hundred tiles at ten apart is eighteen lines: {}", grid.len());
        for line in &grid {
            assert!(
                line.min.x >= outline.min.x - 1.0
                    && line.max.x <= outline.max.x + 1.0
                    && line.min.y >= outline.min.y - 1.0
                    && line.max.y <= outline.max.y + 1.0,
                "a grid line at {line:?} is outside the world at {outline:?}"
            );
        }

        // And it moves with the camera, or the markers would slide over a fixed backdrop.
        let zoomed = zoom_around(fit(VIEWPORT, WORLD), VIEWPORT, WORLD, VIEWPORT / 2.0, 3.0);
        let (bigger, _) = outline_and_grid(zoomed, VIEWPORT, WORLD);
        assert!(
            bigger.width() > outline.width(),
            "zooming in did not grow the world: {} against {}",
            bigger.width(),
            outline.width()
        );

        let panned = pan_by(zoomed, VIEWPORT, WORLD, Vec2::new(80.0, 0.0));
        let (moved, _) = outline_and_grid(panned, VIEWPORT, WORLD);
        assert_ne!(moved.min.x, bigger.min.x, "panning did not move the world under the markers");
    }

    #[test]
    fn a_map_with_nothing_to_describe_draws_no_outline_around_it() {
        // An outline around nothing is a claim that the world is that size.
        use super::super::testing;

        let mut app = map_app();
        let mut offline = app.world().resource::<UiState>().get().clone();
        offline.world_map.availability =
            MapAvailability::Unavailable(ao_core::view::MapUnavailable::Offline);
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), offline);
        app.update();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let outlines = app
            .world_mut()
            .query_filtered::<Entity, With<WorldMapOutline>>()
            .iter(app.world())
            .count();
        assert_eq!(outlines, 0, "an unavailable map drew a world outline anyway");
    }

    #[test]
    fn the_map_says_which_of_the_two_missing_art_stories_applies() {
        // A device that cannot hold the overview will never show it; art that has not been
        // published yet will appear when it is. Collapsing them into "no map" sends someone
        // looking for a setting that does not exist.
        use super::super::testing;

        let mut app = map_app();
        app.world_mut().insert_resource(super::super::scale::TargetLimits::for_device(8192));
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();
        let published = overlay_text(&mut app).join(" | ");
        assert!(
            published.to_lowercase().contains("not published"),
            "a capable device is not told the art is unpublished: {published}"
        );

        let mut app = map_app();
        app.world_mut().insert_resource(super::super::scale::TargetLimits::for_device(512));
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();
        let unsupported = overlay_text(&mut app).join(" | ");
        assert!(
            unsupported.to_lowercase().contains("outline only"),
            "a device below the limit is not told why it never will: {unsupported}"
        );
    }

    #[test]
    fn a_marker_can_be_interrogated_rather_than_only_looked_at() {
        // Hover, focus and a name. A marker a player cannot ask about is a coloured dot.
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let markers: Vec<Entity> = app
            .world_mut()
            .query_filtered::<Entity, With<WorldMapMarker>>()
            .iter(app.world())
            .collect();
        assert!(!markers.is_empty(), "nothing was drawn to interrogate");

        for entity in markers {
            let kind = app.world().get::<WorldMapMarker>(entity).expect("a marker").0;
            assert!(
                app.world().get::<Interaction>(entity).is_some(),
                "{kind:?} cannot be hovered or focused"
            );
            let named = app
                .world()
                .get::<super::super::icons::AccessibleName>(entity)
                .map(|name| name.0.clone())
                .unwrap_or_default();
            assert!(!named.is_empty(), "{kind:?} has no name to read out");
            let readable = super::super::fallback_label(&named);
            assert!(!readable.contains('.'), "{kind:?} would announce a key: {readable}");
            assert!(
                app.world().get::<super::super::icons::ShowsTooltip>(entity).is_some(),
                "{kind:?} says nothing on hover"
            );
        }
    }

    #[test]
    fn an_out_of_date_overview_says_so_and_is_worth_retrying() {
        use ao_core::view::MapUnavailable;
        assert!(
            MapUnavailable::Stale.is_retryable(),
            "an out-of-date map cannot be refreshed, which is the only fix it has"
        );
        let readable = super::super::fallback_label(MapUnavailable::Stale.name_key());
        assert!(!readable.contains('.'), "the stale state would show a key: {readable}");

        use super::super::testing;
        let mut app = map_app();
        let mut stale = app.world().resource::<UiState>().get().clone();
        stale.world_map.availability = MapAvailability::Unavailable(MapUnavailable::Stale);
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), stale);
        app.update();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let shown = overlay_text(&mut app).join(" | ");
        assert!(
            shown.to_lowercase().contains("stale"),
            "an out-of-date overview opened without saying so: {shown}"
        );
        assert!(markers_drawn(&mut app).is_empty(), "a stale overview still drew markers");
    }

    #[test]
    fn an_unavailable_world_map_says_so_rather_than_opening_black() {
        use super::super::testing;

        let mut app = map_app();
        let mut offline = app.world().resource::<UiState>().get().clone();
        offline.world_map.availability =
            MapAvailability::Unavailable(ao_core::view::MapUnavailable::Offline);
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), offline);
        app.update();

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let texts = overlay_text(&mut app);
        assert!(
            texts.iter().any(|text| text.to_lowercase().contains("offline")),
            "an unavailable map opened without saying why: {texts:?}"
        );
        assert!(markers_drawn(&mut app).is_empty(), "an unavailable map still drew markers");
    }

    #[test]
    fn an_empty_world_map_is_labelled_too() {
        use super::super::testing;

        let mut app = map_app();
        let mut bare = app.world().resource::<UiState>().get().clone();
        bare.world_map.markers.clear();
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), bare);
        app.update();

        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let texts = overlay_text(&mut app);
        assert!(
            texts.iter().any(|text| !text.is_empty() && !text.contains('.')),
            "an empty map opened with nothing readable on it: {texts:?}"
        );
        assert!(
            !texts.iter().any(|text| text.starts_with("map.")),
            "a semantic key reached the screen: {texts:?}"
        );
    }

    #[test]
    fn the_session_keeps_running_behind_the_open_map() {
        // The map suppresses what the *player* can send, not what the server can say.
        // A client that stopped applying snapshots while a map was open would look like
        // it had frozen, and would show a stale world the moment the map closed.
        use super::super::testing;

        let mut app = map_app();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();
        let before = markers_drawn(&mut app).len();
        assert!(before > 0, "this test needs markers to start with");

        let mut moved = app.world().resource::<UiState>().get().clone();
        moved.service.phase = ao_core::view::ConnectionPhase::Playing;
        moved.world_map.markers.push(MapMarker { x: 7, y: 9, kind: MarkerKind::Merchant });
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), moved);
        app.update();
        app.update();

        assert_eq!(
            markers_drawn(&mut app).len(),
            before + 1,
            "a snapshot that arrived while the map was open did not reach it"
        );
        assert_eq!(
            app.world().resource::<UiState>().get().service.phase,
            ao_core::view::ConnectionPhase::Playing,
            "the overlay changed the connection state, which is not its to change"
        );
    }

    #[test]
    fn the_map_draws_only_the_markers_the_server_sent() {
        // The rule this task states is that the overlay cannot reveal a hidden NPC, player,
        // objective or resource. What that means in code is that no marker may be
        // *synthesised* from anything else the client happens to know. The snapshot carries
        // five presences — two of them hostile creatures — and clearing the marker list has
        // to empty the map completely, presences and all. A map that drew a dot per
        // presence would look richer and would be telling the player where the monsters
        // are.
        use super::super::testing;

        let mut app = map_app();
        let before = app.world().resource::<UiState>().get().clone();
        assert!(
            before.presences.len() >= 2,
            "this test is vacuous without presences to leak: {}",
            before.presences.len()
        );

        let mut bare = before.clone();
        bare.world_map.markers.clear();
        UiState::set(&mut app.world_mut().resource_mut::<UiState>(), bare);
        app.update();
        testing::tap_key(&mut app, KeyCode::Tab);
        app.update();
        app.update();

        let drawn = markers_drawn(&mut app);
        assert!(
            drawn.is_empty(),
            "the map drew {drawn:?} with an empty marker list and {} presences",
            before.presences.len()
        );

        let selves =
            app.world_mut().query_filtered::<Entity, With<SelfMark>>().iter(app.world()).count();
        assert_eq!(selves, 1, "the player's own position is theirs to see: {selves}");
    }

    #[test]
    fn the_manifest_states_the_budget_the_client_compiles_in() {
        // The manifest is the entry the production asset has to fit. If it and the client
        // can disagree, the budget is a comment.
        let number = |key: &str| -> u64 {
            manifest_field(key)
                .unwrap_or_else(|| panic!("the manifest does not state {key}"))
                .parse()
                .unwrap_or_else(|_| panic!("{key} is not a number"))
        };
        assert_eq!(number("max-dimension"), OVERVIEW_MAX_DIMENSION as u64);
        assert_eq!(number("reduced-dimension"), OVERVIEW_REDUCED_DIMENSION as u64);
        assert_eq!(number("bytes-per-pixel"), OVERVIEW_BYTES_PER_PIXEL);
        assert_eq!(number("max-compressed-bytes"), OVERVIEW_MAX_COMPRESSED_BYTES);
        assert_eq!(
            number("decoded-bytes"),
            OverviewProfile::Full { dimension: OVERVIEW_MAX_DIMENSION }.decoded_bytes()
        );
        assert_eq!(
            number("reduced-decoded-bytes"),
            OverviewProfile::Reduced { dimension: OVERVIEW_REDUCED_DIMENSION }.decoded_bytes()
        );

        // A licence and a source, because an asset with neither cannot be shipped.
        for key in ["id", "path", "source", "licence", "below-reduced"] {
            let value = manifest_field(key).unwrap_or("");
            assert!(!value.is_empty(), "the manifest does not state {key}");
        }

        // Its own entry, not the gameplay world pack. Drawing the overview from the pack
        // is the thing this budget exists to prevent.
        let path = manifest_field("path").unwrap_or_default();
        assert!(
            path.starts_with("world-map/"),
            "the overview points at {path}, which is not its own asset"
        );
        assert_eq!(
            manifest_field("below-reduced"),
            Some("outline"),
            "a device below the reduced profile must fall back to the outline"
        );
    }

    #[test]
    fn a_device_gets_the_largest_overview_it_can_actually_hold() {
        // Keyed off the device's own texture limit, which is the same number the world
        // render target is bounded by. Guessing from the user agent is how a client ends up
        // asking a phone for sixteen megabytes.
        assert_eq!(profile_for(8192), OverviewProfile::Full { dimension: OVERVIEW_MAX_DIMENSION });
        assert_eq!(
            profile_for(OVERVIEW_MAX_DIMENSION),
            OverviewProfile::Full { dimension: OVERVIEW_MAX_DIMENSION },
            "a device at exactly the limit can hold the full asset"
        );
        assert_eq!(
            profile_for(OVERVIEW_MAX_DIMENSION - 1),
            OverviewProfile::Reduced { dimension: OVERVIEW_REDUCED_DIMENSION }
        );
        assert_eq!(
            profile_for(OVERVIEW_REDUCED_DIMENSION - 1),
            OverviewProfile::Outline,
            "a device below the reduced limit gets the outline rather than a broken texture"
        );
        assert_eq!(profile_for(0), OverviewProfile::Outline);
    }

    #[test]
    fn the_overview_budget_is_the_one_the_documentation_states() {
        // Sixteen megabytes at the full profile, four at the reduced one, nothing for the
        // outline. Written as a test because a budget in a comment is a wish.
        assert_eq!(
            OverviewProfile::Full { dimension: OVERVIEW_MAX_DIMENSION }.decoded_bytes(),
            16 * 1024 * 1024
        );
        assert_eq!(
            OverviewProfile::Reduced { dimension: OVERVIEW_REDUCED_DIMENSION }.decoded_bytes(),
            4 * 1024 * 1024
        );
        assert_eq!(OverviewProfile::Outline.decoded_bytes(), 0);

        // And the wire ceiling is smaller than what the world pack costs, which is the
        // whole reason this is a separate asset.
        assert!(OVERVIEW_MAX_COMPRESSED_BYTES < 4 * 1024 * 1024);
    }

    #[test]
    fn the_overlay_never_asks_for_the_gameplay_world_pack() {
        // The invariant this asset exists for, checked against the source: nothing in the
        // overlay reaches for the pack, the map loader or a tile sheet. A world overview
        // decoded out of gameplay data would trade a fixed cost for an unbounded one.
        // The production half only: this test names the forbidden words, so reading the
        // whole file would find them in its own list.
        let whole = include_str!("worldmap.rs");
        let source = whole.split("#[cfg(test)]").next().expect("a production half");
        for forbidden in ["world_pack", "PackedMap", "LoadedMap", "SheetTextures", "resolve_grh"] {
            assert!(
                !source.contains(forbidden),
                "the overlay reaches for {forbidden}, which belongs to the gameplay pack"
            );
        }
    }

    #[test]
    fn the_whole_world_fits_and_the_spare_axis_is_letterboxed() {
        // The smaller ratio, so nothing is cropped. A map that hides a corner of the world
        // is answering a different question than the one the player asked.
        let view = fit(VIEWPORT, WORLD);
        assert_eq!(view.scale, 6.0, "the fit is not the smaller of the two ratios");
        assert_eq!(view.centre, Vec2::new(50.0, 50.0));

        // The world is 600 wide at that scale in a 900-wide viewport: 300 pixels of
        // letterbox, 150 each side.
        let left = project(Vec2::new(0.0, 0.0), view, VIEWPORT);
        let right = project(WORLD, view, VIEWPORT);
        assert_eq!(left.x, 150.0);
        assert_eq!(right.x, 750.0);
        assert_eq!(left.y, 0.0, "the fitted axis should touch the top");
        assert_eq!(right.y, 600.0);
    }

    #[test]
    fn a_player_cannot_zoom_out_past_the_whole_world() {
        let out = zoom_around(fit(VIEWPORT, WORLD), VIEWPORT, WORLD, VIEWPORT / 2.0, -20.0);
        assert_eq!(out.scale, fit_scale(VIEWPORT, WORLD), "zoomed out past the world");
    }

    #[test]
    fn zoom_is_bounded_in_both_directions_however_absurd_the_delta() {
        let deep = zoom_around(fit(VIEWPORT, WORLD), VIEWPORT, WORLD, VIEWPORT / 2.0, 1e9);
        assert!(deep.scale.is_finite(), "an absurd wheel produced {}", deep.scale);
        assert!(deep.scale <= MAX_PIXELS_PER_TILE, "zoomed past the maximum: {}", deep.scale);

        let mad = zoom_around(fit(VIEWPORT, WORLD), VIEWPORT, WORLD, VIEWPORT / 2.0, f32::NAN);
        assert!(mad.scale.is_finite() && mad.centre.is_finite(), "a NaN wheel poisoned the view");
    }

    #[test]
    fn zooming_keeps_the_tile_under_the_cursor_where_it_is() {
        // What makes a map feel like a map. Zooming about the middle drifts whatever the
        // player was looking at off the screen.
        // A square viewport, and zoomed in far enough that neither axis is letterboxed:
        // while an axis still shows the whole world it is *centred*, and no anchoring can
        // survive that — which is the rule the test below states.
        let viewport = Vec2::splat(600.0);
        let start = clamp(MapView { centre: Vec2::splat(50.0), scale: 6.0 }, viewport, WORLD);
        let anchor = Vec2::new(400.0, 400.0);
        let before = unproject(anchor, start, viewport);

        let zoomed = zoom_around(start, viewport, WORLD, anchor, 3.0);
        let after = unproject(anchor, zoomed, viewport);

        assert!(zoomed.scale > start.scale, "the zoom did not go in");
        assert!(
            (after - before).length() < 0.75,
            "the tile under the cursor moved from {before:?} to {after:?}"
        );
    }

    #[test]
    fn keeping_the_world_in_frame_outranks_keeping_the_cursor_still() {
        // Zooming with the cursor near the world's edge cannot do both: holding the tile
        // under the cursor would require showing space beyond the world. The frame wins,
        // and the map slides — which is what every map does at its border.
        let start = clamp(MapView { centre: Vec2::splat(50.0), scale: 6.0 }, VIEWPORT, WORLD);
        let anchor = Vec2::new(740.0, 100.0);

        let zoomed = zoom_around(start, VIEWPORT, WORLD, anchor, 3.0);
        let half = VIEWPORT / (2.0 * zoomed.scale);

        assert!(zoomed.centre.is_finite(), "an edge zoom produced {:?}", zoomed.centre);
        assert!(
            zoomed.centre.x <= WORLD.x - half.x + 0.01 || half.x * 2.0 >= WORLD.x,
            "the zoom showed space beyond the world: {:?}",
            zoomed.centre
        );
    }

    #[test]
    fn panning_cannot_drag_the_world_out_of_the_frame() {
        let zoomed = zoom_around(fit(VIEWPORT, WORLD), VIEWPORT, WORLD, VIEWPORT / 2.0, 3.0);
        let far = pan_by(zoomed, VIEWPORT, WORLD, Vec2::splat(-1e6));
        let half = VIEWPORT / (2.0 * far.scale);

        assert!(far.centre.is_finite(), "panning produced {:?}", far.centre);
        assert!(
            far.centre.x <= WORLD.x - half.x + 0.01 && far.centre.x >= half.x - 0.01,
            "the world was dragged out of frame: {:?}",
            far.centre
        );
    }

    #[test]
    fn a_zero_sized_world_and_a_zero_sized_viewport_produce_no_infinities() {
        // The malformed fixture sends a zero-sized world, and a hidden overlay has a
        // zero-sized viewport for one frame while the shell is laid out.
        for viewport in [Vec2::ZERO, Vec2::new(1.0, 0.0), VIEWPORT] {
            for world in [Vec2::ZERO, Vec2::new(0.0, 100.0), WORLD] {
                let view = fit(viewport, world);
                assert!(
                    view.scale.is_finite() && view.scale > 0.0 && view.centre.is_finite(),
                    "fit({viewport:?}, {world:?}) produced {view:?}"
                );
                let clamped = clamp(view, viewport, world);
                assert!(
                    clamped.scale.is_finite() && clamped.centre.is_finite(),
                    "clamp({viewport:?}, {world:?}) produced {clamped:?}"
                );
                let projected = project(Vec2::splat(10.0), clamped, viewport);
                assert!(projected.is_finite(), "projection produced {projected:?}");
            }
        }
    }

    #[test]
    fn a_malformed_view_falls_back_to_the_last_one_that_worked() {
        // Not to the fit: reset is a deliberate return to the whole world, and losing an
        // arrangement the player made because one frame was malformed is a different and
        // worse thing.
        let mut camera = WorldMapCamera::default();
        let good = clamp(MapView { centre: Vec2::new(30.0, 40.0), scale: 8.0 }, VIEWPORT, WORLD);
        camera.set(good);

        camera.set(MapView { centre: Vec2::new(f32::NAN, 0.0), scale: 8.0 });
        assert_eq!(camera.view, good, "a malformed frame replaced a good view");

        camera.set(MapView { centre: Vec2::splat(10.0), scale: f32::INFINITY });
        assert_eq!(camera.view, good, "an infinite scale replaced a good view");
    }

    #[test]
    fn reset_always_returns_the_whole_world() {
        let mut camera = WorldMapCamera::default();
        camera.set(clamp(MapView { centre: Vec2::splat(10.0), scale: 12.0 }, VIEWPORT, WORLD));
        camera.reset(VIEWPORT, WORLD);
        assert_eq!(camera.view, fit(VIEWPORT, WORLD));
    }

    #[test]
    fn the_players_own_marker_cannot_be_filtered_away() {
        // A map that can hide where you are is a map you can get lost on while looking at
        // it.
        let mut filters = CategoryFilters::default();
        for kind in CATEGORIES {
            filters.toggle(kind);
        }
        assert!(filters.shows(MarkerKind::Player), "the player's own marker was filtered out");
        assert!(!filters.shows(MarkerKind::Merchant), "a category refused to switch off");
    }

    #[test]
    fn filtering_changes_what_is_drawn_and_nothing_else() {
        let map = fixtures::snapshot(Scenario::Populated).world_map;
        let mut filters = CategoryFilters::default();
        let before = drawn_markers(&map, &filters).len();
        assert!(before >= 5, "the fixture has too few markers to filter: {before}");

        filters.toggle(MarkerKind::Merchant);
        let hidden = drawn_markers(&map, &filters).len();
        assert_eq!(
            hidden,
            before - 1,
            "switching one category off hid {} markers",
            before - hidden
        );

        filters.toggle(MarkerKind::Merchant);
        assert_eq!(
            drawn_markers(&map, &filters).len(),
            before,
            "switching a category back on lost a marker"
        );
        assert_eq!(
            map.markers.len(),
            before,
            "filtering changed the markers themselves rather than what is drawn"
        );
    }

    #[test]
    fn every_category_has_a_name_and_a_distinct_key() {
        let mut seen: Vec<String> = Vec::new();
        for kind in CATEGORIES {
            let key = kind.name_key();
            let readable = super::super::fallback_label(key);
            assert!(!readable.contains('.'), "{kind:?} would show a key: {readable}");
            assert!(!seen.contains(&key.to_string()), "{kind:?} reuses {key}");
            seen.push(key.to_string());
        }
    }
}
