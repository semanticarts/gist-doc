#!/usr/bin/env bash
# Build WIDOCO documentation and apply the hash-navigation patch for a gist release.
# Run from the repo root: bash tools/widoco/build.sh <version>
# Example: bash tools/widoco/build.sh 14.1
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: bash tools/widoco/build.sh <version>  (e.g. 14.1)" >&2
  exit 1
fi

RELEASE_DIR="docs/gist-${VERSION}"
if [[ ! -d "$RELEASE_DIR" ]]; then
  echo "ERROR: directory '$RELEASE_DIR' not found" >&2
  exit 1
fi

echo "==> Fetching WIDOCO jar if needed..."
bash tools/widoco/fetch-widoco.sh

echo "==> Running WIDOCO for gist-${VERSION}..."
(cd "$RELEASE_DIR" && bash widoco.command.txt)

echo "==> Applying hash-navigation patch..."
python3 tools/widoco/patch_widoco_hash.py "${RELEASE_DIR}/widoco-documentation/index-en.html"

echo ""
echo "Build complete. To smoke-test, run:"
echo "  python -m http.server 8000 --directory ${RELEASE_DIR}/widoco-documentation"
echo "Then open: http://localhost:8000/index-en.html#Address"
