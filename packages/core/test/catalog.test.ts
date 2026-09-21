import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { catalogHash, parse3le, parseTle, type Tle } from "../src/orbit/tle.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");

const catalog = (): Tle[] =>
  readdirSync(join(root, "vectors/tle"))
    .filter((f) => f.startsWith("starlink-") && f.endsWith(".txt"))
    .sort()
    .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));

test("catalog hash is stable across runs", () => {
  assert.equal(catalogHash(catalog()), catalogHash(catalog()));
});

test("catalog hash does not depend on the order elements were loaded in", () => {
  const forward = catalog();
  const reversed = [...forward].reverse();
  assert.equal(catalogHash(forward), catalogHash(reversed));
});

/**
 * The whole point of committing the catalog: an attestation resolved against a
 * doctored element set must be distinguishable on chain from one resolved
 * against the real thing. A single digit of mean motion has to move the hash.
 */
test("one altered digit in one element set changes the hash", () => {
  const original = catalog();
  const before = catalogHash(original);

  const target = original[0]!;
  // 15.65058989379064 -> 15.65058989379065, still a valid checksummed line
  const digits = target.line2.slice(0, 68);
  const bumped = `${digits.slice(0, 67)}${(Number(digits[67]) + 1) % 10}`;
  let sum = 0;
  for (let i = 0; i < 68; i++) {
    const ch = bumped[i]!;
    if (ch === "-") sum += 1;
    else if (ch >= "0" && ch <= "9") sum += ch.charCodeAt(0) - 48;
  }
  const doctored = parseTle(target.line1, `${bumped}${sum % 10}`, target.name);

  assert.notEqual(doctored.line2, target.line2, "fixture did not actually change");
  assert.notEqual(catalogHash([doctored, ...original.slice(1)]), before);
});

test("dropping a satellite changes the hash", () => {
  const full = catalog();
  assert.notEqual(catalogHash(full.slice(1)), catalogHash(full));
});

test("a catalog holding the same satellite twice is rejected", () => {
  const dup = catalog();
  assert.throws(() => catalogHash([...dup, dup[0]!]), /duplicate/i);
});

test("an empty catalog is rejected", () => {
  assert.throws(() => catalogHash([]), /empty/i);
});
