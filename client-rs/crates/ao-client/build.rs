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

    let short_sha = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|sha| sha.trim().to_string())
        .filter(|sha| !sha.is_empty());

    if let Some(sha) = short_sha {
        println!("cargo:rustc-env=AO_BUILD={sha}");
        // Rebuild when HEAD moves, or the stamp goes stale and starts lying.
        println!("cargo:rerun-if-changed=../../../.git/HEAD");
        println!("cargo:rerun-if-changed=../../../.git/refs/heads");
    }
}
