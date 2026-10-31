# Working on the docs

This site is [Zensical](https://zensical.org), built with uv through the toolchain's go archetype. Its look comes from
the [toolchain site](https://oss.bitwisemedia.uk/toolchain/): the same `docs/stylesheets/extra.css` tokens and header
partials, with a landing page in `overrides/home.html`.

```sh
mise run serve        # http://localhost:8004, live reload for docs/ edits
mise run docs-build   # render into site/
```

## The demo walkthrough is generated

The [walkthrough](../guides/building-a-set.md) and several command pages include what `auto-dj demo` prints, and link
the preview it builds. Both docs tasks run `docs-demo` first:

```sh
auto-dj demo docs/demo --tracks build/demo/tracks --no-open
```

It renders the ten demo tracks into `build/demo/tracks/` (never into the site) and writes into `docs/demo/`:

| File                          | What                                                  |
| ----------------------------- | ----------------------------------------------------- |
| `docs/demo/tracks.md`         | The track table (title, key, BPM, length, file)       |
| `docs/demo/features.txt`      | What `features` prints                                |
| `docs/demo/plan.txt`          | What `plan` prints                                    |
| `docs/demo/plan.md`           | The planned cues, one row per track                   |
| `docs/demo/set-check.txt`     | `set` on the playlist as filed                        |
| `docs/demo/set-suggested.txt` | `set --order suggested`                               |
| `docs/demo/preview/`          | The set-list page, `set.mp3` and the transition clips |

None of it is committed (`docs/demo/` and `build/` are git-ignored). The task is skipped while the Go sources are
unchanged, and the output is identical on every run, so the site always shows exactly what the code does. Pages include
the fragments with `--8<-- "demo/<file>"`; `pymdownx.snippets` runs with `check_paths`, so a page that includes a
fragment that doesn't exist fails the build.

## Decision records

`docs/decisions/` holds the ADRs in [MADR](https://adr.github.io/madr/) format, published under **Decisions**. Add a new
one with the next four-digit number, list it in `docs/decisions/index.md` and in the `nav` of `zensical.toml`.

## Linting

Prose under `docs/` follows the house prettier and markdownlint rules (`mise run lint`). `docs/.markdownlint.yaml`
relaxes the fenced-code rule, because admonition and tab bodies need indentation.

## Publishing

`.github/workflows/docs.yaml` builds the site (Go and ffmpeg from the mise pins, then `mise run docs-build`) and deploys
it to GitHub Pages on every push to `main` that touches the docs or the code. Pages must be set to **Settings → Pages →
Source → GitHub Actions**.
