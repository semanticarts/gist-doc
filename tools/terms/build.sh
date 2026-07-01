#!/usr/bin/env bash
# Generate per-term RDF files for a gist release.
# Run from the repo root: bash tools/terms/build.sh <version>
# Example: bash tools/terms/build.sh 14.1.0
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: bash tools/terms/build.sh <version>  (e.g. 14.1.0)" >&2
  exit 1
fi

BASE="https://w3id.org/semanticarts/ontology"
NS="https://w3id.org/semanticarts/ns/ontology/gist/"
OUT="docs/terms"

echo "==> Building per-term RDF files for gist ${VERSION}..."
python3 tools/terms/build.py \
  "${BASE}/gistCore${VERSION}.ttl" \
  "${BASE}/gistRdfsAnnotations${VERSION}.ttl" \
  "${BASE}/gistSubClassAssertions${VERSION}.ttl" \
  "${OUT}" \
  --namespace "${NS}"

echo ""
echo "Done. Output in ${OUT}/"
