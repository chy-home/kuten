# AGENTS.md

## Project Overview

This is a small browser app for extracting English vocabulary and 2-3 word phrases from pasted text or uploaded `.txt` files. It is aimed at IT delivery work, including Google/Microsoft advertising delivery, batch processing, cloud storage, and data pipeline scenarios.

The app is intentionally simple:

- `index.html`: UI structure
- `styles.css`: UI styling
- `app.js`: browser logic, extraction, dictionary lookup, online lookup/cache behavior
- `server.js`: static file server plus lookup-cache write API
- `data/*.json`: offline IPA, word meaning, phrase meaning, and online lookup cache
- `scripts/test-cache-flow.js`: integration-style test for cache, online switch, and trimming behavior
- `scripts/enrich-delivery-ad-dictionaries.js`: repeatable dictionary enrichment script

## Run

Use the built-in Node server. Do not rely on `file://`, because the app loads JSON dictionaries and writes cache through an API.

```bash
node server.js
```

Open:

```text
http://localhost:8080
```

Use a different port with:

```bash
PORT=9000 node server.js
```

## Test

Run:

```bash
node scripts/test-cache-flow.js
```

The test starts `server.js`, writes a temporary cache payload, loads `app.js` in a browser-like VM context, and verifies:

- default offline mode does not use online cache or external fetch
- enabling "use online model" allows cache reuse and online translation
- disabling the switch prevents online translation
- known-word filtering and trimming work

The test restores `data/catch.json` after it runs.

## Offline Dictionary Rules

The offline dictionaries are plain JSON objects:

- `data/ipa-dictionary.json`: `"word": "/ipa/"`
- `data/meaning-dictionary.json`: `"word": "Chinese meaning"` or context-aware arrays
- `data/phrase-meaning-dictionary.json`: `"2-3 word phrase": "Chinese meaning"`

Keep JSON valid and UTF-8 encoded. Prefer lowercase keys because extraction normalizes input to lowercase.

Phrase extraction currently generates only 2-word and 3-word phrases, so adding 4+ word phrase entries will not help unless extraction logic is changed.

For IT delivery and ads-domain updates, prefer adding entries through `scripts/enrich-delivery-ad-dictionaries.js`, then run it:

```bash
node scripts/enrich-delivery-ad-dictionaries.js
```

That script merges entries and sorts keys. After changing dictionaries, run the cache-flow test.

## Online Model Behavior

The "use online model" checkbox is optional and defaults to off unless the user's browser has a saved preference.

When it is off:

- extraction uses only offline dictionaries and local rules
- online lookup cache is not applied to extraction results
- online provider, endpoint, API key, and translate button are disabled
- no external translation request should be made

When it is on:

- extraction may reuse cached online lookup results from `data/catch.json`
- clicking "translate" can call the selected online provider
- successful online results can be written back through `POST /api/lookup-cache`

Do not make online lookup mandatory for basic extraction.

## Known Words / Trimming

The "known words" textarea accepts words separated by spaces, commas, or newlines. The app normalizes and lemmatizes these words.

Known words are used in two places:

- during extraction, matching words are excluded from the word list
- the "trim known words" button removes matching words from the current result

For phrases, the current behavior removes a phrase only when all words in the phrase are known. This preserves useful mixed phrases that contain at least one unknown word.

## Editing Guidance

- Keep the app dependency-free unless there is a strong reason.
- Use the existing JSON dictionary format instead of introducing a database.
- Keep UI labels in Chinese.
- Keep extraction behavior deterministic when online mode is off.
- Do not remove user cache data from `data/catch.json` except in tests that restore it.
- If server binding fails in the sandbox with `EPERM`, rerun tests with the required approval rather than changing the server.
