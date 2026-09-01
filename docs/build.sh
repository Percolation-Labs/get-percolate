#!/usr/bin/env bash
# Build the docs. Deps are pinned here rather than in a requirements file
# because there are two of them and they are only ever used by this script.
set -euo pipefail
cd "$(dirname "$0")/.."
exec uv run --quiet \
  --with "markdown==3.7" \
  --with "pygments==2.19.1" \
  python docs/build.py "$@"
