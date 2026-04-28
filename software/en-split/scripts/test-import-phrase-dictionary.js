const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const rootDir = path.resolve(__dirname, "..");
const scriptPath = path.join(rootDir, "scripts", "import-phrase-dictionary.js");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "en-split-phrases-"));

try {
  testTsvFormat();
  testJsonlFormat();
  console.log("phrase dictionary import ok");
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}

function testTsvFormat() {
  const inputPath = path.join(tempDir, "phrases.tsv");
  const basePath = path.join(tempDir, "base.json");
  const outputPath = path.join(tempDir, "output.json");

  fs.writeFileSync(
    inputPath,
    [
      "# comment",
      "real_time\t实时",
      "data pipeline\t数据管道",
      "privacy compliance\t隐私合规",
      "too many words here\t应被忽略",
      "bad-entry",
      "data pipeline\t重复项",
      ""
    ].join("\n")
  );
  fs.writeFileSync(basePath, `${JSON.stringify({ "data pipeline": "旧释义" }, null, 2)}\n`);

  const result = runNode([
    scriptPath,
    inputPath,
    "--target", outputPath,
    "--merge-with", basePath
  ]);
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const output = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(output["real time"], "实时");
  assert.equal(output["data pipeline"], "旧释义");
  assert.equal(output["privacy compliance"], "隐私合规");
  assert.equal(output["too many words here"], undefined);
}

function testJsonlFormat() {
  const inputPath = path.join(tempDir, "phrases.jsonl");
  const outputPath = path.join(tempDir, "jsonl-output.json");

  fs.writeFileSync(
    inputPath,
    [
      JSON.stringify({ phrase: "batch processing", meaning: "批处理" }),
      JSON.stringify({ term: "cross platform", zh: "跨平台" }),
      JSON.stringify({ phrase: "single", meaning: "单词，应忽略" }),
      "not json",
      ""
    ].join("\n")
  );

  const result = runNode([
    scriptPath,
    inputPath,
    "--target", outputPath,
    "--format", "jsonl",
    "--prefer", "input"
  ]);
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const output = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(output["batch processing"], "批处理");
  assert.equal(output["cross platform"], "跨平台");
  assert.equal(output.single, undefined);
}

function runNode(args) {
  return spawnSync(process.execPath, args, {
    cwd: rootDir,
    encoding: "utf8"
  });
}
