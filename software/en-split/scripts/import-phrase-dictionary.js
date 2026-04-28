const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");

main();

function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    printUsageAndExit();
  }

  const options = parseArgs(args);
  const inputPath = resolveCliPath(options.input);
  const targetPath = resolveCliPath(options.target || "data/base-phrase-meaning-dictionary.json");
  const mergeWithPath = resolveCliPath(options.mergeWith || options.target || "data/base-phrase-meaning-dictionary.json");
  const existingDictionary = readJsonIfExists(mergeWithPath);
  const lines = fs.readFileSync(inputPath, "utf8").split(/\r?\n/);

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

  for (const line of lines) {
    const parsedEntry = parseLine(line, options.format);
    if (!parsedEntry) {
      continue;
    }

    stats.parsed += 1;
    const phrase = normalizePhrase(parsedEntry.phrase);
    const meaning = cleanMeaning(parsedEntry.meaning);
    if (!phrase || !meaning) {
      stats.skipped += 1;
      continue;
    }

    if (importedEntries[phrase]) {
      stats.duplicates += 1;
      continue;
    }

    importedEntries[phrase] = meaning;
    stats.imported += 1;
  }

  const mergedDictionary = { ...existingDictionary };
  for (const [phrase, meaning] of Object.entries(importedEntries)) {
    if (!mergedDictionary[phrase]) {
      mergedDictionary[phrase] = meaning;
      stats.added += 1;
      continue;
    }

    if (options.prefer === "input" && mergedDictionary[phrase] !== meaning) {
      mergedDictionary[phrase] = meaning;
      stats.overwritten += 1;
      continue;
    }

    stats.preserved += 1;
  }

  writeJson(targetPath, mergedDictionary);

  console.log(`Parsed ${stats.parsed} phrase entries from ${path.basename(inputPath)}.`);
  console.log(`Imported ${stats.imported} normalized phrase entries.`);
  console.log(`Added ${stats.added} new phrase entries.`);
  console.log(`Overwrote ${stats.overwritten} existing phrase entries.`);
  console.log(`Preserved ${stats.preserved} existing phrase entries.`);
  console.log(`Skipped ${stats.skipped} unsupported entries.`);
  console.log(`Ignored ${stats.duplicates} duplicate entries.`);
}

function printUsageAndExit() {
  console.error(
    "Usage: node scripts/import-phrase-dictionary.js /path/to/phrases.txt " +
    "[--target data/base-phrase-meaning-dictionary.json] " +
    "[--merge-with data/base-phrase-meaning-dictionary.json] " +
    "[--prefer existing|input] [--format auto|tsv|jsonl]"
  );
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    input: "",
    target: "data/base-phrase-meaning-dictionary.json",
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
      if (nextValue !== "existing" && nextValue !== "input") {
        console.error("--prefer must be either existing or input");
        process.exit(1);
      }
      options.prefer = nextValue;
      index += 1;
      continue;
    }

    if (arg === "--format") {
      if (!["auto", "tsv", "jsonl"].includes(nextValue)) {
        console.error("--format must be auto, tsv, or jsonl");
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

function parseLine(line, format) {
  const normalizedLine = String(line).trim();
  if (!normalizedLine || normalizedLine.startsWith("#")) {
    return null;
  }

  if (format === "jsonl") {
    return parseJsonLine(normalizedLine);
  }

  if (format === "tsv") {
    return parseTsvLine(normalizedLine);
  }

  return normalizedLine.startsWith("{")
    ? parseJsonLine(normalizedLine)
    : parseTsvLine(normalizedLine);
}

function parseTsvLine(line) {
  const [phrase, meaning] = line.split("\t");
  if (!phrase || !meaning) {
    return null;
  }

  return { phrase, meaning };
}

function parseJsonLine(line) {
  try {
    const parsed = JSON.parse(line);
    return {
      phrase: parsed.phrase || parsed.term || "",
      meaning: parsed.meaning || parsed.zh || ""
    };
  } catch (error) {
    return null;
  }
}

function normalizePhrase(value) {
  const normalized = String(value)
    .toLowerCase()
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  if (!normalized) {
    return "";
  }

  const tokens = normalized.split(" ");
  if (tokens.length < 2 || tokens.length > 3) {
    return "";
  }

  if (!tokens.every((token) => /^[a-z]+(?:'[a-z]+)*$/.test(token))) {
    return "";
  }

  return tokens.join(" ");
}

function cleanMeaning(value) {
  const normalized = String(value)
    .replace(/\s+/g, " ")
    .replace(/\\n/g, "；")
    .trim();

  if (!normalized) {
    return "";
  }

  return normalized
    .split(/[;；]/)
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 3)
    .join("；");
}

function writeJson(filePath, data) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const sorted = Object.fromEntries(
    Object.entries(data).sort(([left], [right]) => left.localeCompare(right))
  );
  fs.writeFileSync(filePath, `${JSON.stringify(sorted, null, 2)}\n`);
}
