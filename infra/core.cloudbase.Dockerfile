FROM elixir:1.19-otp-28 AS build
ENV MIX_ENV=prod
WORKDIR /workspace/services/core
COPY vendor/hex-2.5.1 /root/.mix/archives/hex-2.5.1
COPY vendor/rebar3 /root/.mix/elixir/1-19-otp-28/rebar3
COPY vendor/deps ./deps
COPY services/core/mix.exs services/core/mix.lock ./
RUN mix deps.compile
COPY services/core/config ./config
COPY services/core/lib ./lib
COPY services/core/priv ./priv
RUN mix compile --warnings-as-errors && mix release

FROM elixir:1.19-otp-28 AS runtime
ENV MIX_ENV=prod PHX_SERVER=true MEDIA_ROOT=/workspace/content/demo/media
WORKDIR /workspace/services/core
COPY --from=build /workspace/services/core/_build/prod/rel/ruxi ./
COPY content /workspace/content
RUN groupadd --system ruxi && useradd --system --gid ruxi ruxi
USER ruxi
EXPOSE 4000
CMD ["bin/ruxi", "start"]
