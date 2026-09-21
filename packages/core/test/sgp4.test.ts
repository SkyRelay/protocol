import assert from "node:assert/strict";
import { test } from "node:test";
import { parseTle } from "../src/orbit/tle.ts";
import { initSgp4, propagate, propagateTle } from "../src/orbit/sgp4.ts";
import { WGS72 } from "../src/orbit/constants.ts";

const VANGUARD_1 =
  "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753";
const VANGUARD_2 =
  "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667";

/** CelesTrak GP element set, epoch 2026-263 — the near-circular case the pipeline actually uses. */
const STARLINK_1008_1 =
  "1 44714U 19074B   26263.45059432  .00030609  00000+0  30957-3 0  9996";
const STARLINK_1008_2 =
  "2 44714  53.1478 327.2457 0002393  69.1515 290.9757 15.65058989379064";

/**
 * Reference states published in the SGP4 verification output (tcppver.out)
 * that accompanies Vallado et al., AIAA 2006-6753, for satellite 00005.
 * These are external values, not a regression baseline captured from this
 * implementation: position AND velocity are both pinned.
 */
const VALLADO_00005 = [
  {
    tsinceMin: 0,
    positionKm: [7022.46529266, -1400.08296755, 0.03995155],
    velocityKmS: [1.893841015, 6.405893759, 4.534807250],
  },
  {
    tsinceMin: 360,
    positionKm: [-7154.03120202, -3783.17682504, -3536.19412294],
    velocityKmS: [4.741887409, -4.151817765, -2.093935425],
  },
] as const;

test("TLE checksum and identity", () => {
  const tle = parseTle(VANGUARD_1, VANGUARD_2, "VANGUARD 1");
  assert.equal(tle.noradId, 5);
  assert.equal(tle.epochYear, 2000);
  assert.ok(Math.abs(tle.eccentricity - 0.1859667) < 1e-12);
});

test("Vallado WGS-72 Vanguard-1 position matches the published verification output", () => {
  const tle = parseTle(VANGUARD_1, VANGUARD_2, "VANGUARD 1");
  for (const c of VALLADO_00005) {
    const { positionKm } = propagateTle(tle, c.tsinceMin);
    for (let i = 0; i < 3; i++) {
      const err = Math.abs(positionKm[i]! - c.positionKm[i]!);
      assert.ok(err < 1e-6, `t=${c.tsinceMin} axis ${i} position error ${err} km`);
    }
  }
});

test("Vallado WGS-72 Vanguard-1 velocity matches the published verification output", () => {
  const tle = parseTle(VANGUARD_1, VANGUARD_2, "VANGUARD 1");
  for (const c of VALLADO_00005) {
    const { velocityKmS } = propagateTle(tle, c.tsinceMin);
    for (let i = 0; i < 3; i++) {
      const err = Math.abs(velocityKmS[i]! - c.velocityKmS[i]!);
      assert.ok(err < 1e-6, `t=${c.tsinceMin} axis ${i} velocity error ${err} km/s`);
    }
  }
});

/**
 * SGP4's analytic velocity is not the exact derivative of its own position
 * expression: the short-period periodics are differentiated only in part, so a
 * residual of ~2e-4 relative (eccentric orbits) / ~2e-6 relative (near-circular
 * Starlink shells) is inherent to the model. The 1e-3 relative bound is far
 * inside that and still three orders of magnitude tighter than any unit or
 * scaling mistake, which is what this test exists to catch.
 */
test("velocity agrees with the numerical derivative of position", () => {
  const orbits = [
    parseTle(VANGUARD_1, VANGUARD_2, "VANGUARD 1"),
    parseTle(STARLINK_1008_1, STARLINK_1008_2, "STARLINK-1008"),
  ];
  const h = 1e-3; // minutes
  for (const tle of orbits) {
    const state = initSgp4(tle);
    for (const t of [0, 17.5, 120, 600]) {
      const { velocityKmS } = propagate(state, t);
      const speed = Math.hypot(...velocityKmS);
      const ahead = propagate(state, t + h).positionKm;
      const behind = propagate(state, t - h).positionKm;
      for (let i = 0; i < 3; i++) {
        const numeric = (ahead[i]! - behind[i]!) / (2 * h * 60);
        const relative = Math.abs(numeric - velocityKmS[i]!) / speed;
        assert.ok(
          relative < 1e-3,
          `${tle.name} t=${t} axis ${i}: dr/dt ${numeric} vs v ${velocityKmS[i]} (relative ${relative})`,
        );
      }
    }
  }
});

test("speed satisfies vis-viva for the osculating orbit", () => {
  const tle = parseTle(VANGUARD_1, VANGUARD_2, "VANGUARD 1");
  const state = initSgp4(tle);
  for (const t of [0, 45, 300]) {
    const { positionKm, velocityKmS } = propagate(state, t);
    const r = Math.hypot(...positionKm);
    const v = Math.hypot(...velocityKmS);
    // a from the specific orbital energy must stay close to the TLE semi-major axis
    const energy = (v * v) / 2 - WGS72.muKm3s2 / r;
    const a = -WGS72.muKm3s2 / (2 * energy);
    assert.ok(a > 8000 && a < 9300, `t=${t}: implausible semi-major axis ${a} km from |v|=${v} km/s`);
  }
});

test("near-earth guard rejects deep-space elements", () => {
  const tle = parseTle(VANGUARD_1, VANGUARD_2, "VANGUARD 1");
  assert.throws(
    () => initSgp4({ ...tle, meanMotionRevPerDay: 1.0027 }),
    /deep-space/,
  );
});
