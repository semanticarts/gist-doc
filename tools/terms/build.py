#!/usr/bin/env python3
"""
build.py — Generate per-term SCBD static files from an OWL ontology.

For each named term in the ontology's namespace, writes Turtle, RDF/XML, and
JSON-LD fragments to <out_dir>/<LocalName>.{ttl,rdf,jsonld}.

Uses SCBD with orphan blank-node fragments filtered out — see scbd_no_orphans.py.

Usage:
    python build.py <ontology.ttl> [<more.ttl> ...] <out_dir> [--namespace <ns>]

Arguments:
    ontology.ttl   One or more paths (or URLs) to source ontology Turtle files.
                   All files are merged into a single graph before extraction.
    out_dir        Directory to write per-term fragments into.
    --namespace    Namespace IRI prefix to filter terms (e.g.
                   https://w3id.org/semanticarts/ns/ontology/gist/).
                   If omitted, all named subjects typed as OWL vocabulary
                   items are included.
"""
import argparse
import sys
from pathlib import Path

from rdflib import Graph, URIRef
from rdflib.namespace import OWL, RDF

sys.path.insert(0, str(Path(__file__).parent))
from canonicalize import canonicalize_jsonld, canonicalize_rdfxml
from relabel import relabel_bnodes
from scbd_no_orphans import scbd_no_orphans

TERM_TYPES = (OWL.Class, OWL.ObjectProperty, OWL.DatatypeProperty, OWL.AnnotationProperty)


def enumerate_terms(graph: Graph, namespace: str | None) -> list[URIRef]:
    terms: set[URIRef] = set()
    for term_type in TERM_TYPES:
        for s in graph.subjects(RDF.type, term_type):
            if isinstance(s, URIRef):
                terms.add(s)
    if namespace:
        terms = {t for t in terms if str(t).startswith(namespace)}
    return sorted(terms, key=str)


def build_static_files(graph: Graph, out_dir: Path, terms: list[URIRef]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    skipped = 0
    for term in terms:
        local = str(term).rsplit("#", 1)[-1].rsplit("/", 1)[-1]
        if not local:
            skipped += 1
            continue

        sub = scbd_no_orphans(graph, term)
        sub = relabel_bnodes(sub)
        for prefix, ns in graph.namespaces():
            sub.bind(prefix, ns)

        (out_dir / f"{local}.ttl").write_bytes(sub.serialize(format="turtle").encode())
        (out_dir / f"{local}.rdf").write_bytes(
            canonicalize_rdfxml(sub.serialize(format="xml")).encode()
        )
        (out_dir / f"{local}.jsonld").write_bytes(
            canonicalize_jsonld(sub.serialize(format="json-ld", indent=2)).encode()
        )

    written = len(terms) - skipped
    print(f"Wrote {written} terms × 3 formats → {out_dir}")
    if skipped:
        print(f"Skipped {skipped} terms (no local name)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1].strip())
    parser.add_argument(
        "sources",
        nargs="+",
        metavar="ontology.ttl",
        help="One or more paths or URLs to source ontology Turtle files",
    )
    parser.add_argument("out_dir", type=Path, help="Output directory for term fragments")
    parser.add_argument(
        "--namespace",
        help="Restrict to terms whose IRI starts with this prefix",
    )
    args = parser.parse_args()

    g = Graph()
    for src in args.sources:
        print(f"Loading {src} ...")
        before = len(g)
        g.parse(src)
        print(f"  +{len(g) - before:,} triples  ({len(g):,} total)")
    print(f"Merged graph: {len(g):,} triples")

    terms = enumerate_terms(g, args.namespace)
    print(f"Found {len(terms)} terms to process")

    build_static_files(g, args.out_dir, terms)
    print("Done.")


if __name__ == "__main__":
    main()
