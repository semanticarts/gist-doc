# Testing `semanticarts.htaccess`

These tests let you validate `semanticarts.htaccess` on your own machine
**before** copying it into the [w3id.org](https://github.com/perma-id/w3id.org)
repo's `semanticarts/` folder. w3id.org runs Apache, so the only faithful way to
test the rewrite logic is to run Apache against the file — which `run-tests.sh`
does inside a throwaway container.

## What it checks

`run-tests.sh` starts `httpd:2.4` with the htaccess loaded as a per-directory
`.htaccess` at the document root — the same context it has under w3id.org's
`/semanticarts/` folder (the directory prefix is stripped before the
`^ns/ontology/gist/...` patterns are matched). It then drives the rules with
`curl` and asserts, for each branch, the **status code** and the **`Location`
header** without following the redirect:

- Per-term content negotiation (`Accept: text/turtle | application/rdf+xml |
  application/ld+json | application/json | text/html | */* | none`).
- That the HTML branch emits a **literal `#Account`** fragment — this proves the
  `[NE]` flag is present (without it Apache escapes `#` to `%23` and the
  in-page `loadHash()` scroll breaks).
- A realistic browser `Accept` header routes to the WIDOCO HTML.
- Namespace IRI (`/ns/ontology/gist` with and without a trailing slash) → 302.
- Whole-ontology IRIs (`/ontology/gistCore14.1.0`, plus the explicit-extension
  pass-through) → Semantic Arts server / WIDOCO. The redirect target preserves
  the full request path, including the leading `ontology/` segment.
- The catch-all (anything else, e.g. the `ns/data/gist/` namespace) → 303 to a
  Turtle file on the Semantic Arts server, preserving the request path.

## Live deref regression test (`check-live-deref.sh`)

`run-tests.sh` checks only the **first redirect hop**, offline, against a local
Apache. That cannot catch the `/gistCore.rdf` incident: the `.htaccess` redirect
fired correctly (a valid 303/302 `Location`, so `run-tests.sh` passed), but the
**final destination** on `ontologies.semanticarts.com` 404'd because the
unversioned "latest" alias file was never published there. Checking only the hop
— or only the per-term files on GitHub Pages — misses it.

`check-live-deref.sh` closes that gap. It hits the **real** IRIs on w3id.org,
**follows every redirect to completion**, and asserts a final **200 whose body
actually parses** in the negotiated format (via `rdflib`/`jq` when available). It
targets the **unversioned** alias (`…/ontology/gistCore`) — the resource that
went missing — and pairs each with the **versioned** pass-through
(`gistCore14.1.0.{ttl,rdf,jsonld}`) as a control.

If an unversioned case 404s at the final hop **while its versioned control still
resolves**, that is the exact incident signature and is flagged as
`SIGNATURE  unversioned latest alias missing on ontologies.semanticarts.com:
<name>` — distinct from a generic redirect-rule break (which would fail the
versioned case too).

```bash
tools/htaccess-test/check-live-deref.sh                        # gistCore, v14.1.0
NAMES="gistCore gistMediaTypes" tools/htaccess-test/check-live-deref.sh
VERSION=14.1.0 NAMES=gistCore    tools/htaccess-test/check-live-deref.sh
```

- Needs **internet**, not Docker or the `HTACCESS` file — it tests the *deployed*
  rules, so run it after a w3id.org change lands. Good as a CI/cron canary.
- Env: `NAMES` (space-separated modules, default `gistCore`), `VERSION` (default
  `14.1.0`), `IRI_BASE`, `TIMEOUT`.
- Body validators are **optional**: `rdflib` under `python3`/`python`
  (Turtle/RDF-XML/JSON-LD, `pip install rdflib`) or `jq` (JSON-LD only). Missing
  validators downgrade a body check to `PASS*`/`WARN`, never a FAIL. On
  Windows/Git Bash the interpreter is usually `python`, which is detected too.
- Exit codes: `0` all passed · `1` a real failure (final 404, bad body, or the
  signature) · `2` could not run (w3id.org itself unreachable). Cases that are
  **network-unreachable** (e.g. a firewalled runner with no route to GitHub
  Pages, which the HTML branch redirects to) are reported as **WARN**, not FAIL,
  so they don't cause spurious failures.

## Requirements

- Docker (running) — for `run-tests.sh` only
- `curl`

The first run pulls the `httpd:2.4` image (needs internet once). After that the
routing tests run fully offline — they assert the **redirect targets**, not that
those targets resolve.

### Windows / Git Bash

`run-tests.sh` runs on Windows under Git Bash (MSYS/MINGW). It handles the MSYS
quirk where the shell rewrites Unix-style arguments into Windows paths — left
unhandled, that mangles the container-side bind-mount target
(`/usr/local/apache2/htdocs/.htaccess`) and Apache never loads the rules, so
every request 404s. The script disables that conversion (`MSYS_NO_PATHCONV=1`)
and translates the host path with `cygpath` for the `docker` calls, so no manual
setup is needed. Docker Desktop must be running on the host (not inside a dev
container).

## Run

`semanticarts.htaccess` is intentionally **not** stored in this repo — it lives
in the [w3id.org](https://github.com/perma-id/w3id.org) repo's
`semanticarts/.htaccess`. Point the harness at your working copy with
`HTACCESS`. Relative or absolute paths both work (the script resolves it to an
absolute path before mounting it into the container):

```bash
# Routing logic only (path is relative to your current directory):
HTACCESS=../w3id.org/semanticarts/.htaccess tools/htaccess-test/run-tests.sh

# Also confirm the live gist-doc Pages targets resolve with 200
# (only meaningful AFTER the deref branch is merged and Pages has redeployed):
HTACCESS=../w3id.org/semanticarts/.htaccess CHECK_TARGETS=1 tools/htaccess-test/run-tests.sh
```

Exit code is `0` only when every check passes, so it works in CI too.

### Useful overrides

- `HTACCESS` (**required**) — path to the `semanticarts.htaccess` under test
  (relative or absolute; typically `../w3id.org/semanticarts/.htaccess`).
- `PORT` (default `8080`) — host port for the test Apache.
- `PAGES_BASE` (default `https://semanticarts.github.io/gist-doc`) — expected redirect base / target host.
- `CHECK_TARGETS` (default `0`) — `1` = also verify the live Pages files resolve (200).

## No Docker? Two fallbacks

1. **Direct Pages reachability only** — skips the rewrite logic but confirms the
   files the rules point at are actually published:

   ```bash
   for u in terms/Account.ttl terms/Account.rdf terms/Account.jsonld \
            latest/widoco-documentation/index-en.html; do
     printf '%s  %s\n' "$(curl -sL -o /dev/null -w '%{http_code}' \
       "https://semanticarts.github.io/gist-doc/$u")" "$u"
   done
   ```

2. **Local Apache install** — copy `semanticarts.htaccess` to a directory with
   `AllowOverride All` and `mod_rewrite` enabled, then run the same `curl`
   assertions from `run-tests.sh` against it.

## After it passes

Copy `semanticarts.htaccess` into the w3id.org repo's `semanticarts/.htaccess`,
open the PR there, and once merged re-run the conneg checks against the real
IRIs:

```bash
curl -sI -H 'Accept: text/turtle' \
  https://w3id.org/semanticarts/ns/ontology/gist/Account
# expect: 303 + Location: https://semanticarts.github.io/gist-doc/terms/Account.ttl
```
