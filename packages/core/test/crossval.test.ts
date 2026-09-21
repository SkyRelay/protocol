import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { sgp4, twoline2satrec } from "satellite.js";
import { parse3le, type Tle } from "../src/orbit/tle.ts";
import { propagateTle } from "../src/orbit/sgp4.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");

const TSINCE_MIN = [0, 12.5, 45, 200, 720] as const;

const shipped = (): Tle[] =>
  readdirSync(join(root, "vectors/tle"))
    .filter((f) => f.endsWith(".txt"))
    .sort()
    .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));

/**
 * Vallado's published table pins one eccentric verification case. A second
 * implementation has to agree on the near-circular Starlink sets the pipeline
 * actually uses, or that table is a special case. satellite.js is that second
 * implementation. Measured residual on these four element sets: 1.8e-10 km /
 * 1.6e-13 km/s; the 1e-6 km / 1e-9 km/s bounds sit well above that noise.
 */
test("SGP4 position agrees with satellite.js on every shipped element set", () => {
  const tles = shipped();
  assert.ok(tles.length > 0, "vectors/tle is empty");
  for (const tle of tles) {
    const satrec = twoline2satrec(tle.line1, tle.line2);
    for (const tsinceMin of TSINCE_MIN) {
      const { positionKm } = propagateTle(tle, tsinceMin);
      const theirs = sgp4(satrec, tsinceMin);
      assert.ok(theirs, `${tle.name} t=${tsinceMin}: satellite.js returned null`);
      const ref = [theirs.position.x, theirs.position.y, theirs.position.z] as const;
      for (let i = 0; i < 3; i++) {
        const err = Math.abs(positionKm[i]! - ref[i]!);
        assert.ok(
          err < 1e-6,
          `${tle.name} t=${tsinceMin} axis ${i} position error ${err} km`,
        );
      }
    }
  }
});

test("SGP4 velocity agrees with satellite.js on every shipped element set", () => {
  const tles = shipped();
  assert.ok(tles.length > 0, "vectors/tle is empty");
  for (const tle of tles) {
    const satrec = twoline2satrec(tle.line1, tle.line2);
    for (const tsinceMin of TSINCE_MIN) {
      const { velocityKmS } = propagateTle(tle, tsinceMin);
      const theirs = sgp4(satrec, tsinceMin);
      assert.ok(theirs, `${tle.name} t=${tsinceMin}: satellite.js returned null`);
      const ref = [theirs.velocity.x, theirs.velocity.y, theirs.velocity.z] as const;
      for (let i = 0; i < 3; i++) {
        const err = Math.abs(velocityKmS[i]! - ref[i]!);
        assert.ok(
          err < 1e-9,
          `${tle.name} t=${tsinceMin} axis ${i} velocity error ${err} km/s`,
        );
      }
    }
  }
});
