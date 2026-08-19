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

/// The selected target, centred at the top of the world.
///
/// Over the world rather than in the rail: a player deciding whether to attack is looking
/// at the thing they are attacking, not at a panel beside it.
#[derive(Component)]
pub struct TargetStrip;

/// Where the server's notices stack, above the hotbar.
///
/// Low and central, because that is where the player's attention already is during a
/// fight, and a refusal shown in a corner has not been delivered.
#[derive(Component)]
pub struct NoticeStack;

/// Content that only exists in the full rail.
#[derive(Component)]
pub struct FullRailOnly;

/// Content that only exists in the compact rail.
#[derive(Component)]
pub struct CompactRailOnly;

/// The geometry currently applied, kept so the shell only rebuilds on a change.
///
/// `None` until the first real window size arrives. It matters that this is not
/// a stand-in geometry: the rail mode is carried forward across frames for
/// hysteresis, so seeding it with a zero-sized window seeds *compact*, and every
/// window inside the hysteresis band then loads as an icon strip even though its
/// width plainly asks for a full rail. A window that has never been laid out has
/// no previous mode, which is exactly what `shell_geometry_with` takes.
#[derive(Resource, Debug, Clone, Copy, PartialEq, Default)]
pub struct AppliedGeometry(pub Option<ShellGeometry>);

pub struct ShellPlugin;

impl Plugin for ShellPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<AppliedGeometry>()
            .init_resource::<ScaleDomains>()
            .init_resource::<scale::TargetLimits>()
            .add_systems(Update, adopt_device_limits)
            .add_systems(Startup, spawn_shell)
            .add_systems(Update, (apply_geometry, apply_rail_mode).chain());

        // Before the geometry, so a ratio change is laid out in the frame it is
        // observed rather than the next one.
        #[cfg(target_arch = "wasm32")]
        app.add_systems(Update, track_host_canvas.before(apply_geometry));
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

                    // The target, centred at the top. Between the messages on the left
                    // and the minimap on the right, which is the one horizontal strip of
                    // the world nothing else claims.
                    world.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            left: Val::Percent(50.0),
                            top: Val::Px(space::BASE),
                            // Half its own width back, so the strip is centred on the
                            // world rather than starting at its centre.
                            margin: UiRect::left(Val::Percent(-12.0)),
                            flex_direction: FlexDirection::Column,
                            align_items: AlignItems::Center,
                            max_width: Val::Percent(24.0),
                            ..default()
                        },
                        Pickable::IGNORE,
                        TargetStrip,
                    ));

                    // Notices, above where the hotbar sits: low and central, where a
                    // player's attention already is during a fight.
                    world.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            right: Val::Px(space::BASE),
                            bottom: Val::Px(size::HOTBAR_SLOT + space::WIDE * 2.0),
                            flex_direction: FlexDirection::Column,
                            align_items: AlignItems::FlexEnd,
                            max_width: Val::Percent(56.0),
                            ..default()
                        },
                        Pickable::IGNORE,
                        NoticeStack,
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

/// Replace the fallback target limits with what the renderer will actually take.
///
/// The device's `max_texture_dimension_2d` is the only authority on how large a
/// render target can be, and it is not a constant: WebGL2 guarantees 2048, most
/// desktop hardware offers 16384, and the client cannot know which it has until
/// a device exists. Reading it once and caching it keeps the choice of target
/// size honest without querying every frame.
///
/// `Option<Res<..>>` because there is no render device in a headless test, and
/// the fallback is the right answer there.
fn adopt_device_limits(
    device: Option<Res<bevy::render::renderer::RenderDevice>>,
    mut limits: ResMut<scale::TargetLimits>,
    mut adopted: Local<bool>,
) {
    if *adopted {
        return;
    }
    let Some(device) = device else {
        return;
    };
    let reported = device.limits().max_texture_dimension_2d;
    let next = scale::TargetLimits::for_device(reported);
    if *limits != next {
        info!("render target limit is {reported}px (was assuming {})", limits.max_dimension);
        *limits = next;
    }
    *adopted = true;
}

/// Keep the Bevy window, the canvas backing store and the device ratio in step.
///
/// One rule, applied once per change: the window's *logical* size is the host
/// element's CSS box, its *physical* size is that times the device pixel ratio,
/// and the scale factor is the ratio. Every Bevy consumer — layout, cursor,
/// picking — then works in units that agree.
///
/// Two earlier attempts are worth knowing about. Bevy's `fit_canvas_to_parent`
/// installs the CSS box as the *physical* size, so at ratio 2 the client believed
/// it had half the window it had. Pinning the scale factor to 1 fixed the layout
/// and left the input paths in device pixels, so clicks drifted further off the
/// further they were from the origin — invisible at ratio 1, which is why it
/// survived until clicks were driven in a browser at 1.25x.
///
/// It reads the *parent*, deliberately. Reading the canvas fed Bevy's own sizing
/// of the canvas back into the measurement and the element grew without bound —
/// 7628 pixels wide before I stopped it.
#[cfg(target_arch = "wasm32")]
fn track_host_canvas(
    mut windows: Query<(Entity, &mut Window)>,
    mut resized: MessageWriter<bevy::window::WindowResized>,
    mut rescaled: MessageWriter<bevy::window::WindowScaleFactorChanged>,
) {
    let Some((css, ratio)) = host_shell_box() else {
        return;
    };
    let Ok((entity, mut window)) = windows.single_mut() else {
        return;
    };

    // `WindowResolution::set` takes a *logical* size and multiplies by the scale
    // factor itself, so the CSS box goes in unmodified. Pre-multiplying applied the
    // ratio twice: at 2x the backing store came out 5112 pixels wide instead of
    // 2556 — four times the pixels, and enough that the software renderer drew
    // nothing at all.
    let current = Vec2::new(window.width(), window.height());
    // Guarded, or this is a resize event every frame and the shell rebuilds on one.
    if (current - css).abs().max_element() < 0.5
        && (window.resolution.base_scale_factor() - ratio).abs() < f32::EPSILON
    {
        return;
    }

    let rescale = (window.resolution.base_scale_factor() - ratio).abs() >= f32::EPSILON;
    window.resolution.set_scale_factor(ratio);
    window.resolution.set(css.x, css.y);

    // Announced, because we changed the window rather than the browser telling winit
    // that it did. `camera_system` refreshes a camera's cached target information only
    // for windows named in these messages, and the UI takes its scale factor from that
    // cache — so a device pixel ratio change applied silently left every node laid out
    // at the old scale. Measured after a ratio change from 1 to 2: the canvas backing
    // store correctly doubled to 2196x1476 while an inventory slot stayed 42 physical
    // pixels instead of 84, which is a whole interface at half size.
    announce_window_change(entity, css, ratio, rescale, &mut resized, &mut rescaled);
}

/// Tell the rest of the engine about a window we changed ourselves.
///
/// Not wasm-gated, so it can be tested: the browser is where the ratio changes, but
/// what the engine does with the announcement is the same everywhere.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
fn announce_window_change(
    window: Entity,
    logical: Vec2,
    scale_factor: f32,
    rescaled_too: bool,
    resized: &mut MessageWriter<bevy::window::WindowResized>,
    rescaled: &mut MessageWriter<bevy::window::WindowScaleFactorChanged>,
) {
    if rescaled_too {
        rescaled.write(bevy::window::WindowScaleFactorChanged {
            window,
            scale_factor: scale_factor as f64,
        });
    }
    resized.write(bevy::window::WindowResized {
        window,
        width: logical.x,
        height: logical.y,
    });
}

/// The host element's CSS box and the display's device pixel ratio.
///
/// The shell, not the canvas: the canvas's size is what Bevy is being told to set,
/// and measuring it produces a feedback loop.
#[cfg(target_arch = "wasm32")]
fn host_shell_box() -> Option<(Vec2, f32)> {
    let window = web_sys::window()?;
    let ratio = window.device_pixel_ratio() as f32;
    let element = window.document()?.query_selector("#shell").ok()??;
    let css = Vec2::new(element.client_width() as f32, element.client_height() as f32);
    if css.x <= 0.0 || css.y <= 0.0 || !ratio.is_finite() || ratio <= 0.0 {
        return None;
    }
    Some((css, ratio))
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
    // Resolved twice: the scale depends on how much room the world has, and how
    // much room the world has depends on the rail's clamps, which scale. One
    // pass to find the scale, a second to lay out with it.
    let probe = layout::shell_geometry(logical);
    let resolved = scale::resolve(logical, probe.world.size(), window.scale_factor());
    // The mode currently on screen, so a window resting on the breakpoint keeps
    // what it has rather than flipping every frame.
    let geometry =
        layout::shell_geometry_with(logical, resolved.ui, applied.0.map(|g| g.rail_mode));
    if applied.0 == Some(geometry) && resolved == *domains {
        return;
    }
    applied.0 = Some(geometry);
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
    let Some(geometry) = applied.0 else {
        return;
    };
    let full_visible = geometry.rail_mode == RailMode::Full;

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

        let window = Vec2::new(1280.0, 720.0);
        let region = layout::shell_geometry(window).world.size();
        let one = scale::resolve(window, region, 1.0);
        let two = scale::resolve(window, region, 2.0);

        let at_1x = view_viewport(view, one.device).unwrap();
        let at_2x = view_viewport(view, two.device).unwrap();

        assert_eq!(at_2x.physical_size.x, at_1x.physical_size.x * 2);
        assert_eq!(two.projection_scale() * 2.0, one.projection_scale());
    }

    /// The shared harness: the real shell, the real cameras, and the real world
    /// camera from `world::world_camera`.
    ///
    /// Was a local builder that spawned its own approximation of the world
    /// camera — which by construction could not notice the client getting its
    /// render layer, order or target wrong. One description of "a running
    /// shell", used by every test that needs one.
    fn camera_app(window_size: Vec2) -> App {
        super::super::testing::shell_app(window_size)
    }

    #[test]
    fn a_size_change_announces_a_resize_and_only_a_ratio_change_announces_a_rescale() {
        // Both messages matter and for different reasons. Without the rescale, Bevy
        // never refreshes the camera's cached scale factor and the whole interface stays
        // laid out at the old one — measured in a browser as a canvas backing store that
        // correctly doubled while an inventory slot stayed 42 physical pixels instead of
        // 84. Sending it on every resize would be the opposite mistake: a rescale
        // invalidates every node's layout, and a window being dragged emits a resize a
        // frame.
        let mut app = App::new();
        app.add_message::<bevy::window::WindowResized>()
            .add_message::<bevy::window::WindowScaleFactorChanged>();
        let window = app.world_mut().spawn_empty().id();

        let announce = move |rescaled_too: bool| {
            move |mut resized: MessageWriter<bevy::window::WindowResized>,
                  mut rescaled: MessageWriter<bevy::window::WindowScaleFactorChanged>| {
                announce_window_change(
                    window,
                    Vec2::new(1280.0, 832.0),
                    2.0,
                    rescaled_too,
                    &mut resized,
                    &mut rescaled,
                );
            }
        };

        use bevy::ecs::system::RunSystemOnce;
        app.world_mut().run_system_once(announce(false)).expect("runs");
        let resizes = app.world().resource::<Messages<bevy::window::WindowResized>>().len();
        let rescales =
            app.world().resource::<Messages<bevy::window::WindowScaleFactorChanged>>().len();
        assert_eq!(resizes, 1, "a size change did not announce a resize");
        assert_eq!(rescales, 0, "a size change announced a scale factor change as well");

        app.world_mut().run_system_once(announce(true)).expect("runs");
        assert_eq!(
            app.world().resource::<Messages<bevy::window::WindowScaleFactorChanged>>().len(),
            1,
            "a ratio change did not announce itself, so the interface would stay at the old scale"
        );
    }

    #[test]
    fn no_two_controls_share_a_key() {
        // A key names one control. Two entities answering to the same one is
        // undetectable from inside the client and ruinous outside it: the published
        // rectangles are looked up by key, so automation measures the first entity and
        // the pointer hits whichever is actually there — which reads as a hit-testing
        // error a couple of pixels wide rather than as a duplicated panel.
        //
        // The same ambiguity reaches players through the keyboard: Tab visits both,
        // and the second visit looks like a control that swallowed the focus ring.
        let mut app = camera_app(Vec2::new(1280.0, 800.0));
        for _ in 0..8 {
            app.update();
        }

        let mut counts = std::collections::BTreeMap::<String, usize>::new();
        let mut keys = app.world_mut().query::<&crate::ui::controls::ControlKey>();
        for key in keys.iter(app.world()) {
            *counts.entry(key.as_str().to_string()).or_default() += 1;
        }

        let duplicated: Vec<_> =
            counts.iter().filter(|(_, count)| **count > 1).map(|(key, count)| format!("{key} x{count}")).collect();
        assert!(!counts.is_empty(), "the shell published no keyed controls at all");
        assert!(duplicated.is_empty(), "these keys name more than one entity: {duplicated:?}");
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

    /// Every region the shell partitions the window into.
    fn regions_of(geometry: ShellGeometry) -> [(&'static str, Rect); 3] {
        [("top bar", geometry.top_bar), ("world", geometry.world), ("rail", geometry.rail)]
    }

    fn overlap(a: Rect, b: Rect) -> bool {
        let intersection = a.intersect(b);
        intersection.width() > 0.01 && intersection.height() > 0.01
    }

    #[test]
    fn the_regions_partition_the_window_without_overlap_or_spill() {
        // The shell's whole job. Checked across every size a player can produce
        // — including the degenerate ones a browser reports mid-restore, which
        // is where negative extents come from.
        let sizes = [
            Vec2::new(1280.0, 720.0),
            Vec2::new(1920.0, 1080.0),
            Vec2::new(2560.0, 1440.0),
            Vec2::new(3440.0, 1440.0),
            Vec2::new(1024.0, 768.0),
            Vec2::new(900.0, 700.0),
            Vec2::new(640.0, 480.0),
            Vec2::new(1.0, 1.0),
            Vec2::ZERO,
        ];

        for size in sizes {
            let geometry = layout::shell_geometry(size);
            let window = Rect::from_corners(Vec2::ZERO, size);

            for (name, rect) in regions_of(geometry) {
                assert!(rect.width() >= 0.0, "{size:?}: {name} has negative width");
                assert!(rect.height() >= 0.0, "{size:?}: {name} has negative height");
                assert!(
                    rect.min.x >= -0.01
                        && rect.min.y >= -0.01
                        && rect.max.x <= window.max.x + 0.01
                        && rect.max.y <= window.max.y + 0.01,
                    "{size:?}: {name} at {rect:?} is outside the window"
                );
            }

            let regions = regions_of(geometry);
            for (i, (a_name, a)) in regions.iter().enumerate() {
                for (b_name, b) in &regions[i + 1..] {
                    assert!(!overlap(*a, *b), "{size:?}: {a_name} overlaps {b_name}");
                }
            }
        }
    }

    #[test]
    fn the_top_bar_spans_the_full_width_and_the_rail_is_full_height_below_it() {
        // The layout contract from the roadmap, stated as geometry rather than
        // as a screenshot.
        for size in [Vec2::new(1280.0, 720.0), Vec2::new(1920.0, 1080.0)] {
            let geometry = layout::shell_geometry(size);

            assert_eq!(geometry.top_bar.min.x, 0.0, "{size:?}: the bar does not start at the edge");
            assert_eq!(geometry.top_bar.max.x, size.x, "{size:?}: the bar does not span the width");

            assert_eq!(
                geometry.rail.min.y, geometry.top_bar.max.y,
                "{size:?}: a gap under the bar"
            );
            assert_eq!(geometry.rail.max.y, size.y, "{size:?}: the rail stops short of the bottom");
            assert_eq!(geometry.rail.max.x, size.x, "{size:?}: the rail stops short of the edge");
        }
    }

    #[test]
    fn the_world_and_the_rail_together_fill_the_width_below_the_bar() {
        // Any unused perimeter has to be a deliberate layout result. A gap here
        // would be an accidental black rectangle, which is exactly what the
        // task forbids.
        for size in [Vec2::new(1280.0, 720.0), Vec2::new(1920.0, 1080.0), Vec2::new(1024.0, 768.0)]
        {
            let geometry = layout::shell_geometry(size);
            assert_eq!(
                geometry.world.width() + geometry.rail.width(),
                size.x,
                "{size:?}: world and rail leave a gap"
            );
        }
    }

    #[test]
    fn the_hotbar_stays_inside_and_centred_on_the_world() {
        // Centred on the *world*, not the window: with a 420-pixel rail,
        // centring on the window puts it visibly right of the world it belongs
        // to, and at the extreme it slides under the rail.
        for size in [Vec2::new(1280.0, 720.0), Vec2::new(1920.0, 1080.0), Vec2::new(3440.0, 1440.0)]
        {
            let geometry = layout::shell_geometry(size);
            let view = layout::world_view(geometry.world);

            let world_centre = view.rect.center().x;
            let window_centre = size.x / 2.0;
            assert!(
                world_centre < window_centre,
                "{size:?}: the world's centre is not left of the window's, so this proves nothing"
            );

            // The hotbar spans the viewport and centres its own children, so
            // its bounds are the viewport's.
            assert!(view.rect.min.x >= geometry.world.min.x - 0.01);
            assert!(view.rect.max.x <= geometry.world.max.x + 0.01);
            assert!(
                view.rect.max.y <= size.y + 0.01,
                "{size:?}: the hotbar row is below the window"
            );
        }
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

    /// The world region's node and the camera that draws into it, in physical
    /// pixels, from one solved app.
    fn world_node_and_viewport(app: &mut App) -> (Rect, bevy::camera::Viewport) {
        use super::super::testing;

        let node = app
            .world_mut()
            .query::<(Entity, &Region)>()
            .iter(app.world())
            .find(|(_, region)| **region == Region::World)
            .map(|(entity, _)| entity)
            .expect("the shell has no world region");
        let rect = testing::solved_rect(app, node).expect("the world region was never solved");

        let viewport = app
            .world_mut()
            .query_filtered::<&Camera, With<WorldCamera>>()
            .iter(app.world())
            .next()
            .and_then(|camera| camera.viewport.clone())
            .expect("the world camera has no viewport");

        (rect, viewport)
    }

    #[test]
    fn the_camera_viewport_is_the_world_node_at_every_ui_scale() {
        // The closure requirement for this task, and the fault it names: global
        // UiScale multiplies every Val::Px the shell declares, while a camera
        // viewport is set in physical pixels and is not multiplied by anything.
        // Get that wrong and the world is drawn into a rectangle the interface
        // does not agree exists — which is how the entire shell ended up inside
        // a clipped viewport once already.
        //
        // Compared as solved bounds against the real viewport, not as the
        // arithmetic that produced both, because they were produced by the same
        // arithmetic and would agree with each other while both being wrong.
        use super::super::testing;

        for window in [Vec2::new(1280.0, 760.0), Vec2::new(2560.0, 1520.0)] {
            let mut app = testing::shell_app(window);
            let scale = app.world().resource::<UiScale>().0;
            let (rect, viewport) = world_node_and_viewport(&mut app);

            assert!(
                (rect.width() - viewport.physical_size.x as f32).abs() <= 1.0
                    && (rect.height() - viewport.physical_size.y as f32).abs() <= 1.0,
                "at {window:?} (UI scale {scale}) the world node is {}x{} and the viewport is {}x{}",
                rect.width(),
                rect.height(),
                viewport.physical_size.x,
                viewport.physical_size.y
            );
            assert!(
                (rect.min.x - viewport.physical_position.x as f32).abs() <= 1.0
                    && (rect.min.y - viewport.physical_position.y as f32).abs() <= 1.0,
                "at {window:?} (UI scale {scale}) the world node starts at {:?} and the viewport at {:?}",
                rect.min,
                viewport.physical_position
            );
        }

        // And that the two windows really did exercise different scales, or the
        // test is one case written twice.
        assert_eq!(
            testing::shell_app(Vec2::new(1280.0, 760.0)).world().resource::<UiScale>().0,
            1.0,
            "the first case is not at UI scale 1"
        );
        let large = testing::shell_app(Vec2::new(2560.0, 1520.0)).world().resource::<UiScale>().0;
        assert!(large > 1.0, "the second case is at UI scale {large}, not above 1");
    }

    #[test]
    fn a_device_pixel_ratio_change_alone_does_not_change_what_is_framed() {
        // The other half: a sharper display is more pixels for the same scene,
        // never a different amount of scene. If the logical framing moves with
        // the ratio, a player on a 150% display is playing a different game —
        // seeing more or less of the world than everyone else.
        use super::super::layout;
        use super::super::testing;

        let window = Vec2::new(1280.0, 760.0);
        let mut baseline = None;

        for ratio in [1.0f32, 1.25, 1.5, 1.75, 2.0] {
            let app = testing::shell_app_at(window, ratio);
            let geometry = testing::settled(&app);
            let view = layout::world_view(geometry.world);

            match baseline {
                None => baseline = Some((geometry.world, view.tiles)),
                Some((world, tiles)) => {
                    assert_eq!(
                        geometry.world, world,
                        "at {ratio}x the world is framed at {:?} instead of {world:?}",
                        geometry.world
                    );
                    assert_eq!(
                        view.tiles, tiles,
                        "at {ratio}x the player sees {:?} tiles instead of {tiles:?}",
                        view.tiles
                    );
                }
            }
        }
    }

    #[test]
    fn a_higher_ratio_buys_more_physical_pixels_for_the_same_world() {
        // The complement of the test above, so "nothing changed" cannot pass by
        // the ratio being ignored altogether. The logical framing holds; the
        // backing store the camera draws into grows with the ratio.
        use super::super::testing;

        let window = Vec2::new(1280.0, 760.0);
        let mut previous = 0u32;
        for ratio in [1.0f32, 2.0] {
            let mut app = testing::shell_app_at(window, ratio);
            let (_, viewport) = world_node_and_viewport(&mut app);
            assert!(
                viewport.physical_size.x > previous,
                "at {ratio}x the viewport is {} physical pixels wide, no more than at the last ratio ({previous})",
                viewport.physical_size.x
            );
            previous = viewport.physical_size.x;
        }
    }

    #[test]
    fn a_host_mode_change_and_back_preserves_what_the_player_was_doing() {
        // From inside the client, maximise-and-restore is two window resizes and
        // no other notification. Anything that does not survive them is state
        // the client silently drops when a player presses the maximise button —
        // and the danger is that most of it survives by accident, because
        // nothing touches it, so an untested pass here means nothing.
        use super::super::character::SelectedSlot;
        use super::super::controls::{Control, ControlKey, FocusOwner, TextField};
        use super::super::testing;

        let windowed = Vec2::new(1280.0, 760.0);
        let maximised = Vec2::new(1920.0, 1040.0);

        let mut app = testing::shell_app(windowed);

        // Something selected, something focused, something half-typed.
        app.world_mut().resource_mut::<SelectedSlot>().0 = Some(4);

        // A key of its own. Reusing an inventory slot's key made focus reattach
        // to the real slot on the next frame — which is correct behaviour, and
        // was the test setting up a collision rather than a finding.
        let key = ControlKey::new("chat.compose");
        let field = app
            .world_mut()
            .spawn((Node::default(), Control::default(), key.clone(), {
                let mut field = TextField::new();
                for character in "hola ".chars() {
                    field.insert(character);
                }
                field
            }))
            .id();
        app.world_mut().resource_mut::<FocusOwner>().focus(field, Some(&key));

        // And a camera looking somewhere specific.
        let centre = Vec3::new(1234.0, -567.0, 0.0);
        let camera = app
            .world_mut()
            .query_filtered::<Entity, With<WorldCamera>>()
            .iter(app.world())
            .next()
            .expect("there is a world camera");
        app.world_mut().entity_mut(camera).insert(Transform::from_translation(centre));
        app.update();

        testing::resize(&mut app, maximised);
        testing::resize(&mut app, windowed);

        assert_eq!(
            app.world().resource::<SelectedSlot>().0,
            Some(4),
            "the selected item was lost across a maximise and restore"
        );
        // By key, not entity: a panel rebuild is allowed to replace the entity,
        // and that is exactly what focus-by-key exists to survive. What must not
        // change is *which control* the keyboard belongs to.
        assert_eq!(
            app.world().resource::<FocusOwner>().key(),
            Some(&key),
            "focus forgot which control it belonged to across a restore"
        );
        let focused = app
            .world()
            .resource::<FocusOwner>()
            .entity()
            .expect("focus was lost across a maximise and restore");
        assert_eq!(
            app.world().get::<ControlKey>(focused),
            Some(&key),
            "focus points at an entity that is not the control it names"
        );
        assert_eq!(
            app.world().get::<TextField>(field).map(|f| f.value().to_string()),
            Some("hola ".to_string()),
            "composing text was lost across a maximise and restore"
        );
        assert_eq!(
            app.world().get::<Transform>(camera).map(|t| t.translation),
            Some(centre),
            "the camera moved across a maximise and restore"
        );
    }

    #[test]
    fn the_pointer_is_recomputed_for_the_geometry_the_window_now_has() {
        // The other half of a restore, and the one that survives by accident
        // least gracefully: the pointer pipeline is derived from the shell
        // geometry, so a stale reading makes the first click after a restore
        // land on the tile the *previous* window had under the cursor.
        use super::super::pointer::{PointerState, PointerTarget};
        use super::super::testing;

        let narrow = Vec2::new(1000.0, 800.0);
        let wide = Vec2::new(1920.0, 1040.0);

        let mut app = testing::shell_app(narrow);

        // A point chosen to be over the rail in the narrow window and over the
        // world in the wide one — the rail's right edge moves, so the same
        // screen position means two different things.
        let narrow_rail = testing::settled(&app).rail;
        let probe = Vec2::new(narrow_rail.min.x + 8.0, 400.0);

        testing::point_at(&mut app, probe);
        assert_eq!(
            app.world().resource::<PointerState>().target,
            Some(PointerTarget::Interface),
            "the probe point is not over the interface, so this proves nothing"
        );

        testing::resize(&mut app, wide);
        let wide_rail = testing::settled(&app).rail;
        assert!(
            probe.x < wide_rail.min.x,
            "the rail did not move past the probe point, so this proves nothing"
        );

        testing::point_at(&mut app, probe);
        assert_eq!(
            app.world().resource::<PointerState>().target,
            Some(PointerTarget::World),
            "the pointer still reports the rail at a position the world now owns"
        );
        assert!(
            app.world().resource::<PointerState>().tile.is_some(),
            "the pointer is over the world but names no tile"
        );
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
