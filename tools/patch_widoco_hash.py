#!/usr/bin/env python3
"""Post-process WIDOCO output so bare local-name fragments (e.g. #Address)
resolve to anchors whose id is the full gist IRI. Run after WIDOCO."""
import re
import sys
from pathlib import Path

# Must match the IRIs WIDOCO emits as anchor id="..." values.
ONTOLOGY_NS = "https://w3id.org/semanticarts/ns/ontology/gist/"
DATA_NS = "https://w3id.org/semanticarts/ns/data/gist/"

PATCHED = (
    'var hash = decodeURIComponent(location.hash.slice(1));\n'
    '\tvar target = hash && (\n'
    '\t  document.getElementById(hash) ||\n'
    f'\t  document.getElementById("{ONTOLOGY_NS}" + hash) ||\n'
    f'\t  document.getElementById("{DATA_NS}" + hash)\n'
    '\t);\n'
    '\tif(target){\n'
    "\t  $('html, body').animate({scrollTop: $(target).offset().top}, 0);\n"
    '\t}'
)

# Matches the stock WIDOCO hash-handling block (whitespace-tolerant).
STOCK = re.compile(
    r"var\s+hash\s*=\s*location\.hash;\s*"
    r"if\(\$\(hash\)\.offset\(\)\s*!=\s*null\)\s*\{\s*"
    r"\$\('html, body'\)\.animate\(\{scrollTop:\s*\$\(hash\)\.offset\(\)\.top\},\s*0\);\s*"
    r"\}",
    re.DOTALL,
)

def patch(path: Path) -> bool:
    html = path.read_text(encoding="utf-8")
    if "decodeURIComponent(location.hash" in html:
        print(f"{path}: already patched, skipping")
        return True
    new_html, n = STOCK.subn(PATCHED, html, count=1)
    if n != 1:
        print(f"ERROR: stock loadHash block not found in {path}. "
              "WIDOCO output format may have changed; update patch_widoco_hash.py.",
              file=sys.stderr)
        return False
    path.write_text(new_html, encoding="utf-8")
    print(f"{path}: patched hash navigation")
    return True

if __name__ == "__main__":
    files = [Path(a) for a in sys.argv[1:]]
    if not files:
        print("usage: patch_widoco_hash.py <generated-index.html> [...]", file=sys.stderr)
        sys.exit(2)
    sys.exit(0 if all(patch(f) for f in files) else 1)
