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
    mut pointer: ResMut<PointerState>,
) {
    let Ok(window) = windows.single() else {
        return;
    };

    let geometry = applied.0;
    let view = super::layout::world_view(geometry.world).rect;

    let Some(position) = window.cursor_position() else {
        // The pointer left the window. Reported as absent rather than stale, so
        // a drag cannot keep tracking a cursor that is no longer there.
        *pointer = PointerState::default();
        return;
    };

    let camera_centre =
        cameras.iter().next().map(|t| t.translation.truncate()).unwrap_or(Vec2::ZERO);
    let target = target_at(position, geometry, view);

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

    /// Ratios a real user is likely to have.
    const RATIOS: [f32; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

    /// Window sizes standing in for windowed, maximised and fullscreen.
    const SIZES: [(&str, Vec2); 3] = [
        ("windowed", Vec2::new(1280.0, 832.0)),
        ("maximized", Vec2::new(1920.0, 1080.0)),
        ("fullscreen", Vec2::new(2560.0, 1440.0)),
    ];

    /// Centre of a tile in world units.
    ///
    /// Not `splat(TILE_SIZE / 2)`: tile y grows downward while world y grows
    /// upward, so the centre is half a tile right and half a tile *down*, which
    /// is negative. Getting this wrong in a test reports an off-by-one in the
    /// code that is really an off-by-one in the expectation.
    fn tile_centre(tile: IVec2) -> Vec2 {
        tile_to_world(tile) + Vec2::new(TILE_SIZE / 2.0, -TILE_SIZE / 2.0)
    }

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
