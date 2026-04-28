# AGENTS.md

## Project Overview

This is a small browser app for extracting English vocabulary and 2-3 word phrases from pasted text or uploaded `.txt` files. It is aimed at IT delivery work, including Google/Microsoft advertising delivery, batch processing, cloud storage, and data pipeline scenarios.

The app is intentionally simple:

- `index.html`: UI structure
- `styles.css`: UI styling
- `app.js`: browser logic, extraction, layered dictionary lookup, online lookup/cache behavior
- `server.js`: static file server plus lookup-cache write API
- `ignore.txt`: manually editable ignored-words file, auto-loaded on refresh
- `data/*.json`: layered offline IPA/meaning/phrase dictionaries plus online lookup cache
- `scripts/test-cache-flow.js`: integration-style test for cache, online switch, and trimming behavior
- `scripts/enrich-delivery-ad-dictionaries.js`: repeatable dictionary enrichment script
- `scripts/import-ecdict.js`: import `ECDICT` CSV into the base offline dictionary layer
- `scripts/import-cmudict.js`: import `CMUdict` or IPA-tab pronunciation data into the base offline IPA layer
- `scripts/import-phrase-dictionary.js`: import 2-3 word offline phrase meanings into the base phrase layer

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
- if an online translation returns the original English term unchanged, it is treated as "not found"
- `ignore.txt` is auto-loaded into the ignored words field
- known-word filtering and trimming work

The test restores `data/catch.json` and `ignore.txt` after it runs.

## Offline Dictionary Rules

The offline dictionaries are plain JSON objects:

- `data/base-ipa-dictionary.json`: 基础开源/通用 IPA 层
- `data/base-meaning-dictionary.json`: 基础开源/通用释义层
- `data/base-phrase-meaning-dictionary.json`: 基础通用短语层
- `data/base-root-memory-dictionary.json`: 基础通用词根记忆层
- `data/ipa-dictionary.json`: `"word": "/ipa/"`
- `data/meaning-dictionary.json`: `"word": "Chinese meaning"` or context-aware arrays
- `data/phrase-meaning-dictionary.json`: `"2-3 word phrase": "Chinese meaning"`
- `data/root-memory-dictionary.json`: `"word": "词根记忆提示"`

Keep JSON valid and UTF-8 encoded. Prefer lowercase keys because extraction normalizes input to lowercase.

Dictionary loading is layered. Base dictionaries load first, then project/domain dictionaries override them. This is intended for integrating larger open-source offline dictionaries while preserving project-specific IT ads terminology.

Current repository state:

- `ECDICT` has already been imported into the base layer
- `data/base-meaning-dictionary.json` is large (about 21 MB, ~399k entries)
- `data/base-ipa-dictionary.json` is large (about 6.5 MB, ~199k entries)
- base dictionaries are intended as generated assets, not hand-maintained content

Because the base dictionaries are large generated files, prefer updating them through import scripts rather than manual editing.

Phrase extraction currently generates only 2-word and 3-word phrases, so adding 4+ word phrase entries will not help unless extraction logic is changed.

The phrase extraction checkbox is currently off by default. Phrase extraction only runs when the user explicitly enables it.

For IT delivery and ads-domain updates, prefer adding entries through `scripts/enrich-delivery-ad-dictionaries.js`, then run it:

```bash
node scripts/enrich-delivery-ad-dictionaries.js
```

This script updates the project/domain override layer:

- `data/ipa-dictionary.json`
- `data/meaning-dictionary.json`
- `data/phrase-meaning-dictionary.json`

For larger open-source offline dictionaries, prefer importing them into the base layer. Supported / planned sources:

- `ECDICT` for English-Chinese meanings
- `CMUdict` for English pronunciation

The repo includes:

```bash
node scripts/import-ecdict.js /path/to/ecdict.csv
node scripts/import-cmudict.js /path/to/cmudict.dict
node scripts/import-phrase-dictionary.js /path/to/phrases.tsv
```

`import-ecdict.js` rewrites:

- `data/base-ipa-dictionary.json`
- `data/base-meaning-dictionary.json`

`import-cmudict.js` writes into the IPA base layer and by default merges with the existing base dictionary:

- default target: `data/base-ipa-dictionary.json`
- supported input formats:
  - original `CMUdict` ARPABET lines such as `HELLO  HH AH0 L OW1`
  - `word<TAB>/ipa/` or `word<TAB>ipa` fallback files

Examples:

```bash
node scripts/import-cmudict.js /path/to/cmudict.dict
node scripts/import-cmudict.js /path/to/pronunciations.txt --format ipa-tab --prefer cmu
```

`import-phrase-dictionary.js` writes into the base phrase layer and only keeps 2-word or 3-word lowercase-normalizable phrases:

- default target: `data/base-phrase-meaning-dictionary.json`
- supported input formats:
  - `phrase<TAB>Chinese meaning`
  - JSONL such as `{"phrase":"data pipeline","meaning":"数据管道"}`

Examples:

```bash
node scripts/import-phrase-dictionary.js /path/to/phrases.tsv
node scripts/import-phrase-dictionary.js /path/to/phrases.jsonl --format jsonl --prefer input
```

It should be treated as a generator step for the base layer, not as a merge into the domain override layer.

After changing dictionaries, run the cache-flow test.

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
- if an online provider returns the original English word or phrase unchanged, treat that as "not found", keep `待补充释义`, and do not count it as a usable cached translation

Do not make online lookup mandatory for basic extraction.

## Ignored Words / Trimming

The "ignored words" textarea accepts words separated by spaces, commas, or newlines. The app normalizes and lemmatizes these words.

Ignored words also support a file-backed workflow:

- `ignore.txt` can be edited manually in the project root
- refreshing the page auto-loads `ignore.txt`
- the file-backed value is intended to seed/replace the textarea on refresh
- server responses for `ignore.txt` use no-store caching so browser refresh picks up edits

Ignored words are used in two places:

- during extraction, matching words are excluded from the word list
- the "trim ignored words" button removes matching words from the current result

For phrases, the current behavior removes a phrase only when all words in the phrase are ignored. This preserves useful mixed phrases that contain at least one still-useful word.

Hyphenated terms such as `real-time`, `cross-platform`, and `third-party` should continue to resolve through phrase/base dictionary fallback rather than being treated as unsupported tokens.

## Result Presentation

The result area is rendered as a table for direct Excel-friendly copying:

- visible output columns: 序号 / 类型 / 内容 / 次数 / 音标 / 释义 / 词根记忆
- "复制结果" copies tab-separated values
- "下载 TSV" exports tab-separated values
- items with `待补充释义` are sorted to the top of the table
- items with `待补充释义` are highlighted with a light red row background for quick scanning
- the root-memory column is populated only for single words
- root-memory lookup prefers exact offline dictionary hits, then falls back to lightweight prefix/suffix heuristics

## Editing Guidance

- Keep the app dependency-free unless there is a strong reason.
- Use the existing JSON dictionary format instead of introducing a database.
- Do not hand-edit large generated base dictionaries unless there is no better option; prefer changing import scripts or domain override dictionaries.
- Keep UI labels in Chinese.
- Keep extraction behavior deterministic when online mode is off.
- Do not remove user cache data from `data/catch.json` except in tests that restore it.
- Do not remove or overwrite user-maintained `ignore.txt` content except in tests that restore it.
- If dictionary output quality needs improvement, prefer cleaning or filtering import scripts instead of manually patching thousands of generated base entries.
- Expect larger offline dictionary files to increase browser startup/load cost; avoid unnecessary duplicate loads.
- If server binding fails in the sandbox with `EPERM`, rerun tests with the required approval rather than changing the server.
