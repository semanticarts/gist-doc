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
  pass-through) → Semantic Arts server / WIDOCO.
- The catch-all (anything else, e.g. the `ns/data/gist/` namespace) → 302
  pass-through to the Semantic Arts server.

## Requirements

- Docker (running)
- `curl`

The first run pulls the `httpd:2.4` image (needs internet once). After that the
routing tests run fully offline — they assert the **redirect targets**, not that
those targets resolve.

## Run

`semanticarts.htaccess` is intentionally **not** stored in this repo — it lives
in the [w3id.org](https://github.com/perma-id/w3id.org) repo. Point the harness
at your working copy with `HTACCESS`:

```bash
# Routing logic only:
HTACCESS=/path/to/semanticarts.htaccess tools/htaccess-test/run-tests.sh

# Also confirm the live gist-doc Pages targets resolve with 200
# (only meaningful AFTER the deref branch is merged and Pages has redeployed):
HTACCESS=/path/to/semanticarts.htaccess CHECK_TARGETS=1 tools/htaccess-test/run-tests.sh
```

Exit code is `0` only when every check passes, so it works in CI too.

### Useful overrides

- `HTACCESS` (**required**) — path to the `semanticarts.htaccess` under test.
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
