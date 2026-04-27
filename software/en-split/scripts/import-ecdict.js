const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");
const inputPath = process.argv[2];

if (!inputPath) {
  console.error("Usage: node scripts/import-ecdict.js /path/to/ecdict.csv");
  process.exit(1);
}

const resolvedInputPath = path.resolve(process.cwd(), inputPath);
const csvText = fs.readFileSync(resolvedInputPath, "utf8");
const lines = csvText.split(/\r?\n/).filter(Boolean);

if (lines.length <= 1) {
  console.error("ECDICT CSV is empty.");
  process.exit(1);
}

const header = splitCsvLine(lines[0]);
const wordIndex = header.indexOf("word");
const phoneticIndex = header.indexOf("phonetic");
const translationIndex = header.indexOf("translation");

if (wordIndex < 0 || phoneticIndex < 0 || translationIndex < 0) {
  console.error("Unsupported ECDICT CSV header.");
  process.exit(1);
}

const ipaDictionary = {};
const meaningDictionary = {};

for (let index = 1; index < lines.length; index += 1) {
  const cells = splitCsvLine(lines[index]);
  const word = normalizeWord(cells[wordIndex] || "");
  if (!word) {
    continue;
  }

  const phonetic = cleanPhonetic(cells[phoneticIndex] || "");
  const translation = cleanTranslation(cells[translationIndex] || "");

  if (phonetic) {
    ipaDictionary[word] = phonetic;
  }

  if (translation) {
    meaningDictionary[word] = translation;
  }
}

writeJson("data/base-ipa-dictionary.json", ipaDictionary);
writeJson("data/base-meaning-dictionary.json", meaningDictionary);

console.log(`Imported ${Object.keys(meaningDictionary).length} meanings.`);
console.log(`Imported ${Object.keys(ipaDictionary).length} IPA entries.`);

function normalizeWord(value) {
  const normalized = String(value).trim().toLowerCase();
  if (!/^[a-z]+(?:['-][a-z]+)*$/.test(normalized)) {
    return "";
  }
  return normalized;
}

function cleanPhonetic(value) {
  const normalized = String(value).trim();
  if (!normalized) {
    return "";
  }

  if (normalized.startsWith("/") && normalized.endsWith("/")) {
    return normalized;
  }

  return `/${normalized.replace(/^\/+|\/+$/g, "")}/`;
}

function cleanTranslation(value) {
  const normalized = String(value)
    .replace(/\\n/g, "；")
    .replace(/\s+/g, " ")
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

function writeJson(relativePath, data) {
  const filePath = path.join(rootDir, relativePath);
  const sorted = Object.fromEntries(
    Object.entries(data).sort(([left], [right]) => left.localeCompare(right))
  );
  fs.writeFileSync(filePath, `${JSON.stringify(sorted, null, 2)}\n`);
}

function splitCsvLine(line) {
  const cells = [];
  let current = "";
  let inQuotes = false;

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const next = line[index + 1];

    if (char === "\"") {
      if (inQuotes && next === "\"") {
        current += "\"";
        index += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char === "," && !inQuotes) {
      cells.push(current);
      current = "";
      continue;
    }

    current += char;
  }

  cells.push(current);
  return cells;
}
