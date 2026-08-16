//! The fixed application shell: top bar, world viewport, character rail,
//! world messages and hotbar.
//!
//! Every region is a Bevy node. There is no DOM or CSS involved, which is the
//! architecture invariant the roadmap states: one UI tree, one source of UI
//! state, the same on wasm and native.
//!
//! Regions are positioned absolutely from [`layout::shell_geometry`] rather
//! than by flexbox. The world viewport is a camera rectangle, and a camera that
//! reads its rectangle back from a solved flex tree lags the layout by a frame —
//! visible on resize as a stale strip down the edge of the world.

use super::layout::{self, RailMode, ShellGeometry, WorldView};
use super::scale::{self, ScaleDomains};
use super::tokens::{focus, ink, size, space, surface, type_scale};
use bevy::camera::visibility::RenderLayers;
use bevy::camera::{ClearColorConfig, Viewport};
use bevy::prelude::*;

/// Marks the camera that renders the game world.
///
/// Its viewport is the world region only, so the world is clipped to the space
/// the rail leaves.
#[derive(Component)]
pub struct WorldCamera;

/// Marks the camera that renders the shell.
///
/// A second camera, and not an optimisation: a camera's viewport clips
/// *everything* it draws, so pointing the one camera at the world region
/// clipped the top bar at the world's right edge and put the entire character
/// rail outside the frame. The rail was being laid out correctly and simply
/// never rendered.
///
/// This one covers the whole window and never has a viewport set.
#[derive(Component)]
pub struct UiCamera;

/// Render layer the world draws on. Sprites default to this.
pub const WORLD_LAYER: usize = 0;

/// Render layer the shell draws on, so world sprites cannot appear over the
/// rail and shell nodes cannot appear inside the world viewport.
pub const UI_LAYER: usize = 1;

/// Root of the shell tree.
#[derive(Component)]
struct ShellRoot;

/// Regions whose position and size are driven by the geometry.
#[derive(Component, Debug, Clone, Copy, PartialEq, Eq)]
pub enum Region {
    TopBar,
    /// Transparent: it exists to position the overlays, not to draw over the
    /// world. The world itself is rendered by the camera underneath.
    World,
    Rail,
}

/// Where transient server text appears, in the world's upper left.
#[derive(Component)]
pub struct WorldMessageArea;

/// The numbered hotbar, centred against the world viewport.
///
/// Against the *viewport*, not the window: with a 420px rail, centring on the
/// window pushes the hotbar visibly right of the world it belongs to.
#[derive(Component)]
pub struct Hotbar;

/// The minimap, in the world's upper right.
#[derive(Component)]
pub struct Minimap;

/// Content that only exists in the full rail.
#[derive(Component)]
pub struct FullRailOnly;

/// Content that only exists in the compact rail.
#[derive(Component)]
pub struct CompactRailOnly;

/// The geometry currently applied, kept so the shell only rebuilds on a change.
#[derive(Resource, Debug, Clone, Copy, PartialEq)]
pub struct AppliedGeometry(pub ShellGeometry);

impl Default for AppliedGeometry {
    fn default() -> Self {
        Self(layout::shell_geometry(Vec2::ZERO))
    }
}

pub struct ShellPlugin;

impl Plugin for ShellPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<AppliedGeometry>()
            .init_resource::<ScaleDomains>()
            .add_systems(Startup, spawn_shell)
            .add_systems(Update, (apply_geometry, apply_rail_mode).chain());
    }
}

/// Absolute-positioned node covering `rect`.
fn positioned(rect: Rect) -> Node {
    Node {
        position_type: PositionType::Absolute,
        left: Val::Px(rect.min.x),
        top: Val::Px(rect.min.y),
        width: Val::Px(rect.width()),
        height: Val::Px(rect.height()),
        ..default()
    }
}

pub fn spawn_shell(mut commands: Commands) {
    let geometry = layout::shell_geometry(Vec2::ZERO);

    // Drawn after the world and over it, with no clear so the world shows
    // through everywhere the shell is transparent.
    let ui_camera = commands
        .spawn((
            Camera2d,
            Camera { order: 1, clear_color: ClearColorConfig::None, ..default() },
            RenderLayers::layer(UI_LAYER),
            UiCamera,
        ))
        .id();

    commands
        .spawn((
            UiTargetCamera(ui_camera),
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                ..default()
            },
            // The shell must not swallow clicks meant for the world; only its
            // leaves opt back in.
            Pickable::IGNORE,
            ShellRoot,
        ))
        .with_children(|root| {
            root.spawn((
                positioned(geometry.top_bar),
                BackgroundColor(surface::PANEL),
                BorderColor::all(surface::EDGE),
                Region::TopBar,
            ));

            // Transparent. It positions the overlays; the world is the camera
            // rendering behind it.
            root.spawn((positioned(geometry.world), Pickable::IGNORE, Region::World))
                .with_children(|world| {
                    world.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            left: Val::Px(space::BASE),
                            top: Val::Px(space::BASE),
                            // Bounded so a long server notice cannot run under
                            // the minimap.
                            max_width: Val::Percent(62.0),
                            flex_direction: FlexDirection::Column,
                            row_gap: Val::Px(space::HAIR),
                            ..default()
                        },
                        Pickable::IGNORE,
                        WorldMessageArea,
                    ));

                    // Labelled, not blank. The minimap has no data source
                    // until the world adapter lands, and an unexplained empty
                    // rectangle over the world is indistinguishable from a
                    // rendering failure — a player has no way to tell which.
                    world.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            right: Val::Px(space::BASE),
                            top: Val::Px(space::BASE),
                            width: Val::Px(180.0),
                            height: Val::Px(180.0),
                            border: UiRect::all(Val::Px(size::BORDER)),
                            align_items: AlignItems::Center,
                            justify_content: JustifyContent::Center,
                            ..default()
                        },
                        BackgroundColor(surface::WELL),
                        BorderColor::all(surface::EDGE),
                        Minimap,
                        children![label("minimap unavailable", type_scale::MICRO, ink::DISABLED)],
                    ));

                    // Centred on the world viewport by making this row span the
                    // viewport and centre its own children.
                    world.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            left: Val::Px(0.0),
                            right: Val::Px(0.0),
                            bottom: Val::Px(space::BASE),
                            justify_content: JustifyContent::Center,
                            column_gap: Val::Px(space::TIGHT),
                            ..default()
                        },
                        Pickable::IGNORE,
                        Hotbar,
                    ));
                });

            root.spawn((
                positioned(geometry.rail),
                BackgroundColor(surface::PANEL),
                BorderColor::all(surface::EDGE),
                Region::Rail,
            ));
        });
}

/// Resize the regions and the world camera when the window changes.
fn apply_geometry(
    windows: Query<&Window>,
    mut applied: ResMut<AppliedGeometry>,
    mut regions: Query<(&Region, &mut Node)>,
    mut cameras: Query<(&mut Camera, &mut Projection), With<WorldCamera>>,
    mut radius: ResMut<crate::world::ViewRadius>,
    mut domains: ResMut<ScaleDomains>,
    mut ui_scale: ResMut<UiScale>,
) {
    let Ok(window) = windows.single() else {
        return;
    };

    let logical = Vec2::new(window.width(), window.height());
    let resolved = scale::resolve(logical, window.scale_factor());
    let geometry = layout::shell_geometry(logical);
    if geometry == applied.0 && resolved == *domains {
        return;
    }
    applied.0 = geometry;
    *domains = resolved;

    // Text and controls only. Bevy's UiScale does not touch the world camera,
    // which is what keeps "bigger text" from meaning "see more tiles".
    ui_scale.0 = resolved.ui;

    for (region, mut node) in &mut regions {
        let rect = match region {
            Region::TopBar => geometry.top_bar,
            Region::World => geometry.world,
            Region::Rail => geometry.rail,
        };
        // Divided by the UI scale, because Bevy multiplies every Val::Px by it
        // and does *not* touch the camera viewport. Without this the rail
        // drifts away from the world's edge at any scale above 1.0, leaving a
        // seam on one side and an overlap on the other.
        node.left = Val::Px(resolved.node_px(rect.min.x));
        node.top = Val::Px(resolved.node_px(rect.min.y));
        node.width = Val::Px(resolved.node_px(rect.width()));
        node.height = Val::Px(resolved.node_px(rect.height()));
    }

    // The camera viewport is in physical pixels; everything above is logical.
    // This is the single place device pixel ratio is applied.
    let view = layout::world_view(geometry.world);

    for (mut camera, mut projection) in &mut cameras {
        camera.viewport = view_viewport(view, resolved.device);
        if let Projection::Orthographic(ortho) = projection.as_mut() {
            ortho.scale = resolved.projection_scale();
        }
    }

    // Painting follows the viewport. It used to follow a constant, so a window
    // wider than the constant drew black beyond it. Measured in logical
    // pixels, so a sharper display does not paint a different area.
    let tiles = scale::visible_tiles(view.rect.size(), resolved);
    radius.0 = IVec2::new((tiles.x + 1) / 2, (tiles.y + 1) / 2);
}

/// Physical-pixel viewport for the world camera.
///
/// `None` when the world has no area — wgpu rejects a zero-sized viewport, and
/// a browser reports a zero-sized window while a tab is being restored.
pub fn world_viewport(geometry: ShellGeometry, scale_factor: f32) -> Option<Viewport> {
    view_viewport(layout::world_view(geometry.world), scale_factor)
}

/// Physical-pixel viewport for a resolved world view.
pub fn view_viewport(view: WorldView, scale_factor: f32) -> Option<Viewport> {
    let physical_position = (view.rect.min * scale_factor).round();
    let physical_size = (view.rect.size() * scale_factor).round();

    if physical_size.x < 1.0 || physical_size.y < 1.0 {
        return None;
    }

    Some(Viewport {
        physical_position: physical_position.max(Vec2::ZERO).as_uvec2(),
        physical_size: physical_size.as_uvec2(),
        ..default()
    })
}

/// Show the rail content that belongs to the current mode.
fn apply_rail_mode(
    applied: Res<AppliedGeometry>,
    mut full: Query<&mut Node, (With<FullRailOnly>, Without<CompactRailOnly>)>,
    mut compact: Query<&mut Node, (With<CompactRailOnly>, Without<FullRailOnly>)>,
) {
    if !applied.is_changed() {
        return;
    }
    let full_visible = applied.0.rail_mode == RailMode::Full;

    for mut node in &mut full {
        node.display = if full_visible { Display::Flex } else { Display::None };
    }
    for mut node in &mut compact {
        node.display = if full_visible { Display::None } else { Display::Flex };
    }
}

/// Text styled from the tokens, for use across the shell.
pub fn label(text: impl Into<String>, font_size: f32, color: Color) -> impl Bundle {
    (Text::new(text), TextFont { font_size, ..default() }, TextColor(color))
}

/// The standard focus ring, added to whichever control currently has focus.
pub fn focus_ring() -> impl Bundle {
    (
        Node {
            position_type: PositionType::Absolute,
            left: Val::Px(-focus::RING_WIDTH),
            top: Val::Px(-focus::RING_WIDTH),
            right: Val::Px(-focus::RING_WIDTH),
            bottom: Val::Px(-focus::RING_WIDTH),
            border: UiRect::all(Val::Px(focus::RING_WIDTH)),
            ..default()
        },
        BorderColor::all(focus::RING),
    )
}

/// Convenience for the common "small muted label" used throughout the rail.
pub fn muted_label(text: impl Into<String>) -> impl Bundle {
    label(text, type_scale::SMALL, ink::MUTED)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_camera_viewport_tracks_the_world_view_not_the_whole_region() {
        // On a capped display the view is inset inside its region. A camera
        // still filling the region would render world under the perimeter.
        let geometry = layout::shell_geometry(Vec2::new(7680.0, 2160.0));
        let view = layout::world_view(geometry.world);
        let viewport = view_viewport(view, 1.0).expect("has area");

        assert!(view.has_perimeter, "this display should be capped");
        assert_eq!(viewport.physical_size.x, view.rect.width() as u32);
        assert!(
            viewport.physical_size.x < geometry.world.width() as u32,
            "the camera claimed the perimeter as world"
        );
    }

    #[test]
    fn a_high_dpi_display_gets_a_larger_viewport_and_a_matching_projection() {
        // Both halves have to move together. A 2x viewport with a 1x
        // projection shows twice the world; the reverse shows a quarter of it,
        // scaled up.
        let geometry = layout::shell_geometry(Vec2::new(1280.0, 720.0));
        let view = layout::world_view(geometry.world);

        let one = scale::resolve(Vec2::new(1280.0, 720.0), 1.0);
        let two = scale::resolve(Vec2::new(1280.0, 720.0), 2.0);

        let at_1x = view_viewport(view, one.device).unwrap();
        let at_2x = view_viewport(view, two.device).unwrap();

        assert_eq!(at_2x.physical_size.x, at_1x.physical_size.x * 2);
        assert_eq!(two.projection_scale() * 2.0, one.projection_scale());
    }

    /// An app with both cameras and everything `apply_geometry` reads, so the
    /// production system runs rather than a stand-in for it.
    fn camera_app(window_size: Vec2) -> App {
        let mut app = App::new();
        app.init_resource::<AppliedGeometry>()
            .init_resource::<ScaleDomains>()
            .init_resource::<UiScale>()
            .init_resource::<crate::world::ViewRadius>()
            .add_systems(Startup, spawn_shell)
            .add_systems(Update, apply_geometry);

        // The world camera as `world::setup` spawns it.
        app.world_mut().spawn((
            Camera2d,
            Camera { order: 0, ..default() },
            RenderLayers::layer(WORLD_LAYER),
            Projection::Orthographic(OrthographicProjection::default_2d()),
            WorldCamera,
        ));

        let mut window = Window::default();
        window.resolution.set(window_size.x, window_size.y);
        app.world_mut().spawn(window);

        app.update();
        app
    }

    #[test]
    fn the_world_camera_is_clipped_and_the_shell_camera_is_not() {
        // The regression, checked against the real system rather than a
        // hand-built stand-in: one camera with the world's viewport clipped
        // the entire shell, so the rail never rendered.
        let mut app = camera_app(Vec2::new(1280.0, 832.0));

        let mut world = app.world_mut().query_filtered::<&Camera, With<WorldCamera>>();
        let world_viewport = world
            .iter(app.world())
            .next()
            .expect("a world camera")
            .viewport
            .clone()
            .expect("the world camera must be clipped to the world region");

        let mut shell = app.world_mut().query_filtered::<&Camera, With<UiCamera>>();
        let shell_camera = shell.iter(app.world()).next().expect("a shell camera");

        assert!(
            shell_camera.viewport.is_none(),
            "the shell camera is clipped; the rail would be cut off again"
        );

        // And the clipping is real, not a no-op that happens to pass.
        let geometry = layout::shell_geometry(Vec2::new(1280.0, 832.0));
        assert!(
            (world_viewport.physical_size.x as f32) < geometry.top_bar.width(),
            "the world viewport is not actually narrower than the window"
        );
    }

    #[test]
    fn the_two_cameras_draw_different_render_layers() {
        // Shared layers would put world sprites over the rail and shell nodes
        // inside the world viewport.
        let mut app = camera_app(Vec2::new(1280.0, 832.0));

        let mut world = app.world_mut().query_filtered::<&RenderLayers, With<WorldCamera>>();
        let world_layers = world.iter(app.world()).next().expect("world layers").clone();

        let mut shell = app.world_mut().query_filtered::<&RenderLayers, With<UiCamera>>();
        let shell_layers = shell.iter(app.world()).next().expect("shell layers").clone();

        assert!(
            !world_layers.intersects(&shell_layers),
            "the cameras share a render layer: {world_layers:?} and {shell_layers:?}"
        );
    }

    #[test]
    fn the_shell_camera_draws_after_the_world_camera() {
        let mut app = camera_app(Vec2::new(1280.0, 832.0));

        let mut world = app.world_mut().query_filtered::<&Camera, With<WorldCamera>>();
        let world_order = world.iter(app.world()).next().expect("a world camera").order;

        let mut shell = app.world_mut().query_filtered::<&Camera, With<UiCamera>>();
        let shell_order = shell.iter(app.world()).next().expect("a shell camera").order;

        assert!(shell_order > world_order, "the shell would render beneath the world");
    }

    #[test]
    fn the_rail_meets_the_world_at_every_ui_scale() {
        // Bevy multiplies Val::Px by UiScale but leaves the camera viewport
        // alone, so writing raw logical coordinates into the nodes left a seam
        // on one side of the world and an overlap on the other as soon as the
        // scale rose above 1.0.
        let geometry = layout::shell_geometry(Vec2::new(1920.0, 1080.0));

        for ui in [1.0, 1.15, 1.25, 1.5] {
            let domains = ScaleDomains { device: 1.0, world: 1, ui };
            // What the node is told, times what Bevy will multiply it by.
            let rail_left = domains.node_px(geometry.rail.min.x) * ui;
            let world_right = geometry.world.max.x;

            assert!(
                (rail_left - world_right).abs() < 0.01,
                "at UI scale {ui} the rail starts at {rail_left} but the world ends at {world_right}"
            );
        }
    }

    #[test]
    fn the_camera_viewport_is_unchanged_by_the_ui_scale() {
        // The other half of the same invariant: if the viewport moved too, the
        // correction above would overshoot.
        let geometry = layout::shell_geometry(Vec2::new(1920.0, 1080.0));
        let view = layout::world_view(geometry.world);
        let baseline = view_viewport(view, 1.0).unwrap();

        for ui in [1.0, 1.25, 1.5] {
            let _ = ui;
            assert_eq!(view_viewport(view, 1.0).unwrap().physical_size, baseline.physical_size);
        }
    }

    #[test]
    fn the_rail_is_still_drawn_when_the_world_camera_is_clipped_to_the_world() {
        // The exact regression. One camera, viewport set to the world region,
        // and the whole shell was clipped with it: the top bar stopped at the
        // world's right edge and the character rail never rendered at all.
        //
        // The invariant is structural, so it is checkable without a GPU: the
        // shell must be targeted at a camera that has no viewport, while the
        // world camera has one.
        let mut app = App::new();
        app.add_systems(Startup, spawn_shell);
        app.update();

        // A world camera with a restricted viewport, as `apply_geometry` sets.
        let geometry = layout::shell_geometry(Vec2::new(1280.0, 832.0));
        let world_viewport = world_viewport(geometry, 1.0).expect("the world has area");
        assert!(
            (world_viewport.physical_size.x as f32) < geometry.top_bar.width(),
            "this test is meaningless unless the world is narrower than the window"
        );

        let mut roots = app.world_mut().query::<(&UiTargetCamera, &ShellRoot)>();
        let (target, _) = roots.iter(app.world()).next().expect("the shell has a root");
        let target = target.0;

        let camera =
            app.world().get::<Camera>(target).expect("the shell targets a camera that exists");

        assert!(
            camera.viewport.is_none(),
            "the shell is targeted at a clipped camera; the rail would be cut off"
        );
        assert!(app.world().get::<UiCamera>(target).is_some(), "and it must be the shell's own");
    }

    #[test]
    fn the_shell_and_the_world_are_drawn_by_different_cameras() {
        // A camera's viewport clips everything it draws. With one camera,
        // pointing it at the world region clipped the top bar at the world's
        // right edge and put the whole character rail outside the frame — the
        // rail was laid out correctly and simply never rendered.
        let mut app = App::new();
        app.add_systems(Startup, spawn_shell);
        app.update();

        let mut world_cameras = app.world_mut().query_filtered::<Entity, With<WorldCamera>>();
        let mut ui_cameras = app.world_mut().query_filtered::<Entity, With<UiCamera>>();

        // The world camera lives in `world::setup`, so only the shell's is here.
        assert_eq!(ui_cameras.iter(app.world()).count(), 1, "the shell needs its own camera");
        assert_eq!(
            world_cameras.iter(app.world()).count(),
            0,
            "the shell must not also spawn the world camera"
        );
    }

    #[test]
    fn the_shell_camera_draws_over_the_world_and_never_clears_it() {
        // Order decides which is on top; clearing would erase the world the
        // shell is meant to sit over.
        let mut app = App::new();
        app.add_systems(Startup, spawn_shell);
        app.update();

        let mut cameras = app.world_mut().query_filtered::<&Camera, With<UiCamera>>();
        let camera = cameras.iter(app.world()).next().expect("a shell camera");

        assert!(camera.order > 0, "the shell must draw after the world");
        assert!(
            matches!(camera.clear_color, ClearColorConfig::None),
            "the shell camera must not clear the world underneath it"
        );
        assert!(
            camera.viewport.is_none(),
            "the shell camera must cover the whole window; a viewport is what clipped the rail"
        );
    }

    #[test]
    fn the_world_and_the_shell_are_on_separate_render_layers() {
        // Otherwise world sprites draw over the rail, and shell nodes appear
        // inside the world viewport.
        assert_ne!(WORLD_LAYER, UI_LAYER);
        // Sprites default to layer 0, so the world layer has to be that one or
        // every sprite needs an explicit component.
        assert_eq!(WORLD_LAYER, 0);
    }

    #[test]
    fn the_world_camera_viewport_matches_the_world_region() {
        // The camera and the UI must agree on where the world is, or the rail
        // draws over rendered world, or a seam of clear colour appears.
        let geometry = layout::shell_geometry(Vec2::new(1920.0, 1080.0));
        let viewport = world_viewport(geometry, 1.0).expect("a 1080p world has area");

        assert_eq!(viewport.physical_position.x, geometry.world.min.x as u32);
        assert_eq!(viewport.physical_position.y, geometry.world.min.y as u32);
        assert_eq!(viewport.physical_size.x, geometry.world.width() as u32);
        assert_eq!(viewport.physical_size.y, geometry.world.height() as u32);
    }

    #[test]
    fn device_pixel_ratio_is_applied_once_at_the_camera() {
        // Logical everywhere else, physical only here. Applying it twice
        // renders a quarter of the world scaled up; not at all renders a
        // quarter-sized world in the corner.
        let geometry = layout::shell_geometry(Vec2::new(1280.0, 720.0));
        let at_1x = world_viewport(geometry, 1.0).unwrap();
        let at_2x = world_viewport(geometry, 2.0).unwrap();

        assert_eq!(at_2x.physical_size.x, at_1x.physical_size.x * 2);
        assert_eq!(at_2x.physical_size.y, at_1x.physical_size.y * 2);
        assert_eq!(at_2x.physical_position.y, at_1x.physical_position.y * 2);
        // Exact doubling only holds because the geometry is on whole logical
        // pixels; a fractional rail width put these one physical pixel apart.
    }

    #[test]
    fn a_fractional_device_pixel_ratio_produces_whole_physical_pixels() {
        // 1.25 and 1.5 are ordinary Windows and GNOME settings. A fractional
        // viewport is rejected by wgpu, and rounding inconsistently between
        // position and size leaves a one-pixel seam.
        for scale in [1.25, 1.5, 1.75, 2.5] {
            let geometry = layout::shell_geometry(Vec2::new(1600.0, 900.0));
            let viewport = world_viewport(geometry, scale).expect("has area");
            let expected_right = ((geometry.world.max.x) * scale).round() as u32;
            let actual_right = viewport.physical_position.x + viewport.physical_size.x;
            assert!(
                actual_right.abs_diff(expected_right) <= 1,
                "at {scale}x the world's right edge lands at {actual_right}, wanted {expected_right}"
            );
        }
    }

    #[test]
    fn a_zero_sized_window_yields_no_viewport_rather_than_a_panic() {
        // Browsers report this while a tab is restored or a window is
        // minimised, and wgpu rejects a zero-sized viewport.
        let geometry = layout::shell_geometry(Vec2::ZERO);
        assert!(world_viewport(geometry, 1.0).is_none());

        let short = layout::shell_geometry(Vec2::new(1280.0, 20.0));
        assert!(world_viewport(short, 1.0).is_none(), "a window shorter than the bar has no world");
    }

    #[test]
    fn the_viewport_never_starts_off_screen() {
        for size in [Vec2::new(1.0, 1.0), Vec2::new(640.0, 480.0), Vec2::new(3440.0, 1440.0)] {
            let geometry = layout::shell_geometry(size);
            if let Some(viewport) = world_viewport(geometry, 1.0) {
                assert!(viewport.physical_size.x >= 1 && viewport.physical_size.y >= 1);
            }
        }
    }
}
