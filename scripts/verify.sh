#!/bin/sh
# Run after provisioning the isolated ruxi_test database and installing dependencies.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root/services/core"
MIX_ENV=test mix run --no-start priv/repo/init_schema.exs
MIX_ENV=test mix ecto.migrate
mix compile --warnings-as-errors
mix test
cd "$project_root/services/worker"
uv run pytest
cd "$project_root"
python3 scripts/generate_contracts.py
node --test scripts/protocol_client.test.mjs
for app in mobile creator; do
  cd "$project_root/apps/$app"
  flutter analyze
  flutter test
  flutter build web
 done
cd "$project_root"
git diff --check
