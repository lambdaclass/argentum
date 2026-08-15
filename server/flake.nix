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
          ];

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
