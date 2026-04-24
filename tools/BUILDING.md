# Building WIDOCO documentation

How to regenerate the `gist-<version>/widoco-documentation/` output for a gist release.

## Getting the WIDOCO jar

The WIDOCO jar is not committed (39 MB binary, easy to re-fetch). From the repo root, in a bash shell (git-bash on Windows works):

```bash
bash tools/fetch-widoco.sh
```

This downloads the pinned version (currently `widoco-1.4.25 / JDK-17`) from the [WIDOCO releases page](https://github.com/dgarijo/Widoco/releases) into `tools/`. Re-running is a no-op if the jar is already present.

To bump the pinned version, edit `WIDOCO_VERSION` / `WIDOCO_JDK` at the top of `fetch-widoco.sh`.

## Building docs for a gist release

Each gist release lives in its own `gist-<version>/` directory with a `widoco.command.txt` and `widoco_config.txt`. To regenerate:

```bash
bash tools/fetch-widoco.sh        # one-time, grabs the jar if missing
cd gist-<version>
bash widoco.command.txt
```

Output lands in `gist-<version>/widoco-documentation/`. To smoke-test it locally:

```bash
./widoco_test_python-server.bat   # or: python -m http.server 8000 --directory ./widoco-documentation
```

then open http://127.0.0.1:8000/index-en.html.

## Starting a new release

To add `gist-<new-version>/`, copy the most recent version's directory and update:

- `widoco_config.txt` — bump `thisVersionURI`, `latestVersionURI`, `previousVersionURI`, `ontologyRevisionNumber`, all `date*` fields, `citeAs`, and `description`
- `widoco.command.txt` — point `-ontFile` at the new RDF in `../ontologies/`

Drop the new RDF into `ontologies/` at the repo root.
