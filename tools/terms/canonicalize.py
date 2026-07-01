"""
Post-processing canonicalization for serialized RDF output.

rdflib's JSON-LD and RDF/XML serializers emit elements in set-iteration order,
so two builds of the same graph produce different byte sequences even when the
underlying triples (and blank-node labels) are identical.  These helpers parse
the output, sort everything by a stable content key, and re-emit.  Both formats
treat element order as unordered (rdf:List preservation goes through
rdf:first/rdf:rest, not through @list or rdf:parseType="Collection", in
rdflib's default output), so sorting is semantically safe.
"""
from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from typing import Any


def _sort_key(item: Any) -> tuple:
    if not isinstance(item, dict):
        return ("3", json.dumps(item, sort_keys=True, ensure_ascii=False))
    if "@id" in item:
        return ("0", str(item["@id"]))
    if "@value" in item:
        return (
            "1",
            str(item.get("@value")),
            str(item.get("@type", "")),
            str(item.get("@language", "")),
        )
    return ("2", json.dumps(item, sort_keys=True, ensure_ascii=False))


def _canon(obj: Any) -> Any:
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k == "@list" and isinstance(v, list):
                out[k] = [_canon(x) for x in v]
            else:
                out[k] = _canon(v)
        return out
    if isinstance(obj, list):
        return sorted((_canon(x) for x in obj), key=_sort_key)
    return obj


def canonicalize_jsonld(text: str) -> str:
    """Return a byte-stable JSON-LD string semantically equivalent to `text`."""
    return json.dumps(
        _canon(json.loads(text)),
        indent=2,
        sort_keys=True,
        ensure_ascii=False,
    )


def _xml_sort_key(elem: ET.Element) -> tuple:
    """Sort key for an XML element: tag, then sorted attributes, then text,
    then a recursive signature of the subtree so descendants disambiguate."""
    attrs = tuple(sorted(elem.attrib.items()))
    text = (elem.text or "").strip()
    children = tuple(_xml_sort_key(c) for c in elem)
    return (elem.tag, attrs, text, children)


def _xml_sort_recursive(elem: ET.Element) -> None:
    for child in elem:
        _xml_sort_recursive(child)
    if len(elem) > 1:
        elem[:] = sorted(elem, key=_xml_sort_key)


_CR_SENTINEL = "☃CR_SENTINEL_4242☃"


def canonicalize_rdfxml(text: str) -> str:
    """Return a byte-stable RDF/XML string semantically equivalent to `text`.

    ElementTree drops `&#13;` (CR) entities during parse because XML 1.0
    normalizes CR away.  rdflib uses `&#13;` to preserve literal CR characters
    (e.g., in CRLF line endings inside multi-line literals from a Windows
    source).  We swap `&#13;` for a sentinel before parsing and restore it
    after serialization so the canonicalized output parses back to the same
    literals."""
    text = text.replace("&#13;", _CR_SENTINEL)

    for prefix, uri in re.findall(r'xmlns:([\w-]+)="([^"]+)"', text):
        ET.register_namespace(prefix, uri)
    default_ns = re.search(r'xmlns="([^"]+)"', text)
    if default_ns:
        ET.register_namespace("", default_ns.group(1))

    root = ET.fromstring(text)
    _xml_sort_recursive(root)
    ET.indent(root, space="  ")
    body = ET.tostring(root, encoding="utf-8", xml_declaration=True).decode("utf-8")
    body = body.replace(_CR_SENTINEL, "&#13;")
    if not body.endswith("\n"):
        body += "\n"
    return body
