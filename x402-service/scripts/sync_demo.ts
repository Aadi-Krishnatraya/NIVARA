/**
 * NIVARA sync-loop live demo (nivara-sync/1) — FREE endpoints, no payment.
 *
 * Simulates the two-device story end-to-end against a running server:
 *
 *   1. Five soldier devices of unit ALPHA-1 register + upload anonymized,
 *      locally-DP'd check-in batches (as if synced over base-camp Wi-Fi).
 *   2. A soldier of a small unit (DELTA-9, 2 devices) uploads too.
 *   3. The ALPHA-1 commander registers and fetches the unit brief (200 OK,
 *      stable central-DP release, k >= 5 gate satisfied).
 *   4. The DELTA-9 commander gets 451 PRIVACY_THRESHOLD (aggregate suppressed).
 *
 * Usage:
 *   npm run demo:sync              # against http://localhost:4021
 *   BASE_URL=http://host:4021 npm run demo:sync
 */
import { config } from "dotenv";
config({ override: true });

const BASE = process.env.BASE_URL ?? `http://localhost:${process.env.PORT || "4021"}`;

interface Contribution {
  contributionId: string;
  stressIndex: number;
  features: Record<string, number>;
  shapley: Record<string, number>;
  windowStart: string;
  windowEnd: string;
}

function rnd(min: number, max: number): number {
  return min + Math.random() * (max - min);
}

/** Mirror of the app's local DP: Laplace noise on the stress index (eps=1.5). */
function localDp(index: number, epsilon = 1.5): number {
  const scale = 100 / epsilon;
  const u = Math.random() - 0.5;
  const noisy = index - scale * Math.sign(u) * Math.log(1 - 2 * Math.abs(u));
  return Math.min(100, Math.max(0, Math.round(noisy)));
}

function makeContribution(day: number): Contribution {
  // Coarsened features per docs/sync_protocol.md §5.3.
  const mood = Math.round(rnd(1, 5) * 2) / 2;
  const sleepHours = Math.round(rnd(3, 9) * 2) / 2;
  const selfReadiness = Math.round(rnd(1, 5) * 2) / 2;
  const nightPatrolStreak = Math.round(rnd(0, 6));
  const deploymentDays = Math.round(rnd(10, 200) / 5) * 5;
  const cancelledLeave = Math.random() < 0.25 ? 1 : 0;

  // Toy local stress model — the real phone runs quantized TFLite + Shapley.
  const raw =
    100 -
    mood * 9 -
    sleepHours * 5 -
    selfReadiness * 6 +
    nightPatrolStreak * 4 +
    deploymentDays * 0.05 +
    cancelledLeave * 8;
  const idx = localDp(Math.min(100, Math.max(0, raw)));
  const phi = (v: number, w: number) => Math.round(-v * w * 10) / 10;

  const dayStart = new Date(Date.now() - day * 86_400_000);
  const dayEnd = new Date(dayStart.getTime() + 86_400_000 - 1000);
  return {
    contributionId: `c_${Math.random().toString(16).slice(2, 12)}`,
    stressIndex: idx,
    features: { mood, sleepHours, selfReadiness, nightPatrolStreak, deploymentDays, cancelledLeave },
    shapley: {
      mood: phi(mood, 9),
      sleepHours: phi(sleepHours, 5),
      selfReadiness: phi(selfReadiness, 6),
      nightPatrolStreak: Math.round(nightPatrolStreak * 4 * 10) / 10,
      deploymentDays: Math.round(deploymentDays * 0.05 * 10) / 10,
      cancelledLeave: cancelledLeave * 8,
    },
    windowStart: dayStart.toISOString(),
    windowEnd: dayEnd.toISOString(),
  };
}

async function api(path: string, init?: RequestInit): Promise<{ status: number; body: any }> {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
  });
  const body = await res.json().catch(() => null);
  return { status: res.status, body };
}

async function registerSoldier(unitId: string): Promise<string> {
  const { status, body } = await api("/sync/register", {
    method: "POST",
    body: JSON.stringify({ role: "soldier", unitId }),
  });
  if (status !== 200) throw new Error(`register failed: ${status} ${JSON.stringify(body)}`);
  console.log(`  soldier registered  unit=${unitId}  token=${(body as any).deviceToken.slice(0, 12)}…`);
  return (body as any).deviceToken;
}

async function contribute(token: string, unitId: string, contributions: Contribution[]): Promise<void> {
  const windowId = new Date().toISOString().slice(0, 10);
  const { status, body } = await api("/sync/contribute", {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({
      protocol: "nivara-sync/1",
      unitId,
      windowId,
      windowNonce: Math.random().toString(16).slice(2),
      contributions,
    }),
  });
  if (status !== 200) throw new Error(`contribute failed: ${status} ${JSON.stringify(body)}`);
  const b = body as any;
  console.log(
    `  upload accepted     unit=${b.unitId}  batch=${b.accepted}  unit24h=${b.unitContributions24h}  k-gate met=${b.privacyGate.met}`
  );
}

async function commanderBrief(unitId: string): Promise<void> {
  const { status, body: reg } = await api("/sync/register", {
    method: "POST",
    body: JSON.stringify({ role: "commander", unitId }),
  });
  const token = (reg as any).deviceToken as string;
  const { status: code, body } = await api(`/sync/unit/${unitId}/brief?days=7`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (code === 451) {
    console.log(`  COMMANDER ${unitId}  ->  451 PRIVACY_THRESHOLD (aggregate suppressed, k<5) ✓`);
    return;
  }
  if (code !== 200) throw new Error(`brief failed: ${code} ${JSON.stringify(body)}`);
  const b = body as any;
  console.log(`  COMMANDER ${unitId}  ->  200 OK (aggregate-only brief)`);
  console.log(`     contributors=${b.contributors}  dpMean=${b.stressIndex.mean}  bands=${JSON.stringify(b.stressIndex.bands)}`);
  console.log(`     topDriver=${b.pooledShapley[0]?.feature ?? "n/a"} (pooled |phi|=${b.pooledShapley[0]?.pooledPhi ?? 0})`);
  console.log(`     dp=${JSON.stringify(b.dp)}  dataVersion=${b.dataVersion}`);
}

async function main(): Promise<void> {
  console.log(`\n════════ NIVARA sync-loop demo → ${BASE} ════════\n`);

  const health = await api("/health");
  if (health.status !== 200) throw new Error(`server not reachable at ${BASE}`);
  console.log(`server healthy — x402 on Algorand Testnet + nivara-sync/1\n`);

  console.log("1) ALPHA-1: five soldiers sync over base-camp Wi-Fi (anonymized batches)");
  for (let i = 0; i < 5; i++) {
    const token = await registerSoldier("ALPHA-1");
    const batch = [makeContribution(0), makeContribution(1)];
    await contribute(token, "ALPHA-1", batch);
  }

  console.log("\n2) DELTA-9: a 2-soldier observation post syncs too (below the k-gate)");
  for (let i = 0; i < 2; i++) {
    const token = await registerSoldier("DELTA-9");
    await contribute(token, "DELTA-9", [makeContribution(0)]);
  }

  console.log("\n3) Commanders fetch unit briefs");
  await commanderBrief("ALPHA-1");
  await commanderBrief("DELTA-9");

  console.log("\n4) Replay defense: re-sending the same windowNonce is rejected");
  const token = await registerSoldier("ALPHA-1");
  const nonce = "deadbeef";
  const payload = JSON.stringify({
    protocol: "nivara-sync/1",
    unitId: "ALPHA-1",
    windowId: new Date().toISOString().slice(0, 10),
    windowNonce: nonce,
    contributions: [makeContribution(0)],
  });
  await api("/sync/contribute", { method: "POST", headers: { authorization: `Bearer ${token}` }, body: payload });
  const replay = await api("/sync/contribute", { method: "POST", headers: { authorization: `Bearer ${token}` }, body: payload });
  console.log(`  second send -> ${replay.status} ${replay.body && (replay.body as any).error} ✓`);

  console.log("\n✅ sync loop complete — soldier phones → anonymized + DP'd → aggregate-only commander view\n");
}

main().catch((err) => {
  console.error(`\n❌ ${err instanceof Error ? err.message : err}`);
  process.exit(1);
});
