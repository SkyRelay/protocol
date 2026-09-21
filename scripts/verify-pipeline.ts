/**
 * Turn-key feasibility report:
 *   Starlink capture JSON -> features + ASN -> SGP4 boresight match -> EIP-712
 *   digest, then Foundry verifies ecrecover / TTL / replay / operator binding.
 *
 * Every gate is exercised by a fixture that trips it. Nothing degrades: a frame
 * that fails a check is reported as rejected, never attested on softer terms.
 */
import { execSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse3le } from "../packages/core/src/orbit/tle.ts";
import { propagateTle } from "../packages/core/src/orbit/sgp4.ts";
import type { Station } from "../packages/core/src/orbit/pass.ts";
import { runPipeline } from "../packages/core/src/pipeline.ts";
import { ATTESTATION_TYPEHASH, DOMAIN_TYPEHASH } from "../packages/core/src/crypto/eip712.ts";
import { runQuorum } from "../packages/core/src/quorum.ts";
import { operatorFor, readCatalog, readDomain } from "./shared.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const domain = readDomain(root);

/** Rejection each negative fixture must produce, so a silent pass cannot hide. */
const EXPECTED_REJECTION: Record<string, RegExp> = {
  "bad-asn-005": /ASN 15169 is outside/,
  "bad-geometry-006": /boresight .* deg from the nearest catalog satellite/,
};

function fail(msg: string): never {
  console.error(`FAIL  ${msg}`);
  process.exit(1);
}

function ok(msg: string) {
  console.log(`  ok   ${msg}`);
}

console.log(`
SkyRelay feasibility pipeline
=============================
  1. Starlink UT gRPC JSON
  2. Physical features + AS14593/AS45700
  3. SGP4 boresight match + Ku Doppler
  4. EIP-712 digest  ==  Solidity hashAttestation
`);

// --- SGP4 lock against the published Vallado verification output ---
{
  const vanguard = parse3le(readFileSync(join(root, "vectors/tle/vanguard.txt"), "utf8"));
  const expected = {
    positionKm: [7022.46529266, -1400.08296755, 0.03995155],
    velocityKmS: [1.893841015, 6.405893759, 4.534807250],
  };
  const { positionKm, velocityKmS } = propagateTle(vanguard, 0);
  const dr = Math.hypot(...positionKm.map((x, i) => x - expected.positionKm[i]!));
  const dv = Math.hypot(...velocityKmS.map((x, i) => x - expected.velocityKmS[i]!));
  if (dr > 1e-6) fail(`SGP4 Vanguard-1 position residual ${dr} km`);
  if (dv > 1e-6) fail(`SGP4 Vanguard-1 velocity residual ${dv} km/s`);
  ok(`SGP4 Vanguard-1 TEME residual r=${dr.toExponential(2)} km  v=${dv.toExponential(2)} km/s`);
}

console.log(`  eip712 typehash ${ATTESTATION_TYPEHASH}`);
console.log(`  eip712 domain   ${DOMAIN_TYPEHASH}`);

// --- Public catalog: every frame is matched against all of it, not a hint ---
const catalog = readCatalog(root);
ok(`catalog ${catalog.map((t) => `${t.name}(${t.noradId})`).join(" ")}`);

const frames = readdirSync(join(root, "vectors/frames"))
  .filter((f) => f.endsWith(".json"))
  .sort();

let passed = 0;
let rejected = 0;

for (const file of frames) {
  const capture = JSON.parse(readFileSync(join(root, "vectors/frames", file), "utf8"));
  const id = file.replace(/\.json$/, "");
  const station = capture.station as Station;
  const expectFailure = EXPECTED_REJECTION[id];

  let out: ReturnType<typeof runPipeline> | undefined;
  let error: Error | undefined;
  try {
    out = runPipeline({ capture, catalog, station, domain, operator: operatorFor(station.id) });
  } catch (e) {
    error = e as Error;
  }

  if (expectFailure) {
    if (!error) fail(`${file} was accepted but must be rejected`);
    if (!expectFailure.test(error.message)) {
      fail(`${file} was rejected by the wrong gate: ${error.message}`);
    }
    rejected += 1;
    ok(`${file} rejected: ${error.message}`);
    continue;
  }

  if (error || !out) fail(`${file} rejected unexpectedly: ${error?.message}`);
  if (out.attestation.noradId !== capture.expectNoradId) {
    fail(`${file} matched NORAD ${out.attestation.noradId}, expected ${capture.expectNoradId}`);
  }
  passed += 1;
  console.log(
    `  ok   ${file}  NORAD ${out.attestation.noradId}  el=${(out.attestation.elevationMilliDeg / 1000).toFixed(2)}°  ` +
      `fd=${out.attestation.dopplerHz} Hz  SNR=${(out.attestation.snrMilliDb / 1000).toFixed(2)} dB  ASN ${out.attestation.asn}  ` +
      `boresight residual ${out.sighting.boresightResidualDeg.toFixed(3)}°`,
  );
  console.log(`       digest ${out.digest}`);
}

if (passed < 3) fail(`expected >= 3 positive frames, got ${passed}`);
if (rejected < Object.keys(EXPECTED_REJECTION).length) fail("not every negative fixture ran");

// --- quorum: three stations, one satellite, one second ---
{
  const ids: string[] = JSON.parse(
    readFileSync(join(root, "vectors/eip712/attestations.json"), "utf8"),
  ).quorum.members;
  const members = ids.map((id) => {
    const capture = JSON.parse(readFileSync(join(root, "vectors/frames", `${id}.json`), "utf8"));
    const station = capture.station as Station;
    return { capture, station, operator: operatorFor(station.id) };
  });

  const q = runQuorum({ members, catalog, domain });
  ok(
    `quorum NORAD ${q.noradId} at t=${q.timestamp}: ${q.reports.length} stations agree, ` +
      `worst boresight residual ${q.worstBoresightResidualDeg.toFixed(3)}\u00b0`,
  );
  for (let i = 0; i < q.reports.length; i++) {
    const r = q.reports[i]!;
    console.log(
      `       ${ids[i]!.padEnd(20)} ${members[i]!.station.id.padEnd(12)} ` +
        `el=${(r.attestation.elevationMilliDeg / 1000).toFixed(2).padStart(6)}\u00b0  ` +
        `fd=${String(r.attestation.dopplerHz).padStart(8)} Hz  ASN ${r.attestation.asn}`,
    );
  }

  const elevations = new Set(q.reports.map((r) => r.attestation.elevationMilliDeg));
  if (elevations.size !== q.reports.length) {
    fail("quorum members reported identical geometry; they are not independent observations");
  }

  // a member that saw a different second must not be admitted
  const stray = JSON.parse(
    readFileSync(join(root, "vectors/frames/handover-002.json"), "utf8"),
  );
  try {
    runQuorum({
      members: [members[0]!, { capture: stray, station: stray.station, operator: operatorFor("MERIDIAN-04") }],
      catalog,
      domain,
    });
    fail("a quorum spanning two different seconds was accepted");
  } catch (e) {
    const message = (e as Error).message;
    if (!/disagrees on the second/.test(message)) fail(`quorum rejected for the wrong reason: ${message}`);
    ok(`quorum rejects a member from another second: ${message}`);
  }
}

console.log("\nUnit tests");
execSync("pnpm test", { cwd: root, stdio: "inherit" });

console.log("\nFoundry on-chain verification");
try {
  if (!existsSync(join(root, "contracts/lib/forge-std"))) {
    execSync("forge install foundry-rs/forge-std", { cwd: join(root, "contracts"), stdio: "inherit" });
  }
  execSync("forge test", { cwd: join(root, "contracts"), stdio: "inherit" });
} catch {
  fail("forge test failed");
}

console.log(`
RESULT  positive=${passed}  negative=${rejected}  quorum=3 stations  forge=pass
        pipeline closed: gRPC JSON → ASN filter → SGP4 boresight match → catalog commitment
                       → EIP-712 → BSC quorum verifier
`);
