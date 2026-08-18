//! Does rendering into an image target work here, and at which step does it stop?
//!
//! The production offscreen world target was implemented and reverted because
//! the texture came out empty with no wgpu validation error anywhere. Three
//! things were changed at once while diagnosing it — frustum culling, asset
//! usages, MSAA — which is why the answer never became clear.
//!
//! This isolates the question into stages that fail one at a time, and reads the
//! texture back so the answer is pixels rather than a screenshot:
//!
//!   1. clear an image target to a known colour;
//!   2. draw one colour-only quad into it, needing no asset;
//!   3. draw one sprite from a generated texture — and only that, so a failure
//!      here is unambiguously about sampling;
//!   4. two cameras in one frame — one drawing into a texture, a second sampling
//!      that texture into a different one, which is the production arrangement
//!      minus the window swapchain.
//!
//! Run each separately, and run native and WebGL2 separately, so texture
//! writing, sampling and camera ordering are never diagnosed together:
//!
//!   cargo run -p ao-client --example render_target_probe -- 1
//!
//! Native uses whatever Vulkan device is present; lavapipe is enough. The WASM
//! side of the same question needs the browser and is not this file's job — this
//! establishes the native baseline, and a stage that fails here was never a
//! WebGL2 problem.

use bevy::app::{AppExit, ScheduleRunnerPlugin};
use bevy::camera::RenderTarget;
use bevy::prelude::*;
use bevy::render::gpu_readback::{Readback, ReadbackComplete};
use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat, TextureUsages};
use bevy::render::RenderPlugin;
use bevy::window::ExitCondition;
use std::time::Duration;

/// Deliberately tiny: this asks whether anything renders, not how much.
const SIZE: u32 = 64;

/// The clear colour, chosen to be nothing a default would produce.
const CLEAR: Color = Color::srgb(0.25, 0.0, 0.5);
/// The same, as the bytes it reads back as.
const CLEAR_BYTES: [u8; 3] = [64, 0, 128];

/// The colour-only quad of stages 2 and 4.
const QUAD: Color = Color::srgb(1.0, 1.0, 0.0);
const QUAD_BYTES: [u8; 3] = [255, 255, 0];

/// The generated texture stage 3 samples. Distinct from the quad on purpose:
/// stage 3 has to prove sampling, not merely that something was drawn.
const SAMPLED_BYTES: [u8; 3] = [0, 255, 255];

/// Frames to wait before giving up. Readback is asynchronous.
const PATIENCE: u32 = 60;

/// Frames of rendering to allow before a readback is believed.
const SETTLE: u32 = 12;

#[derive(Resource)]
struct Probe {
    stage: u8,
    frames: u32,
    reported: bool,
    /// The texture to read, held until the settling frames have passed.
    ///
    /// Requesting readback from the start and then ignoring early completions
    /// was not enough: a completion accepted on frame 12 may describe a copy
    /// submitted on frame 1. The request itself has to be late.
    pending: Option<Handle<Image>>,
    requested: bool,
}

fn main() -> AppExit {
    // Returned, not discarded: `App::run` hands back an `AppExit` and a `main`
    // that ignores it exits zero however the probe ended, which is how a FAIL
    // verdict still reported success.
    let stage: u8 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1);
    if !(1..=4).contains(&stage) {
        eprintln!("stage must be 1, 2, 3 or 4");
        return AppExit::from_code(2);
    }
    println!("== render target probe, stage {stage} ==");

    App::new()
        .insert_resource(Probe {
            stage,
            frames: 0,
            reported: false,
            pending: None,
            requested: false,
        })
        .add_plugins(
            DefaultPlugins
                .set(WindowPlugin {
                    // Headless: no window, so this runs over ssh and in CI. The
                    // render device is created either way.
                    primary_window: None,
                    exit_condition: ExitCondition::DontExit,
                    ..default()
                })
                .set(RenderPlugin { ..default() })
                .set(ImagePlugin::default_nearest()),
        )
        .add_plugins(ScheduleRunnerPlugin::run_loop(Duration::from_millis(16)))
        .add_systems(Startup, spawn)
        .add_systems(Update, (give_up, request_readback).chain())
        .run()
}

/// An empty target of `size`, usable as a camera attachment and as a texture.
fn target_image(size: u32) -> Image {
    let mut image = Image::new_fill(
        Extent3d { width: size, height: size, depth_or_array_layers: 1 },
        TextureDimension::D2,
        // Opaque black, so "cleared" is distinguishable from "never touched".
        &[0, 0, 0, 255],
        TextureFormat::Rgba8UnormSrgb,
        bevy::asset::RenderAssetUsages::default(),
    );
    image.texture_descriptor.usage = TextureUsages::TEXTURE_BINDING
        | TextureUsages::COPY_DST
        | TextureUsages::COPY_SRC
        | TextureUsages::RENDER_ATTACHMENT;
    image
}

/// Stage 4: the production shape. One camera draws the scene into a texture; a
/// second camera, later in the order and on its own layer, samples that texture
/// through a quad into a second texture. If this passes natively then two target
/// kinds in one frame are fine and the browser is the differentiator.
fn spawn_two_cameras(commands: &mut Commands, images: &mut Assets<Image>) -> Handle<Image> {
    let scene = images.add(target_image(SIZE));
    let presented = images.add(target_image(SIZE));

    // Layer 1 is the scene; layer 2 is the presentation. Separated exactly as
    // production separates world from compositor, so a shared layer cannot make
    // this pass for the wrong reason.
    commands.spawn((
        Camera2d,
        Camera { order: -1, clear_color: ClearColorConfig::Custom(CLEAR), ..default() },
        RenderTarget::Image(scene.clone().into()),
        bevy::camera::visibility::RenderLayers::layer(1),
        Msaa::Off,
    ));
    commands.spawn((
        Sprite::from_color(QUAD, Vec2::splat(16.0)),
        Transform::default(),
        bevy::camera::visibility::RenderLayers::layer(1),
    ));

    commands.spawn((
        Camera2d,
        Camera { order: 0, clear_color: ClearColorConfig::Custom(Color::BLACK), ..default() },
        RenderTarget::Image(presented.clone().into()),
        bevy::camera::visibility::RenderLayers::layer(2),
        Msaa::Off,
    ));
    commands.spawn((
        Sprite { image: scene, custom_size: Some(Vec2::splat(SIZE as f32)), ..default() },
        Transform::default(),
        // The production quad needed this: sprite bounds come from the image, and
        // a render target has no useful main-world dimensions.
        bevy::camera::visibility::NoFrustumCulling,
        bevy::camera::visibility::RenderLayers::layer(2),
    ));

    presented
}

fn spawn(mut commands: Commands, mut images: ResMut<Assets<Image>>, mut probe: ResMut<Probe>) {
    if probe.stage == 4 {
        let presented = spawn_two_cameras(&mut commands, &mut images);
        probe.pending = Some(presented);
        return;
    }

    let mut target = Image::new_fill(
        Extent3d { width: SIZE, height: SIZE, depth_or_array_layers: 1 },
        TextureDimension::D2,
        // Opaque black, so "cleared" is distinguishable from "never touched".
        &[0, 0, 0, 255],
        TextureFormat::Rgba8UnormSrgb,
        bevy::asset::RenderAssetUsages::default(),
    );
    target.texture_descriptor.usage = TextureUsages::TEXTURE_BINDING
        | TextureUsages::COPY_DST
        | TextureUsages::COPY_SRC
        | TextureUsages::RENDER_ATTACHMENT;
    let handle = images.add(target);

    // The camera that renders into the texture. `Msaa::Off` because the target
    // has one sample and a camera asking for four resolves into nothing.
    commands.spawn((
        Camera2d,
        Camera { order: 0, clear_color: ClearColorConfig::Custom(CLEAR), ..default() },
        RenderTarget::Image(handle.clone().into()),
        Msaa::Off,
    ));

    if probe.stage == 2 {
        // Colour only: no asset to load, nothing to go missing.
        commands.spawn((Sprite::from_color(QUAD, Vec2::splat(16.0)), Transform::default()));
    }

    if probe.stage == 3 {
        // A generated texture, so stage 3 differs from stage 2 only by sampling.
        let mut pixels = Vec::with_capacity(4 * 4 * 4);
        for _ in 0..16 {
            pixels.extend_from_slice(&[0, 255, 255, 255]);
        }
        let sprite = images.add(Image::new(
            Extent3d { width: 4, height: 4, depth_or_array_layers: 1 },
            TextureDimension::D2,
            pixels,
            TextureFormat::Rgba8UnormSrgb,
            bevy::asset::RenderAssetUsages::default(),
        ));
        commands.spawn((
            Sprite { image: sprite, custom_size: Some(Vec2::splat(24.0)), ..default() },
            Transform::from_xyz(0.0, 0.0, 1.0),
        ));
    }

    // Requested later, by `request_readback`, so the copy that completes cannot
    // predate the rendering it is supposed to describe.
    probe.pending = Some(handle);
}

/// Ask for the texture only once the scene has been rendering for a while.
fn request_readback(mut commands: Commands, mut probe: ResMut<Probe>) {
    if probe.requested || probe.frames < SETTLE {
        return;
    }
    let Some(handle) = probe.pending.take() else {
        return;
    };
    probe.requested = true;
    commands.spawn(Readback::texture(handle)).observe(observe);
}

/// Whether any pixel is within tolerance of `want`.
fn contains(data: &[u8], want: [u8; 3]) -> bool {
    data.chunks_exact(4).any(|p| p[..3].iter().zip(want).all(|(a, b)| a.abs_diff(b) <= 6))
}

/// Report what the GPU actually produced, and say so in the exit code.
///
/// Every stage names the exact colour it expects. Stage 3 used to pass on "more
/// than one colour present", which the stage-2 quad already guarantees — so it
/// could not fail even if sampling a texture were completely broken.
fn observe(
    complete: On<ReadbackComplete>,
    mut probe: ResMut<Probe>,
    mut exit: MessageWriter<AppExit>,
) {
    if probe.reported {
        return;
    }
    probe.reported = true;

    let data: &[u8] = &complete.data;
    let centre = ((SIZE as usize / 2) * SIZE as usize + SIZE as usize / 2) * 4;

    let distinct = {
        let mut seen: Vec<[u8; 4]> = Vec::new();
        for chunk in data.chunks_exact(4) {
            let pixel = [chunk[0], chunk[1], chunk[2], chunk[3]];
            if !seen.contains(&pixel) {
                seen.push(pixel);
                if seen.len() > 8 {
                    break;
                }
            }
        }
        seen
    };

    println!("   bytes read back: {}", data.len());
    println!("   centre pixel:    {:?}", &data.get(centre..centre + 4));
    println!("   distinct pixels: {distinct:?}");

    // The colours each stage puts on the screen, by construction.
    let cleared = contains(data, CLEAR_BYTES);
    let quad = contains(data, QUAD_BYTES);
    let sampled = contains(data, SAMPLED_BYTES);
    let untouched = data.chunks_exact(4).all(|p| p[..3] == [0, 0, 0]);

    let (ok, verdict) = match probe.stage {
        1 if untouched => (
            false,
            "the target was never cleared — rendering into an image target does not reach the texture",
        ),
        1 if cleared => (true, "the clear colour reached the texture"),
        1 => (false, "the texture changed, but not to the clear colour"),

        2 if !cleared => (false, "stage 1 regressed; fix that before reading this"),
        2 if quad => (true, "a colour-only quad reached the texture"),
        2 => (false, "cleared, but the quad was not drawn into it"),

        // Specifically the cyan of the generated texture. "More than one colour"
        // is satisfied by the quad alone and proves nothing about sampling.
        3 if !cleared => (false, "stage 1 regressed; fix that before reading this"),
        3 if sampled => (true, "a sprite sampling a generated texture reached the target"),
        3 => (
            false,
            "cleared, but the sampled texture did not draw — sampling is the broken step",
        ),

        4 if cleared && quad => (
            true,
            "two cameras and two targets in one frame work; the browser, not the arrangement, is the difference",
        ),
        4 if !cleared && !quad => (
            false,
            "the presented texture has none of the scene — the second camera never sampled the first one's target",
        ),
        4 if quad => (false, "the quad arrived but the first target's clear did not"),
        4 => (false, "the first target's clear arrived but the quad did not"),

        _ => (false, "unknown stage"),
    };

    println!("   RESULT: {} — {verdict}", if ok { "PASS" } else { "FAIL" });
    // A diagnostic that exits zero on failure is a diagnostic nothing can gate
    // on: a script running all four stages would report success throughout.
    exit.write(if ok { AppExit::Success } else { AppExit::from_code(1) });
}

/// Do not hang if readback never completes; that is itself the answer.
fn give_up(mut probe: ResMut<Probe>, mut exit: MessageWriter<AppExit>) {
    probe.frames += 1;
    if probe.frames > PATIENCE && !probe.reported {
        println!("   RESULT: FAIL — no readback completed in {PATIENCE} frames.");
        println!("           The texture was never copied back, so nothing can be said");
        println!("           about what was rendered into it.");
        exit.write(AppExit::from_code(1));
    }
}
