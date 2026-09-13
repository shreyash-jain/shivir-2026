/**
 * The generator (Python) and the scanner (JavaScript) each implement the
 * check character independently. If they ever disagree, every badge at the
 * event fails to scan. This test extracts the real functions out of the
 * shipped index.html — not a copy — and checks them against Python's output.
 *
 * Run: node tests/crossvalidate.js
 */

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");

function loadScannerCodeLogic() {
  const html = fs.readFileSync(path.join(ROOT, "scanner/index.html"), "utf8");
  const start = html.indexOf("const ALPHABET");
  const marker = html.indexOf("const pretty");
  if (start === -1 || marker === -1) throw new Error("could not locate code logic in index.html");
  const src = html.slice(start, html.indexOf("\n", marker));
  // `const` declarations create lexical bindings, not properties on the
  // sandbox, so export them explicitly.
  const exported = "\nglobalThis.__api = { ALPHABET, BODY, LEN, checkChar, normalise, validCode, pretty };";
  const sandbox = {};
  vm.createContext(sandbox);
  new vm.Script(src + exported).runInContext(sandbox);
  return sandbox.__api;
}

function pythonCodes(n) {
  const script = `
import sys, tempfile, csv, subprocess, pathlib
sys.path.insert(0, "${ROOT}/tools")
from make_qr_labels import generate_codes
print("\\n".join(generate_codes(${n})))
`;
  return execFileSync("python3", ["-c", script], { encoding: "utf8" }).trim().split("\n");
}

let failed = 0;
const check = (name, cond) => {
  console.log((cond ? "  pass  " : "  FAIL  ") + name);
  if (!cond) failed++;
};

const js = loadScannerCodeLogic();

// 1. Every code Python generates must be accepted by the scanner.
const codes = pythonCodes(3000);
const accepted = codes.filter(js.validCode).length;
check(`scanner accepts all Python codes (${accepted}/${codes.length})`, accepted === codes.length);

// 2. The scanner must reject corrupted versions of those same codes.
//    Exhaustive over every single-character substitution, so the rate is a
//    measurement rather than a coin flip. See CLAUDE.md for why it is not 100%.
let rejected = 0, attempts = 0;
for (const c of codes.slice(0, 200)) {
  for (let i = 0; i < 8; i++) {
    for (const ch of js.ALPHABET) {
      if (ch === c[i]) continue;
      attempts++;
      if (!js.validCode(c.slice(0, i) + ch + c.slice(i + 1))) rejected++;
    }
  }
}
const rate = rejected / attempts;
check(`scanner rejects single-character typos (${(rate * 100).toFixed(2)}% of ${attempts})`,
      rate > 0.93);

// 3. Alphabets must match exactly.
const pyAlphabet = execFileSync("python3",
  ["-c", `import sys; sys.path.insert(0,"${ROOT}/tools"); from make_qr_labels import ALPHABET; print(ALPHABET)`],
  { encoding: "utf8" }).trim();
check("alphabets identical", pyAlphabet === js.ALPHABET);

// 4. Display formatting must agree.
const c0 = codes[0];
const pyPretty = execFileSync("python3",
  ["-c", `import sys; sys.path.insert(0,"${ROOT}/tools"); from make_qr_labels import pretty; print(pretty("${c0}"))`],
  { encoding: "utf8" }).trim();
check(`display form identical (${pyPretty})`, pyPretty === js.pretty(c0));

// 5. Input tolerance — volunteers type these by hand under pressure.
check("tolerates hyphen, lowercase and spaces",
  [js.pretty(c0), c0.toLowerCase(), `  ${js.pretty(c0)}  `].every(js.validCode));

console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
