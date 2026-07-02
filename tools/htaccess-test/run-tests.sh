#!/usr/bin/env bash
#
# Test semanticarts.htaccess locally BEFORE deploying it to the w3id.org repo.
#
# It stands up a throwaway Apache (httpd:2.4) container that loads
# semanticarts.htaccess as a per-directory .htaccess at the document root —
# exactly the context it runs in under w3id.org's /semanticarts/ folder, where
# RewriteRule patterns like `^ns/ontology/gist/...` match the path with the
# directory prefix stripped. It then drives the rules with curl, asserting the
# status code and Location header for every content-negotiation branch.
#
# Requirements (on your host, outside the dev container):
#   - docker (running)
#   - curl
#
# semanticarts.htaccess is intentionally NOT stored in this repo (it is deployed
# to the w3id.org repo), so point the harness at your working copy:
#
#   HTACCESS=/path/to/semanticarts.htaccess tools/htaccess-test/run-tests.sh
#
# Usage:
#   HTACCESS=... tools/htaccess-test/run-tests.sh                  # routing tests (no internet needed*)
#   HTACCESS=... CHECK_TARGETS=1 tools/htaccess-test/run-tests.sh  # also verify the live
#                                                                  # gist-doc Pages targets resolve (200)
#
#   *the first run pulls the httpd:2.4 image, which needs internet once.
#
# Env overrides: HTACCESS (required), PORT, CONTAINER, PAGES_BASE
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HTACCESS="${HTACCESS:-${REPO_ROOT}/semanticarts.htaccess}"
PORT="${PORT:-8080}"
CONTAINER="${CONTAINER:-semanticarts-htaccess-test}"
BASE="http://localhost:${PORT}"
PAGES_BASE="${PAGES_BASE:-https://semanticarts.github.io/gist-doc}"
CHECK_TARGETS="${CHECK_TARGETS:-0}"

# Browser-style Accept header (what Chrome/Firefox actually send). Must route to
# HTML even though it contains application/xml and */* — none of those match the
# turtle/rdf/json conds, so it falls through to the text/html rule.
BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'

red() { printf '\033[31m%s\033[0m' "$1"; }
grn() { printf '\033[32m%s\033[0m' "$1"; }

if [[ ! -f "${HTACCESS}" ]]; then
  cat >&2 <<EOF
ERROR: semanticarts.htaccess not found at:
  ${HTACCESS}

This file is intentionally not stored in the gist-doc repo (it is deployed to
the w3id.org repo). Point the harness at your working copy with HTACCESS:

  HTACCESS=/path/to/semanticarts.htaccess ${0}
EOF
  exit 2
fi
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 2; }

cleanup() { docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Starting Apache (httpd:2.4) with semanticarts.htaccess at the doc root..."
cleanup
docker run -d --name "${CONTAINER}" -p "${PORT}:80" \
  -v "${HTACCESS}:/usr/local/apache2/htdocs/.htaccess:ro" \
  httpd:2.4 \
  bash -c "
    sed -i 's|^#LoadModule rewrite_module|LoadModule rewrite_module|' conf/httpd.conf
    sed -i 's|AllowOverride None|AllowOverride All|g'                  conf/httpd.conf
    exec httpd-foreground
  " >/dev/null

echo -n "==> Waiting for Apache to come up"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/" 2>/dev/null || echo 000)"
  [[ "${code}" != "000" ]] && break
  echo -n "."; sleep 1
done
echo
if [[ "${code:-000}" == "000" ]]; then
  echo "ERROR: Apache did not respond on ${BASE}. Container logs:" >&2
  docker logs "${CONTAINER}" 2>&1 | tail -n 20 >&2
  exit 2
fi

pass=0; fail=0

# assert_redirect <desc> <path> <accept> <want_code> <want_location_substr>
# Sends one request WITHOUT following redirects and checks the status line and
# the Location header. Pass accept='-' to send no Accept header at all.
assert_redirect() {
  local desc="$1" path="$2" accept="$3" want_code="$4" want_loc="$5"
  local curl_accept=(-H "Accept: ${accept}")
  [[ "${accept}" == "-" ]] && curl_accept=(-H "Accept:")  # remove the header

  local hdrs status loc
  hdrs="$(curl -s -o /dev/null -D - "${curl_accept[@]}" "${BASE}/${path}")"
  status="$(printf '%s' "${hdrs}" | awk 'NR==1{print $2}')"
  loc="$(printf '%s' "${hdrs}" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"

  if [[ "${status}" == "${want_code}" && "${loc}" == *"${want_loc}"* ]]; then
    printf '  %s  %s\n' "$(grn PASS)" "${desc}"
    pass=$((pass+1))
  else
    printf '  %s  %s\n' "$(red FAIL)" "${desc}"
    printf '        Accept:   %s\n' "${accept}"
    printf '        expected: %s  Location ~ %s\n' "${want_code}" "${want_loc}"
    printf '        got:      %s  Location = %s\n' "${status:-<none>}" "${loc:-<none>}"
    fail=$((fail+1))
  fi
}

P="${PAGES_BASE}"
O="https://ontologies.semanticarts.com"

echo
echo "== Per-term content negotiation: /ns/ontology/gist/Account =="
assert_redirect "turtle  -> terms/Account.ttl"      "ns/ontology/gist/Account" "text/turtle"         303 "${P}/terms/Account.ttl"
assert_redirect "rdf+xml -> terms/Account.rdf"      "ns/ontology/gist/Account" "application/rdf+xml" 303 "${P}/terms/Account.rdf"
assert_redirect "ld+json -> terms/Account.jsonld"   "ns/ontology/gist/Account" "application/ld+json" 303 "${P}/terms/Account.jsonld"
assert_redirect "json    -> terms/Account.jsonld"   "ns/ontology/gist/Account" "application/json"    303 "${P}/terms/Account.jsonld"
assert_redirect "html    -> widoco#Account (NE: literal '#', not %23)" \
                                                    "ns/ontology/gist/Account" "${BROWSER_ACCEPT}"   303 "${P}/latest/widoco-documentation/index-en.html#Account"
assert_redirect "*/*     -> terms/Account.ttl (default)" "ns/ontology/gist/Account" "*/*"            303 "${P}/terms/Account.ttl"
assert_redirect "no Accept header -> terms/Account.ttl (default)" "ns/ontology/gist/Account" "-"     303 "${P}/terms/Account.ttl"

echo
echo "== Namespace IRI: /ns/ontology/gist =="
assert_redirect "no slash -> Namespace.html"        "ns/ontology/gist"  "*/*" 302 "${O}/ontology/Namespace.html"
assert_redirect "trailing slash -> Namespace.html"  "ns/ontology/gist/" "*/*" 302 "${O}/ontology/Namespace.html"

echo
echo "== Whole-ontology IRI: /ontology/gistCore14.1.0 =="
assert_redirect "explicit .ttl -> server (pass-through)" "ontology/gistCore14.1.0.ttl" "text/turtle" 303 "${O}/gistCore14.1.0.ttl"
assert_redirect "turtle  -> server .ttl"            "ontology/gistCore14.1.0" "text/turtle"          303 "${O}/gistCore14.1.0.ttl"
assert_redirect "rdf+xml -> server .rdf"            "ontology/gistCore14.1.0" "application/rdf+xml"   303 "${O}/gistCore14.1.0.rdf"
assert_redirect "ld+json -> server .jsonld"         "ontology/gistCore14.1.0" "application/ld+json"   303 "${O}/gistCore14.1.0.jsonld"
assert_redirect "html    -> widoco docs"            "ontology/gistCore14.1.0" "${BROWSER_ACCEPT}"     303 "${P}/latest/widoco-documentation/index-en.html"
assert_redirect "*/*     -> server .ttl (default)"  "ontology/gistCore14.1.0" "*/*"                   303 "${O}/gistCore14.1.0.ttl"

echo
echo "== Catch-all pass-through: everything else -> Semantic Arts server (302) =="
assert_redirect "bare gistCore             -> server" "gistCore"            "*/*" 302 "${O}/gistCore"
assert_redirect "ns/data/gist/Foo (data ns) -> server" "ns/data/gist/Foo"   "*/*" 302 "${O}/ns/data/gist/Foo"

echo
echo "------------------------------------------------------------"
printf 'Routing tests: %s passed, %s failed\n' "$(grn ${pass})" "$([[ ${fail} -eq 0 ]] && grn 0 || red ${fail})"

if [[ "${CHECK_TARGETS}" == "1" ]]; then
  echo
  echo "== Live target reachability on ${PAGES_BASE} (requires the branch to be merged & Pages deployed) =="
  tfail=0
  for rel in \
    "terms/Account.ttl" \
    "terms/Account.rdf" \
    "terms/Account.jsonld" \
    "latest/widoco-documentation/index-en.html"; do
    code="$(curl -sL -o /dev/null -w '%{http_code}' "${PAGES_BASE}/${rel}")"
    if [[ "${code}" == "200" ]]; then
      printf '  %s  %s\n' "$(grn 200)" "${PAGES_BASE}/${rel}"
    else
      printf '  %s  %s\n' "$(red "${code}")" "${PAGES_BASE}/${rel}"
      tfail=$((tfail+1))
    fi
  done
  [[ ${tfail} -gt 0 ]] && fail=$((fail+tfail))
fi

echo
[[ ${fail} -eq 0 ]] && { echo "$(grn 'ALL CHECKS PASSED')"; exit 0; }
echo "$(red 'SOME CHECKS FAILED')"; exit 1
