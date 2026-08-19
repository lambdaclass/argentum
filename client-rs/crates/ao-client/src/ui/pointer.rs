//! One coordinate pipeline, from pointer position to tile.
//!
//! Every transform between a cursor and a tile is applied here, exactly once:
//! the world camera's viewport offset, the device pixel ratio, the world zoom
//! and the flip between screen and world axes. Applying any of them twice, or
//! in the wrong order, produces a click that lands a tile or two from where the
//! player aimed — which reads as lag or as a broken hit box, and is nearly
//! impossible to diagnose from a screenshot.
//!
//! It is also where the UI intercepts. A click on the character rail must not
//! also select a tile behind it, and that decision belongs in one place rather
//! than being re-derived by every panel.
//!
//! Pure, so the edges can be tested exhaustively: centre, one pixel inside each
//! boundary, one pixel outside, at every device pixel ratio a player is likely
//! to have.

use super::layout::{ShellGeometry, TILE_SIZE};
use super::scale::ScaleDomains;
use bevy::prelude::*;

/// What a pointer position refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PointerTarget {
    /// Over the world viewport: the world may act on it.
    World,
    /// Over the top bar or the character rail. The world must not see it.
    Interface,
    /// Outside the client entirely, which a browser still reports during a
    /// drag that leaves the window.
    Outside,
}

/// Put the cursor in the same units as the layout.
///
/// A guard, currently a no-op, kept for the failure it prevents. Overriding the
/// window's scale factor makes the window report one unit while `cursor_position`
/// keeps dividing the backend's physical cursor by the *override*, so the two
/// disagree by the real ratio: with the factor pinned to 1 on a 2x display, a click
/// 400 pixels from the left edge was treated as 800 and landed in the character
/// rail instead of the world.
///
/// The error is exactly zero at ratio 1, which is why it survived every test until
/// clicks were driven in a browser at 1.25x. `track_host_canvas` no longer
/// overrides anything, so `base` and `applied` are equal and this returns 1.0 —
/// and if an override is ever reintroduced, the cursor stays correct.
fn cursor_correction(window: &Window) -> f32 {
    let reported = window.resolution.base_scale_factor();
    let applied = window.resolution.scale_factor();
    if reported > 0.0 && applied > 0.0 {
        applied / reported
    } else {
        1.0
    }
}

/// Decide what a logical-pixel pointer position is over.
///
/// The world is checked against the *view* rectangle rather than the whole
/// world region, because a capped display leaves a cosmetic perimeter that is
/// not world and must not be clickable as though it were.
pub fn target_at(pointer: Vec2, geometry: ShellGeometry, view: Rect) -> PointerTarget {
    let window = Rect::from_corners(Vec2::ZERO, geometry.rail.max);
    if !contains(window, pointer) {
        return PointerTarget::Outside;
    }
    if contains(view, pointer) {
        return PointerTarget::World;
    }
    PointerTarget::Interface
}

/// A control under the pointer wins, even inside the world's rectangle.
///
/// The geometric classification above cannot answer this: the hotbar is anchored to
/// the bottom centre of the *world viewport*, so every one of its slots is inside the
/// world rectangle and classified as world. The consequence is not subtle — a click
/// meant for a potion also selected the ground under it, so one click both drank and
/// walked. The same applies to anything else the shell floats over the world.
///
/// Kept as a function of the two facts rather than folded into `target_at`, because
/// `target_at` is pure geometry that a test can sweep exhaustively, while "is a
/// control under the pointer" is a question only the running interface can answer.
pub fn intercept(geometric: PointerTarget, over_control: bool) -> PointerTarget {
    match geometric {
        PointerTarget::World if over_control => PointerTarget::Interface,
        other => other,
    }
}

/// Half-open containment.
///
/// A rectangle owns its left and top edges and not its right and bottom, so
/// adjacent regions cannot both claim the pixel between them. Inclusive
/// containment is why a click on the seam between world and rail could
/// activate both.
fn contains(rect: Rect, point: Vec2) -> bool {
    point.x >= rect.min.x && point.x < rect.max.x && point.y >= rect.min.y && point.y < rect.max.y
}

/// World position under a logical-pixel pointer position.
///
/// `camera_centre` is the world point the camera is looking at, which follows
/// the player's interpolated position.
pub fn world_position_at(
    pointer: Vec2,
    view: Rect,
    domains: ScaleDomains,
    camera_centre: Vec2,
) -> Vec2 {
    // Logical pixels per world unit. Not the device ratio: that is applied
    // once, at the camera viewport, and applying it again here is the classic
    // double-scaling bug that makes clicks drift further from the cursor the
    // further they are from the centre.
    let per_world_unit = domains.world as f32;

    let from_centre = pointer - view.center();
    // Screen y grows downward and world y grows upward.
    camera_centre + Vec2::new(from_centre.x, -from_centre.y) / per_world_unit
}

/// Where a world position lands on screen, in logical pixels.
///
/// The inverse of [`world_position_at`], and here rather than in the panel that needs it
/// for the reason this module exists: every transform between the world and the screen is
/// applied in one place, exactly once. A label that computed its own position would be a
/// second copy of the device ratio and the zoom.
pub fn screen_of_world(
    world: Vec2,
    view: Rect,
    domains: ScaleDomains,
    camera_centre: Vec2,
) -> Vec2 {
    let per_world_unit = domains.world as f32;
    let from_centre = (world - camera_centre) * per_world_unit;
    // Screen y grows downward and world y grows upward, the same flip as the forward
    // direction and the one thing that must not be applied twice.
    view.center() + Vec2::new(from_centre.x, -from_centre.y)
}

/// The centre of a tile, in world units.
///
/// `tile_to_world` gives a tile's top-left corner, which is where a sprite is anchored. A
/// label belongs over the middle of the thing it names.
pub fn tile_centre(tile: IVec2) -> Vec2 {
    tile_to_world(tile) + Vec2::new(TILE_SIZE / 2.0, -TILE_SIZE / 2.0)
}

/// Tile containing a world position.
///
/// Tiles are addressed from 1 and `tile_to_world` returns a tile's top-left
/// corner, so this is its inverse: floor, then shift the origin.
pub fn world_to_tile(world: Vec2) -> IVec2 {
    IVec2::new((world.x / TILE_SIZE).floor() as i32 + 1, (-world.y / TILE_SIZE).floor() as i32 + 1)
}

/// Top-left corner of a tile, in world units. Mirrors `world::tile_to_world`.
pub fn tile_to_world(tile: IVec2) -> Vec2 {
    Vec2::new((tile.x - 1) as f32 * TILE_SIZE, -((tile.y - 1) as f32) * TILE_SIZE)
}

/// Tile under a pointer, or `None` when the pointer is not over the world.
pub fn tile_at(
    pointer: Vec2,
    geometry: ShellGeometry,
    view: Rect,
    domains: ScaleDomains,
    camera_centre: Vec2,
) -> Option<IVec2> {
    if target_at(pointer, geometry, view) != PointerTarget::World {
        return None;
    }
    Some(world_to_tile(world_position_at(pointer, view, domains, camera_centre)))
}

/// Where the pointer is, resolved once per frame.
///
/// A resource rather than each panel querying the cursor itself: the transforms
/// below have to be applied exactly once, and every additional caller is
/// another chance to apply the device ratio twice.
#[derive(Resource, Debug, Clone, Copy, Default)]
pub struct PointerState {
    /// Logical position, if the pointer is in the window at all.
    pub position: Option<Vec2>,
    pub target: Option<PointerTarget>,
    /// The tile under the pointer, when it is over the world.
    pub tile: Option<IVec2>,
}

impl PointerState {
    /// Whether the world may act on the pointer this frame.
    pub fn over_world(&self) -> bool {
        self.target == Some(PointerTarget::World)
    }
}

pub struct PointerPlugin;

impl Plugin for PointerPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<PointerState>().add_systems(Update, resolve_pointer);
    }
}

fn resolve_pointer(
    windows: Query<&Window>,
    applied: Res<super::shell::AppliedGeometry>,
    domains: Res<ScaleDomains>,
    cameras: Query<&Transform, With<super::shell::WorldCamera>>,
    // Interaction rather than the hover map: it is the same state the controls
    // themselves act on, so the world and the interface cannot disagree about which of
    // them the pointer is over. Only controls count — the world region is a UI node
    // too, and treating every hovered node as interface would make the world
    // permanently unclickable.
    controls: Query<&Interaction, With<super::controls::Control>>,
    mut pointer: ResMut<PointerState>,
) {
    let Ok(window) = windows.single() else {
        return;
    };

    // Before the first layout there is no world rectangle to resolve against,
    // and guessing one would report a tile under a pointer that is over nothing.
    let Some(geometry) = applied.0 else {
        *pointer = PointerState::default();
        return;
    };
    let view = super::layout::world_view(geometry.world).rect;

    let Some(position) = window.cursor_position() else {
        // The pointer left the window. Reported as absent rather than stale, so
        // a drag cannot keep tracking a cursor that is no longer there.
        *pointer = PointerState::default();
        return;
    };
    let position = position * cursor_correction(window);

    let camera_centre =
        cameras.iter().next().map(|t| t.translation.truncate()).unwrap_or(Vec2::ZERO);
    let over_control = controls.iter().any(|interaction| !matches!(interaction, Interaction::None));
    let target = intercept(target_at(position, geometry, view), over_control);

    *pointer = PointerState {
        position: Some(position),
        target: Some(target),
        tile: (target == PointerTarget::World)
            .then(|| world_to_tile(world_position_at(position, view, *domains, camera_centre))),
    };
}

#[cfg(test)]
mod tests {
    use super::super::layout;
    use super::*;

    /// Every inventory slot in the real tree, with the rectangle it occupies.
    fn solved_slots(app: &mut App) -> Vec<(Entity, Rect)> {
        use super::super::character::InventorySlotButton;
        use super::super::testing;

        let entities: Vec<Entity> = app
            .world_mut()
            .query_filtered::<Entity, With<InventorySlotButton>>()
            .iter(app.world())
            .collect();
        entities
            .into_iter()
            .filter_map(|entity| testing::solved_rect(app, entity).map(|rect| (entity, rect)))
            .collect()
    }

    /// What the interaction pipeline says is under the pointer.
    fn hovered(app: &mut App) -> Vec<Entity> {
        use super::super::controls::Control;
        let mut found: Vec<Entity> = app
            .world_mut()
            .query::<(Entity, &Control)>()
            .iter(app.world())
            .filter(|(_, control)| control.hovered)
            .map(|(entity, _)| entity)
            .collect();
        found.sort();
        found
    }

    #[test]
    fn a_click_on_the_interface_is_never_also_a_click_on_the_world() {
        // The rule that keeps a click on the rail from also swinging a sword.
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        let geometry = testing::settled(&app);

        for inside_ui in [
            geometry.rail.center(),
            geometry.top_bar.center(),
            Vec2::new(geometry.rail.min.x + 1.0, geometry.rail.center().y),
        ] {
            testing::move_pointer(&mut app, inside_ui);
            let state = app.world().resource::<PointerState>();
            assert_ne!(
                state.target,
                Some(PointerTarget::World),
                "{inside_ui:?} is over the interface but was reported as the world"
            );
            assert!(
                state.tile.is_none(),
                "{inside_ui:?} is over the interface but named a world tile"
            );
        }
    }

    #[test]
    fn a_control_floating_over_the_world_takes_the_click_from_it() {
        // The hotbar is anchored to the bottom centre of the world viewport, so every
        // slot sits inside the world rectangle. Geometry alone therefore calls it
        // world, and one click drank a potion *and* walked onto the tile underneath.
        //
        // Driven through the production system with the control hovered, because the
        // rule is about the running interface: a headless picking backend has no render
        // target to hover anything through, which is why the browser suite checks the
        // same thing from the outside.
        use super::super::testing;

        let mut app = testing::shell_app(Vec2::new(1280.0, 832.0));
        let geometry = testing::settled(&app);
        let over_world = geometry.world.center();

        testing::move_pointer(&mut app, over_world);
        assert_eq!(
            app.world().resource::<PointerState>().target,
            Some(PointerTarget::World),
            "the centre of the world is not over the world"
        );

        let slot = app
            .world_mut()
            .query_filtered::<Entity, With<super::super::hotbar::HotbarSlot>>()
            .iter(app.world())
            .next()
            .expect("the shell has hotbar slots");
        *app.world_mut().get_mut::<Interaction>(slot).expect("a slot is interactive") =
            Interaction::Hovered;
        // The production system, run directly rather than through a frame: Bevy's
        // picking backend rewrites `Interaction` from its hover map every update, and
        // headless there is no render target to hover anything through — so a whole
        // frame would clear the state under test. The system is the real one; only its
        // scheduling belongs to the test.
        use bevy::ecs::system::RunSystemOnce;
        app.world_mut().run_system_once(resolve_pointer).expect("the system runs");

        let state = *app.world().resource::<PointerState>();
        assert_eq!(
            state.target,
            Some(PointerTarget::Interface),
            "a hovered control did not take the pointer from the world"
        );
        assert!(state.tile.is_none(), "an intercepted pointer still named a tile");
        assert!(!state.over_world(), "the world would still act on this click");
    }

    #[test]
    fn interception_leaves_the_interface_and_the_outside_alone() {
        // The rule only ever takes the world's side away. A control cannot make a
        // pointer that is outside the window into an interface pointer, and the
        // interface staying the interface is not something to re-decide.
        for geometric in [PointerTarget::Interface, PointerTarget::Outside] {
            assert_eq!(intercept(geometric, true), geometric);
            assert_eq!(intercept(geometric, false), geometric);
        }
        assert_eq!(intercept(PointerTarget::World, false), PointerTarget::World);
        assert_eq!(intercept(PointerTarget::World, true), PointerTarget::Interface);
    }

    /// Ratios a real user is likely to have.
    const RATIOS: [f32; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

    /// Window sizes standing in for windowed, maximised and fullscreen.
    const SIZES: [(&str, Vec2); 3] = [
        ("windowed", Vec2::new(1280.0, 832.0)),
        ("maximized", Vec2::new(1920.0, 1080.0)),
        ("fullscreen", Vec2::new(2560.0, 1440.0)),
    ];


    /// The world's share of a window, as the shell lays it out.
    fn world_region_of(window: Vec2) -> Vec2 {
        layout::shell_geometry(window).world.size()
    }

    fn scene(size: Vec2, ratio: f32) -> (ShellGeometry, Rect, ScaleDomains) {
        let geometry = layout::shell_geometry(size);
        let view = layout::world_view(geometry.world).rect;
        let domains = super::super::scale::resolve(size, world_region_of(size), ratio);
        (geometry, view, domains)
    }

    #[test]
    fn a_click_on_the_rail_never_reaches_the_world() {
        // The interception rule. Without it, opening a panel also selects
        // whatever tile happens to be behind it.
        for (name, size) in SIZES {
            let (geometry, view, domains) = scene(size, 1.0);
            let on_rail = geometry.rail.center();

            assert_eq!(target_at(on_rail, geometry, view), PointerTarget::Interface, "{name}");
            assert_eq!(tile_at(on_rail, geometry, view, domains, Vec2::ZERO), None, "{name}");
        }
    }

    #[test]
    fn a_click_on_the_top_bar_never_reaches_the_world() {
        for (name, size) in SIZES {
            let (geometry, view, _) = scene(size, 1.0);
            assert_eq!(
                target_at(geometry.top_bar.center(), geometry, view),
                PointerTarget::Interface,
                "{name}"
            );
        }
    }

    #[test]
    fn the_seam_between_world_and_rail_belongs_to_exactly_one_of_them() {
        // Inclusive containment on both sides means the pixel between two
        // regions activates both, which is how a click near the rail's edge
        // both opened a panel and moved the player.
        for (name, size) in SIZES {
            let (geometry, view, _) = scene(size, 1.0);
            let seam_y = view.center().y;

            let last_world = Vec2::new(view.max.x - 1.0, seam_y);
            let first_rail = Vec2::new(view.max.x, seam_y);

            assert_eq!(target_at(last_world, geometry, view), PointerTarget::World, "{name}");
            assert_ne!(target_at(first_rail, geometry, view), PointerTarget::World, "{name}");
        }
    }

    #[test]
    fn every_edge_of_the_world_viewport_is_classified_correctly() {
        // One pixel inside is world, one pixel outside is not — checked on all
        // four edges, which is where an off-by-one hides.
        for (name, size) in SIZES {
            let (geometry, view, _) = scene(size, 1.0);
            let centre = view.center();

            let inside = [
                Vec2::new(view.min.x, centre.y),
                Vec2::new(view.max.x - 1.0, centre.y),
                Vec2::new(centre.x, view.min.y),
                Vec2::new(centre.x, view.max.y - 1.0),
            ];
            for point in inside {
                assert_eq!(
                    target_at(point, geometry, view),
                    PointerTarget::World,
                    "{name} {point:?}"
                );
            }

            let outside = [
                Vec2::new(view.min.x - 1.0, centre.y),
                Vec2::new(view.max.x, centre.y),
                Vec2::new(centre.x, view.min.y - 1.0),
                Vec2::new(centre.x, view.max.y),
            ];
            for point in outside {
                assert_ne!(
                    target_at(point, geometry, view),
                    PointerTarget::World,
                    "{name} {point:?}"
                );
            }
        }
    }

    #[test]
    fn a_pointer_outside_the_window_is_reported_as_outside() {
        // Browsers keep reporting positions during a drag that leaves the
        // window, and treating those as world clicks teleports the selection.
        let (geometry, view, _) = scene(Vec2::new(1280.0, 832.0), 1.0);

        for point in [Vec2::new(-5.0, 400.0), Vec2::new(400.0, -5.0), Vec2::new(5000.0, 400.0)] {
            assert_eq!(target_at(point, geometry, view), PointerTarget::Outside, "{point:?}");
        }
    }

    #[test]
    fn the_centre_of_the_viewport_is_the_tile_the_camera_looks_at() {
        // The anchor for everything else. If this is wrong, every click is
        // wrong by the same amount and it looks like a calibration problem
        // rather than a maths one.
        for (name, size) in SIZES {
            for ratio in RATIOS {
                let (geometry, view, domains) = scene(size, ratio);
                let camera = tile_centre(IVec2::new(50, 50));

                let tile = tile_at(view.center(), geometry, view, domains, camera);
                assert_eq!(tile, Some(IVec2::new(50, 50)), "{name} at {ratio}x");
            }
        }
    }

    #[test]
    fn a_device_pixel_ratio_change_does_not_move_the_tile_under_the_pointer() {
        // The pointer arrives in logical pixels and the ratio is applied once,
        // at the camera. Applying it again here makes clicks drift further
        // from the cursor the further they are from the centre.
        let size = Vec2::new(1920.0, 1080.0);
        let camera = tile_to_world(IVec2::new(50, 50));

        let (geometry, view, baseline) = scene(size, 1.0);
        let probes = [
            view.center(),
            view.center() + Vec2::new(200.0, 0.0),
            view.center() - Vec2::new(0.0, 150.0),
            view.min + Vec2::splat(3.0),
        ];
        let expected: Vec<_> =
            probes.iter().map(|p| tile_at(*p, geometry, view, baseline, camera)).collect();

        for ratio in RATIOS {
            let (geometry, view, domains) = scene(size, ratio);
            for (probe, want) in probes.iter().zip(&expected) {
                assert_eq!(
                    tile_at(*probe, geometry, view, domains, camera),
                    *want,
                    "{ratio}x moved the tile under {probe:?}"
                );
            }
        }
    }

    #[test]
    fn a_tile_maps_back_to_itself_through_the_whole_pipeline() {
        // Round trip: take a tile, find where it is drawn, click there, get the
        // same tile. Catches a sign error or a half-tile offset that a
        // one-directional test would not.
        for (name, size) in SIZES {
            for ratio in RATIOS {
                let (geometry, view, domains) = scene(size, ratio);
                let camera = tile_centre(IVec2::new(50, 50));

                for tile in
                    [IVec2::new(50, 50), IVec2::new(48, 47), IVec2::new(53, 52), IVec2::new(50, 45)]
                {
                    // Centre of the tile, in world units.
                    let world = tile_to_world(tile) + Vec2::new(TILE_SIZE / 2.0, -TILE_SIZE / 2.0);
                    // Where that lands on screen.
                    let offset = (world - camera) * domains.world as f32;
                    let screen = view.center() + Vec2::new(offset.x, -offset.y);

                    assert_eq!(
                        tile_at(screen, geometry, view, domains, camera),
                        Some(tile),
                        "{name} at {ratio}x lost tile {tile:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn adjacent_screen_pixels_never_skip_a_tile() {
        // Walking across the viewport a pixel at a time, the tile index may
        // repeat or advance by one, never jump. A jump means the scale is
        // wrong and some tiles cannot be clicked at all.
        let size = Vec2::new(1920.0, 1080.0);
        for ratio in RATIOS {
            let (geometry, view, domains) = scene(size, ratio);
            let camera = tile_to_world(IVec2::new(50, 50));

            let y = view.center().y;
            let mut previous: Option<i32> = None;
            let mut x = view.min.x;
            while x < view.max.x {
                if let Some(tile) = tile_at(Vec2::new(x, y), geometry, view, domains, camera) {
                    if let Some(last) = previous {
                        let step = tile.x - last;
                        assert!(
                            (0..=1).contains(&step),
                            "{ratio}x jumped {step} tiles between {}px and {}px",
                            x - 1.0,
                            x
                        );
                    }
                    previous = Some(tile.x);
                }
                x += 1.0;
            }
        }
    }

    #[test]
    fn the_world_and_tile_conversions_are_inverses() {
        for tile in [IVec2::new(1, 1), IVec2::new(50, 50), IVec2::new(100, 73)] {
            // The top-left corner belongs to the tile itself.
            assert_eq!(world_to_tile(tile_to_world(tile)), tile);
            // As does any point strictly inside it.
            let inside = tile_to_world(tile) + Vec2::new(TILE_SIZE - 1.0, -(TILE_SIZE - 1.0));
            assert_eq!(world_to_tile(inside), tile);
        }
    }

    #[test]
    fn the_tile_boundary_is_half_open_so_two_tiles_never_claim_a_point() {
        let tile = IVec2::new(50, 50);
        let corner = tile_to_world(tile);

        assert_eq!(world_to_tile(corner), tile);
        // One world unit further along belongs to the next tile.
        assert_eq!(world_to_tile(corner + Vec2::new(TILE_SIZE, 0.0)), IVec2::new(51, 50));
        assert_eq!(world_to_tile(corner - Vec2::new(0.0, TILE_SIZE)), IVec2::new(50, 51));
    }

    #[test]
    fn a_capped_display_does_not_make_its_perimeter_clickable() {
        // On a very wide display the world is inset inside its region, and the
        // remaining frame is decoration. Treating it as world would select
        // tiles that are not drawn there.
        let size = Vec2::new(7680.0, 2160.0);
        let (geometry, view, _) = scene(size, 1.0);
        assert!(view.min.x > geometry.world.min.x, "this display should be capped");

        let in_perimeter = Vec2::new(geometry.world.min.x + 1.0, view.center().y);
        assert_eq!(target_at(in_perimeter, geometry, view), PointerTarget::Interface);
    }
}
