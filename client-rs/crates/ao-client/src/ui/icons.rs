//! Icons drawn from primitives, owned by this project.
//!
//! Deliberately not an icon font or a sprite sheet. A font would be another
//! third-party asset to license and ship, and a sheet would be artwork someone
//! has to draw before the shell can be finished. These are a handful of
//! rectangles and rounded corners composed into recognisable shapes, so they
//! are unambiguously ours, scale with the interface without resampling, and
//! recolour with the state of the control they sit in.
//!
//! They are also not a substitute for a name. Every icon ships with a tooltip
//! and an accessible name, because an unlabelled glyph is a guess — which is
//! the specific complaint that `LN`, `PIC`, `AUD`, `CBT` and `CFG` earned.

use super::tokens::{ink, size};
use bevy::prelude::*;

/// A control's human-readable name.
///
/// Rendered as a tooltip on hover and exposed to assistive technology. Held as
/// a localisation key rather than a sentence, so the interface can be
/// translated without hunting through widget code.
#[derive(Component, Debug, Clone, PartialEq, Eq)]
pub struct AccessibleName(pub String);

impl AccessibleName {
    pub fn new(key: &str) -> Self {
        Self(key.to_string())
    }
}

/// What an icon depicts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Icon {
    /// Language: a globe, as meridians over a circle.
    Language,
    /// Screenshot: a camera body with a lens.
    Screenshot,
    /// Audio: a speaker cone.
    Audio,
    /// Combat messages: crossed blades.
    Combat,
    /// Settings: a gear, as a hub with teeth.
    Settings,
    /// Support: a life ring.
    Support,
    /// Minimise: a single low bar.
    Minimise,
    /// Maximise: an open frame.
    Maximise,
    /// Close: an X.
    Close,
}

impl Icon {
    /// Localisation key for this icon's name.
    ///
    /// The key, not the text: an icon that ships an English sentence cannot be
    /// translated, and the whole point of pairing icons with names is that the
    /// name is readable by the player who needs it.
    pub fn name_key(self) -> &'static str {
        match self {
            Icon::Language => "action.language",
            Icon::Screenshot => "action.screenshot",
            Icon::Audio => "action.audio",
            Icon::Combat => "action.combat-messages",
            Icon::Settings => "action.settings",
            Icon::Support => "action.support",
            Icon::Minimise => "action.minimise",
            Icon::Maximise => "action.maximise",
            Icon::Close => "action.close",
        }
    }

    /// The strokes making up this icon, in a unit square.
    ///
    /// Coordinates are fractions of the icon's box, so one description serves
    /// every size the interface is drawn at.
    pub fn strokes(self) -> Vec<Stroke> {
        match self {
            Icon::Language => vec![
                Stroke::ring(0.5, 0.5, 0.42),
                // Meridian and equator: enough to read as a globe rather than
                // as a plain circle. Not thinner than this — at the top bar's
                // size a 0.06 stroke computes to 0.97 pixels and survives only
                // because the renderer clamps it, which is not a property to
                // depend on.
                Stroke::bar(0.5, 0.5, 0.10, 0.84),
                Stroke::bar(0.5, 0.5, 0.84, 0.10),
                Stroke::ring(0.5, 0.5, 0.20),
            ],
            Icon::Screenshot => vec![
                Stroke::bar(0.5, 0.58, 0.86, 0.52),
                // Viewfinder bump, so it is a camera and not a window.
                Stroke::bar(0.36, 0.26, 0.30, 0.16),
                Stroke::ring(0.5, 0.58, 0.20),
            ],
            Icon::Audio => vec![
                Stroke::bar(0.28, 0.5, 0.20, 0.34),
                Stroke::bar(0.46, 0.5, 0.16, 0.66),
                Stroke::ring(0.66, 0.5, 0.20),
                Stroke::ring(0.66, 0.5, 0.34),
            ],
            Icon::Combat => vec![
                Stroke::diagonal(0.5, 0.5, 0.80, 0.14, true),
                Stroke::diagonal(0.5, 0.5, 0.80, 0.14, false),
            ],
            Icon::Settings => vec![
                Stroke::ring(0.5, 0.5, 0.24),
                // Four teeth. Enough to read as a gear at 26 logical pixels;
                // more would blur into a disc.
                Stroke::bar(0.5, 0.12, 0.22, 0.22),
                Stroke::bar(0.5, 0.88, 0.22, 0.22),
                Stroke::bar(0.12, 0.5, 0.22, 0.22),
                Stroke::bar(0.88, 0.5, 0.22, 0.22),
            ],
            Icon::Support => vec![Stroke::ring(0.5, 0.5, 0.44), Stroke::ring(0.5, 0.5, 0.18)],
            Icon::Minimise => vec![Stroke::bar(0.5, 0.74, 0.62, 0.14)],
            Icon::Maximise => vec![Stroke::frame(0.5, 0.5, 0.66, 0.66)],
            Icon::Close => vec![
                Stroke::diagonal(0.5, 0.5, 0.72, 0.14, true),
                Stroke::diagonal(0.5, 0.5, 0.72, 0.14, false),
            ],
        }
    }
}

/// One mark in an icon, in unit-square coordinates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stroke {
    /// Centre, as a fraction of the icon box.
    pub centre: Vec2,
    /// Size, as a fraction of the icon box.
    pub size: Vec2,
    /// Fraction of the shorter side used as corner radius. 0.5 is a circle.
    pub radius: f32,
    /// Filled, or an outline.
    pub hollow: bool,
    /// Rotation in radians, for the diagonals.
    pub rotation: f32,
}

impl Stroke {
    pub fn bar(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            centre: Vec2::new(x, y),
            size: Vec2::new(width, height),
            radius: 0.0,
            hollow: false,
            rotation: 0.0,
        }
    }

    /// An outlined circle of `radius`, as a fraction of the box.
    pub fn ring(x: f32, y: f32, radius: f32) -> Self {
        Self {
            centre: Vec2::new(x, y),
            size: Vec2::splat(radius * 2.0),
            radius: 0.5,
            hollow: true,
            rotation: 0.0,
        }
    }

    pub fn frame(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            centre: Vec2::new(x, y),
            size: Vec2::new(width, height),
            radius: 0.0,
            hollow: true,
            rotation: 0.0,
        }
    }

    /// A bar rotated 45 degrees one way or the other.
    pub fn diagonal(x: f32, y: f32, length: f32, thickness: f32, ascending: bool) -> Self {
        Self {
            centre: Vec2::new(x, y),
            size: Vec2::new(length, thickness),
            radius: 0.0,
            hollow: false,
            rotation: if ascending {
                std::f32::consts::FRAC_PI_4
            } else {
                -std::f32::consts::FRAC_PI_4
            },
        }
    }
}

/// Build an icon at `box_size` logical pixels, in `colour`.
pub fn icon(kind: Icon, box_size: f32, colour: Color) -> impl Bundle {
    let strokes = kind.strokes();

    (
        Node {
            width: Val::Px(box_size),
            height: Val::Px(box_size),
            position_type: PositionType::Relative,
            ..default()
        },
        Children::spawn(SpawnIter(
            strokes.into_iter().map(move |stroke| stroke_node(stroke, box_size, colour)),
        )),
    )
}

/// The default icon size for a top-bar action.
pub fn action_icon(kind: Icon, colour: Color) -> impl Bundle {
    icon(kind, size::ICON_BUTTON * 0.62, colour)
}

fn stroke_node(stroke: Stroke, box_size: f32, colour: Color) -> impl Bundle {
    let width = (stroke.size.x * box_size).max(1.0);
    let height = (stroke.size.y * box_size).max(1.0);
    // Rounded relative to the shorter side, so a `radius` of 0.5 is a circle
    // whatever the aspect.
    let radius = stroke.radius * width.min(height);
    // Outlines are one pixel until the icon is large enough for two, so they
    // stay crisp at the sizes the top bar uses.
    let border = if box_size >= 24.0 { 2.0 } else { 1.0 };

    (
        Node {
            position_type: PositionType::Absolute,
            left: Val::Px(stroke.centre.x * box_size - width / 2.0),
            top: Val::Px(stroke.centre.y * box_size - height / 2.0),
            width: Val::Px(width),
            height: Val::Px(height),
            border: if stroke.hollow { UiRect::all(Val::Px(border)) } else { UiRect::ZERO },
            // A field on `Node` in this version rather than its own component.
            border_radius: BorderRadius::all(Val::Px(radius)),
            ..default()
        },
        if stroke.hollow { BackgroundColor(Color::NONE) } else { BackgroundColor(colour) },
        BorderColor::all(if stroke.hollow { colour } else { Color::NONE }),
        // Rotation is applied to the node's transform; layout positions it and
        // this spins it in place, which is how the diagonals are drawn without
        // needing a mesh.
        UiTransform::from_rotation(Rot2::radians(stroke.rotation)),
    )
}

/// A hover tooltip.
///
/// Positioned below its control and bounded so a long translation cannot run
/// off the edge of the window.
#[derive(Component, Debug, Clone, Copy)]
pub struct Tooltip;

/// Marks a control that shows `AccessibleName` on hover.
#[derive(Component, Debug, Clone, Copy)]
pub struct ShowsTooltip;

/// The tooltip layer, one per client.
///
/// A single reused node rather than one per control: a tooltip spawned beside
/// every button is hundreds of entities that exist to be invisible, and one of
/// them inevitably outlives its control.
#[derive(Component, Debug, Clone, Copy)]
pub struct TooltipLayer;

pub struct TooltipPlugin;

impl Plugin for TooltipPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, spawn_tooltip_layer).add_systems(Update, follow_hovered_control);
    }
}

fn spawn_tooltip_layer(mut commands: Commands) {
    commands.spawn((
        Node {
            position_type: PositionType::Absolute,
            display: Display::None,
            padding: UiRect::axes(
                Val::Px(super::tokens::space::SNUG),
                Val::Px(super::tokens::space::HAIR),
            ),
            max_width: Val::Px(260.0),
            border: UiRect::all(Val::Px(super::tokens::size::BORDER)),
            ..default()
        },
        BackgroundColor(super::tokens::surface::PANEL),
        BorderColor::all(super::tokens::surface::EDGE),
        // Above everything, and never a pointer target itself — a tooltip that
        // can be hovered flickers as it steals the pointer from its own
        // control.
        GlobalZIndex(1000),
        Pickable::IGNORE,
        TooltipLayer,
        children![tooltip_text("")],
    ));
}

/// Show the hovered control's name beneath it.
fn follow_hovered_control(
    hovered: Query<
        (&Interaction, &AccessibleName, &ComputedNode, &UiGlobalTransform),
        With<ShowsTooltip>,
    >,
    windows: Query<&Window>,
    mut layer: Query<(&mut Node, &Children), With<TooltipLayer>>,
    mut text: Query<&mut Text>,
) {
    let Ok((mut node, children)) = layer.single_mut() else {
        return;
    };

    let showing =
        hovered.iter().find(|(interaction, ..)| !matches!(interaction, Interaction::None));

    let Some((_, name, computed, transform)) = showing else {
        node.display = Display::None;
        return;
    };

    for child in children.iter() {
        if let Ok(mut text) = text.get_mut(child) {
            // The key is shown as-is until a catalogue exists. Better a visible
            // key than a blank tooltip: it still identifies the action, and it
            // makes the missing translation obvious rather than silent.
            text.0 = name.0.clone();
        }
    }

    let size = computed.size();
    let centre = transform.translation;
    let below = centre.y + size.y / 2.0 + super::tokens::space::TIGHT;

    // Clamped so a wide tooltip on the right-hand end of the bar stays on
    // screen rather than being cut off by the window edge.
    let window_width = windows.iter().next().map(|w| w.width()).unwrap_or(f32::MAX);
    let left = (centre.x - 60.0).clamp(0.0, (window_width - 120.0).max(0.0));

    node.display = Display::Flex;
    node.left = Val::Px(left);
    node.top = Val::Px(below);
}

pub fn tooltip_text(name: &str) -> impl Bundle {
    (
        Text::new(name.to_string()),
        TextFont { font_size: super::tokens::type_scale::MICRO, ..default() },
        TextColor(ink::PRIMARY),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Icon; 9] = [
        Icon::Language,
        Icon::Screenshot,
        Icon::Audio,
        Icon::Combat,
        Icon::Settings,
        Icon::Support,
        Icon::Minimise,
        Icon::Maximise,
        Icon::Close,
    ];

    #[test]
    fn every_icon_has_a_distinct_name_key() {
        // Two actions sharing a key means one of them is described to the
        // player as the other, which is worse than an unlabelled glyph.
        let mut keys: Vec<&str> = ALL.iter().map(|icon| icon.name_key()).collect();
        keys.sort_unstable();
        let before = keys.len();
        keys.dedup();
        assert_eq!(keys.len(), before, "two icons share a name key");
    }

    #[test]
    fn every_name_is_a_key_rather_than_a_sentence() {
        // An icon that ships English cannot be translated, and the point of
        // pairing an icon with a name is that the name is readable by the
        // player who needs it.
        for icon in ALL {
            let key = icon.name_key();
            assert!(key.contains('.'), "{icon:?} has a literal name: {key:?}");
            assert!(!key.contains(' '), "{icon:?} has a sentence: {key:?}");
        }
    }

    #[test]
    fn every_icon_actually_draws_something() {
        for icon in ALL {
            assert!(!icon.strokes().is_empty(), "{icon:?} draws nothing");
        }
    }

    #[test]
    fn every_stroke_stays_inside_its_box() {
        // A stroke that overflows its box overlaps the control beside it, and
        // in a row of nine that reads as a single smear.
        for icon in ALL {
            for stroke in icon.strokes() {
                // Diagonals are rotated about their centre, so their extent is
                // the half-diagonal rather than half the width.
                let extent = if stroke.rotation == 0.0 {
                    stroke.size / 2.0
                } else {
                    Vec2::splat((stroke.size.x + stroke.size.y) / 2.0 / std::f32::consts::SQRT_2)
                };

                let min = stroke.centre - extent;
                let max = stroke.centre + extent;
                assert!(
                    min.x >= -0.01 && min.y >= -0.01 && max.x <= 1.01 && max.y <= 1.01,
                    "{icon:?} has a stroke from {min:?} to {max:?}"
                );
            }
        }
    }

    #[test]
    fn icons_are_distinguishable_from_one_another() {
        // Two actions drawn identically are two unlabelled buttons that do
        // different things.
        for (i, a) in ALL.iter().enumerate() {
            for b in &ALL[i + 1..] {
                assert_ne!(a.strokes(), b.strokes(), "{a:?} and {b:?} are drawn the same");
            }
        }
    }

    #[test]
    fn a_stroke_is_never_thinner_than_a_pixel() {
        // Sub-pixel strokes vanish entirely at the sizes the top bar uses.
        for icon in ALL {
            for stroke in icon.strokes() {
                let smallest = stroke.size.min_element() * (size::ICON_BUTTON * 0.62);
                assert!(smallest >= 1.0, "{icon:?} has a {smallest}px stroke");
            }
        }
    }

    #[test]
    fn an_accessible_name_holds_a_key() {
        let name = AccessibleName::new("action.settings");
        assert_eq!(name.0, "action.settings");
    }
}
