.PHONY: deps db setup run start test console format credo check docs clean purge pg.start pg.stop client.dev client.build client.typecheck client.preview client.clean

NIX := nix develop --command

# ---- PostgreSQL ----

pg.start:
	@if pg_isready -q 2>/dev/null; then \
		echo "PostgreSQL already running."; \
	elif [ -d .pgdata ]; then \
		pg_ctl start -D .pgdata -l .pgdata/postgres.log; \
		echo "PostgreSQL started."; \
	else \
		echo "Run 'nix develop' first to initialize PostgreSQL."; \
		exit 1; \
	fi

pg.stop:
	@pg_ctl stop -D .pgdata 2>/dev/null || true

# ---- Development ----

deps:
	$(NIX) mix local.hex --force --if-missing
	$(NIX) mix local.rebar --force --if-missing
	$(NIX) mix deps.get

db: deps
	$(NIX) mix ecto.reset

setup: deps db

run:
	$(NIX) iex --sname argentum --cookie argentum -S mix phx.server

../client/node_modules: ../client/package.json
	$(NIX) npm --prefix ../client install

client.dev: ../client/node_modules
	$(NIX) npm --prefix ../client run dev -- --host 127.0.0.1 --port 5173

client.build: ../client/node_modules
	$(NIX) npm --prefix ../client run build

client.typecheck: ../client/node_modules
	$(NIX) npm --prefix ../client run typecheck

client.preview: ../client/node_modules
	$(NIX) npm --prefix ../client run preview -- --host 127.0.0.1 --port 4173

daemon:
	$(NIX) elixir --sname argentum --cookie argentum --no-halt -S mix phx.server

attach:
	$(NIX) iex --sname remote_$$(date +%s) --cookie argentum --remsh argentum

start: pg.start setup run

test: pg.start
	$(NIX) mix test

test.protocol:
	$(NIX) mix test --only app:ao_protocol

test.arena:
	$(NIX) mix test --only app:arena

test.backend:
	$(NIX) mix test --only app:game_backend

console:
	$(NIX) iex -S mix

# ---- Quality ----

format:
	$(NIX) mix format

credo:
	$(NIX) mix credo

check: format credo

docs:
	$(NIX) mix docs

# ---- Cleanup ----

clean:
	$(NIX) mix clean
	rm -rf _build/dev _build/test

client.clean:
	rm -rf ../client/node_modules ../client/dist

purge: pg.stop
	rm -rf _build/ deps/ .pgdata/ ../client/node_modules ../client/dist
