from __future__ import annotations

from rdflib import BNode, Graph, URIRef


def _build_reverse_index(graph: Graph) -> dict:
    """Build {object: [(subject, predicate)]} for efficient backward traversal."""
    idx: dict = {}
    for s, p, o in graph:
        if o not in idx:
            idx[o] = []
        idx[o].append((s, p))
    return idx


def _cbd_expand(
    graph: Graph, node: URIRef | BNode, result: set, visited: set
) -> None:
    """Add all outgoing triples from node to result, recursing into blank-node objects."""
    if node in visited:
        return
    visited.add(node)
    for s, p, o in graph.triples((node, None, None)):
        result.add((s, p, o))
        if isinstance(o, BNode):
            _cbd_expand(graph, o, result, visited)


def _find_anchor(
    start_bnode: BNode, reverse_index: dict
) -> tuple[set, set] | None:
    """
    Walk backward from start_bnode through blank-node chains, looking for a
    named (IRI) ancestor.  Returns (back_chain_triples, chain_bnodes) when an
    anchor is found, or None when the fragment is orphaned.
    """
    visited: set = {start_bnode}
    queue: list = [start_bnode]
    chain_triples: set = set()
    chain_bnodes: set = {start_bnode}
    anchor_found = False

    while queue:
        current = queue.pop()
        for s, p in reverse_index.get(current, []):
            chain_triples.add((s, p, current))
            if isinstance(s, URIRef):
                anchor_found = True
            elif isinstance(s, BNode) and s not in visited:
                visited.add(s)
                chain_bnodes.add(s)
                queue.append(s)

    return (chain_triples, chain_bnodes) if anchor_found else None


def _validate(result: set) -> None:
    """
    Assert every blank node in result is connected — directly or transitively —
    to some IRI in result (treating subject–object edges as bidirectional for
    blank-node connectivity checks).
    """
    bnodes = {n for triple in result for n in triple if isinstance(n, BNode)}
    if not bnodes:
        return

    # Seed: bnodes directly adjacent to an IRI
    anchored: set = set()
    for s, p, o in result:
        if isinstance(s, BNode) and isinstance(o, URIRef):
            anchored.add(s)
        if isinstance(o, BNode) and isinstance(s, URIRef):
            anchored.add(o)

    # Propagate through bnode–bnode edges
    changed = True
    while changed:
        changed = False
        for s, p, o in result:
            if isinstance(s, BNode) and isinstance(o, BNode):
                if s in anchored and o not in anchored:
                    anchored.add(o)
                    changed = True
                elif o in anchored and s not in anchored:
                    anchored.add(s)
                    changed = True

    orphans = bnodes - anchored
    assert not orphans, f"Orphan blank nodes in SCBD result: {orphans}"


def scbd_no_orphans(graph: Graph, term: URIRef) -> Graph:
    """
    Return the SCBD of `term` in `graph`, with orphan blank-node fragments filtered out.

    Includes:
      - All outgoing triples from `term`, recursively through blank-node objects (CBD).
      - All incoming triples to `term` from named (IRI) subjects.
      - Blank-node back-reference chains that resolve to a named ancestor,
        with full blank-node-connected subgraph expansion at each step.

    Excludes:
      - Orphan blank-node fragments with no path to a named ancestor.
    """
    result: set = set()
    reverse_index = _build_reverse_index(graph)

    # Phase 1 — outgoing CBD
    _cbd_expand(graph, term, result, set())

    # Phase 2 — anchored back-references
    for s, p, o in graph.triples((None, None, term)):
        if isinstance(s, URIRef):
            result.add((s, p, o))
        elif isinstance(s, BNode):
            chain_result = _find_anchor(s, reverse_index)
            if chain_result is not None:
                back_chain_triples, chain_bnodes = chain_result
                result |= back_chain_triples
                cbd_visited: set = set()
                for bn in chain_bnodes:
                    _cbd_expand(graph, bn, result, cbd_visited)

    _validate(result)

    out = Graph()
    for triple in result:
        out.add(triple)
    return out
