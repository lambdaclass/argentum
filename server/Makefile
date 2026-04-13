.PHONY: deps db setup run start test console format credo check docs clean purge pg.start pg.stop client.dev client.build client.typecheck client.preview client.clean docker.up docker.down docker.migrate docker.test docker.build stats stats.code stats.test stats.ratio

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

# ---- Stats ----

stats:
	@echo "=== Server: code vs test lines per app ==="
	@for app in apps/*/; do \
		name=$$(basename $$app); \
		code=$$(find $$app/lib -name '*.ex' 2>/dev/null | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
		tests=$$(find $$app/test -name '*.exs' 2>/dev/null | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
		printf "  %-20s %6s code  %6s test  (%s%%)\n" "$$name" "$$code" "$$tests" "$$(echo "scale=0; $$tests * 100 / ($$code + 1)" | bc)"; \
	done
	@echo ""
	@total_code=$$(find apps/*/lib -name '*.ex' | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
	total_test=$$(find apps/*/test -name '*.exs' | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
	printf "  %-20s %6s code  %6s test  (%s%%)\n" "TOTAL" "$$total_code" "$$total_test" "$$(echo "scale=0; $$total_test * 100 / ($$total_code + 1)" | bc)"
	@echo ""
	@echo "=== Client: code vs test lines ==="
	@client=../client; \
	code=$$(find $$client/src -name '*.ts' -o -name '*.tsx' 2>/dev/null | grep -v '\.test\.' | grep -v '\.spec\.' | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
	unit=$$(find $$client/src -name '*.test.*' 2>/dev/null | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
	e2e=$$(find $$client/tests -name '*.spec.*' 2>/dev/null | xargs cat 2>/dev/null | wc -l | tr -d ' '); \
	tests=$$((unit + e2e)); \
	printf "  %-20s %6s code  %6s test  (%s%%)\n" "client" "$$code" "$$tests" "$$(echo "scale=0; $$tests * 100 / ($$code + 1)" | bc)"; \
	printf "  %-20s %13s unit  %5s e2e\n" "" "$$unit" "$$e2e"

# ---- Docker ----

docker.up:
	docker compose up -d postgres

docker.down:
	docker compose down

docker.migrate: docker.up
	docker compose run --rm migrate

docker.test: docker.up
	docker compose run --rm test

docker.build:
	docker build -t argentum:latest .
