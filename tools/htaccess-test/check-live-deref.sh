#!/usr/bin/env bash
#
# LIVE end-to-end regression test for the deployed semanticarts.htaccess rules.
#
# Unlike run-tests.sh (which stands up a local Apache and checks only the FIRST
# redirect hop, offline), this script hits the real IRIs on w3id.org, FOLLOWS
# every redirect to completion, and asserts a final 200 whose body actually
# parses in the negotiated format.
#
# Why this exists: the /gistCore.rdf incident. The .htaccess redirect fired
# correctly (303/302 with a good Location), so run-tests.sh passed — but the
# final destination on ontologies.semanticarts.com 404'd because the unversioned
# "latest" alias file wasn't published there. Checking only the redirect hop, or
# only the per-term files on GitHub Pages, cannot catch that. This test follows
# the w3id.org -> SA-server chain through to the real 200.
#
# It targets the UNVERSIONED alias (…/ontology/gistCore) — the resource that
# went missing — and pairs it with the VERSIONED pass-through (gistCore14.1.0.*)
# as a control. If the unversioned cases 404 at the final hop while the versioned
# ones succeed, that is the exact incident signature and is flagged as such.
#
# Requirements:
#   - curl
#   - internet access to w3id.org, ontologies.semanticarts.com, and (for the
#     HTML/WIDOCO branch) semanticarts.github.io
#   - OPTIONAL body validators: python3 + rdflib (Turtle/RDF-XML/JSON-LD),
#     or jq (well-formed JSON-LD). Missing validators downgrade a body check to
#     a WARN, never a FAIL.
#
# Usage:
#   tools/htaccess-test/check-live-deref.sh                       # gistCore, v14.1.0
#   NAMES="gistCore gistMediaTypes" ./check-live-deref.sh         # multiple modules
#   VERSION=14.1.0 NAMES=gistCore ./check-live-deref.sh
#
# Env overrides: NAMES, VERSION, IRI_BASE, TIMEOUT
#
# Exit codes: 0 = all checks passed; 1 = a real failure (final 404, wrong
# content, or the alias-missing signature); 2 = could not run (e.g. w3id.org
# itself unreachable). Cases that are UNREACHABLE due to the network — as
# opposed to a real 404 from the server — are reported as WARN, not FAIL, so a
# firewalled runner (e.g. a container with no route to GitHub Pages) does not
# produce false failures.
set -uo pipefail

NAMES="${NAMES:-gistCore}"
VERSION="${VERSION:-14.1.0}"
IRI_BASE="${IRI_BASE:-https://w3id.org/semanticarts/ontology}"
TIMEOUT="${TIMEOUT:-20}"

# Browser-style Accept header (what Chrome/Firefox send). Contains
# application/xml and */* but must still route to HTML, so keep it verbatim.
BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'

red()  { printf '\033[31m%s\033[0m' "$1"; }
grn()  { printf '\033[32m%s\033[0m' "$1"; }
ylw()  { printf '\033[33m%s\033[0m' "$1"; }

command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 2; }

# Body validators (optional). Detect once. Prefer python3, fall back to python
# (Windows/Git Bash usually ships the interpreter as `python`, not `python3`).
PYTHON=""
for p in python3 python; do command -v "$p" >/dev/null 2>&1 && { PYTHON="$p"; break; }; done
HAVE_RDFLIB=0
[[ -n "${PYTHON}" ]] && "${PYTHON}" -c 'import rdflib' >/dev/null 2>&1 && HAVE_RDFLIB=1
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
#   bucket:      "unversioned" | "versioned" (for the signature assertion)
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

echo "==> Live deref regression test"
echo "    base=${IRI_BASE}  names='${NAMES}'  version=${VERSION}"

# Guard: if w3id.org itself is unreachable, we cannot run at all.
gc="$(curl -sL -m "${TIMEOUT}" -o /dev/null -w '%{http_code}' "${IRI_BASE}/${NAMES%% *}" 2>/dev/null || echo 000)"
if [[ "${gc}" == "000" ]]; then
  echo "ERROR: cannot reach ${IRI_BASE} (http 000). Check network. Aborting." >&2
  exit 2
fi

for name in ${NAMES}; do
  U="${IRI_BASE}/${name}"
  echo
  echo "== Unversioned alias: ${U} =="
  check "rdf+xml -> 200 valid RDF/XML"          "${U}" "application/rdf+xml" rdfxml unversioned "${name}"
  check "turtle  -> 200 valid Turtle"           "${U}" "text/turtle"         turtle unversioned "${name}"
  check "ld+json -> 200 valid JSON-LD"          "${U}" "application/ld+json" jsonld unversioned "${name}"
  check "browser -> 200 WIDOCO HTML"            "${U}" "${BROWSER_ACCEPT}"   html   unversioned "${name}"
  check "*/*     -> 200 Turtle (default)"       "${U}" "*/*"                 turtle unversioned "${name}"
  check "no Accept -> 200 Turtle (default)"     "${U}" "-"                   turtle unversioned "${name}"

  echo
  echo "== Versioned pass-through: ${U}${VERSION}.{ttl,rdf,jsonld} (control) =="
  check "${VERSION}.ttl    -> 200 valid Turtle"   "${U}${VERSION}.ttl"    "*/*" turtle versioned "${name}"
  check "${VERSION}.rdf    -> 200 valid RDF/XML"  "${U}${VERSION}.rdf"    "*/*" rdfxml versioned "${name}"
  check "${VERSION}.jsonld -> 200 valid JSON-LD"  "${U}${VERSION}.jsonld" "*/*" jsonld versioned "${name}"
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
    printf '        (versioned %s%s.* resolves, but unversioned %s 404s at the final hop)\n' "${name}" "${VERSION}" "${name}"
    sig=1
  fi
done

printf 'Live deref: %s passed, %s failed, %s warnings\n' \
  "$(grn ${pass})" "$([[ ${fail} -eq 0 ]] && grn 0 || red ${fail})" "$(ylw ${warn})"

echo
[[ ${fail} -eq 0 ]] && { echo "$(grn 'ALL LIVE CHECKS PASSED')"; exit 0; }
[[ ${sig} -eq 1 ]] && echo "$(red 'INCIDENT SIGNATURE DETECTED — see SIGNATURE lines above')"
echo "$(red 'SOME LIVE CHECKS FAILED')"; exit 1
