import assert from "node:assert/strict";
import { test } from "node:test";
import { parseTle } from "../src/orbit/tle.ts";
import { observe, type Station } from "../src/orbit/pass.ts";
import { geodeticToEcef, gstime, lookAngles } from "../src/orbit/coords.ts";
import { WGS72, WGS72_FLATTENING, RAD2DEG } from "../src/orbit/constants.ts";

const STARLINK_1008 = parseTle(
  "1 44714U 19074B   26263.45059432  .00030609  00000+0  30957-3 0  9996",
  "2 44714  53.1478 327.2457 0002393  69.1515 290.9757 15.65058989379064",
  "STARLINK-1008",
);

const STATION: Station = { id: "T", name: "test", latDeg: 18.23, lonDeg: 109.51, altKm: 0.05 };

/** Peak of a real STARLINK-1008 pass over the station (elevation 73.5 deg). */
const PASS_PEAK_UTC = Date.UTC(2026, 8, 20, 15, 30, 41);

test("gstime reproduces GMST at J2000.0", () => {
  const deg = gstime(2451545.0) * RAD2DEG;
  assert.ok(Math.abs(deg - 280.46062) < 1e-4, `GMST(J2000) = ${deg}, expected 280.46062`);
});

test("a station at zero altitude lies on the WGS-72 ellipsoid", () => {
  const a = WGS72.radiusEarthKm;
  const b = a * (1 - WGS72_FLATTENING);
  for (const latDeg of [0, 18.23, 45, 53.5, -70]) {
    const [x, y, z] = geodeticToEcef(latDeg, 109.51, 0);
    const residual = (x * x + y * y) / (a * a) + (z * z) / (b * b) - 1;
    assert.ok(
      Math.abs(residual) < 1e-12,
      `lat ${latDeg}: station is off the ellipsoid (residual ${residual})`,
    );
  }
});

test("a point on the local vertical is at 90 degrees elevation", () => {
  const sat = geodeticToEcef(STATION.latDeg, STATION.lonDeg, 550);
  const look = lookAngles(STATION.latDeg, STATION.lonDeg, STATION.altKm!, sat, [0, 0, 0]);
  assert.ok(Math.abs(look.elevationDeg - 90) < 1e-9, `elevation ${look.elevationDeg}`);
  assert.ok(Math.abs(look.rangeKm - (550 - STATION.altKm!)) < 1e-9, `range ${look.rangeKm}`);
});

/**
 * The observer is fixed in ECEF, so the reported range-rate must equal the time
 * derivative of the reported range. This fails unless the TEME -> ECEF velocity
 * transform subtracts the transport term omega x r.
 */
test("range-rate is the time derivative of range", () => {
  const base = PASS_PEAK_UTC;
  const h = 0.5; // seconds
  for (const offsetMin of [-30, -10, 0, 10, 30]) {
    const t = base + offsetMin * 60_000;
    const here = observe(STARLINK_1008, STATION, new Date(t));
    const ahead = observe(STARLINK_1008, STATION, new Date(t + h * 1000));
    const behind = observe(STARLINK_1008, STATION, new Date(t - h * 1000));
    const numeric = (ahead.rangeKm - behind.rangeKm) / (2 * h);
    const err = Math.abs(numeric - here.rangeRateKmS);
    assert.ok(
      err < 1e-3,
      `offset ${offsetMin} min: d(range)/dt ${numeric} vs rangeRate ${here.rangeRateKmS} (err ${err} km/s)`,
    );
  }
});

test("Ku Doppler stays inside the physical envelope for a LEO pass", () => {
  let seen = 0;
  for (let s = -300; s <= 300; s += 5) {
    const o = observe(STARLINK_1008, STATION, new Date(PASS_PEAK_UTC + s * 1000));
    if (o.elevationDeg <= 0) continue;
    seen += 1;
    assert.ok(Math.abs(o.dopplerHz) < 300_000, `|fd| = ${o.dopplerHz} Hz exceeds the Ku LEO envelope`);
    assert.ok(Math.abs(o.rangeRateKmS) < 8, `|range-rate| = ${o.rangeRateKmS} km/s is not physical`);
  }
  assert.ok(seen > 0, "no visible sample found in the search window");
});
