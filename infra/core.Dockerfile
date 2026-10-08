FROM elixir:1.19-otp-28
WORKDIR /workspace/services/core
COPY services/core/mix.exs services/core/mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get
COPY services/core .
COPY content /workspace/content
RUN mix compile
EXPOSE 4000
CMD ["sh","-c","mix ecto.create && mix run --no-start priv/repo/init_schema.exs && mix ecto.migrate && mix run priv/repo/seeds.exs && PHX_SERVER=true mix run --no-halt"]
