/**
 * Appends `.js` to relative import specifiers in the compiled dist/.
 *
 * The source deliberately keeps them extensionless: the monorepo consumes this
 * package as TypeScript, and Next's webpack builds resolve `./contracts` but not
 * `./contracts.js` (no file by that name exists before compilation), so writing
 * the extension in source breaks the hub, admin, and site builds.
 *
 * Node ESM and TypeScript's node16/nodenext resolution need the opposite: an
 * extensionless specifier in a published ESM package fails at both runtime and
 * typecheck. Rewriting the emitted output satisfies both.
 */
import { readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DIST = resolve(dirname(fileURLToPath(import.meta.url)), "dist");

// `from "./x"` and bare `import "./x"`, skipping specifiers that already carry
// an extension we would not want to double up.
const RELATIVE_IMPORT = /((?:from|import)\s+)(["'])(\.\.?\/[^"']+)\2/g;
const HAS_EXTENSION = /\.(js|mjs|cjs|json)$/;

let rewritten = 0;

for (const entry of await readdir(DIST, { withFileTypes: true })) {
  if (!entry.isFile() || !/\.(js|d\.ts)$/.test(entry.name)) continue;

  const path = join(DIST, entry.name);
  const before = await readFile(path, "utf-8");
  const after = before.replace(RELATIVE_IMPORT, (match, keyword, quote, specifier) =>
    HAS_EXTENSION.test(specifier) ? match : `${keyword}${quote}${specifier}.js${quote}`,
  );

  if (after !== before) {
    await writeFile(path, after);
    rewritten += 1;
  }
}

if (rewritten === 0) {
  throw new Error(
    "fix-dist-extensions: rewrote nothing. Either dist/ is missing or the emit shape changed — " +
      "publishing now would ship specifiers Node cannot resolve.",
  );
}

console.log(`→ added .js to relative imports in ${rewritten} dist files`);
