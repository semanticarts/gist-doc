"""pytest test suite for relabel.py — verifies deterministic, stable, semantically
equivalent blank-node relabeling."""
import sys
from pathlib import Path

from rdflib import BNode, Graph, Namespace, URIRef
from rdflib.compare import isomorphic

sys.path.insert(0, str(Path(__file__).parent.parent))
from relabel import relabel_bnodes
from scbd_no_orphans import scbd_no_orphans

EX = Namespace("http://example.org/")
TURTLE_PREFIXES = """\
@prefix :    <http://example.org/> .
@prefix owl: <http://www.w3.org/2002/07/owl#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:<http://www.w3.org/2000/01/rdf-schema#> .
"""

NESTED = """
:Bar owl:equivalentClass [ a owl:Class ;
    owl:intersectionOf ( :Foo [ a owl:Restriction ;
        owl:onProperty :p ;
        owl:someValuesFrom :Foo ] ) ] .
:Foo a owl:Class .
"""


def parse(ttl: str) -> Graph:
    g = Graph()
    g.parse(data=TURTLE_PREFIXES + ttl, format="turtle")
    return g


def test_relabel_preserves_semantics():
    """Relabeled graph is isomorphic to original — semantics unchanged."""
    g = parse(NESTED)
    out = relabel_bnodes(g)
    assert isomorphic(out, g)


def test_relabel_is_deterministic():
    """Two independent parse + extract + relabel runs produce the same bnode
    labels."""
    g1 = parse(NESTED)
    g2 = parse(NESTED)
    sub1 = relabel_bnodes(scbd_no_orphans(g1, EX.Foo))
    sub2 = relabel_bnodes(scbd_no_orphans(g2, EX.Foo))

    labels1 = sorted(str(n) for triple in sub1 for n in triple if isinstance(n, BNode))
    labels2 = sorted(str(n) for triple in sub2 for n in triple if isinstance(n, BNode))
    assert labels1 == labels2
    assert labels1, "expected some bnodes in the result"


def test_relabel_distinguishes_structurally_distinct_bnodes():
    """Two bnodes with different content get different labels."""
    g = parse("""
    :Foo a owl:Class ;
        rdfs:subClassOf [ a owl:Restriction ;
            owl:onProperty :p ;
            owl:someValuesFrom :A ] ,
        [ a owl:Restriction ;
            owl:onProperty :q ;
            owl:someValuesFrom :B ] .
    """)
    out = relabel_bnodes(g)
    restriction_bnodes = {
        s for s, _, _ in out.triples((None, None, None))
        if isinstance(s, BNode)
        and (s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
             URIRef("http://www.w3.org/2002/07/owl#Restriction")) in out
    }
    assert len(restriction_bnodes) == 2, (
        f"expected two distinct restriction bnodes, got {len(restriction_bnodes)}"
    )


def test_relabel_byte_stable_turtle_and_jsonld():
    """Full pipeline twice → byte-identical Turtle and JSON-LD."""
    def pipeline():
        g = parse(NESTED)
        sub = relabel_bnodes(scbd_no_orphans(g, EX.Foo))
        return (
            sub.serialize(format="turtle"),
            sub.serialize(format="json-ld", indent=2),
        )

    ttl1, jsonld1 = pipeline()
    ttl2, jsonld2 = pipeline()
    assert ttl1 == ttl2, "turtle output differs across runs"
    assert jsonld1 == jsonld2, "json-ld output differs across runs"


def test_relabel_rdfxml_bnode_labels_stable():
    """RDF/XML bnode labels are stable across runs even though rdflib's
    PrettyXMLSerializer emits elements in nondeterministic (set-iteration)
    order.  This is the relabel module's contribution — eliminating the
    `nodeID="..."` churn that previously dominated `.rdf` diffs."""
    import re

    def labels():
        g = parse(NESTED)
        sub = relabel_bnodes(scbd_no_orphans(g, EX.Foo))
        rdf_xml = sub.serialize(format="xml")
        return sorted(set(re.findall(r'nodeID="([^"]+)"', rdf_xml)))

    assert labels() == labels()
    assert labels(), "expected some nodeID labels"


def test_generated_files_roundtrip():
    """Every serialized output must parse back into an isomorphic graph.
    Catches invalid bnode labels, broken namespace declarations, or any other
    serialization defect that the byte-level tests would miss."""
    g = parse(NESTED)
    sub = relabel_bnodes(scbd_no_orphans(g, EX.Foo))
    for fmt in ("turtle", "xml", "json-ld"):
        text = sub.serialize(format=fmt)
        reparsed = Graph()
        reparsed.parse(data=text, format=fmt)
        assert isomorphic(reparsed, sub), f"{fmt} round-trip not isomorphic"


def test_relabel_idempotent():
    """Relabeling a relabeled graph produces the same labels (fixed point)."""
    g = parse(NESTED)
    once = relabel_bnodes(scbd_no_orphans(g, EX.Foo))
    twice = relabel_bnodes(once)

    labels_once = sorted(str(n) for triple in once for n in triple if isinstance(n, BNode))
    labels_twice = sorted(str(n) for triple in twice for n in triple if isinstance(n, BNode))
    assert labels_once == labels_twice
