//! An app that really solves the UI layout, for tests that need to know where
//! things ended up rather than what they were declared as.
//!
//! Arithmetic tests over the geometry functions could not see the fault that
//! reached the browser during W-0002: the full rail's content was spawned into
//! the 56-pixel compact strip as well, because both carry the same region
//! marker, so five labelled bars overflowed a strip meant for slivers. Every
//! declared width was right; only the solved tree was wrong.
//!
//! It is also what tells a suspected layout fault from a misread screenshot. A
//! second suspicion from the same capture — that two half-width bars were
//! overflowing the rail — turned out to be the fill boundary inside a bar, and
//! this harness is what settled it rather than another round of guessing.
//!
//! The plugin list is deliberately the smallest one that makes `ComputedNode`
//! real. It is not the renderer: nothing here draws, and there is no GPU. Only
//! `bevy_ui`'s own dependencies are present, plus the asset types its systems
//! ask for by value.

use bevy::prelude::*;

use super::layout;
use super::shell::{AppliedGeometry, ShellPlugin};

/// A running shell, laid out for a window of `size` logical pixels.
pub fn shell_app(size: Vec2) -> App {
    shell_app_at(size, 1.0)
}

/// The same, on a display with `device_pixel_ratio` physical pixels per logical.
///
/// The window keeps `size` *logical* pixels and grows its backing store, which
/// is what a higher-DPI display actually is. Setting the physical size alone
/// would be a smaller window, not a sharper one, and the test would then be
/// measuring the wrong thing while appearing to cover DPI.
///
/// Worth having natively: Playwright's `deviceScaleFactor` is an emulation that
/// changes `window.devicePixelRatio` without winit observing it, so the browser
/// harness cannot check this at all.
pub fn shell_app_at(size: Vec2, device_pixel_ratio: f32) -> App {
    let mut resolution = bevy::window::WindowResolution::default();
    resolution.set(size.x * device_pixel_ratio, size.y * device_pixel_ratio);
    resolution.set_scale_factor(device_pixel_ratio);

    let mut app = App::new();
    app.add_plugins((
        MinimalPlugins,
        bevy::asset::AssetPlugin::default(),
        // Configured rather than spawned separately: WindowPlugin creates the
        // primary window itself, and a second Window entity makes every
        // `windows.single()` in the shell fail silently, which reads as "the
        // shell never laid itself out".
        bevy::window::WindowPlugin {
            primary_window: Some(Window { resolution, ..default() }),
            ..default()
        },
        bevy::transform::TransformPlugin,
        bevy::input::InputPlugin,
        bevy::text::TextPlugin,
        bevy::picking::PickingPlugin,
        bevy::picking::InteractionPlugin,
        bevy::image::ImagePlugin::default(),
        bevy::ui::UiPlugin::default(),
    ));
    // `update_image_content_size_system` reads this collection whether or not
    // any image node exists. Adding SpritePlugin for it would drag in meshes
    // and the 2D render pipeline, which this app has no use for.
    app.init_asset::<bevy::image::TextureAtlasLayout>();

    app.add_plugins((
        // Without a font, every piece of text measures as zero and the solved
        // tree can never overflow — which would make an overflow test that
        // passes mean nothing at all. The face is embedded and installed
        // synchronously, so there is no asset load to wait for.
        super::fonts::FontPlugin,
        super::state::UiStatePlugin,
        super::controls::ControlsPlugin,
        ShellPlugin,
        super::pointer::PointerPlugin,
        super::rail::RailPlugin,
        super::character::CharacterPanelPlugin,
        super::spells::SpellPanelPlugin,
        super::chat::ChatPanelPlugin,
        super::target::TargetPanelPlugin,
        super::labels::LabelPlugin,
        super::minimap::MinimapPlugin,
        // The hotbar is part of the shell, so a harness without it answers
        // questions about a shell that does not exist.
        super::hotbar::HotbarPlugin,
    ))
    .init_resource::<crate::world::ViewRadius>()
    // The player the harness's camera is already looking at. `WorldPlugin` provides this
    // in production; without it the label layer has nobody to measure distance from, and
    // every shell test fails on a missing resource rather than on its own question.
    .init_resource::<crate::world::LocalPlayer>()
    // The graphics resources the rail's rebuild reads to resolve item artwork.
    // Empty here: no sheets have arrived, which is the case every slot's fallback
    // exists for, and the one a headless test can actually reproduce.
    .init_resource::<crate::graphics::Graphics>()
    .init_resource::<crate::graphics::SheetTextures>()
    .init_resource::<crate::world::SheetAtlases>()
    .init_asset::<bevy::image::TextureAtlasLayout>();

    // A mouse pointer, so picking has something to route input through. Bevy's
    // input plugin spawns this in production; there is no winit here.
    app.world_mut().spawn((
        bevy::picking::pointer::PointerId::Mouse,
        bevy::picking::pointer::PointerLocation::default(),
    ));

    // The real world camera, from the client's own definition. A hand-written
    // stand-in here could not notice the client getting its render layer, order
    // or projection wrong.
    app.world_mut().spawn(crate::world::world_camera(50, 50));

    // Spawn the tree, apply the geometry that produced, solve the layout the
    // geometry asked for, and let the clip pass propagate through it.
    for _ in 0..4 {
        app.update();
    }
    app
}

/// Resize the window and let the shell settle at the new size.
///
/// This is what a host-mode change looks like from inside the client: the page
/// resizes the canvas, winit reports a new window size, and nothing else about
/// the client is told anything. Anything that does not survive this is state the
/// client is dropping on a maximise.
pub fn resize(app: &mut App, size: Vec2) {
    let mut windows = app.world_mut().query::<&mut Window>();
    let mut window = windows.single_mut(app.world_mut()).expect("there is one window");
    window.resolution.set(size.x, size.y);
    for _ in 0..4 {
        app.update();
    }
}

/// Put the pointer at a logical position inside the window.
pub fn point_at(app: &mut App, position: Vec2) {
    let mut windows = app.world_mut().query::<&mut Window>();
    let mut window = windows.single_mut(app.world_mut()).expect("there is one window");
    let factor = window.scale_factor() as f64;
    window.set_physical_cursor_position(Some(bevy::math::DVec2::new(
        position.x as f64 * factor,
        position.y as f64 * factor,
    )));
    app.update();
}

/// Tap a key through Bevy's own input pipeline.
///
/// Same reason as `press_mouse`: `InputPlugin` rebuilds `ButtonInput` from events every
/// frame, so a press written onto the resource is gone before any gameplay system reads
/// it. A test that does that is asking whether a keystroke *nobody delivered* had an
/// effect, and the answer is always no.
pub fn tap_key(app: &mut App, key_code: KeyCode) {
    let window = app
        .world_mut()
        .query_filtered::<Entity, With<bevy::window::PrimaryWindow>>()
        .iter(app.world())
        .next()
        .expect("there is no primary window");
    for state in [bevy::input::ButtonState::Pressed, bevy::input::ButtonState::Released] {
        app.world_mut().write_message(bevy::input::keyboard::KeyboardInput {
            key_code,
            logical_key: bevy::input::keyboard::Key::Unidentified(
                bevy::input::keyboard::NativeKey::Unidentified,
            ),
            state,
            text: None,
            repeat: false,
            window,
        });
        app.update();
    }
}

/// Press a mouse button through Bevy's own input pipeline.
///
/// Through the message rather than by assigning `ButtonInput`: this app runs
/// `InputPlugin`, whose systems clear `just_pressed` at the start of every frame and
/// rebuild it from events. A press written directly onto the resource is therefore gone
/// before any gameplay system reads it — which reads as "the click did nothing".
pub fn press_mouse(app: &mut App, button: bevy::input::mouse::MouseButton) {
    let window = app
        .world_mut()
        .query_filtered::<Entity, With<bevy::window::PrimaryWindow>>()
        .iter(app.world())
        .next()
        .expect("there is no primary window");
    app.world_mut().write_message(bevy::input::mouse::MouseButtonInput {
        button,
        state: bevy::input::ButtonState::Pressed,
        window,
    });
    app.update();
}

/// The window's own pointer target, for driving real pointer input.
///
/// Public because every hand-built pointer event needs it. A fabricated target entity
/// looks harmless and is not: `Pointer` events propagate to the parent, and an entity
/// with no parent propagates to the pointer's window — stopping only if that entity
/// actually has a `Window`. A stand-in without one traverses to itself forever, and the
/// test hangs rather than failing.
pub fn window_target(app: &mut App) -> bevy::camera::NormalizedRenderTarget {
    let window = app
        .world_mut()
        .query_filtered::<Entity, With<bevy::window::PrimaryWindow>>()
        .iter(app.world())
        .next()
        .expect("there is no primary window");
    bevy::camera::NormalizedRenderTarget::Window(
        bevy::window::WindowRef::Entity(window)
            .normalize(Some(window))
            .expect("a window reference normalises"),
    )
}

/// Move the real pointer to a position, in physical pixels of the window.
///
/// Drives `PointerInput` through Bevy's own picking, rather than setting
/// `Interaction` by hand. The difference matters for this: whether the control
/// *visibly* under the pointer is the one that receives the event is a question
/// about hit testing, and a test that assigns the answer cannot ask it.
pub fn move_pointer(app: &mut App, position: Vec2) {
    let target = window_target(app);

    // The window's own cursor as well as the picking pointer. They are two different
    // facts and production reads both: picking hovers controls, while the pointer
    // pipeline reads `Window::cursor_position`. Feeding only picking left
    // `PointerState` empty for the whole test, so every assertion of the form "this
    // position is not the world" passed on a pointer that was nowhere at all.
    let scale = app
        .world_mut()
        .query::<&Window>()
        .iter(app.world())
        .next()
        .map(|window| window.resolution.scale_factor())
        .unwrap_or(1.0);
    if let Some(mut window) = app
        .world_mut()
        .query_filtered::<&mut Window, With<bevy::window::PrimaryWindow>>()
        .iter_mut(app.world_mut())
        .next()
    {
        window.set_physical_cursor_position(Some((position * scale).as_dvec2()));
    }

    app.world_mut().write_message(bevy::picking::pointer::PointerInput::new(
        bevy::picking::pointer::PointerId::Mouse,
        bevy::picking::pointer::Location { target, position },
        bevy::picking::pointer::PointerAction::Move { delta: Vec2::ZERO },
    ));
    app.update();
}

/// Press and release the primary button where the pointer is.
pub fn click_pointer(app: &mut App, position: Vec2) {
    use bevy::picking::pointer::{Location, PointerAction, PointerButton, PointerId, PointerInput};

    move_pointer(app, position);
    let target = window_target(app);
    for action in [
        PointerAction::Press(PointerButton::Primary),
        PointerAction::Release(PointerButton::Primary),
    ] {
        let location = Location { target: target.clone(), position };
        app.world_mut().write_message(PointerInput::new(PointerId::Mouse, location, action));
        app.update();
    }
}

/// The rail mode the shell settled on, which must exist once it has run.
pub fn settled(app: &App) -> layout::ShellGeometry {
    app.world().resource::<AppliedGeometry>().0.expect("the shell never laid itself out")
}

/// Where a node actually ended up, in logical pixels of the window.
///
/// `UiGlobalTransform` puts the origin at the node's centre, which is not the
/// coordinate anything else in this client is expressed in.
pub fn solved_rect(app: &App, entity: Entity) -> Option<Rect> {
    let node = app.world().get::<ComputedNode>(entity)?;
    let transform = app.world().get::<UiGlobalTransform>(entity)?;
    let half = node.size() / 2.0;
    let centre = transform.translation;
    Some(Rect::from_corners(centre - half, centre + half))
}

/// Every descendant of `root`, `root` excluded.
pub fn descendants(app: &App, root: Entity) -> Vec<Entity> {
    let mut found = Vec::new();
    let mut queue = vec![root];
    while let Some(entity) = queue.pop() {
        let Some(children) = app.world().get::<Children>(entity) else {
            continue;
        };
        for child in children.iter() {
            found.push(child);
            queue.push(child);
        }
    }
    found
}

/// Whether an entity and all its ancestors are displayed.
pub fn is_displayed(app: &App, entity: Entity) -> bool {
    let mut current = Some(entity);
    while let Some(id) = current {
        match app.world().get::<Node>(id) {
            Some(node) if node.display == Display::None => return false,
            _ => {}
        }
        current = app.world().get::<ChildOf>(id).map(|parent| parent.parent());
    }
    true
}
