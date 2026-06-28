#!/usr/bin/env bash
# Test the full WIDOCO build + hash patch for a gist release.
# Run from the repo root: bash tools/test-build.sh <version>
# Example: bash tools/test-build.sh 14.1
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: bash tools/test-build.sh <version>  (e.g. 14.1)" >&2
  exit 1
fi

RELEASE_DIR="docs/gist-${VERSION}"
if [[ ! -d "$RELEASE_DIR" ]]; then
  echo "ERROR: directory '$RELEASE_DIR' not found" >&2
  exit 1
fi

echo "==> Fetching WIDOCO jar if needed..."
bash tools/fetch-widoco.sh

echo "==> Running WIDOCO for gist-${VERSION}..."
(cd "$RELEASE_DIR" && bash widoco.command.txt)

echo "==> Applying hash-navigation patch..."
python3 tools/patch_widoco_hash.py "${RELEASE_DIR}/widoco-documentation/index-en.html"

echo ""
echo "Build complete. To smoke-test, run:"
echo "  python -m http.server 8000 --directory ${RELEASE_DIR}/widoco-documentation"
echo "Then open: http://127.0.0.1:8000/index-en.html#Address"
