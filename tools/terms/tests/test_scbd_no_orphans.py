"""pytest test suite for scbd_no_orphans.py — seven test cases from the spec."""
import sys
from pathlib import Path

import pytest
from rdflib import BNode, Graph, Namespace, URIRef
from rdflib.compare import isomorphic
from rdflib.namespace import OWL, RDF, RDFS

sys.path.insert(0, str(Path(__file__).parent.parent))
from scbd_no_orphans import scbd_no_orphans

EX = Namespace("http://example.org/")
TURTLE_PREFIXES = """\
@prefix :    <http://example.org/> .
@prefix owl: <http://www.w3.org/2002/07/owl#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:<http://www.w3.org/2000/01/rdf-schema#> .
"""


def parse(ttl: str) -> Graph:
    g = Graph()
    g.parse(data=TURTLE_PREFIXES + ttl, format="turtle")
    return g


# ---------------------------------------------------------------------------
# Test 1 — Basic class
# ---------------------------------------------------------------------------

def test1_basic_class():
    g = parse(":Foo a owl:Class ; rdfs:label \"Foo\" .")
    result = scbd_no_orphans(g, EX.Foo)
    expected = parse(":Foo a owl:Class ; rdfs:label \"Foo\" .")
    assert isomorphic(result, expected)


# ---------------------------------------------------------------------------
# Test 2 — Class with restriction
# ---------------------------------------------------------------------------

def test2_restriction():
    src = """
    :Foo a owl:Class ;
        rdfs:subClassOf [ a owl:Restriction ;
            owl:onProperty :bar ;
            owl:someValuesFrom :Baz ] .
    """
    g = parse(src)
    result = scbd_no_orphans(g, EX.Foo)
    expected = parse(src)
    assert isomorphic(result, expected)


# ---------------------------------------------------------------------------
# Test 3 — Named back-reference
# ---------------------------------------------------------------------------

def test3_named_back_reference():
    src = ":Foo a owl:Class . :someProperty rdfs:range :Foo ."
    g = parse(src)
    result = scbd_no_orphans(g, EX.Foo)
    expected = parse(src)
    assert isomorphic(result, expected)


# ---------------------------------------------------------------------------
# Test 4 — Orphan list tail (the critical case)
# ---------------------------------------------------------------------------

def test4_orphan_list_tail():
    g = parse(":Foo a owl:Class . [] rdf:first :Foo ; rdf:rest () .")
    result = scbd_no_orphans(g, EX.Foo)
    expected = parse(":Foo a owl:Class .")
    assert isomorphic(result, expected)


# ---------------------------------------------------------------------------
# Test 5 — Anchored list tail
# ---------------------------------------------------------------------------

def test5_anchored_list_tail():
    src = """
    :Foo a owl:Class .
    :Bar owl:equivalentClass [ a owl:Class ;
        owl:intersectionOf ( :Other :Foo ) ] .
    """
    g = parse(src)
    result = scbd_no_orphans(g, EX.Foo)
    expected = parse(src)
    assert isomorphic(result, expected)


# ---------------------------------------------------------------------------
# Test 6 — Multi-hop bnode chain
# ---------------------------------------------------------------------------

def test6_multihop_bnode_chain():
    src = """
    :Foo a owl:Class .
    :Bar rdfs:subClassOf [ a owl:Restriction ;
        owl:onProperty :p ;
        owl:someValuesFrom [ a owl:Class ;
            owl:unionOf ( :Foo :Other ) ] ] .
    """
    g = parse(src)
    result = scbd_no_orphans(g, EX.Foo)
    expected = parse(src)
    assert isomorphic(result, expected)


# ---------------------------------------------------------------------------
# Test 7 — Real ontology: gist:Person
# ---------------------------------------------------------------------------

def test7_real_ontology():
    g = Graph()
    try:
        g.parse("https://w3id.org/semanticarts/ontology/gistCore14.1.0")
    except Exception as e:
        pytest.skip(f"Could not load gist ontology: {e}")

    GIST = Namespace("https://w3id.org/semanticarts/ns/ontology/gist/")
    person = GIST.Person

    # scbd_no_orphans raises AssertionError internally if any orphan bnode survives
    result = scbd_no_orphans(g, person)

    # Person must appear in the result
    assert any(person in triple for triple in result), "gist:Person not found in result"

    # Explicit check: every (bnode, rdf:first, person) triple in the result must
    # have a named (IRI) ancestor reachable via backward traversal within the result.
    rev: dict = {}
    for s, p, o in result:
        rev.setdefault(o, []).append((s, p))

    for s, p, o in result:
        if p == RDF.first and o == person and isinstance(s, BNode):
            visited: set = {s}
            queue = [s]
            found_anchor = False
            while queue and not found_anchor:
                curr = queue.pop()
                for subj, _ in rev.get(curr, []):
                    if isinstance(subj, URIRef):
                        found_anchor = True
                        break
                    if isinstance(subj, BNode) and subj not in visited:
                        visited.add(subj)
                        queue.append(subj)
            assert found_anchor, f"Orphan list cell referencing gist:Person: {s}"
