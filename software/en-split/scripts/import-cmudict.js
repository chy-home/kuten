const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");

function printUsageAndExit() {
  console.error(
    "Usage: node scripts/import-cmudict.js /path/to/cmudict.dict " +
    "[--target data/base-ipa-dictionary.json] [--merge-with data/base-ipa-dictionary.json] " +
    "[--prefer existing|cmu] [--format auto|cmudict|ipa-tab]"
  );
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    input: "",
    target: "data/base-ipa-dictionary.json",
    mergeWith: "",
    prefer: "existing",
    format: "auto"
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    if (!arg.startsWith("--")) {
      if (!options.input) {
        options.input = arg;
        continue;
      }

      console.error(`Unexpected argument: ${arg}`);
      process.exit(1);
    }

    const nextValue = argv[index + 1];
    if (!nextValue || nextValue.startsWith("--")) {
      console.error(`Missing value for ${arg}`);
      process.exit(1);
    }

    if (arg === "--target") {
      options.target = nextValue;
      index += 1;
      continue;
    }

    if (arg === "--merge-with") {
      options.mergeWith = nextValue;
      index += 1;
      continue;
    }

    if (arg === "--prefer") {
      if (nextValue !== "existing" && nextValue !== "cmu") {
        console.error("--prefer must be either existing or cmu");
        process.exit(1);
      }
      options.prefer = nextValue;
      index += 1;
      continue;
    }

    if (arg === "--format") {
      if (!["auto", "cmudict", "ipa-tab"].includes(nextValue)) {
        console.error("--format must be auto, cmudict, or ipa-tab");
        process.exit(1);
      }
      options.format = nextValue;
      index += 1;
      continue;
    }

    console.error(`Unknown flag: ${arg}`);
    process.exit(1);
  }

  if (!options.input) {
    printUsageAndExit();
  }

  return options;
}

function resolveCliPath(filePath) {
  return path.isAbsolute(filePath)
    ? filePath
    : path.resolve(process.cwd(), filePath);
}

function readJsonIfExists(filePath) {
  if (!fs.existsSync(filePath)) {
    return {};
  }

  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function parseInputLine(line, format) {
  const normalizedLine = String(line).trim();
  if (!normalizedLine || normalizedLine.startsWith(";;;")) {
    return null;
  }

  if (format === "ipa-tab") {
    return parseIpaTabLine(normalizedLine);
  }

  if (format === "cmudict") {
    return parseCmudictLine(normalizedLine);
  }

  return normalizedLine.includes("\t")
    ? parseIpaTabLine(normalizedLine)
    : parseCmudictLine(normalizedLine);
}

function parseIpaTabLine(line) {
  const [rawWord, rawIpa] = line.split("\t");
  if (!rawWord || !rawIpa) {
    return null;
  }

  const firstPronunciation = rawIpa
    .split(",")
    .map((item) => item.trim())
    .find(Boolean);

  if (!firstPronunciation) {
    return null;
  }

  return {
    word: stripVariantSuffix(rawWord),
    ipa: cleanIpa(firstPronunciation)
  };
}

function parseCmudictLine(line) {
  const match = line.match(/^(\S+)\s+(.+)$/);
  if (!match) {
    return null;
  }

  const [, rawWord, rawPronunciation] = match;
  const symbols = rawPronunciation.trim().split(/\s+/).filter(Boolean);
  const ipa = arpabetToIpa(symbols);
  if (!ipa) {
    return null;
  }

  return {
    word: stripVariantSuffix(rawWord),
    ipa
  };
}

function stripVariantSuffix(word) {
  return String(word).replace(/\(\d+\)$/g, "");
}

function normalizeWord(value) {
  const normalized = String(value).trim().toLowerCase();
  if (!/^[a-z]+(?:['-][a-z]+)*$/.test(normalized)) {
    return "";
  }
  return normalized;
}

function cleanIpa(value) {
  const normalized = String(value).trim().replace(/^\/+|\/+$/g, "");
  if (!normalized) {
    return "";
  }

  return `/${normalized}/`;
}

function arpabetToIpa(symbols) {
  const phonemes = symbols.map(parsePhoneme).filter(Boolean);
  if (phonemes.length === 0) {
    return "";
  }

  const stressPositions = new Map();
  const vowelIndexes = [];

  phonemes.forEach((phoneme, index) => {
    if (phoneme.isVowelLike) {
      const previousVowelIndex = vowelIndexes.length > 0
        ? vowelIndexes[vowelIndexes.length - 1]
        : -1;

      if (phoneme.stress === "1" || phoneme.stress === "2") {
        const stressMark = phoneme.stress === "1" ? "ˈ" : "ˌ";
        const between = phonemes
          .slice(previousVowelIndex + 1, index)
          .filter((item) => !item.isVowelLike)
          .map((item) => item.base);
        const onsetSize = detectOnsetSize(between);
        const markIndex = Math.max(index - onsetSize, 0);
        if (!stressPositions.has(markIndex)) {
          stressPositions.set(markIndex, stressMark);
        }
      }

      vowelIndexes.push(index);
    }
  });

  const output = phonemes
    .map((phoneme, index) => `${stressPositions.get(index) || ""}${phoneme.ipa}`)
    .join("");

  return cleanIpa(output);
}

function parsePhoneme(symbol) {
  const match = String(symbol).trim().match(/^([A-Z-]+?)([012])?$/);
  if (!match) {
    return null;
  }

  const [, base, stress = ""] = match;
  const ipa = phonemeToIpa(base, stress);
  if (!ipa) {
    return null;
  }

  return {
    base,
    stress,
    ipa,
    isVowelLike: VOWEL_LIKE_SYMBOLS.has(base)
  };
}

function phonemeToIpa(base, stress) {
  if (VOWEL_IPA_MAP[base]) {
    const value = VOWEL_IPA_MAP[base];
    return typeof value === "function" ? value(stress) : value;
  }

  return CONSONANT_IPA_MAP[base] || "";
}

function detectOnsetSize(cluster) {
  if (cluster.length === 0) {
    return 0;
  }

  for (let size = cluster.length; size >= 1; size -= 1) {
    const suffix = cluster.slice(cluster.length - size).join(" ");
    if (VALID_ONSETS.has(suffix)) {
      return size;
    }
  }

  return 0;
}

function writeJson(filePath, data) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const sorted = Object.fromEntries(
    Object.entries(data).sort(([left], [right]) => left.localeCompare(right))
  );
  fs.writeFileSync(filePath, `${JSON.stringify(sorted, null, 2)}\n`);
}

const VOWEL_LIKE_SYMBOLS = new Set([
  "AA", "AE", "AH", "AO", "AW", "AX", "AXR", "AY", "EH", "ER", "EY",
  "IH", "IX", "IY", "OW", "OY", "UH", "UW", "UX", "EL", "EM", "EN", "ENG"
]);

const VOWEL_IPA_MAP = {
  AA: "ɑ",
  AE: "æ",
  AH: (stress) => (stress === "0" || stress === "" ? "ə" : "ʌ"),
  AO: "ɔ",
  AW: "aʊ",
  AX: "ə",
  AXR: "ɚ",
  AY: "aɪ",
  EH: (stress) => (stress === "0" || stress === "" ? "ə" : "ɛ"),
  EL: "əl",
  EM: "əm",
  EN: "ən",
  ENG: "ŋ",
  ER: (stress) => (stress === "0" || stress === "" ? "ɚ" : "ɝ"),
  EY: "eɪ",
  IH: "ɪ",
  IX: "ɨ",
  IY: "i",
  OW: "oʊ",
  OY: "ɔɪ",
  UH: "ʊ",
  UW: "u",
  UX: "ʉ"
};

const CONSONANT_IPA_MAP = {
  B: "b",
  CH: "tʃ",
  D: "d",
  DH: "ð",
  DX: "ɾ",
  F: "f",
  G: "ɡ",
  HH: "h",
  HV: "h",
  JH: "dʒ",
  K: "k",
  L: "l",
  M: "m",
  N: "n",
  NG: "ŋ",
  P: "p",
  Q: "ʔ",
  R: "r",
  S: "s",
  SH: "ʃ",
  T: "t",
  TH: "θ",
  V: "v",
  W: "w",
  WH: "ʍ",
  Y: "j",
  Z: "z",
  ZH: "ʒ"
};

const VALID_ONSETS = new Set([
  "B", "CH", "D", "DH", "F", "G", "HH", "JH", "K", "L", "M", "N", "P",
  "R", "S", "SH", "T", "TH", "V", "W", "Y", "Z", "ZH",
  "B L", "B R", "B Y", "D R", "D W", "F L", "F R", "F Y", "G L", "G R",
  "G W", "G Y", "HH Y", "K L", "K R", "K W", "K Y", "M Y", "N Y", "P L",
  "P R", "P Y", "S F", "S K", "S K L", "S K R", "S K W", "S L", "S M",
  "S N", "S P", "S P L", "S P R", "S T", "S T R", "S W", "SH R", "T R",
  "T W", "TH R", "V Y"
]);

main();

function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    printUsageAndExit();
  }

  const options = parseArgs(args);
  const inputPath = resolveCliPath(options.input);
  const targetPath = resolveCliPath(options.target || "data/base-ipa-dictionary.json");
  const mergeWithPath = resolveCliPath(options.mergeWith || options.target || "data/base-ipa-dictionary.json");
  const existingDictionary = readJsonIfExists(mergeWithPath);
  const cmudictText = fs.readFileSync(inputPath, "utf8");

  const importedEntries = {};
  const stats = {
    parsed: 0,
    imported: 0,
    skipped: 0,
    duplicates: 0,
    added: 0,
    overwritten: 0,
    preserved: 0
  };

  for (const line of cmudictText.split(/\r?\n/)) {
    const parsedEntry = parseInputLine(line, options.format);
    if (!parsedEntry) {
      continue;
    }

    stats.parsed += 1;
    const word = normalizeWord(parsedEntry.word);
    if (!word || !parsedEntry.ipa) {
      stats.skipped += 1;
      continue;
    }

    if (importedEntries[word]) {
      stats.duplicates += 1;
      continue;
    }

    importedEntries[word] = parsedEntry.ipa;
    stats.imported += 1;
  }

  const mergedDictionary = { ...existingDictionary };
  for (const [word, ipa] of Object.entries(importedEntries)) {
    if (!mergedDictionary[word]) {
      mergedDictionary[word] = ipa;
      stats.added += 1;
      continue;
    }

    if (options.prefer === "cmu" && mergedDictionary[word] !== ipa) {
      mergedDictionary[word] = ipa;
      stats.overwritten += 1;
      continue;
    }

    stats.preserved += 1;
  }

  writeJson(targetPath, mergedDictionary);

  console.log(`Parsed ${stats.parsed} entries from ${path.basename(inputPath)}.`);
  console.log(`Imported ${stats.imported} normalized IPA entries.`);
  console.log(`Added ${stats.added} new IPA entries.`);
  console.log(`Overwrote ${stats.overwritten} existing IPA entries.`);
  console.log(`Preserved ${stats.preserved} existing IPA entries.`);
  console.log(`Skipped ${stats.skipped} unsupported entries.`);
  console.log(`Ignored ${stats.duplicates} duplicate variants.`);
}
