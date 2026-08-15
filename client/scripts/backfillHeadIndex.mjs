#!/usr/bin/env node
/**
 * Backfill the missing entries in resources/indices/cabezas.json.
 *
 * 90 NPCs render as a headless body — Robbie <Quest> (head 618), Igor
 * <Provisiones> (701), Sergio <Quest> (602) and so on. They reference head ids
 * 515-757, but the generated head index stops at 514, so headGrhForDirection
 * returns null and nothing is drawn above the body.
 *
 * The source `resources/raw/init/cabezas.ini` declares `NumHeads=757` and does
 * contain those entries, and their graphics resolve in `graficos_full.json`.
 *
 * IMPORTANT — the two datasets are not the same art set. cabezas.json head 1 is
 * grh 3000-3003 while cabezas.ini [HEAD1] is 33269-33272, and cuerpos.json
 * disagrees with cuerpos.dat on head offsets too. Whoever generated the checked-in
 * indices used a different AO dump than the one in resources/raw. This script
 * therefore only APPENDS ids the index is missing and never rewrites an existing
 * entry, so no current NPC or player appearance changes.
 *
 * Direction mapping follows the AO heading enum used throughout the .ind/.ini
 * format: Head1=North, Head2=East, Head3=South, Head4=West. If backfilled heads
 * face the wrong way when an NPC turns, swap north/east here — that is the one
 * assumption in this script that the source does not state explicitly.
 *
 *     node scripts/backfillHeadIndex.mjs [--write]
 *
 * Without --write it reports what it would change and touches nothing.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const indexPath = join(repoRoot, "resources", "indices", "cabezas.json");
const sourcePath = join(repoRoot, "resources", "raw", "init", "cabezas.ini");
const graphicsPath = join(repoRoot, "resources", "indices", "graficos_full.json");

const write = process.argv.includes("--write");

function parseHeadIni(text) {
  const heads = new Map();
  let current = null;

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    const section = /^\[HEAD(\d+)\]$/i.exec(line);
    if (section) {
      current = Number(section[1]);
      heads.set(current, {});
      continue;
    }

    const pair = /^Head([1-4])\s*=\s*(\d+)/i.exec(line);
    if (pair && current != null) {
      heads.get(current)[`head${pair[1]}`] = Number(pair[2]);
    }
  }

  return heads;
}

const index = JSON.parse(readFileSync(indexPath, "utf8"));
const source = parseHeadIni(readFileSync(sourcePath, "utf8"));
const graphics = JSON.parse(readFileSync(graphicsPath, "utf8"));

const knownGrh = new Set();
for (const entry of graphics) {
  if (entry && typeof entry === "object" && typeof entry.id === "number") {
    knownGrh.add(entry.id);
  }
}

const existing = new Set();
for (const entry of index) {
  if (entry && typeof entry === "object" && typeof entry.id === "number") {
    existing.add(entry.id);
  }
}

const added = [];
const skippedNoGraphics = [];

for (const [id, dirs] of [...source.entries()].sort((a, b) => a[0] - b[0])) {
  if (existing.has(id)) {
    continue;
  }

  const { head1, head2, head3, head4 } = dirs;
  if (!head1 || !head2 || !head3 || !head4) {
    continue;
  }

  // A head whose graphics are absent would still render as nothing; adding it
  // would only trade one silent failure for another.
  const missing = [head1, head2, head3, head4].filter((grh) => !knownGrh.has(grh));
  if (missing.length > 0) {
    skippedNoGraphics.push({ id, missing });
    continue;
  }

  added.push({ id, up: head1, right: head2, down: head3, left: head4 });
}

console.log(`head index entries: ${existing.size}`);
console.log(`source declares:    ${source.size}`);
console.log(`would append:       ${added.length}`);
if (skippedNoGraphics.length > 0) {
  console.log(`skipped (graphics missing): ${skippedNoGraphics.length}`);
  for (const s of skippedNoGraphics.slice(0, 5)) {
    console.log(`   head ${s.id} -> missing grh ${s.missing.join(", ")}`);
  }
}

if (added.length > 0) {
  console.log("sample:", JSON.stringify(added.slice(0, 3)));
}

if (!write) {
  console.log("\nDry run. Pass --write to apply.");
  process.exit(0);
}

const merged = [...index, ...added];
writeFileSync(indexPath, `${JSON.stringify(merged, null, 2)}\n`);
console.log(`\nWrote ${added.length} new heads to ${indexPath}`);
