const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const rootDir = path.resolve(__dirname, "..");
const scriptPath = path.join(rootDir, "scripts", "import-cmudict.js");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "en-split-cmudict-"));

try {
  testCmudictFormat();
  testIpaTabFormat();
  console.log("cmudict import ok");
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}

function testCmudictFormat() {
  const inputPath = path.join(tempDir, "sample-cmudict.dict");
  const basePath = path.join(tempDir, "base.json");
  const outputPath = path.join(tempDir, "output.json");

  fs.writeFileSync(
    inputPath,
    [
      ";;; comment",
      "HELLO  HH AH0 L OW1",
      "PROJECT  P R AA1 JH EH0 K T",
      "READ(2)  R IY1 D",
      "REAL-TIME  R IY1 L T AY1 M",
      "CAN'T  K AE1 N T",
      "123ABC  W AH1 N",
      ""
    ].join("\n")
  );
  fs.writeFileSync(basePath, `${JSON.stringify({ hello: "/legacy/" }, null, 2)}\n`);

  const result = runNode([
    scriptPath,
    inputPath,
    "--target", outputPath,
    "--merge-with", basePath
  ]);
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const output = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(output.hello, "/legacy/");
  assert.equal(output.project, "/ˈprɑdʒəkt/");
  assert.equal(output.read, "/ˈrid/");
  assert.equal(output["real-time"], "/ˈrilˈtaɪm/");
  assert.equal(output["can't"], "/ˈkænt/");
  assert.equal(output["123abc"], undefined);
}

function testIpaTabFormat() {
  const inputPath = path.join(tempDir, "sample-ipa.txt");
  const outputPath = path.join(tempDir, "ipa-output.json");

  fs.writeFileSync(
    inputPath,
    [
      "alpha\t/ˈælfə/",
      "beta\tˈbeɪtə, ˈbiːtə",
      "gamma(2)\t/ˈɡæmə/",
      "bad entry",
      ""
    ].join("\n")
  );

  const result = runNode([
    scriptPath,
    inputPath,
    "--target", outputPath,
    "--format", "ipa-tab",
    "--prefer", "cmu"
  ]);
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const output = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(output.alpha, "/ˈælfə/");
  assert.equal(output.beta, "/ˈbeɪtə/");
  assert.equal(output.gamma, "/ˈɡæmə/");
}

function runNode(args) {
  return spawnSync(process.execPath, args, {
    cwd: rootDir,
    encoding: "utf8"
  });
}
