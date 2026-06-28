# Building Per-Term RDF Files

Generates one small RDF fragment per named `gist:` term so authoritative IRIs such as `https://w3id.org/semanticarts/ns/ontology/gist/Account` can resolve to useful machine-readable descriptions via content negotiation.

## Background

Each fragment is the Symmetric Concise Bounded Description (SCBD) of the term, as defined in the W3C Member Submission [*CBD - Concise Bounded Description*](https://www.w3.org/submissions/CBD/), with orphan blank-node fragments filtered out. Output is byte-stable across rebuilds via deterministic blank-node relabeling and sorted serialization.

See the source modules for implementation details:
- `scbd_no_orphans.py` — SCBD extraction with orphan filtering
- `relabel.py` — deterministic blank-node relabeling
- `canonicalize.py` — stable serialization for JSON-LD and RDF/XML

## Requirements

- Python 3.11 or newer
- `rdflib`

```bash
python -m pip install rdflib
```

For running the test suite:

```bash
python -m pip install pytest
python -m pytest tools/terms/tests/
```

## Rebuilding the Term Files

`tools/terms/build.sh` fetches the ontology modules directly from their published URLs and generates the per-term files. Run from the repo root:

```bash
bash tools/terms/build.sh <version>   # e.g. bash tools/terms/build.sh 14.1.0
```

Output lands in `docs/terms/` — one `.ttl`, `.rdf`, and `.jsonld` file per term.

To run manually or with local files instead:

```bash
python tools/terms/build.py \
  https://w3id.org/semanticarts/ontology/gistCore14.1.0.ttl \
  https://w3id.org/semanticarts/ontology/gistRdfsAnnotations14.1.0.ttl \
  https://w3id.org/semanticarts/ontology/gistSubClassAssertions14.1.0.ttl \
  docs/terms \
  --namespace https://w3id.org/semanticarts/ns/ontology/gist/
```

## Content Negotiation (.htaccess)

The `w3id.org` Apache rewrite rules are managed separately and not committed to this repo. The rules cover:

- `https://w3id.org/semanticarts/ns/ontology/gist/` — redirects to the Semantic Arts landing page
- `https://w3id.org/semanticarts/ns/ontology/gist/{Term}` — content negotiation to per-term RDF files or WIDOCO HTML
- `https://w3id.org/semanticarts/ontology/{OntologyDocument}` — full-ontology document routing

For term IRIs, content negotiation redirects to:

- `text/turtle` → `/terms/{Term}.ttl`
- `application/rdf+xml` → `/terms/{Term}.rdf`
- `application/ld+json` or `application/json` → `/terms/{Term}.jsonld`
- `text/html` → `/latest/#{Term}` (JavaScript redirect to latest WIDOCO docs)
- default → Turtle
