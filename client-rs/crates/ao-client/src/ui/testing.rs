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
    let mut resolution = bevy::window::WindowResolution::default();
    resolution.set(size.x, size.y);

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
        super::rail::RailPlugin,
        super::character::CharacterPanelPlugin,
    ))
    .init_resource::<crate::world::ViewRadius>();

    // Spawn the tree, apply the geometry that produced, solve the layout the
    // geometry asked for, and let the clip pass propagate through it.
    for _ in 0..4 {
        app.update();
    }
    app
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
