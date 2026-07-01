"""pytest test suite for canonicalize.py — verifies that JSON-LD post-processing
produces byte-stable, semantically equivalent output."""
import json
import sys
from pathlib import Path

from rdflib import Graph

sys.path.insert(0, str(Path(__file__).parent.parent))
from canonicalize import canonicalize_jsonld, canonicalize_rdfxml


def test_idempotent():
    """Canonicalizing twice gives the same output."""
    raw = json.dumps([
        {"@id": "ex:B", "ex:p": [{"@id": "ex:Z"}, {"@id": "ex:A"}]},
        {"@id": "ex:A", "ex:q": [{"@value": "z"}, {"@value": "a"}]},
    ])
    once = canonicalize_jsonld(raw)
    twice = canonicalize_jsonld(once)
    assert once == twice


def test_input_order_independent():
    """Two inputs differing only in array/key order produce identical output."""
    a = json.dumps([
        {"@id": "ex:B", "ex:p": [{"@id": "ex:Z"}, {"@id": "ex:A"}]},
        {"@id": "ex:A", "ex:q": [{"@value": "z"}, {"@value": "a"}]},
    ])
    b = json.dumps([
        {"ex:q": [{"@value": "a"}, {"@value": "z"}], "@id": "ex:A"},
        {"ex:p": [{"@id": "ex:A"}, {"@id": "ex:Z"}], "@id": "ex:B"},
    ])
    assert canonicalize_jsonld(a) == canonicalize_jsonld(b)


def test_jsonld_list_order_preserved():
    """`@list` arrays in JSON-LD encode rdf:List, which is ordered.
    Canonicalization must not reorder them, only sort everything else."""
    raw = json.dumps([{
        "@id": "ex:Foo",
        "ex:items": [{
            "@list": [{"@id": "ex:Z"}, {"@id": "ex:A"}, {"@id": "ex:M"}]
        }]
    }])
    out = json.loads(canonicalize_jsonld(raw))
    list_items = out[0]["ex:items"][0]["@list"]
    assert [item["@id"] for item in list_items] == ["ex:Z", "ex:A", "ex:M"]


def test_preserves_jsonld_semantics():
    """Canonicalized output parses back into a graph isomorphic to the input."""
    src_ttl = """
    @prefix : <http://example.org/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    :Foo a owl:Class ;
        owl:equivalentClass [ a owl:Class ;
            owl:intersectionOf ( :A :B :C ) ] .
    """
    g = Graph()
    g.parse(data=src_ttl, format="turtle")

    raw_jsonld = g.serialize(format="json-ld", indent=2)
    canon = canonicalize_jsonld(raw_jsonld)

    from rdflib.compare import isomorphic
    reparsed = Graph()
    reparsed.parse(data=canon, format="json-ld")
    assert isomorphic(reparsed, g)


def test_rdfxml_idempotent():
    """Canonicalizing twice gives the same output."""
    g = Graph()
    g.parse(data="""
    @prefix : <http://example.org/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    :Foo a owl:Class ;
        owl:equivalentClass [ a owl:Class ;
            owl:intersectionOf ( :A :B :C ) ] .
    """, format="turtle")
    raw = g.serialize(format="xml")
    once = canonicalize_rdfxml(raw)
    twice = canonicalize_rdfxml(once)
    assert once == twice


def test_rdfxml_preserves_semantics():
    """Canonicalized output parses back into a graph isomorphic to the input."""
    src_ttl = """
    @prefix : <http://example.org/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    :Foo a owl:Class ;
        owl:equivalentClass [ a owl:Class ;
            owl:intersectionOf ( :A :B :C ) ] .
    """
    g = Graph()
    g.parse(data=src_ttl, format="turtle")

    raw = g.serialize(format="xml")
    canon = canonicalize_rdfxml(raw)

    from rdflib.compare import isomorphic
    reparsed = Graph()
    reparsed.parse(data=canon, format="xml")
    assert isomorphic(reparsed, g)


def test_build_pipeline_byte_stable_jsonld():
    """End-to-end: parsing, extracting, relabeling, and emitting canonicalized
    JSON-LD twice produces byte-identical files even for a graph rich enough
    to exercise rdflib's set-iteration ordering."""
    from relabel import relabel_bnodes
    from scbd_no_orphans import scbd_no_orphans

    src = """
    @prefix : <http://example.org/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    :Foo a owl:Class .
    :A owl:equivalentClass [ a owl:Class ;
        owl:intersectionOf ( :Foo [ a owl:Restriction ;
            owl:onProperty :p ; owl:someValuesFrom :Foo ] ) ] .
    :B owl:equivalentClass [ a owl:Class ;
        owl:intersectionOf ( :Foo [ a owl:Restriction ;
            owl:onProperty :q ; owl:someValuesFrom :Foo ] ) ] .
    :C owl:equivalentClass [ a owl:Class ;
        owl:unionOf ( :Foo [ a owl:Restriction ;
            owl:onProperty :r ; owl:someValuesFrom :Foo ] ) ] .
    :D rdfs:range :Foo .
    :E rdfs:domain :Foo .
    """

    def pipeline():
        g = Graph()
        g.parse(data=src, format="turtle")
        from rdflib import Namespace
        EX = Namespace("http://example.org/")
        sub = relabel_bnodes(scbd_no_orphans(g, EX.Foo))
        return canonicalize_jsonld(sub.serialize(format="json-ld", indent=2))

    a = pipeline()
    b = pipeline()
    assert a == b


def test_build_pipeline_byte_stable_rdfxml():
    """End-to-end byte stability for RDF/XML using the same multi-anchor
    fixture that breaks rdflib's default ordering."""
    from relabel import relabel_bnodes
    from scbd_no_orphans import scbd_no_orphans

    src = """
    @prefix : <http://example.org/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    :Foo a owl:Class .
    :A owl:equivalentClass [ a owl:Class ;
        owl:intersectionOf ( :Foo [ a owl:Restriction ;
            owl:onProperty :p ; owl:someValuesFrom :Foo ] ) ] .
    :B owl:equivalentClass [ a owl:Class ;
        owl:intersectionOf ( :Foo [ a owl:Restriction ;
            owl:onProperty :q ; owl:someValuesFrom :Foo ] ) ] .
    :C owl:equivalentClass [ a owl:Class ;
        owl:unionOf ( :Foo [ a owl:Restriction ;
            owl:onProperty :r ; owl:someValuesFrom :Foo ] ) ] .
    :D rdfs:range :Foo .
    :E rdfs:domain :Foo .
    """

    def pipeline():
        g = Graph()
        g.parse(data=src, format="turtle")
        from rdflib import Namespace
        EX = Namespace("http://example.org/")
        sub = relabel_bnodes(scbd_no_orphans(g, EX.Foo))
        return canonicalize_rdfxml(sub.serialize(format="xml"))

    a = pipeline()
    b = pipeline()
    assert a == b
