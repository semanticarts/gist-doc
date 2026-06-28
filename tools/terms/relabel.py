"""
Deterministic blank-node relabeling for per-term SCBD fragments.

`relabel_bnodes(graph)` returns a copy of `graph` with every blank node replaced
by a `BNode` whose identifier is a hash of a canonical path from a named (IRI)
ancestor.  The result is semantically equivalent to the input but has stable
bnode identifiers across runs, so re-serializing produces byte-identical output
when the source graph is unchanged.

Assumes every blank node in the input is anchored to at least one named IRI
(the invariant maintained by `scbd_no_orphans.scbd_no_orphans`).  Two blank
nodes with identical anchored paths and identical outgoing content will collapse
to a single label, which is the correct behavior under simple RDF entailment.
"""
from __future__ import annotations

import hashlib

from rdflib import BNode, Graph, Literal, URIRef

_BNODE_PREFIX = "b"
_HASH_LEN = 16


def _node_sig(node, graph: Graph, seen: frozenset) -> str:
    """Canonical string for an RDF node, recursing into bnodes through their
    outgoing edges.  `seen` carries the in-progress recursion stack to break
    cycles.  Deduplicates predicate-object pairs via a set before sorting so
    that structurally identical bnodes produce identical signatures regardless
    of rdflib's set-iteration order."""
    if isinstance(node, URIRef):
        return f"U<{node}>"
    if isinstance(node, Literal):
        return f"L{node.n3()}"
    if isinstance(node, BNode):
        if node in seen:
            return "B<cycle>"
        seen = seen | {node}
        pairs = {
            (str(p), _node_sig(o, graph, seen))
            for p, o in graph.predicate_objects(node)
        }
        return "B{" + ";".join(f"{p}={r}" for p, r in sorted(pairs)) + "}"
    return f"?<{node}>"


def _path_to_named(bnode: BNode, graph: Graph, seen: frozenset) -> str:
    """Lexicographically smallest canonical path from `bnode` back to a named
    ancestor.  Sibling disambiguation uses the *sorted unique* set of sibling
    signatures, so structurally identical siblings share the same path key
    (and therefore the same label — they collapse, which is sound under RDF
    simple entailment)."""
    if bnode in seen:
        return f"CYCLE<{_node_sig(bnode, graph, frozenset())}>"
    seen = seen | {bnode}

    parents = list(graph.subject_predicates(bnode))
    if not parents:
        return f"ORPHAN<{_node_sig(bnode, graph, frozenset())}>"

    my_sig = _node_sig(bnode, graph, frozenset())

    candidates: list[str] = []
    for parent, predicate in parents:
        if isinstance(parent, URIRef):
            base = f"<{parent}>"
        elif isinstance(parent, BNode):
            base = _path_to_named(parent, graph, seen)
        else:
            base = f"?<{parent}>"

        sibling_sigs = sorted({
            _node_sig(o, graph, frozenset())
            for o in graph.objects(parent, predicate)
            if isinstance(o, BNode)
        })
        if len(sibling_sigs) <= 1:
            idx_part = ""
        else:
            sig_idx = sibling_sigs.index(my_sig)
            idx_part = f"[{sig_idx}]"

        candidates.append(f"{base}|{predicate}{idx_part}")

    return min(candidates)


def relabel_bnodes(graph: Graph) -> Graph:
    """Return a new graph with every blank node replaced by a deterministic
    `BNode` whose identifier is `hash(path-key)`."""
    out = Graph()
    for prefix, ns in graph.namespaces():
        out.bind(prefix, ns)

    label_map: dict[BNode, BNode] = {}
    for triple in graph:
        for node in triple:
            if isinstance(node, BNode) and node not in label_map:
                key = _path_to_named(node, graph, frozenset())
                digest = hashlib.sha1(key.encode("utf-8")).hexdigest()[:_HASH_LEN]
                label_map[node] = BNode(_BNODE_PREFIX + digest)

    for s, p, o in graph:
        s_out = label_map[s] if isinstance(s, BNode) else s
        o_out = label_map[o] if isinstance(o, BNode) else o
        out.add((s_out, p, o_out))

    return out
