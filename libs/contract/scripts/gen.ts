// Writes openapi.json and src/schema.d.ts from the zod schemas. `--check` writes nothing and fails on drift (the gate).
import { readFileSync, writeFileSync } from "node:fs";
import openapiTS, { astToString } from "openapi-typescript";
import { openapiDocument } from "../src/index.js";

const root = new URL("..", import.meta.url);
const doc = openapiDocument();
const spec = `${JSON.stringify(doc, null, 2)}\n`;
const types = `${astToString(await openapiTS(JSON.parse(spec)))}`;
const out = { "openapi.json": spec, "src/schema.d.ts": types };

const check = process.argv.includes("--check");
let drift = false;
for (const [file, text] of Object.entries(out)) {
  const url = new URL(file, root);
  let cur = "";
  try { cur = readFileSync(url, "utf8"); } catch { /* missing = drift */ }
  if (cur === text) continue;
  if (check) { console.error(`error: libs/contract/${file} is out of date; run: pnpm --filter @offerlane/contract gen`); drift = true; }
  else writeFileSync(url, text);
}
if (drift) process.exit(1);
