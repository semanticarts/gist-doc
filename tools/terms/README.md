# Per-Term RDF Dereferencing Files

Background and design notes for the per-term RDF fragments generated under
`tools/terms/`. For build and publishing instructions, see
[BUILDING.md](BUILDING.md).

These tools generate one small RDF fragment per named `gist:` term so
authoritative IRIs such as
`https://w3id.org/semanticarts/ns/ontology/gist/Account` can resolve to useful
machine-readable descriptions, or human-readable descriptions when published
alongside the generated content. The generated files in `docs/terms/` can be
hosted on any static HTTP/S server, and made available at gist's authoritative
IRIs through `w3id.org` redirects to that server with basic content negotiation
(see [BUILDING.md](BUILDING.md)).

## Dereferencing Behavior and W3C Documents

No W3C Recommendation defines what triples a server should return when an
ontology term IRI is dereferenced. There are no widely-adopted common practices.

The relevant W3C documents are:

- [*Best Practice Recipes for Publishing RDF Vocabularies*](https://www.w3.org/TR/swbp-vocab-pub/)
  (2008, Working Group **Note**) — covers HTTP-level mechanics: hash vs slash
  namespaces, 303 redirects, content negotiation, Apache configuration. It does
  not specify the RDF payload for per-term responses.
- [*Cool URIs for the Semantic Web*](https://www.w3.org/TR/cooluris/) (2008,
  Interest Group **Note**) — covers 303 and hash IRI patterns and the
  `httpRange-14` resolution. Also silent on payload composition.
- [*CBD - Concise Bounded Description*](https://www.w3.org/submissions/CBD/)
  (2005, Member **Submission**) — defines **CBD** and **SCBD**. Submissions are not
  endorsed by W3C and have no normative standing.

[RDF 1.1 Concepts](https://www.w3.org/TR/rdf11-concepts/) (a Recommendation) is
explicit that the RDF specs do not address dereferencing behavior:

> Perhaps the most important characteristic of IRIs in web architecture is that
> they can be dereferenced, and hence serve as starting points for interactions
> with a remote server. This specification is not concerned with such interactions.
> It does not define an interaction model.

## Concise Bounded Description (CBD) and Symmetric CBD (SCBD)

The **Concise Bounded Description (CBD)** is the subgraph of all triples whose subject is the given term, plus recursively the CBDs of any blank nodes reached as objects. This provides a self-contained description of a node's outgoing properties.

The **Symmetric CBD (SCBD)** extends the CBD by also including all triples where the term appears as the object, pulling in incoming edges too. The result is a fully symmetric neighborhood of the node in both directions.

Because gist makes extensive use of axioms, a lot of the semantics of a given term are defined via incoming edges by axioms that are grouped not with the given term but with other, closely related terms. We use SCBD to provide the consumer with all axioms that directly pertain to the meaning of the referenced term.

## How the Term-Specific RDF Serializations are Generated

`build.py` loads the source ontology modules into a single merged graph, then for
each named term in the target namespace writes a per-term fragment to
`docs/terms/{LocalName}.{ttl,rdf,jsonld}`.

### Source ontology files

The ontology itself is not stored in this repo; the build fetches the published
gist release modules from `w3id.org` and merges them into one graph before
extraction (see [BUILDING.md](BUILDING.md) for the exact URLs, versioning, and
the option to build from local files). Three modules are merged:

- `gistCore` — the core ontology: class and property declarations and their axioms.
- `gistRdfsAnnotations` — RDFS annotations (labels, comments, and other
  human-readable metadata) for the terms.
- `gistSubClassAssertions` — the pre-computed `rdfs:subClassOf` assertions.

Because each per-term fragment is the SCBD computed against the *merged* graph,
a term's annotations and subclass assertions are folded into its fragment even
though they originate in separate source files.

### Python scripts

The Python scripts that implement the generation are:

- `scbd_no_orphans.py` — core extraction function; implements the SCBD variant
  described below (SCBD with orphan blank-node fragments filtered out).
- `relabel.py` — deterministic blank-node relabeling; replaces rdflib's
  parse-time bnode IDs with hashes of canonical anchor paths so re-runs don't
  churn IDs.
- `canonicalize.py` — post-processing for the JSON-LD and RDF/XML serializer
  output; sorts dicts, arrays, and XML elements so element ordering is stable
  across runs (preserving `@list` order, which is semantically significant).
- `build.py` — CLI that loads one or more source ontology Turtle files and writes
  per-term fragments to an output directory.

The `tests/` directory holds pytest suites covering the extraction logic
(`test_scbd_no_orphans.py`, 6 cases), the relabeling (`test_relabel.py`, 7
cases — including a round-trip isomorphism check for every serialization), and
the canonicalization (`test_canonicalize.py`, 8 cases — semantics preservation,
idempotence, byte stability, and `@list` order preservation).

### Extraction of Symmetric Concise Bounded Description (SCBD)

Each fragment is the Symmetric Concise Bounded Description (SCBD) of the term, as
defined in the W3C Member Submission [*CBD - Concise Bounded
Description*](https://www.w3.org/submissions/CBD/), with one minor adjustment:
orphan blank-node fragments are filtered out.

The extraction proceeds in two phases:

- **Phase 1 — outgoing CBD**: all triples reachable from the term via blank-node
  chains (restrictions, list cells, class expressions, etc.) are included.
- **Phase 2 — back-references**: for each triple `(s, p, term)` where `s` is a
  blank node, the algorithm walks backward through blank-node chains looking for
  a named (IRI) ancestor. If one is found, the full chain and its CBD expansion
  are included. If no named ancestor exists, the fragment is **dropped**.

That drop step is the only departure from spec-compliant SCBD, and it's a minor
one: the dropped fragments are blank-node subgraphs that have no path to any
named IRI in the source graph (for example, stray one-element `rdf:List` cells
that survive serialization but no longer belong to a containing class expression).
Including them in a per-term fragment is noise — the consumer cannot interpret a
list cell without the class expression that owns it.

This still captures every genuinely useful back-reference, such as `owl:unionOf`
or `owl:intersectionOf` expressions on other named classes that reference the
term.

### Deterministic output

rdflib assigns fresh blank-node identifiers on every parse, and its RDF/XML
and JSON-LD serializers emit elements in set-iteration order. Both effects
would otherwise produce noisy diffs on every rebuild. `build.py` neutralizes
them in two passes after extraction:

- `relabel.py` replaces each blank node with one whose identifier is
  `hash(canonical-path-from-named-ancestor)`. Structurally identical bnodes
  collapse to a single label, which is sound under RDF simple entailment.
- `canonicalize.py` post-processes the serializer output. JSON-LD dicts and
  arrays are sorted recursively, except for arrays under `@list` (which encode
  rdf:List and are semantically ordered). RDF/XML elements are sorted by
  `(tag, attributes, text, subtree-signature)`; CR entities (`&#13;`) are
  swapped through a Unicode sentinel across the parse/serialize cycle so
  CRLF line endings inside multi-line literals survive XML 1.0's text
  normalization.

Result: rerunning `build.py` on an unchanged source ontology produces
byte-identical `.ttl`, `.rdf`, and `.jsonld` files. The round-trip test in
`test_relabel.py` verifies that every serialization parses back to a graph
isomorphic to the original.
