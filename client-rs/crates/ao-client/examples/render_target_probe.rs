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
//!   3. draw one sprite from a generated texture.
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
use bevy::render::render_resource::{
    Extent3d, TextureDimension, TextureFormat, TextureUsages,
};
use bevy::render::RenderPlugin;
use bevy::window::ExitCondition;
use std::time::Duration;

/// Deliberately tiny: this asks whether anything renders, not how much.
const SIZE: u32 = 64;

/// The clear colour, chosen to be nothing a default would produce.
const CLEAR: Color = Color::srgb(0.25, 0.0, 0.5);

/// Frames to wait before giving up. Readback is asynchronous.
const PATIENCE: u32 = 60;

/// Frames of rendering to allow before a readback is believed.
const SETTLE: u32 = 12;

#[derive(Resource)]
struct Probe {
    stage: u8,
    frames: u32,
    reported: bool,
}

fn main() {
    let stage: u8 = std::env::args()
        .nth(1)
        .and_then(|a| a.parse().ok())
        .unwrap_or(1);
    if !(1..=3).contains(&stage) {
        eprintln!("stage must be 1, 2 or 3");
        std::process::exit(2);
    }
    println!("== render target probe, stage {stage} ==");

    App::new()
        .insert_resource(Probe { stage, frames: 0, reported: false })
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
        .add_systems(Update, (give_up, report).chain())
        .run();
}

fn spawn(mut commands: Commands, mut images: ResMut<Assets<Image>>, probe: Res<Probe>) {
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

    if probe.stage >= 2 {
        // Colour only: no asset to load, nothing to go missing.
        commands.spawn((
            Sprite::from_color(Color::srgb(1.0, 1.0, 0.0), Vec2::splat(16.0)),
            Transform::default(),
        ));
    }

    if probe.stage >= 3 {
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

    // Read the texture back every frame until something arrives.
    commands.spawn(Readback::texture(handle)).observe(observe);
}

/// Report what the GPU actually produced.
fn observe(complete: On<ReadbackComplete>, mut probe: ResMut<Probe>, mut exit: MessageWriter<AppExit>) {
    if probe.reported {
        return;
    }
    // Readback fires every frame, and the earliest completions can describe the
    // texture before anything has rendered into it. Reporting the first one made
    // this probe claim a failure it had not observed — the initial fill read back
    // as "never cleared". Wait for several frames of real rendering first.
    if probe.frames < SETTLE {
        return;
    }
    probe.reported = true;

    let data: &[u8] = &complete.data;
    let expected_clear = [64u8, 0, 128];
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

    let cleared = data
        .chunks_exact(4)
        .any(|p| p[..3].iter().zip(expected_clear).all(|(a, b)| a.abs_diff(b) <= 4));
    let untouched = data.chunks_exact(4).all(|p| p[..3] == [0, 0, 0]);

    match probe.stage {
        1 => {
            if untouched {
                println!("   RESULT: FAIL — the target was never cleared. Rendering into an");
                println!("           image target does not reach the texture at all here.");
            } else if cleared {
                println!("   RESULT: PASS — the clear colour reached the texture.");
            } else {
                println!("   RESULT: UNCLEAR — the texture changed but not to the clear colour.");
            }
        }
        2 | 3 => {
            let drew = distinct.len() > 1;
            if !cleared {
                println!("   RESULT: FAIL — stage 1 regressed; fix that before reading this.");
            } else if drew {
                println!("   RESULT: PASS — geometry reached the texture, not just the clear.");
            } else {
                println!("   RESULT: FAIL — cleared, but nothing was drawn into it.");
                println!("           So the camera writes to the target and the draw does not.");
            }
        }
        _ => {}
    }

    exit.write(AppExit::Success);
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

fn report() {}
