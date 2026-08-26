import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ALL_ARTIFACTS } from "./contracts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SMART_CONTRACTS_DIR = resolve(HERE, "..", "..");
const FOUNDRY_OUT = join(SMART_CONTRACTS_DIR, "out");
const JSON_OUT = resolve(HERE, "..", "json");

await mkdir(JSON_OUT, { recursive: true });

for (const name of ALL_ARTIFACTS) {
  const artifactPath = join(FOUNDRY_OUT, `${name}.sol`, `${name}.json`);
  const artifact = JSON.parse(await readFile(artifactPath, "utf-8"));
  const target = join(JSON_OUT, `${name}.json`);
  await writeFile(target, `${JSON.stringify(artifact.abi, null, 2)}\n`);
  console.log(`  ✓ ${name}.json`);
}

console.log(`\nWrote ${ALL_ARTIFACTS.length} ABIs to ${JSON_OUT}`);
