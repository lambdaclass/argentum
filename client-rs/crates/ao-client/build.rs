//! Stamps the build identity into the binary.
//!
//! The top bar shows this so a screenshot can be matched to a commit. Without
//! it, "this is how it looks now" and "I just fixed that" are impossible to
//! line up — which cost a round trip more than once.

use std::process::Command;

fn main() {
    // Only when the caller has not supplied one; CI sets its own.
    println!("cargo:rerun-if-env-changed=AO_BUILD");
    if std::env::var("AO_BUILD").is_ok() {
        return;
    }

    let Some(sha) = run(&["rev-parse", "--short=7", "HEAD"]) else {
        return;
    };

    // Dirtiness is scoped to what actually goes into this binary. Using a bare
    // `git describe --dirty` made the stamp flip whenever any file in the
    // repository was edited — a note in the roadmap was enough — so a verified
    // build would fail its own check moments later for a change that could not
    // possibly be in it.
    let sources = ["crates", "assets", "Cargo.toml", "Cargo.lock"];
    let mut args = vec!["status", "--porcelain", "--"];
    args.extend_from_slice(&sources);
    let dirty = run(&args).map(|out| !out.is_empty()).unwrap_or(false);

    let stamp = if dirty { format!("{sha}-dirty") } else { sha };
    println!("cargo:rustc-env=AO_BUILD={stamp}");

    // Everything the stamp is computed from, or it goes stale and starts lying.
    //
    // Naming any rerun-if-changed turns off cargo's default of re-running when
    // a package file changes, so the sources have to be listed too. Without
    // them this script only re-ran when HEAD moved: editing a source file left
    // the previous stamp baked in, which is precisely when "-dirty" should have
    // appeared and did not. `./build.sh web` then failed its own check with a
    // message blaming a stale artifact, and `cargo clean -p` did not help
    // because the script still had no reason to run again.
    for source in ["crates", "assets", "Cargo.toml", "Cargo.lock"] {
        println!("cargo:rerun-if-changed=../../{source}");
    }
    println!("cargo:rerun-if-changed=../../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../../.git/refs/heads");
}

/// Run a git command from the client directory, or `None` if it fails.
fn run(args: &[&str]) -> Option<String> {
    Command::new("git")
        .args(args)
        .current_dir("../..")
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|text| text.trim().to_string())
}
