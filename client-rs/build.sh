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

# The client must compile no hosts and no credentials: in production it derives
# its endpoints from the page origin, and development values live in
# web/index.html, which is the host page rather than the artifact.
#
# The values to look for are read out of index.html rather than listed here, so
# this keeps testing the real thing when the dev configuration changes. A
# regression is easy to reintroduce — one `const` is enough — and invisible
# until something is deployed against the wrong host.
assert_no_embedded_config() {
  local artifact="$1"
  local failed=0

  while read -r value; do
    [ -z "$value" ] && continue
    if grep -aqF -- "$value" "$artifact"; then
      echo "    FAIL: \"$value\" is compiled into $artifact" >&2
      failed=1
    fi
  done < <(sed -n 's/.*<meta name="ao:[^"]*" content="\([^"]*\)".*/\1/p' web/index.html)

  if [ "$failed" -ne 0 ]; then
    echo "    Configuration belongs in the page or the environment, not the binary." >&2
    return 1
  fi

  echo "    no hosts or credentials embedded"
}

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

    echo "==> configuration check"
    assert_no_embedded_config web/pkg/ao-client_bg.wasm

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
    echo
    # Native has no page origin to derive from, so it will not start without
    # these. That is deliberate: the alternative is a host compiled into the
    # binary.
    echo "Run it:  AO_ASSET_ORIGIN=http://127.0.0.1:4000 \\"
    echo "         AO_GATEWAY_URL=ws://127.0.0.1:7667/ao \\"
    echo "         AO_CHARACTER_NAME=... AO_CHARACTER_PASSWORD=... \\"
    echo "         target/release/ao-client"
    ;;

  check)
    echo "==> roadmap structure"
    bash scripts/check_roadmap.sh
    echo "==> formatting"
    cargo fmt --all --check
    echo "==> check wasm target"
    cargo check -p ao-client --target wasm32-unknown-unknown
    echo "==> check native target"
    cargo check -p ao-client
    # Both crates, not just ao-core: ao-client holds the config resolution and
    # session bookkeeping, and those are exactly the parts that are easy to get
    # wrong without a browser noticing.
    echo "==> test"
    cargo test --workspace
    if [ -f web/pkg/ao-client_bg.wasm ]; then
      echo "==> configuration check"
      assert_no_embedded_config web/pkg/ao-client_bg.wasm
    fi
    ;;

  *)
    echo "unknown target: $TARGET (expected web | native | check)" >&2
    exit 1
    ;;
esac
