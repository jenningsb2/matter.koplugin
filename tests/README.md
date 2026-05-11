# Tests

Unit + fixture tests for the pure-Lua modules in this plugin (mainly `matter_markdown.lua`). Runs in any standalone Lua interpreter — no KOReader required.

## Running

```bash
lua tests/run_tests.lua
```

Exit code is `0` on success, `1` if anything fails.

## Fixtures

- **`fixtures/sample_response.json`** — A synthesized Matter API response shaped exactly like a real one. The article body is original, made-up text crafted to exercise every code path in the converter: headings at multiple levels, backslash escapes (`\.`, `\-`, `\(` …), links, images, footnotes, lists, blockquotes, fenced code. Safe to check in, no copyright concerns.

- **`fixtures/private_response.json`** — Optional. If you have a real Matter API response you'd like to test against (something you fetched from your own account via `GET /items/{id}?include=markdown`), save it here. This file is `.gitignore`d so it never ends up in commits. The test runner picks it up automatically and reports stats.

  This is useful for catching regressions when Matter changes its extractor formatting — drop in a fresh response after upgrading and verify the TOC, escape handling, and conversion still produce the expected output.

## What it covers

- **Unit checks** on the converter: headings, emphasis, code, links, images, autolinks, lists, blockquotes, hr, fenced code, footnotes, backslash escapes, HTML escaping.
- **TOC extraction** using the same pattern `matter_epub.lua` uses to scan `<hN>` tags in generated HTML.
- **End-to-end** conversion of a fixture's `markdown` field through to HTML + TOC, with stats printed for inspection.

## What it doesn't cover

- The full EPUB packager (`matter_epub.lua`) — depends on KOReader-only modules (`ffi/archiver`, `libs/libkoreader-cre`, etc.) and can only be tested by running the plugin inside KOReader.
- The Matter API client (`main.lua`) — depends on KOReader's HTTPS, settings, and UI stack.
