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

Place the gist web download bundle inside the repository root (it is gitignored):

```text
gist14.1.0_webDownload/
  ontologies/
    turtle/
      gistCore14.1.0.ttl
      gistRdfsAnnotations14.1.0.ttl
      gistSubClassAssertions14.1.0.ttl
```

Then run from the repo root:

```bash
python tools/terms/build.py \
  gist14.1.0_webDownload/ontologies/turtle/gistCore14.1.0.ttl \
  gist14.1.0_webDownload/ontologies/turtle/gistRdfsAnnotations14.1.0.ttl \
  gist14.1.0_webDownload/ontologies/turtle/gistSubClassAssertions14.1.0.ttl \
  docs/terms \
  --namespace https://w3id.org/semanticarts/ns/ontology/gist/
```

Output lands in `docs/terms/` — 216 terms × 3 serializations (`.ttl`, `.rdf`, `.jsonld`).

## Content Negotiation (.htaccess)

`tools/terms/semanticarts.htaccess` contains the proposed `w3id.org` Apache rewrite rules for content negotiation. Before deploying, update the base URL in that file if the published site is not:

```text
https://semanticarts.github.io/gist-doc
```

The rules cover:

- `https://w3id.org/semanticarts/ns/ontology/gist/` — redirects to the Semantic Arts landing page
- `https://w3id.org/semanticarts/ns/ontology/gist/{Term}` — content negotiation to per-term RDF files or WIDOCO HTML
- `https://w3id.org/semanticarts/ontology/{OntologyDocument}` — full-ontology document routing

For term IRIs, content negotiation redirects to:

- `text/turtle` → `/terms/{Term}.ttl`
- `application/rdf+xml` → `/terms/{Term}.rdf`
- `application/ld+json` or `application/json` → `/terms/{Term}.jsonld`
- `text/html` → `/latest/#{Term}` (JavaScript redirect to latest WIDOCO docs)
- default → Turtle
