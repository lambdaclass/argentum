ARG ELIXIR_VERSION=1.16.3
ARG OTP_VERSION=26.2.5.5
ARG DEBIAN_CODENAME=bookworm

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_CODENAME}-20240612"
ARG RUNNER_IMAGE="debian:${DEBIAN_CODENAME}-slim"

# ---------- build stage ----------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl clang protobuf-compiler && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Rust (needed for TileGrid NIF)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /app

ENV MIX_ENV="prod"

RUN mix local.hex --force && mix local.rebar --force

# Deps first (cache layer)
COPY mix.exs mix.lock ./
COPY apps/ao_protocol/mix.exs apps/ao_protocol/mix.exs
COPY apps/ao_session/mix.exs apps/ao_session/mix.exs
COPY apps/ao_tcp_gateway/mix.exs apps/ao_tcp_gateway/mix.exs
COPY apps/arena/mix.exs apps/arena/mix.exs
COPY apps/bot_army/mix.exs apps/bot_army/mix.exs
COPY apps/game_backend/mix.exs apps/game_backend/mix.exs
COPY config/config.exs config/prod.exs config/runtime.exs config/

RUN mix deps.get --only prod && mix deps.compile

# Rust NIF source
COPY apps/arena/native apps/arena/native

# App source
COPY apps apps
COPY config config

RUN mix compile --warnings-as-errors
RUN mix release argentum

# ---------- runner stage ----------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/argentum ./
COPY --from=builder /app/apps/game_backend/priv/repo/migrations ./priv/repo/migrations

ENV PHX_SERVER=true

EXPOSE 3000 7666 7667

CMD ["bin/argentum", "start"]
