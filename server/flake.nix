{
  description = "Argentum Online Elixir Server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        erlang = pkgs.beam.packages.erlang_26;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            erlang.erlang
            erlang.elixir_1_16
            pkgs.postgresql_16
            pkgs.rustc
            pkgs.cargo
            # clippy and rustfmt must come from the same nixpkgs revision as
            # rustc. Leaving them out does not disable them — cargo falls
            # through to whatever toolchain is on the ambient PATH, and a
            # clippy-driver from a different rustc cannot read the artifacts
            # cargo build just produced. That surfaces as a baffling
            # `E0514: found crate bevy compiled by an incompatible version of
            # rustc` on a tree that builds and tests cleanly.
            pkgs.clippy
            pkgs.rustfmt
            pkgs.clang
            pkgs.gnumake
            pkgs.nodejs_22
            pkgs.protobuf
            pkgs.cacert
            # Rust/WASM client (client-rs). rustc ships the wasm32 std but not a
            # linker for it, so lld is required; wasm-bindgen generates the JS
            # bindings and binaryen's wasm-opt shrinks the release build.
            pkgs.lld
            pkgs.wasm-bindgen-cli
            pkgs.binaryen
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.inotify-tools
            # Native desktop build of client-rs. Bevy links windowing, input,
            # audio and graphics at build time, so without these the native
            # target fails to compile at all — which also silently stops
            # `cargo test -p ao-client` from ever running.
            pkgs.pkg-config
            pkgs.alsa-lib
            pkgs.udev
            pkgs.vulkan-loader
            pkgs.libxkbcommon
            pkgs.wayland
            pkgs.libx11
            pkgs.libxcursor
            pkgs.libxi
            pkgs.libxrandr
          ];

          # Bevy loads Vulkan and the windowing libraries with dlopen at
          # runtime, so having them at link time is not enough.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
            pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.alsa-lib
              pkgs.udev
              pkgs.vulkan-loader
              pkgs.libxkbcommon
              pkgs.wayland
              pkgs.libx11
              pkgs.libxcursor
              pkgs.libxi
              pkgs.libxrandr
            ]
          );

          shellHook = ''
            export PATH="$HOME/.mix/escripts:$PATH"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export HEX_CACERTS_PATH="$SSL_CERT_FILE"
            # Anchor the cluster to the repo, not $PWD. Entering the shell
            # from client-rs (or anywhere else) used to initialise a second,
            # stray postgres data directory there.
            AO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
            export PGDATA="$AO_ROOT/server/.pgdata"
            export PGHOST="$PGDATA"
            export PGPORT="5432"

            if [ ! -d "$PGDATA" ]; then
              echo "Initializing PostgreSQL..."
              initdb --auth=trust --no-locale --encoding=UTF8
              echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              echo "listen_addresses = '127.0.0.1'" >> "$PGDATA/postgresql.conf"
              echo "port = 5432" >> "$PGDATA/postgresql.conf"
              pg_ctl start -l "$PGDATA/postgres.log"
              createuser -s postgres 2>/dev/null || true
              echo "PostgreSQL initialized and started."
            elif ! pg_isready -q 2>/dev/null; then
              pg_ctl start -l "$PGDATA/postgres.log"
              echo "PostgreSQL started."
            else
              echo "PostgreSQL already running."
            fi
          '';
        };
      });
}
