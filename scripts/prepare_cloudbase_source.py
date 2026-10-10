#!/usr/bin/env python3
"""Build an allowlisted, credential-free source bundle for CloudBase Linux builds.

Run `mix deps.get` locally first. Dependency source and pinned build tools are
included because public Hex downloads can time out in the remote build network.
No local compiled artifacts, auth files or dotenv files are included.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=root / '.local/deploy/core')
args = parser.parse_args()
stage = args.output.resolve()
if stage == root or stage in root.parents:
    raise SystemExit('Choose a separate staging directory')
stage.mkdir(parents=True, exist_ok=True)
for rel in ['services/core/lib', 'services/core/config', 'services/core/priv', 'content']:
    dest = stage / rel
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(root / rel, dest)
for rel in ['services/core/mix.exs', 'services/core/mix.lock']:
    dest = stage / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / rel, dest)
result = subprocess.run(['mix', 'run', '--no-start', '-e', 'IO.puts(Mix.Utils.mix_home())'], cwd=root / 'services/core', capture_output=True, text=True, check=True)
mix_home = Path(result.stdout.strip().splitlines()[-1])
hex_dirs = sorted((mix_home / 'archives').glob('hex-*'))
rebar = list(mix_home.glob('elixir/*/rebar3'))
if not hex_dirs or not rebar:
    raise SystemExit('Install Hex and Rebar locally with mix local.hex and mix local.rebar')
vendor = stage / 'vendor'
if vendor.exists():
    shutil.rmtree(vendor)
shutil.copytree(root / 'services/core/deps', vendor / 'deps', ignore=shutil.ignore_patterns('_build', '*.beam', '.git', '.DS_Store'))
shutil.copytree(hex_dirs[-1], vendor / 'hex-2.5.1')
shutil.copy2(rebar[-1], vendor / 'rebar3')
shutil.copy2(root / 'infra/core.cloudbase.Dockerfile', stage / 'Dockerfile')
(stage / '.dockerignore').write_text((root / '.dockerignore').read_text() + '\n!vendor/deps\n!vendor/deps/**\n')
(stage / 'cloudbaserc.json').unlink(missing_ok=True)
print(f'Prepared credential-free CloudBase source: {stage}')
