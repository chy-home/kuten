const sourceText = document.getElementById("sourceText");
const resultText = document.getElementById("resultText");
const resultTable = document.getElementById("resultTable");
const resultTableBody = document.getElementById("resultTableBody");
const resultEmptyState = document.getElementById("resultEmptyState");
const summary = document.getElementById("summary");
const txtFile = document.getElementById("txtFile");
const extractButton = document.getElementById("extractButton");
const translateButton = document.getElementById("translateButton");
const clearButton = document.getElementById("clearButton");
const copyButton = document.getElementById("copyButton");
const downloadButton = document.getElementById("downloadButton");
const minWordLength = document.getElementById("minWordLength");
const minPhraseFrequency = document.getElementById("minPhraseFrequency");
const excludeStopwords = document.getElementById("excludeStopwords");
const includePhrases = document.getElementById("includePhrases");
const useOnlineModel = document.getElementById("useOnlineModel");
const onlineProvider = document.getElementById("onlineProvider");
const translationEndpoint = document.getElementById("translationEndpoint");
const translationApiKey = document.getElementById("translationApiKey");
const knownWords = document.getElementById("knownWords");
const trimKnownWordsButton = document.getElementById("trimKnownWordsButton");
const DEFAULT_RESULT_EMPTY_TEXT = "点击“分词”后，这里会生成可直接复制到 Excel 的表格结果。";

const stopwords = new Set([
  "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by", "for", "from",
  "had", "has", "have", "he", "her", "here", "hers", "him", "his", "i", "if", "in", "into",
  "is", "it", "its", "me", "my", "of", "on", "or", "our", "ours", "she", "that", "the",
  "their", "theirs", "them", "there", "they", "this", "those", "to", "too", "us", "was",
  "we", "were", "what", "when", "where", "which", "who", "will", "with", "you", "your", "yours"
]);

const ROOT_PREFIX_RULES = [
  { prefix: "re", meaning: "再次/回" },
  { prefix: "un", meaning: "否定/反向" },
  { prefix: "de", meaning: "去除/向下" },
  { prefix: "dis", meaning: "分离/否定" },
  { prefix: "pre", meaning: "预先" },
  { prefix: "post", meaning: "之后" },
  { prefix: "trans", meaning: "跨越/转移" },
  { prefix: "inter", meaning: "在...之间" },
  { prefix: "auto", meaning: "自动" },
  { prefix: "multi", meaning: "多" },
  { prefix: "sub", meaning: "下/子" },
  { prefix: "super", meaning: "超/上" },
  { prefix: "over", meaning: "过度/在上" }
];

const ROOT_SUFFIX_RULES = [
  { suffix: "ation", meaning: "行为/结果" },
  { suffix: "ition", meaning: "行为/结果" },
  { suffix: "tion", meaning: "行为/结果" },
  { suffix: "sion", meaning: "行为/状态" },
  { suffix: "ment", meaning: "结果/状态" },
  { suffix: "ness", meaning: "性质/状态" },
  { suffix: "able", meaning: "可...的" },
  { suffix: "ible", meaning: "可...的" },
  { suffix: "ality", meaning: "性质" },
  { suffix: "ivity", meaning: "性质/活动" },
  { suffix: "ization", meaning: "化/过程" },
  { suffix: "ising", meaning: "过程" },
  { suffix: "ing", meaning: "过程/进行中" },
  { suffix: "er", meaning: "执行者/工具" },
  { suffix: "or", meaning: "执行者/工具" },
  { suffix: "ist", meaning: "从事者" },
  { suffix: "ity", meaning: "性质" },
  { suffix: "ive", meaning: "具有...性质" }
];

const ONLINE_LOOKUP_DELAY_MIN_MS = 800;
const ONLINE_LOOKUP_DELAY_MAX_MS = 2200;
const USE_ONLINE_MODEL_STORAGE_KEY = "en-split-use-online-model";
const KNOWN_WORDS_STORAGE_KEY = "en-split-known-words";
const KNOWN_WORDS_FILE_PATH = "./ignore.txt";

let ipaDictionary = {}

let meaningDictionary = {}

let phraseMeaningDictionary = {}

let rootMemoryDictionary = {}

const onlineMeaningCache = new Map();
let dictionariesReady = false;
let dictionaryLoadPromise = null;
let lookupCacheReady = false;
let lookupCacheLoadPromise = null;
let knownWordsReady = false;
let knownWordsLoadPromise = null;
let currentExtraction = null;

lookupCacheLoadPromise = loadLookupCacheFromFile();
restoreUserPreferences();
knownWordsLoadPromise = loadKnownWordsFromFile();
syncOnlineControls();
useOnlineModel.addEventListener("change", () => {
  persistUserPreferences();
  syncOnlineControls();
});
knownWords.addEventListener("input", persistUserPreferences);
onlineProvider.addEventListener("change", syncOnlineProviderFields);
syncOnlineProviderFields();

if (typeof window !== "undefined") {
  window.__appStartupReady = Promise.allSettled([
    lookupCacheLoadPromise,
    knownWordsLoadPromise
  ]);
}

txtFile.addEventListener("change", async (event) => {
  const [file] = event.target.files;
  if (!file) {
    return;
  }

  const text = await file.text();
  sourceText.value = text;
});

extractButton.addEventListener("click", async () => {
  const text = sourceText.value.trim();
  if (!text) {
    summary.textContent = "请输入文本或先上传 TXT 文件。";
    resetResultView();
    currentExtraction = null;
    return;
  }

  try {
    await ensureKnownWordsLoaded();
    summary.textContent = "正在加载离线词典...";
    await ensureLookupCacheLoaded();
    await ensureDictionariesLoaded();
  } catch (error) {
    summary.textContent = error.message || "离线词典加载失败。";
    resetResultView();
    return;
  }

  const extraction = extractVocabulary(text, {
    minLength: Number(minWordLength.value) || 3,
    minPhraseHits: Number(minPhraseFrequency.value) || 2,
    excludeCommonWords: excludeStopwords.checked,
    includePhraseExtraction: includePhrases.checked,
    knownWords: getKnownWordSet()
  });

  if (useOnlineModel.checked) {
    const localCacheHits = applyLookupCacheToExtraction(extraction, {
      provider: onlineProvider.value,
      translationEndpoint: translationEndpoint.value.trim()
    });

    if (localCacheHits > 0) {
      extraction.cacheStats = {
        hits: localCacheHits,
        saved: 0,
        writeFailed: false
      };
    }
  }

  currentExtraction = extraction;
  updateResultView(extraction);
  summary.textContent = buildSummaryText(extraction);
});

translateButton.addEventListener("click", async () => {
  if (!useOnlineModel.checked) {
    summary.textContent = "已关闭在线模型，不会请求在线翻译。";
    return;
  }

  if (!currentExtraction) {
    summary.textContent = "请先点击“分词”生成结果。";
    return;
  }

  try {
    summary.textContent = "正在补充在线释义...";
    await ensureLookupCacheLoaded();
    const cacheStats = await enrichMeaningsOnline(currentExtraction, {
      provider: onlineProvider.value,
      translationEndpoint: translationEndpoint.value.trim(),
      apiKey: translationApiKey.value.trim()
    });
    currentExtraction.cacheStats = cacheStats;
    updateResultView(currentExtraction);
    summary.textContent = buildSummaryText(currentExtraction);
  } catch (error) {
    summary.textContent = error.message || "在线翻译失败。";
  }
});

trimKnownWordsButton.addEventListener("click", async () => {
  if (!currentExtraction) {
    summary.textContent = "请先点击“分词”生成结果。";
    return;
  }

  await ensureKnownWordsLoaded();
  const knownWordSet = getKnownWordSet();
  if (knownWordSet.size === 0) {
    summary.textContent = "请先填写已忽略单词。";
    return;
  }

  const trimStats = trimKnownWordsFromExtraction(currentExtraction, knownWordSet);
  updateResultView(currentExtraction);
  summary.textContent = `${buildSummaryText(currentExtraction)} 已裁剪 ${trimStats.words} 个单词，${trimStats.phrases} 个短语。`;
});

clearButton.addEventListener("click", () => {
  sourceText.value = "";
  resetResultView();
  txtFile.value = "";
  currentExtraction = null;
  summary.textContent = "已清空";
});

copyButton.addEventListener("click", async () => {
  if (!resultText.value.trim()) {
    summary.textContent = "当前没有可复制的结果。";
    return;
  }

  try {
    if (!navigator.clipboard || !window.isSecureContext) {
      throw new Error("clipboard-unavailable");
    }

    await navigator.clipboard.writeText(resultText.value);
    summary.textContent = "结果已复制到剪贴板。";
  } catch (error) {
    resultText.focus();
    resultText.select();
    summary.textContent = "浏览器限制了自动复制，已帮你选中文本，可直接 Ctrl/Cmd+C。";
  }
});

downloadButton.addEventListener("click", () => {
  if (!resultText.value.trim()) {
    summary.textContent = "当前没有可下载的结果。";
    return;
  }

  const blob = new Blob([resultText.value], { type: "text/tab-separated-values;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = "extracted-vocabulary.tsv";
  anchor.click();
  URL.revokeObjectURL(url);
  summary.textContent = "已下载 TSV 结果。";
});

function extractVocabulary(text, options) {
  const normalizedText = text.replace(/\r\n/g, "\n");
  const tokens = normalizeTokens(normalizedText);
  const knownWordSet = options.knownWords || new Set();
  const wordCounts = new Map();
  const wordContexts = new Map();

  for (const [index, token] of tokens.entries()) {
    if (token.length < options.minLength) {
      continue;
    }

    if (options.excludeCommonWords && stopwords.has(token)) {
      continue;
    }

    if (isKnownWord(token, knownWordSet)) {
      continue;
    }

    wordCounts.set(token, (wordCounts.get(token) || 0) + 1);
    pushContext(wordContexts, token, collectContext(tokens, index));
  }

  const words = [...wordCounts.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([word, count]) => ({
      word,
      count,
      ipa: getIpa(word),
      meaning: getMeaning(word, wordContexts.get(word) || [], "word"),
      memory: getRootMemory(word)
    }));

  const phrases = options.includePhraseExtraction
    ? extractPhrases(normalizedText, options.minPhraseHits, knownWordSet)
    : [];

  return { words, phrases };
}

function normalizeTokens(text) {
  const matches = text.toLowerCase().match(/[a-z]+(?:['-][a-z]+)*/g);
  if (!matches) {
    return [];
  }

  return matches
    .map((item) => item.replace(/^['-]+|['-]+$/g, ""))
    .filter(Boolean);
}

async function ensureDictionariesLoaded() {
  if (dictionariesReady) {
    return;
  }

  if (!dictionaryLoadPromise) {
    dictionaryLoadPromise = loadDictionaries();
  }

  await dictionaryLoadPromise;
  dictionariesReady = true;
}

async function ensureKnownWordsLoaded() {
  if (knownWordsReady) {
    return;
  }

  if (!knownWordsLoadPromise) {
    knownWordsLoadPromise = loadKnownWordsFromFile();
  }

  await knownWordsLoadPromise;
  knownWordsReady = true;
}

async function loadDictionaries() {
  try {
    const manifestResponse = await fetch("./data/dictionary-manifest.json");
    if (!manifestResponse.ok) {
      throw new Error("词典清单加载失败。");
    }

    const manifest = await manifestResponse.json();
    const [ipaData, meaningData, phraseData, rootMemoryData] = await Promise.all([
      fetchMergedDictionary(manifest.dictionaries.ipaDictionary),
      fetchMergedDictionary(manifest.dictionaries.meaningDictionary),
      fetchMergedDictionary(manifest.dictionaries.phraseMeaningDictionary),
      fetchMergedDictionary(manifest.dictionaries.rootMemoryDictionary)
    ]);

    ipaDictionary = ipaData;
    meaningDictionary = meaningData;
    phraseMeaningDictionary = phraseData;
    rootMemoryDictionary = rootMemoryData;
  } catch (error) {
    dictionaryLoadPromise = null;
    if (location.protocol === "file:") {
      throw new Error("离线词典和查询缓存采用独立 JSON 文件，请执行 node server.js 后访问 http://localhost:8080。");
    }
    throw error;
  }
}

async function fetchJson(path) {
  const response = await fetch(path);
  if (!response.ok) {
    throw new Error(`词典文件加载失败: ${path}`);
  }

  return response.json();
}

async function fetchMergedDictionary(paths) {
  const pathList = Array.isArray(paths) ? paths : [paths];
  const dictionaries = await Promise.all(pathList.map(fetchJson));
  return dictionaries.reduce((merged, current) => ({ ...merged, ...current }), {});
}

async function loadKnownWordsFromFile() {
  try {
    const response = await fetch(KNOWN_WORDS_FILE_PATH, {
      cache: "no-store"
    });

    if (!response.ok) {
      if (response.status === 404) {
        knownWordsReady = true;
        return;
      }
      throw new Error("ignore.txt 加载失败。");
    }

    applyKnownWordsText(await response.text());
    knownWordsReady = true;
  } catch (error) {
    knownWordsReady = true;
  }
}

function applyKnownWordsText(text) {
  knownWords.value = typeof text === "string"
    ? text.replace(/\r\n/g, "\n")
    : "";
  persistUserPreferences();
}

function extractPhrases(text, minHits, knownWordSet = new Set()) {
  const phraseCounts = new Map();
  const phraseContexts = new Map();
  const segments = text
    .toLowerCase()
    .split(/[\n.?!;:]+/)
    .map((part) => normalizeTokens(part))
    .filter((part) => part.length > 1);

  for (const segment of segments) {
    for (let size = 2; size <= 3; size += 1) {
      for (let index = 0; index <= segment.length - size; index += 1) {
        const slice = segment.slice(index, index + size);
        if (!isUsefulPhrase(slice)) {
          continue;
        }

        if (slice.every((word) => isKnownWord(word, knownWordSet))) {
          continue;
        }

        const phrase = slice.join(" ");
        phraseCounts.set(phrase, (phraseCounts.get(phrase) || 0) + 1);
        pushContext(phraseContexts, phrase, collectContext(segment, index, size));
      }
    }
  }

  return [...phraseCounts.entries()]
    .filter(([, count]) => count >= minHits)
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([phrase, count]) => ({
      phrase,
      count,
      ipa: phrase.split(" ").map(getIpa).join(" "),
      meaning: getMeaning(phrase, phraseContexts.get(phrase) || [], "phrase")
    }));
}

function isUsefulPhrase(words) {
  if (words.some((word) => word.length < 2)) {
    return false;
  }

  if (words.every((word) => stopwords.has(word))) {
    return false;
  }

  if (stopwords.has(words[0]) || stopwords.has(words[words.length - 1])) {
    return false;
  }

  if (words.some((word, index) => index > 0 && index < words.length - 1 && isConnectorWord(word))) {
    return false;
  }

  return words.some((word) => word.length >= 4);
}

function isConnectorWord(word) {
  return word === "and" || word === "or" || word === "with" || word === "for" || word === "to";
}

function getKnownWordSet() {
  return new Set(normalizeTokens(knownWords.value).map((word) => lemmatizeWord(word)));
}

function isKnownWord(word, knownWordSet) {
  if (!knownWordSet || knownWordSet.size === 0) {
    return false;
  }

  const normalizedWord = word.toLowerCase();
  return knownWordSet.has(normalizedWord) || knownWordSet.has(lemmatizeWord(normalizedWord));
}

function trimKnownWordsFromExtraction(extraction, knownWordSet) {
  const beforeWordCount = extraction.words.length;
  const beforePhraseCount = extraction.phrases.length;

  extraction.words = extraction.words.filter((item) => !isKnownWord(item.word, knownWordSet));
  extraction.phrases = extraction.phrases.filter((item) => {
    const words = item.phrase.split(" ");
    return !words.every((word) => isKnownWord(word, knownWordSet));
  });

  return {
    words: beforeWordCount - extraction.words.length,
    phrases: beforePhraseCount - extraction.phrases.length
  };
}

function updateResultView(extraction) {
  const rows = buildResultRows(extraction);
  resultText.value = buildTsvReport(rows);
  renderResultTable(rows);
}

function resetResultView() {
  resultText.value = "";
  if (resultTableBody) {
    resultTableBody.innerHTML = "";
  }
  if (resultTable) {
    resultTable.hidden = true;
  }
  if (resultEmptyState) {
    resultEmptyState.textContent = DEFAULT_RESULT_EMPTY_TEXT;
    resultEmptyState.hidden = false;
  }
}

function buildResultRows(extraction) {
  const wordRows = extraction.words.map((item) => ({
    type: "单词",
    term: item.word,
    count: item.count,
    ipa: item.ipa,
    meaning: item.meaning,
    memory: item.memory
  }));

  const phraseRows = extraction.phrases.map((item) => ({
    type: "短语",
    term: item.phrase,
    count: item.count,
    ipa: item.ipa,
    meaning: item.meaning,
    memory: ""
  }));

  return [...wordRows, ...phraseRows]
    .sort((left, right) => compareResultRows(left, right))
    .map((row, index) => ({
    index: index + 1,
    ...row
    }));
}

function compareResultRows(left, right) {
  const leftMissing = left.meaning === "待补充释义" ? 0 : 1;
  const rightMissing = right.meaning === "待补充释义" ? 0 : 1;

  if (leftMissing !== rightMissing) {
    return leftMissing - rightMissing;
  }

  if (right.count !== left.count) {
    return right.count - left.count;
  }

  if (left.type !== right.type) {
    return left.type.localeCompare(right.type, "zh-CN");
  }

  return left.term.localeCompare(right.term);
}

function buildTsvReport(rows) {
  if (rows.length === 0) {
    return "";
  }

  const header = ["序号", "类型", "内容", "次数", "音标", "释义", "词根记忆"];
  const lines = [header.join("\t")];

  rows.forEach((row) => {
    lines.push([
      row.index,
      sanitizeTsvCell(row.type),
      sanitizeTsvCell(row.term),
      row.count,
      sanitizeTsvCell(row.ipa),
      sanitizeTsvCell(row.meaning),
      sanitizeTsvCell(row.memory)
    ].join("\t"));
  });

  return lines.join("\n");
}

function sanitizeTsvCell(value) {
  return String(value ?? "").replace(/\t/g, " ").replace(/\r?\n/g, " ");
}

function renderResultTable(rows) {
  if (!resultTableBody || !resultTable || !resultEmptyState) {
    return;
  }

  resultTableBody.innerHTML = "";

  if (rows.length === 0) {
    resultTable.hidden = true;
    resultEmptyState.hidden = false;
    resultEmptyState.textContent = "当前没有提取到可展示的数据。";
    return;
  }

  rows.forEach((row) => {
    const tr = document.createElement("tr");
    if (row.meaning === "待补充释义") {
      tr.className = "result-row-missing";
    }
    [row.index, row.type, row.term, row.count, row.ipa, row.meaning, row.memory].forEach((value) => {
      const td = document.createElement("td");
      td.textContent = value;
      tr.appendChild(td);
    });
    resultTableBody.appendChild(tr);
  });

  resultTable.hidden = false;
  resultEmptyState.hidden = true;
}

function buildSummaryText(extraction) {
  const parts = [
    `已提取 ${extraction.words.length} 个单词`,
    `${extraction.phrases.length} 个短语`
  ];

  if (extraction.cacheStats) {
    parts.push(`复用缓存 ${extraction.cacheStats.hits} 条`);
    parts.push(`新增缓存 ${extraction.cacheStats.saved} 条`);
    if (extraction.cacheStats.writeFailed) {
      parts.push("文件缓存写入失败，请使用 node server.js 启动页面");
    }
  }

  return `${parts.join("，")}。`;
}

function getIpa(word) {
  if (ipaDictionary[word]) {
    return ipaDictionary[word];
  }

  if (word.includes("-")) {
    const compoundIpa = getCompoundIpa(word);
    if (compoundIpa) {
      return compoundIpa;
    }
  }

  return `/${guessIpa(word)}/`;
}

function getMeaning(term, contexts, type) {
  const normalizedTerm = term.toLowerCase();
  if (type === "phrase") {
    const directPhraseMeaning = phraseMeaningDictionary[normalizedTerm];
    if (directPhraseMeaning) {
      return directPhraseMeaning;
    }

    const normalizedPhrase = lemmatizePhrase(normalizedTerm);
    if (normalizedPhrase !== normalizedTerm && phraseMeaningDictionary[normalizedPhrase]) {
      return phraseMeaningDictionary[normalizedPhrase];
    }

    return normalizedTerm
      .split(" ")
      .map((word) => getMeaning(word, contexts, "word"))
      .join(" / ");
  }

  const lemma = lemmatizeWord(normalizedTerm);
  const entry = meaningDictionary[normalizedTerm] || meaningDictionary[lemma];
  if (typeof entry === "string") {
    return entry;
  }

  if (Array.isArray(entry)) {
    const contextWords = new Set(
      contexts.flatMap((context) => normalizeTokens(context))
    );

    let bestMeaning = entry[0].zh;
    let bestScore = -1;
    for (const candidate of entry) {
      const score = (candidate.tags || []).reduce(
        (total, tag) => total + (contextWords.has(tag) ? 1 : 0),
        0
      );
      if (score > bestScore) {
        bestScore = score;
        bestMeaning = candidate.zh;
      }
    }

    return bestMeaning;
  }

  if (normalizedTerm.includes("-")) {
    const compoundMeaning = getCompoundMeaning(normalizedTerm, contexts);
    if (compoundMeaning) {
      return compoundMeaning;
    }
  }

  return "待补充释义";
}

function getCompoundIpa(term) {
  const parts = term.split("-").filter(Boolean);
  if (parts.length < 2) {
    return "";
  }

  return `/${parts.map((part) => stripIpaSlashes(getIpa(part))).join("-")}/`;
}

function stripIpaSlashes(ipa) {
  return String(ipa).replace(/^\/+|\/+$/g, "");
}

function getCompoundMeaning(term, contexts) {
  const spacedTerm = term.replace(/-/g, " ");
  const directPhraseMeaning = phraseMeaningDictionary[spacedTerm];
  if (directPhraseMeaning) {
    return directPhraseMeaning;
  }

  const lemmatizedSpacedTerm = lemmatizePhrase(spacedTerm);
  if (lemmatizedSpacedTerm !== spacedTerm && phraseMeaningDictionary[lemmatizedSpacedTerm]) {
    return phraseMeaningDictionary[lemmatizedSpacedTerm];
  }

  const partMeanings = term
    .split("-")
    .map((part) => getMeaning(part, contexts, "word"))
    .filter((meaning) => meaning && meaning !== "待补充释义");

  if (partMeanings.length < 2 || partMeanings.length !== term.split("-").filter(Boolean).length) {
    return "";
  }

  return partMeanings.join("");
}

function getRootMemory(word) {
  const normalizedWord = String(word || "").toLowerCase();
  if (!normalizedWord) {
    return "";
  }

  if (rootMemoryDictionary[normalizedWord]) {
    return rootMemoryDictionary[normalizedWord];
  }

  const lemma = lemmatizeWord(normalizedWord);
  if (lemma !== normalizedWord && rootMemoryDictionary[lemma]) {
    return rootMemoryDictionary[lemma];
  }

  return guessRootMemory(normalizedWord);
}

function guessRootMemory(word) {
  const prefixMatch = ROOT_PREFIX_RULES.find((rule) => word.startsWith(rule.prefix) && word.length > rule.prefix.length + 3);
  const suffixMatch = ROOT_SUFFIX_RULES.find((rule) => word.endsWith(rule.suffix) && word.length > rule.suffix.length + 3);

  if (!prefixMatch && !suffixMatch) {
    return "";
  }

  let stem = word;
  const parts = [];

  if (prefixMatch) {
    stem = stem.slice(prefixMatch.prefix.length);
    parts.push(`${prefixMatch.prefix}(${prefixMatch.meaning})`);
  }

  if (suffixMatch) {
    stem = stem.slice(0, -suffixMatch.suffix.length);
  }

  stem = normalizeRootStem(stem);
  if (stem.length < 3) {
    return "";
  }

  parts.push(stem);

  if (suffixMatch) {
    parts.push(`${suffixMatch.suffix}(${suffixMatch.meaning})`);
  }

  if (parts.length < 2) {
    return "";
  }

  const gloss = [
    prefixMatch?.meaning,
    suffixMatch?.meaning
  ].filter(Boolean).join(" + ");

  return gloss
    ? `${parts.join(" + ")} => ${gloss}`
    : parts.join(" + ");
}

function normalizeRootStem(stem) {
  if (/([b-df-hj-np-tv-z])\1$/.test(stem)) {
    return stem.slice(0, -1);
  }

  if (stem.endsWith("i") && stem.length > 3) {
    return `${stem.slice(0, -1)}y`;
  }

  return stem;
}

function lemmatizePhrase(phrase) {
  return phrase
    .split(" ")
    .map((word) => lemmatizeWord(word))
    .join(" ");
}

function lemmatizeWord(word) {
  const irregulars = {
    analyses: "analysis",
    agendas: "agenda",
    APIs: "api",
    api: "api",
    apps: "app",
    businesses: "business",
    cases: "case",
    children: "child",
    clients: "client",
    companies: "company",
    decisions: "decision",
    deliverables: "deliverable",
    discussions: "discussion",
    documents: "document",
    files: "file",
    findings: "finding",
    issues: "issue",
    minutes: "minutes",
    meetings: "meeting",
    men: "man",
    messages: "message",
    metrics: "metric",
    people: "person",
    priorities: "priority",
    projects: "project",
    proposals: "proposal",
    questions: "question",
    requirements: "requirement",
    resources: "resource",
    results: "result",
    reviews: "review",
    risks: "risk",
    schedules: "schedule",
    stories: "story",
    summaries: "summary",
    systems: "system",
    tasks: "task",
    technologies: "technology",
    updates: "update",
    users: "user",
    values: "value",
    versions: "version",
    women: "woman"
  };

  if (irregulars[word]) {
    return irregulars[word];
  }

  const original = word;

  if (word.endsWith("ies") && word.length > 4) {
    return `${word.slice(0, -3)}y`;
  }

  if (word.endsWith("es") && word.length > 4) {
    const candidate = word.slice(0, -2);
    if (
      /(ches|shes|sses|xes|zes|oes)$/.test(word) ||
      meaningDictionary[candidate] ||
      ipaDictionary[candidate]
    ) {
      return candidate;
    }
  }

  if (word.endsWith("s") && word.length > 3 && !word.endsWith("ss")) {
    const singular = word.slice(0, -1);
    if (meaningDictionary[singular] || ipaDictionary[singular] || !/[us]$/.test(singular)) {
      return singular;
    }
  }

  if (word.endsWith("ied") && word.length > 4) {
    return `${word.slice(0, -3)}y`;
  }

  if (word.endsWith("ed") && word.length > 4) {
    const base = word.slice(0, -2);
    const withE = `${base}e`;
    if (meaningDictionary[base] || ipaDictionary[base]) {
      return base;
    }
    if (meaningDictionary[withE] || ipaDictionary[withE]) {
      return withE;
    }
    if (/([b-df-hj-np-tv-z])\1$/.test(base)) {
      return base.slice(0, -1);
    }
    return base;
  }

  if (word.endsWith("ing") && word.length > 5) {
    const base = word.slice(0, -3);
    const withE = `${base}e`;
    if (meaningDictionary[base] || ipaDictionary[base]) {
      return base;
    }
    if (meaningDictionary[withE] || ipaDictionary[withE]) {
      return withE;
    }
    if (/([b-df-hj-np-tv-z])\1$/.test(base)) {
      return base.slice(0, -1);
    }
    return base;
  }

  if (word.endsWith("er") && word.length > 4) {
    const base = word.slice(0, -2);
    if (meaningDictionary[base] || ipaDictionary[base]) {
      return base;
    }
  }

  return original;
}

async function enrichMeaningsOnline(extraction, options) {
  const stats = {
    hits: 0,
    saved: 0,
    writeFailed: false
  };
  const targets = [
    ...extraction.words
      .filter((item) => item.meaning === "待补充释义")
      .map((item) => attachType(item, "word")),
    ...extraction.phrases
      .filter((item) => item.meaning === "待补充释义")
      .map((item) => attachType(item, "phrase"))
  ].slice(0, 30);

  for (const item of targets) {
    const term = item.type === "word" ? item.word : item.phrase;
    const cacheKey = buildLookupCacheKey(options.provider, term, options.translationEndpoint);
    if (onlineMeaningCache.has(cacheKey)) {
      const cachedResult = onlineMeaningCache.get(cacheKey);
      if (hasUsableOnlineResult(cachedResult, term)) {
        applyOnlineResult(item, cachedResult);
        stats.hits += 1;
        continue;
      }

      if (cachedResult === null) {
        continue;
      }
    }

    try {
      await waitBeforeOnlineLookup();
      const onlineResult = await lookupMeaningOnline(term, item.type, options);
      onlineMeaningCache.set(cacheKey, onlineResult);
      if (onlineResult?.ipa || onlineResult?.meaning) {
        stats.saved += 1;
      }
      applyOnlineResult(item, onlineResult);
    } catch (error) {
      onlineMeaningCache.set(cacheKey, null);
    }
  }

  if (stats.saved > 0) {
    stats.writeFailed = !(await saveLookupCacheToFile());
  }

  return stats;
}

function applyOnlineResult(item, result) {
  if (!result) {
    return;
  }

  if (result.meaning && !isSameMeaningAsTerm(result.meaning, item.type === "word" ? item.word : item.phrase)) {
    item.meaning = result.meaning;
  }

  if (result.ipa && item.type === "word") {
    item.ipa = result.ipa;
  }
}

async function lookupMeaningOnline(term, type, options) {
  if (options.provider === "dictionaryapi") {
    if (type !== "word") {
      return null;
    }
    const dictionaryResult = await lookupViaDictionaryApi(term);
    return dictionaryResult
      ? {
          ipa: dictionaryResult.ipa || "",
          meaning: "待补充释义"
        }
      : null;
  }

  if (options.provider === "mymemory") {
    return lookupViaMyMemory(term, options);
  }

  if (options.provider === "google") {
    return lookupViaGoogle(term, options);
  }

  if (options.provider === "libretranslate") {
    return lookupViaTranslation(term, options);
  }

  const dictionaryResult = type === "word" ? await lookupViaDictionaryApi(term) : null;
  if (dictionaryResult?.definition) {
    const translatedDefinition = await translateText(dictionaryResult.definition, {
      ...options,
      provider: "mymemory"
    });
    return {
      ipa: dictionaryResult.ipa || "",
      meaning: translatedDefinition || "待补充释义"
    };
  }

  return lookupViaMyMemory(term);
}

async function lookupViaDictionaryApi(term) {
  const response = await fetch(
    `https://api.dictionaryapi.dev/api/v2/entries/en/${encodeURIComponent(lemmatizeWord(term.toLowerCase()))}`
  );
  if (!response.ok) {
    return null;
  }

  const payload = await response.json();
  const entry = payload[0];
  if (!entry) {
    return null;
  }

  const phonetic =
    entry.phonetic ||
    entry.phonetics?.find((item) => item.text)?.text ||
    "";
  const definition =
    entry.meanings?.[0]?.definitions?.[0]?.definition ||
    "";

  return {
    ipa: phonetic ? normalizeOnlineIpa(phonetic) : "",
    definition: definition || ""
  };
}

async function lookupViaTranslation(term, options) {
  const translated = await translateText(term, options);
  return translated
    ? buildOnlineMeaningResult(term, translated)
    : null;
}

async function translateText(text, options) {
  if (options.provider === "mymemory") {
    return translateViaMyMemory(text);
  }

  if (options.provider === "google") {
    return translateViaGoogle(text, options);
  }

  const endpoint = options.translationEndpoint || "https://libretranslate.com/translate";
  const payload = {
    q: text,
    source: "en",
    target: "zh",
    format: "text"
  };

  if (options.apiKey) {
    payload.api_key = options.apiKey;
  }

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    return "";
  }

  const data = await response.json();
  return typeof data.translatedText === "string" ? data.translatedText.trim() : "";
}

async function lookupViaMyMemory(term) {
  const translated = await translateViaMyMemory(term);
  return translated ? buildOnlineMeaningResult(term, translated) : null;
}

async function lookupViaGoogle(term, options) {
  const translated = await translateViaGoogle(term, options);
  return translated ? buildOnlineMeaningResult(term, translated) : null;
}

async function translateViaMyMemory(text) {
  const response = await fetch(
    `https://api.mymemory.translated.net/get?q=${encodeURIComponent(text)}&langpair=en|zh-CN`
  );

  if (!response.ok) {
    return "";
  }

  const data = await response.json();
  return typeof data.responseData?.translatedText === "string"
    ? data.responseData.translatedText.trim()
    : "";
}

async function translateViaGoogle(text, options) {
  if (!options.apiKey) {
    return "";
  }

  const endpoint =
    options.translationEndpoint ||
    "https://translation.googleapis.com/language/translate/v2";
  const response = await fetch(`${endpoint}?key=${encodeURIComponent(options.apiKey)}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      q: text,
      source: "en",
      target: "zh-CN",
      format: "text"
    })
  });

  if (!response.ok) {
    return "";
  }

  const data = await response.json();
  return typeof data.data?.translations?.[0]?.translatedText === "string"
    ? data.data.translations[0].translatedText.trim()
    : "";
}

function attachType(item, type) {
  item.type = type;
  return item;
}

function waitBeforeOnlineLookup() {
  const delay = ONLINE_LOOKUP_DELAY_MIN_MS +
    Math.floor(Math.random() * (ONLINE_LOOKUP_DELAY_MAX_MS - ONLINE_LOOKUP_DELAY_MIN_MS + 1));
  return new Promise((resolve) => {
    setTimeout(resolve, delay);
  });
}

function applyLookupCacheToExtraction(extraction, options) {
  let hits = 0;

  for (const item of extraction.words) {
    const result = findLookupCacheResult(item.word, "word", options);
    if (hasUsableOnlineResult(result, item.word)) {
      applyOnlineResult(attachType(item, "word"), result);
      hits += 1;
    }
  }

  for (const item of extraction.phrases) {
    const result = findLookupCacheResult(item.phrase, "phrase", options);
    if (hasUsableOnlineResult(result, item.phrase)) {
      applyOnlineResult(attachType(item, "phrase"), result);
      hits += 1;
    }
  }

  return hits;
}

function findLookupCacheResult(term, type, options) {
  const normalizedTerm = term.toLowerCase();
  const exactKey = buildLookupCacheKey(options.provider, normalizedTerm, options.translationEndpoint);
  if (onlineMeaningCache.has(exactKey)) {
    return onlineMeaningCache.get(exactKey);
  }

  if (type === "word") {
    const lemma = lemmatizeWord(normalizedTerm);
    if (lemma !== normalizedTerm) {
      const lemmaKey = buildLookupCacheKey(options.provider, lemma, options.translationEndpoint);
      if (onlineMeaningCache.has(lemmaKey)) {
        return onlineMeaningCache.get(lemmaKey);
      }
    }
  }

  for (const [key, value] of onlineMeaningCache) {
    const cacheEntry = parseLookupCacheKey(key);
    if (cacheEntry && cacheEntry.term === normalizedTerm) {
      return value;
    }
  }

  return null;
}

function buildLookupCacheKey(provider, term, translationEndpoint) {
  return `${provider}:${term}:${translationEndpoint}`;
}

function parseLookupCacheKey(key) {
  const firstSeparator = key.indexOf(":");
  const secondSeparator = key.indexOf(":", firstSeparator + 1);
  if (firstSeparator <= 0 || secondSeparator <= firstSeparator) {
    return null;
  }

  return {
    provider: key.slice(0, firstSeparator),
    term: key.slice(firstSeparator + 1, secondSeparator),
    translationEndpoint: key.slice(secondSeparator + 1)
  };
}

function buildLookupCachePayload() {
  const items = {};
  for (const [key, value] of onlineMeaningCache) {
    const cacheEntry = parseLookupCacheKey(key);
    const cacheTerm = cacheEntry?.term || "";

    if (!hasUsableOnlineResult(value, cacheTerm)) {
      continue;
    }

    items[key] = value;
  }

  return {
    version: 1,
    updatedAt: new Date().toISOString(),
    items
  };
}

async function ensureLookupCacheLoaded() {
  if (lookupCacheReady) {
    return;
  }

  if (!lookupCacheLoadPromise) {
    lookupCacheLoadPromise = loadLookupCacheFromFile();
  }

  await lookupCacheLoadPromise;
  lookupCacheReady = true;
}

async function loadLookupCacheFromFile() {
  try {
    const response = await fetch("./data/catch.json", {
      cache: "no-store"
    });
    if (!response.ok) {
      if (response.status === 404) {
        lookupCacheReady = true;
        return;
      }
      throw new Error("缓存文件加载失败。");
    }

    importLookupCache(await response.json());
    lookupCacheReady = true;
  } catch (error) {
    lookupCacheReady = true;
  }
}

async function saveLookupCacheToFile() {
  try {
    const response = await fetch("./api/lookup-cache", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(buildLookupCachePayload())
    });

    return response.ok;
  } catch (error) {
    return false;
  }
}

function importLookupCache(payload) {
  const entries = normalizeLookupCacheEntries(payload);
  let importedCount = 0;

  for (const [key, value] of entries) {
    if (typeof key !== "string") {
      continue;
    }

    const cacheEntry = parseLookupCacheKey(key);
    onlineMeaningCache.set(key, normalizeLookupCacheValue(value, cacheEntry?.term || ""));
    importedCount += 1;
  }

  return importedCount;
}

function normalizeLookupCacheEntries(payload) {
  if (!payload || typeof payload !== "object") {
    return [];
  }

  if (payload.items && typeof payload.items === "object" && !Array.isArray(payload.items)) {
    return Object.entries(payload.items);
  }

  if (Array.isArray(payload.entries)) {
    return payload.entries;
  }

  return Object.entries(payload);
}

function normalizeLookupCacheValue(value, term = "") {
  if (!value || typeof value !== "object") {
    return null;
  }

  const normalizedValue = {
    ipa: typeof value.ipa === "string" ? value.ipa : "",
    meaning: typeof value.meaning === "string" ? value.meaning : ""
  };

  if (!hasUsableOnlineResult(normalizedValue, term)) {
    return null;
  }

  if (normalizedValue.meaning && isSameMeaningAsTerm(normalizedValue.meaning, term)) {
    normalizedValue.meaning = "";
  }

  return normalizedValue;
}

function buildOnlineMeaningResult(term, meaning) {
  const normalizedMeaning = String(meaning || "").trim();
  if (!normalizedMeaning || isSameMeaningAsTerm(normalizedMeaning, term)) {
    return null;
  }

  return { meaning: normalizedMeaning };
}

function isSameMeaningAsTerm(meaning, term) {
  return normalizeComparableText(meaning) === normalizeComparableText(term);
}

function hasUsableMeaning(result, term) {
  return Boolean(result?.meaning) && !isSameMeaningAsTerm(result.meaning, term);
}

function hasUsableOnlineResult(result, term) {
  if (!result || typeof result !== "object") {
    return false;
  }

  return Boolean(result.ipa) || hasUsableMeaning(result, term);
}

function normalizeComparableText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[’']/g, "")
    .replace(/[-_\s]+/g, " ")
    .trim();
}

function restoreUserPreferences() {
  try {
    const storedUseOnlineModel = localStorage.getItem(USE_ONLINE_MODEL_STORAGE_KEY);
    if (storedUseOnlineModel !== null) {
      useOnlineModel.checked = storedUseOnlineModel === "true";
    } else {
      useOnlineModel.checked = false;
    }

    const storedKnownWords = localStorage.getItem(KNOWN_WORDS_STORAGE_KEY);
    if (storedKnownWords !== null) {
      knownWords.value = storedKnownWords;
    }
  } catch (error) {
    return;
  }
}

function persistUserPreferences() {
  try {
    localStorage.setItem(USE_ONLINE_MODEL_STORAGE_KEY, String(useOnlineModel.checked));
    localStorage.setItem(KNOWN_WORDS_STORAGE_KEY, knownWords.value);
  } catch (error) {
    return;
  }
}

function syncOnlineControls() {
  const enabled = useOnlineModel.checked;
  onlineProvider.disabled = !enabled;
  translationEndpoint.disabled = !enabled;
  translationApiKey.disabled = !enabled;
  translateButton.disabled = !enabled;
}

function syncOnlineProviderFields() {
  const provider = onlineProvider.value;
  if (provider === "google") {
    translationEndpoint.value = "https://translation.googleapis.com/language/translate/v2";
    translationEndpoint.placeholder = "Google Cloud Translation 官方端点";
    translationApiKey.placeholder = "填写 Google Cloud API Key";
    return;
  }

  if (provider === "libretranslate") {
    translationEndpoint.value = "https://libretranslate.com/translate";
    translationEndpoint.placeholder = "例如：http://内网地址:5000/translate";
    translationApiKey.placeholder = "LibreTranslate / DeepL 等需要时填写";
    return;
  }

  if (provider === "mymemory") {
    translationEndpoint.value = "";
    translationEndpoint.placeholder = "MyMemory 使用内置公共接口，无需填写";
    translationApiKey.placeholder = "MyMemory 无需 API Key";
    return;
  }

  if (provider === "dictionaryapi") {
    translationEndpoint.value = "";
    translationEndpoint.placeholder = "Free Dictionary API 无需填写";
    translationApiKey.placeholder = "Free Dictionary API 无需 API Key";
    return;
  }

  translationEndpoint.value = "";
  translationEndpoint.placeholder = "组合模式默认使用 Free Dictionary + MyMemory";
  translationApiKey.placeholder = "组合模式默认无需 API Key";
}

function normalizeOnlineIpa(phonetic) {
  if (!phonetic) {
    return "";
  }

  return phonetic.startsWith("/") ? phonetic : `/${phonetic}/`;
}

function collectContext(tokens, index, size = 1) {
  const start = Math.max(0, index - 3);
  const end = Math.min(tokens.length, index + size + 3);
  return tokens.slice(start, end).join(" ");
}

function pushContext(targetMap, key, value) {
  if (!value) {
    return;
  }

  const current = targetMap.get(key) || [];
  if (!current.includes(value) && current.length < 3) {
    current.push(value);
  }
  targetMap.set(key, current);
}

function guessIpa(word) {
  let value = word.toLowerCase();

  const exactRules = [
    [/^one$/g, "wʌn"],
    [/^once$/g, "wʌns"],
    [/^two$/g, "tu"],
    [/^use$/g, "juz"],
    [/^used$/g, "juzd"],
    [/^user$/g, "juzər"]
  ];
  exactRules.forEach(([pattern, replacement]) => {
    value = value.replace(pattern, replacement);
  });

  const replacements = [
    [/tion\b/g, "ʃən"],
    [/sion\b/g, "ʒən"],
    [/cian\b/g, "ʃən"],
    [/tial\b/g, "ʃəl"],
    [/ture\b/g, "tʃər"],
    [/sure\b/g, "ʒər"],
    [/dge/g, "dʒ"],
    [/gue\b/g, "ɡ"],
    [/mb\b/g, "m"],
    [/kn/g, "n"],
    [/wr/g, "r"],
    [/alk\b/g, "ɔk"],
    [/all\b/g, "ɔl"],
    [/ough/g, "oʊ"],
    [/eigh/g, "eɪ"],
    [/igh/g, "aɪ"],
    [/ph/g, "f"],
    [/sh/g, "ʃ"],
    [/ch/g, "tʃ"],
    [/th/g, "θ"],
    [/wh/g, "w"],
    [/ck/g, "k"],
    [/ng/g, "ŋ"],
    [/qu/g, "kw"],
    [/ee/g, "i"],
    [/ea/g, "i"],
    [/oo/g, "u"],
    [/ou/g, "aʊ"],
    [/ow/g, "oʊ"],
    [/ew/g, "ju"],
    [/au/g, "ɔ"],
    [/aw/g, "ɔ"],
    [/ai/g, "eɪ"],
    [/ay/g, "eɪ"],
    [/oi/g, "ɔɪ"],
    [/oy/g, "ɔɪ"],
    [/ar/g, "ɑr"],
    [/er/g, "ər"],
    [/ir/g, "ər"],
    [/or/g, "ɔr"],
    [/ur/g, "ər"],
    [/ing\b/g, "ɪŋ"],
    [/ed\b/g, "d"],
    [/es\b/g, "z"],
    [/ly\b/g, "li"],
    [/ment\b/g, "mənt"],
    [/ness\b/g, "nəs"],
    [/less\b/g, "ləs"],
    [/ful\b/g, "fəl"],
    [/able\b/g, "əbəl"],
    [/ible\b/g, "əbəl"],
    [/ous\b/g, "əs"],
    [/ive\b/g, "ɪv"],
    [/ize\b/g, "aɪz"],
    [/ise\b/g, "aɪz"],
    [/ate\b/g, "eɪt"],
    [/ism\b/g, "ɪzəm"],
    [/ary\b/g, "eri"],
    [/ery\b/g, "eri"]
  ];

  replacements.forEach(([pattern, replacement]) => {
    value = value.replace(pattern, replacement);
  });

  value = value
    .replace(/([^aeiou])le\b/g, "$1əl")
    .replace(/c(?=[eiy])/g, "s")
    .replace(/c/g, "k")
    .replace(/g(?=[eiy])/g, "dʒ")
    .replace(/x/g, "ks")
    .replace(/y\b/g, "i");

  if (value.endsWith("e") && !/[əaeiou]e$/.test(value)) {
    value = value.slice(0, -1);
  }

  const singleLetterMap = {
    a: "æ",
    b: "b",
    d: "d",
    e: "ɛ",
    f: "f",
    h: "h",
    i: "ɪ",
    j: "dʒ",
    k: "k",
    l: "l",
    m: "m",
    n: "n",
    o: "ɑ",
    p: "p",
    q: "k",
    r: "r",
    s: "s",
    t: "t",
    u: "ʌ",
    v: "v",
    w: "w",
    y: "j",
    z: "z"
  };

  value = [...value]
    .map((char) => singleLetterMap[char] || char)
    .join("");

  return addPrimaryStress(value);
}

function addPrimaryStress(ipa) {
  if (ipa.startsWith("ˈ") || ipa.length <= 3) {
    return ipa;
  }

  const vowelMatches = [...ipa.matchAll(/[æɛɪɑʌəiuɔaɪoʊaʊɔɪ]+/g)];
  if (vowelMatches.length <= 1) {
    return `ˈ${ipa}`;
  }

  const firstVowelIndex = vowelMatches[0].index || 0;
  return `${ipa.slice(0, firstVowelIndex)}ˈ${ipa.slice(firstVowelIndex)}`;
}
