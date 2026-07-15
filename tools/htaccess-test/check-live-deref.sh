#!/usr/bin/env bash
#
# LIVE resolution check for the whole-ontology semanticarts.htaccess targets.
#
# Two modes verify the SAME whole-ontology files at the two moments that matter:
#
#   MODE=targets (PRE-deploy)  — hit the origin files DIRECTLY on
#     ontologies.semanticarts.com (…/ontology/gistCore.rdf, .ttl, .jsonld, plus
#     the versioned files and the WIDOCO docs). This answers "do the files the
#     new .htaccess will point at actually exist yet?" BEFORE you deploy the
#     rules — you cannot go through w3id.org yet because the new rules aren't
#     live. This is the check that would have caught the /gistCore.rdf incident
#     up front.
#
#   MODE=deref (POST-deploy, default) — hit the real IRIs on w3id.org, FOLLOW
#     every redirect to completion, and assert a final 200 whose body parses.
#     This verifies the deployed rule AND its destination together. Unlike
#     run-tests.sh (local Apache, FIRST redirect hop only, offline), it follows
#     the w3id.org -> SA-server chain through to the real 200.
#
# Why this exists: the /gistCore.rdf incident. The .htaccess redirect fired
# correctly (303/302 with a good Location), so run-tests.sh passed — but the
# final destination on ontologies.semanticarts.com 404'd because the unversioned
# "latest" alias file wasn't published there. Checking only the redirect hop, or
# only the per-term files on GitHub Pages, cannot catch that.
#
# Both modes target the UNVERSIONED alias (gistCore.*) — the resource that went
# missing — and pair it with the VERSIONED file (gistCore14.1.0.*) as a control.
# If the unversioned cases 404 while the versioned ones succeed, that is the
# exact incident signature and is flagged as such.
#
# Requirements:
#   - curl
#   - internet access to ontologies.semanticarts.com and semanticarts.github.io
#     (targets mode), plus w3id.org (deref mode)
#   - OPTIONAL body validators: python3/python + rdflib (Turtle/RDF-XML/JSON-LD),
#     or jq (well-formed JSON-LD). Missing validators downgrade a body check to
#     a WARN, never a FAIL.
#
# Usage:
#   # PRE-deploy: do the target files exist on the origin?
#   MODE=targets tools/htaccess-test/check-live-deref.sh
#   MODE=targets NAMES="gistCore gistMediaTypes" ./check-live-deref.sh
#
#   # POST-deploy: does the live w3id.org chain resolve end to end?
#   tools/htaccess-test/check-live-deref.sh
#   VERSION=14.1.0 NAMES=gistCore ./check-live-deref.sh
#
# Env overrides: MODE (targets|deref, default deref), NAMES, VERSION, IRI_BASE
# (deref base), TARGET_BASE (origin whole-ontology dir, targets mode),
# HTML_TARGET (WIDOCO docs URL), TIMEOUT, PYTHON (path/name of a Python
# interpreter that has rdflib — useful when several Pythons coexist and the one
# on PATH lacks it, e.g. MSYS2 python vs a native C:\Python install).
#
# Exit codes: 0 = all checks passed; 1 = a real failure (404, wrong content, or
# the alias-missing signature); 2 = could not run (base host unreachable). Cases
# that are UNREACHABLE due to the network — as opposed to a real 404 from the
# server — are reported as WARN, not FAIL, so a firewalled runner (e.g. a
# container with no route to GitHub Pages) does not produce false failures.
set -uo pipefail

MODE="${MODE:-deref}"                 # targets = pre-deploy origin check; deref = post-deploy
NAMES="${NAMES:-gistCore}"
VERSION="${VERSION:-14.1.0}"
IRI_BASE="${IRI_BASE:-https://w3id.org/semanticarts/ontology}"
# Where the whole-ontology files actually live — what the .htaccess redirects
# to. Checked directly in targets (pre-deploy) mode.
TARGET_BASE="${TARGET_BASE:-https://ontologies.semanticarts.com/ontology}"
# The WIDOCO docs the HTML branch resolves to (the "latest" docs, shared across
# modules under the current rules).
HTML_TARGET="${HTML_TARGET:-https://semanticarts.github.io/gist-doc/latest/widoco-documentation/index-en.html}"
TIMEOUT="${TIMEOUT:-20}"

case "${MODE}" in
  targets|deref) ;;
  *) echo "ERROR: MODE must be 'targets' or 'deref', got '${MODE}'" >&2; exit 2 ;;
esac

# Browser-style Accept header (what Chrome/Firefox send). Contains
# application/xml and */* but must still route to HTML, so keep it verbatim.
BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'

red()  { printf '\033[31m%s\033[0m' "$1"; }
grn()  { printf '\033[32m%s\033[0m' "$1"; }
ylw()  { printf '\033[33m%s\033[0m' "$1"; }

command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 2; }

# Body validators (optional). Pick a Python that actually has rdflib — not just
# the first `python` on PATH. On Windows/Git Bash several interpreters commonly
# coexist (MSYS2's /mingw64/bin/python, the Windows `py` launcher, a native
# C:\Python\... install) and only one may have rdflib installed. Honor an
# explicit PYTHON override, else probe candidates and keep the first that can
# `import rdflib`. `py` is the Windows launcher, usually pointing at the native
# install where `pip install rdflib` lands.
HAVE_RDFLIB=0
if [[ -n "${PYTHON:-}" ]]; then
  "${PYTHON}" -c 'import rdflib' >/dev/null 2>&1 && HAVE_RDFLIB=1
else
  PYTHON=""
  for p in python3 python py; do
    command -v "$p" >/dev/null 2>&1 || continue
    if "$p" -c 'import rdflib' >/dev/null 2>&1; then PYTHON="$p"; HAVE_RDFLIB=1; break; fi
  done
fi
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

pass=0; fail=0; warn=0

# Track, per name, whether a real final-hop 404 was seen on an unversioned case
# and whether the versioned control succeeded — that pairing is the incident
# signature.
declare -A UNVERSIONED_404
declare -A VERSIONED_OK

# fetch <url> <accept>  ->  prints "<http_code>\t<content_type>\t<curl_exit>" and
# writes the response body to the pre-existing $BODY_FILE. accept='-' sends no
# Accept header. NOTE: fetch is called inside $(...) (a subshell), so it must NOT
# create $BODY_FILE itself — the name would not survive back to the caller. The
# caller (check) creates the temp file; curl -o writes to that real path, which
# the parent can then read.
BODY_FILE=""
fetch() {
  local url="$1" accept="$2"
  local -a hdr=(-H "Accept: ${accept}")
  [[ "${accept}" == "-" ]] && hdr=(-H "Accept:")
  local out code ct rc
  out="$(curl -sL -m "${TIMEOUT}" "${hdr[@]}" -o "${BODY_FILE}" \
        -w '%{http_code}\t%{content_type}' "${url}" 2>/dev/null)"
  rc=$?
  code="${out%%$'\t'*}"
  ct="${out##*$'\t'}"
  printf '%s\t%s\t%s' "${code}" "${ct}" "${rc}"
}

# validate_body <format>  (turtle|rdfxml|jsonld|html) -> 0 ok, 1 invalid, 2 skip
validate_body() {
  local fmt="$1"
  case "${fmt}" in
    turtle|rdfxml|jsonld)
      if [[ "${HAVE_RDFLIB}" == "1" ]]; then
        local rf=turtle
        [[ "${fmt}" == "rdfxml" ]] && rf=xml
        [[ "${fmt}" == "jsonld" ]] && rf=json-ld
        "${PYTHON}" - "$BODY_FILE" "$rf" <<'PY' >/dev/null 2>&1
import sys, rdflib
g = rdflib.Graph()
g.parse(sys.argv[1], format=sys.argv[2])
assert len(g) > 0
PY
        return $(( $? == 0 ? 0 : 1 ))
      fi
      if [[ "${fmt}" == "jsonld" && "${HAVE_JQ}" == "1" ]]; then
        jq -e . "${BODY_FILE}" >/dev/null 2>&1 && return 0 || return 1
      fi
      return 2 ;;
    html)
      grep -qi '<html' "${BODY_FILE}" && return 0 || return 1 ;;
  esac
  return 2
}

# check <desc> <url> <accept> <want_format> <bucket> <name>
#   want_format: turtle|rdfxml|jsonld|html
#   bucket:      "unversioned" | "versioned" | "none" — feeds the alias-missing
#                signature. Use "none" for the HTML/WIDOCO case: it is not one of
#                the SA-server alias files, so it must not trip the signature.
check() {
  local desc="$1" url="$2" accept="$3" fmt="$4" bucket="$5" name="$6"
  local res code ct rc
  BODY_FILE="$(mktemp)"
  res="$(fetch "${url}" "${accept}")"
  code="${res%%$'\t'*}"; rc="${res##*$'\t'}"
  ct="$(printf '%s' "${res}" | cut -f2)"

  # Network could not complete the chain (curl error or 000). Not a server 404 —
  # report WARN so a firewalled runner doesn't fail spuriously.
  if [[ "${rc}" != "0" || "${code}" == "000" ]]; then
    printf '  %s  %s\n' "$(ylw WARN)" "${desc}"
    printf '        unreachable (curl exit %s, http %s) — network, not a server 404\n' "${rc}" "${code}"
    warn=$((warn+1)); rm -f "${BODY_FILE}"; return
  fi

  if [[ "${code}" != "200" ]]; then
    printf '  %s  %s\n' "$(red FAIL)" "${desc}"
    printf '        expected final 200 %s, got %s (ct=%s)\n' "${fmt}" "${code}" "${ct}"
    fail=$((fail+1))
    [[ "${bucket}" == "unversioned" && "${code}" == "404" ]] && UNVERSIONED_404["${name}"]=1
    rm -f "${BODY_FILE}"; return
  fi

  # 200 — now validate the body.
  local v; validate_body "${fmt}"; v=$?
  if [[ "${v}" == "0" ]]; then
    printf '  %s  %s\n' "$(grn PASS)" "${desc}"
    pass=$((pass+1))
    [[ "${bucket}" == "versioned" ]] && VERSIONED_OK["${name}"]=1
  elif [[ "${v}" == "2" ]]; then
    printf '  %s  %s\n' "$(ylw PASS*)" "${desc}"
    printf '        200 OK; body parse skipped (no validator for %s)\n' "${fmt}"
    pass=$((pass+1)); warn=$((warn+1))
    [[ "${bucket}" == "versioned" ]] && VERSIONED_OK["${name}"]=1
  else
    printf '  %s  %s\n' "$(red FAIL)" "${desc}"
    printf '        200 but body did NOT parse as %s (ct=%s)\n' "${fmt}" "${ct}"
    fail=$((fail+1))
  fi
  rm -f "${BODY_FILE}"
}

if [[ "${MODE}" == "targets" ]]; then
  echo "==> Pre-deploy origin target check (do the whole-ontology files exist?)"
  echo "    base=${TARGET_BASE}  names='${NAMES}'  version=${VERSION}"
  GUARD_URL="${TARGET_BASE}/${NAMES%% *}.ttl"; GUARD_HOST="${TARGET_BASE}"
else
  echo "==> Post-deploy live deref check (does the w3id.org chain resolve?)"
  echo "    base=${IRI_BASE}  names='${NAMES}'  version=${VERSION}"
  GUARD_URL="${IRI_BASE}/${NAMES%% *}"; GUARD_HOST="${IRI_BASE}"
fi

# Guard: if the base host itself is unreachable (http 000), we cannot run at all
# — distinct from a real 404, which is a legitimate finding.
gc="$(curl -sL -m "${TIMEOUT}" -o /dev/null -w '%{http_code}' "${GUARD_URL}" 2>/dev/null || echo 000)"
if [[ "${gc}" == "000" ]]; then
  echo "ERROR: cannot reach ${GUARD_HOST} (http 000). Check network. Aborting." >&2
  exit 2
fi

for name in ${NAMES}; do
  if [[ "${MODE}" == "targets" ]]; then
    T="${TARGET_BASE}/${name}"
    echo
    echo "== Unversioned origin files (direct): ${T}.{rdf,ttl,jsonld} =="
    # Requested by explicit extension; no content negotiation happens here — we
    # are asking the origin whether each concrete file exists and is valid.
    check "rdf+xml file exists + valid RDF/XML"  "${T}.rdf"    "*/*" rdfxml unversioned "${name}"
    check "turtle  file exists + valid Turtle"   "${T}.ttl"    "*/*" turtle unversioned "${name}"
    check "ld+json file exists + valid JSON-LD"  "${T}.jsonld" "*/*" jsonld unversioned "${name}"
    check "WIDOCO docs exist (HTML)"             "${HTML_TARGET}" "*/*" html none "${name}"

    echo
    echo "== Versioned origin files (control): ${T}${VERSION}.{ttl,rdf,jsonld} =="
    check "${VERSION}.ttl    exists + valid Turtle"   "${T}${VERSION}.ttl"    "*/*" turtle versioned "${name}"
    check "${VERSION}.rdf    exists + valid RDF/XML"  "${T}${VERSION}.rdf"    "*/*" rdfxml versioned "${name}"
    check "${VERSION}.jsonld exists + valid JSON-LD"  "${T}${VERSION}.jsonld" "*/*" jsonld versioned "${name}"
  else
    U="${IRI_BASE}/${name}"
    echo
    echo "== Unversioned alias: ${U} =="
    check "rdf+xml -> 200 valid RDF/XML"          "${U}" "application/rdf+xml" rdfxml unversioned "${name}"
    check "turtle  -> 200 valid Turtle"           "${U}" "text/turtle"         turtle unversioned "${name}"
    check "ld+json -> 200 valid JSON-LD"          "${U}" "application/ld+json" jsonld unversioned "${name}"
    check "browser -> 200 WIDOCO HTML"            "${U}" "${BROWSER_ACCEPT}"   html   none        "${name}"
    check "*/*     -> 200 Turtle (default)"       "${U}" "*/*"                 turtle unversioned "${name}"
    check "no Accept -> 200 Turtle (default)"     "${U}" "-"                   turtle unversioned "${name}"

    echo
    echo "== Versioned pass-through: ${U}${VERSION}.{ttl,rdf,jsonld} (control) =="
    check "${VERSION}.ttl    -> 200 valid Turtle"   "${U}${VERSION}.ttl"    "*/*" turtle versioned "${name}"
    check "${VERSION}.rdf    -> 200 valid RDF/XML"  "${U}${VERSION}.rdf"    "*/*" rdfxml versioned "${name}"
    check "${VERSION}.jsonld -> 200 valid JSON-LD"  "${U}${VERSION}.jsonld" "*/*" jsonld versioned "${name}"
  fi
done

echo
echo "------------------------------------------------------------"

# Incident signature: unversioned final-hop 404 while the versioned control for
# the same module resolves. Distinguishes the "latest alias missing" failure
# from a generic redirect-rule break (which would fail the versioned case too).
sig=0
for name in ${NAMES}; do
  if [[ "${UNVERSIONED_404[$name]:-0}" == "1" && "${VERSIONED_OK[$name]:-0}" == "1" ]]; then
    printf '  %s  unversioned latest alias missing on ontologies.semanticarts.com: %s\n' "$(red SIGNATURE)" "${name}"
    if [[ "${MODE}" == "targets" ]]; then
      printf '        (versioned %s%s.* exists on the origin, but unversioned %s.* does NOT — publish it BEFORE deploying)\n' "${name}" "${VERSION}" "${name}"
    else
      printf '        (versioned %s%s.* resolves, but unversioned %s 404s at the final hop)\n' "${name}" "${VERSION}" "${name}"
    fi
    sig=1
  fi
done

label="Live deref"; [[ "${MODE}" == "targets" ]] && label="Origin targets"
printf '%s: %s passed, %s failed, %s warnings\n' "${label}" \
  "$(grn ${pass})" "$([[ ${fail} -eq 0 ]] && grn 0 || red ${fail})" "$(ylw ${warn})"

echo
[[ ${fail} -eq 0 ]] && { echo "$(grn 'ALL CHECKS PASSED')"; exit 0; }
[[ ${sig} -eq 1 ]] && echo "$(red 'INCIDENT SIGNATURE DETECTED — see SIGNATURE lines above')"
echo "$(red 'SOME CHECKS FAILED')"; exit 1
