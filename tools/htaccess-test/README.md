# Testing `semanticarts.htaccess`

Two complementary harnesses validate `semanticarts.htaccess` — the rewrite file
deployed to the [w3id.org](https://github.com/perma-id/w3id.org) repo's
`semanticarts/` folder:

- **`run-tests.sh`** — run it **before** deploying. It checks the **routing
  logic offline**: the status code and `Location` each content-negotiation
  branch produces (the first redirect hop only). w3id.org runs Apache, so the
  only faithful way to test the rewrite logic is to run Apache against the file
  — this stands up a throwaway `httpd:2.4` container and drives the real rules
  with `curl`. No internet needed after the image is pulled once.
- **`check-live-deref.sh`** — verifies the whole-ontology files the rules point
  at actually **exist and resolve**, in two modes:
  - **`MODE=targets`** (**before** deploying) — hits the origin files directly
    on `ontologies.semanticarts.com` (`gistCore.rdf`, `.ttl`, `.jsonld`, the
    versioned files, the WIDOCO docs) and confirms each exists and parses. This
    answers *"do the destinations the new rules will point at exist yet?"* —
    which you cannot ask through w3id.org, because the new rules aren't live.
  - **`MODE=deref`** (default, **after** deploying) — hits the real w3id.org
    IRIs, follows every redirect to a final `200`, and validates the body. This
    catches breakage the offline routing test structurally cannot — a correct
    redirect pointing at a destination that doesn't exist.

Use all three checks across the deploy: `run-tests.sh` proves the rules are
written correctly and `check-live-deref.sh MODE=targets` proves their
destinations exist — **both before deploying**; then, once the `.htaccess` is
live on w3id.org, `check-live-deref.sh` (deref) proves the full chain resolves.

---

## `run-tests.sh` — offline routing checks (pre-deploy)

### What it checks

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

It asserts the **redirect targets**, not that those targets resolve — that is
what `check-live-deref.sh` is for.

### Requirements

- Docker (running)
- `curl`

The first run pulls the `httpd:2.4` image (needs internet once). After that the
routing tests run fully offline.

### Windows / Git Bash

`run-tests.sh` runs on Windows under Git Bash (MSYS/MINGW). It handles the MSYS
quirk where the shell rewrites Unix-style arguments into Windows paths — left
unhandled, that mangles the container-side bind-mount target
(`/usr/local/apache2/htdocs/.htaccess`) and Apache never loads the rules, so
every request 404s. The script disables that conversion (`MSYS_NO_PATHCONV=1`)
and translates the host path with `cygpath` for the `docker` calls, so no manual
setup is needed. Docker Desktop must be running on the host (not inside a dev
container).

### Run

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

#### Useful overrides

- `HTACCESS` (**required**) — path to the `semanticarts.htaccess` under test
  (relative or absolute; typically `../w3id.org/semanticarts/.htaccess`).
- `PORT` (default `8080`) — host port for the test Apache.
- `PAGES_BASE` (default `https://semanticarts.github.io/gist-doc`) — expected redirect base / target host.
- `CHECK_TARGETS` (default `0`) — `1` = also verify the live Pages files resolve (200).

### No Docker? Two fallbacks

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

---

## `check-live-deref.sh` — whole-ontology resolution checks

### Why it exists

The offline `run-tests.sh` asserts the redirect **target** (`Location`), not
that the target resolves. The `/gistCore.rdf` incident slipped through exactly
there: the `.htaccess` redirect fired correctly (a valid 303/302 `Location`, so
`run-tests.sh` passed), but the **final destination** on
`ontologies.semanticarts.com` 404'd because the unversioned "latest" alias file
was never published. Checking only the hop — or only the per-term files on
GitHub Pages — misses it.

### What it checks

It verifies the whole-ontology files — the **unversioned** alias (`gistCore.*`),
the resource that went missing, paired with the **versioned** file
(`gistCore14.1.0.*`) as a control — in two modes:

- **`MODE=targets`** (pre-deploy) — requests each origin file **directly** on
  `ontologies.semanticarts.com` (`gistCore.rdf`, `.ttl`, `.jsonld`, the versioned
  files, and the WIDOCO docs) and asserts a `200` whose body parses. Run it
  *before* deploying to confirm the destinations the new rules will point at
  actually exist.
- **`MODE=deref`** (default, post-deploy) — hits the **real** IRIs on w3id.org,
  **follows every redirect to completion**, and asserts a final `200` whose body
  parses in the negotiated format. Run it *after* deploying to confirm the rule
  and its destination resolve together.

In either mode, if an unversioned file is missing (404) **while its versioned
control still resolves**, that is the exact incident signature and is flagged as
`SIGNATURE  unversioned latest alias missing on ontologies.semanticarts.com:
<name>` — distinct from a generic redirect-rule break (which would fail the
versioned case too). Body parsing uses `rdflib`/`jq` when available.

### Requirements

- `curl`
- Internet access to `ontologies.semanticarts.com` and `semanticarts.github.io`
  (targets mode), plus w3id.org (deref mode).
- **Optional** body validators — `rdflib` (Turtle/RDF-XML/JSON-LD,
  `pip install rdflib`) or `jq` (JSON-LD only). Missing validators downgrade a
  body check to `PASS*`/`WARN`, never a FAIL. The script probes `python3`,
  `python`, then the Windows `py` launcher and keeps the first that can
  `import rdflib`. When several Pythons coexist and the one on PATH lacks rdflib
  (e.g. MSYS2's `python` vs a native `C:\Python` install), point `PYTHON` at the
  right one: `PYTHON=/c/Python/Python313/python.exe ...check-live-deref.sh`.

It needs neither Docker nor the `HTACCESS` file. Good as a CI/cron canary.

### Run

```bash
# Pre-deploy: do the origin files the new rules will point at exist?
MODE=targets tools/htaccess-test/check-live-deref.sh
MODE=targets NAMES="gistCore gistMediaTypes" tools/htaccess-test/check-live-deref.sh

# Post-deploy: does the live w3id.org chain resolve end to end?
tools/htaccess-test/check-live-deref.sh                        # gistCore, v14.1.0
VERSION=14.1.0 NAMES=gistCore tools/htaccess-test/check-live-deref.sh
```

#### Useful overrides

- `MODE` (default `deref`) — `targets` = pre-deploy direct origin check;
  `deref` = post-deploy w3id.org resolution.
- `NAMES` (default `gistCore`) — space-separated ontology modules to check, so
  the same alias-gap test covers any module, not just `gistCore`.
- `VERSION` (default `14.1.0`) — release version for the versioned control cases.
- `IRI_BASE` (default `https://w3id.org/semanticarts/ontology`) — deref base.
- `TARGET_BASE` (default `https://ontologies.semanticarts.com/ontology`) — origin
  whole-ontology directory checked in targets mode.
- `HTML_TARGET` — the WIDOCO docs URL the HTML branch resolves to.
- `TIMEOUT` (default `20`) — per-request curl timeout, seconds.
- `PYTHON` — path/name of a Python interpreter that has `rdflib` (see
  Requirements).

#### Exit codes

- `0` — all checks passed.
- `1` — a real failure (404, body did not parse, or the alias-missing signature).
- `2` — could not run (base host unreachable).

Cases that are **network-unreachable** (e.g. a firewalled runner with no route
to GitHub Pages, which the HTML branch resolves to) are reported as **WARN**,
not FAIL, so they don't cause spurious failures.

---

## Deploying to w3id.org

1. **Validate the rules offline** — `run-tests.sh` passes (routing is correct).
2. **Confirm the destinations exist** — before deploying, check that the origin
   files the new rules will point at are actually published:

   ```bash
   MODE=targets tools/htaccess-test/check-live-deref.sh
   ```

   If this flags the alias-missing `SIGNATURE`, publish the missing
   whole-ontology file(s) on `ontologies.semanticarts.com` **before** deploying —
   otherwise you ship a rule that resolves to a 404 (the `/gistCore.rdf`
   incident).
3. **Deploy** — copy `semanticarts.htaccess` into the w3id.org repo's
   `semanticarts/.htaccess` and open the PR there.
4. **Confirm the live chain** — after it merges and GitHub Pages has redeployed:

   ```bash
   # Whole-ontology aliases (unversioned + versioned), following redirects to 200:
   tools/htaccess-test/check-live-deref.sh

   # Spot-check a single per-term IRI by hand (not covered by the script above):
   curl -sI -H 'Accept: text/turtle' \
     https://w3id.org/semanticarts/ns/ontology/gist/Account
   # expect: 303 + Location: https://semanticarts.github.io/gist-doc/terms/Account.ttl
   ```
