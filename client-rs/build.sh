#!/usr/bin/env bash
# Build the Rust client.
#
#   ./build.sh web       wasm bundle in web/pkg, served by web/index.html
#   ./build.sh native    desktop binary (Linux/macOS/Windows)
#   ./build.sh check     fast type-check of both targets
#
# Run inside the dev shell so the pinned toolchain is used:
#   nix develop ../server --command ./build.sh web
set -euo pipefail

cd "$(dirname "$0")"
export CARGO_HOME="${CARGO_HOME:-$PWD/.cargo}"

TARGET="${1:-web}"

# binaryen 126 rejects the wasm rustc emits unless these post-MVP features are
# enabled explicitly. Without them wasm-opt fails with a bare
# "error validating input", which does not hint at the cause.
WASM_OPT_FEATURES=(
  --enable-bulk-memory
  --enable-nontrapping-float-to-int
  --enable-sign-ext
  --enable-mutable-globals
  --enable-reference-types
  --enable-multivalue
  --enable-simd
  --enable-extended-const
)

size_mb() { awk '{printf "%.1f MB\n", $1/1048576}' <<<"$(stat -c %s "$1")"; }

case "$TARGET" in
  web)
    echo "==> cargo build (wasm32-unknown-unknown, release)"
    cargo build -p ao-client --release --target wasm32-unknown-unknown

    raw=target/wasm32-unknown-unknown/release/ao-client.wasm
    echo "    raw:        $(size_mb "$raw")"

    echo "==> wasm-bindgen"
    # wasm-bindgen refuses to run when the CLI and crate versions differ; the
    # workspace pins the crate to match the CLI in the dev shell.
    wasm-bindgen --target web --no-typescript --out-dir web/pkg "$raw"
    echo "    bindgen:    $(size_mb web/pkg/ao-client_bg.wasm)"

    echo "==> wasm-opt -Os"
    wasm-opt -Os "${WASM_OPT_FEATURES[@]}" \
      -o web/pkg/ao-client_bg.opt.wasm web/pkg/ao-client_bg.wasm
    mv web/pkg/ao-client_bg.opt.wasm web/pkg/ao-client_bg.wasm
    echo "    optimized:  $(size_mb web/pkg/ao-client_bg.wasm)"

    echo
    echo "Serve it:  python3 -m http.server 8080 --directory web"
    echo "Then open: http://localhost:8080"
    ;;

  native)
    echo "==> cargo build (native, release)"
    # Needs system graphics/input libraries. On NixOS use the dev shell, which
    # is where those are provided.
    cargo build -p ao-client --release
    echo "    binary: target/release/ao-client"
    ;;

  check)
    echo "==> check wasm target"
    cargo check -p ao-client --target wasm32-unknown-unknown
    echo "==> check native target"
    cargo check -p ao-client
    echo "==> test shared core"
    cargo test -p ao-core
    ;;

  *)
    echo "unknown target: $TARGET (expected web | native | check)" >&2
    exit 1
    ;;
esac
