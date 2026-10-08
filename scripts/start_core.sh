#!/bin/sh
set -eu
# macOS shells often default to 256; the C1 baseline needs 300 sockets plus DB/files.
ulimit -n 4096
cd "$(dirname "$0")/../services/core"
export PHX_SERVER=true
exec mix run --no-halt
