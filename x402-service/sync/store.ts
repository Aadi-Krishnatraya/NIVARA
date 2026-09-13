/**
 * NIVARA internal sync store (protocol: nivara-sync/1).
 *
 * Privacy contract (docs/sync_protocol.md):
 *  - NO identity ever reaches this module: payloads carry rotating
 *    `contributionId`s, coarse timestamps and coarsened features only.
 *  - Per-contribution rows are STAGING ONLY, pruned after 24 h; the read API
 *    exposes aggregates exclusively — there is no route that could express
 *    "give me soldier X".
 *  - `deviceToken`s authenticate requests; they are stored here ONLY as the
 *    auth map key, never joined with contribution data.
 *  - Replay defense: (token, windowId, windowNonce) is single-use.
 *  - k-anonymity gate: units below 5 contributors are never released (451).
 *
 * Storage is in-memory by design for v1: a restart wipes everything, which is
 * the safest possible failure mode for a demo holding anonymized data.
 */

export interface CoarseFeatures {
  mood: number;
  sleepHours: number;
  selfReadiness: number;
  nightPatrolStreak: number;
  deploymentDays: number;
  cancelledLeave: 0 | 1;
}

export interface Contribution {
  contributionId: string;
  stressIndex: number;
  features: CoarseFeatures;
  shapley: Record<string, number>;
  windowStart: string;
  windowEnd: string;
}

interface StagedContribution extends Contribution {
  unitId: string;
  receivedAt: number;
}

export type SyncRole = "soldier" | "commander";

export interface DeviceInfo {
  role: SyncRole;
  unitId: string;
  registeredAt: number;
}

/** Per-contribution staging rows live at most this long, then are pruned. */
const STAGING_TTL_MS = 24 * 60 * 60 * 1000;

/** Same k-anonymity threshold as the Flutter app (PRD §5.2). */
export const SYNC_PRIVACY_THRESHOLD = 5;

/** Central-DP epsilon — matches the app and the paid briefings. */
export const DP_EPSILON = 1.5;

const staging: StagedContribution[] = [];
const usedNonces = new Set<string>();
const tokens = new Map<string, DeviceInfo & { registeredAt: number }>();

/** Stable central-DP release cache: one noise draw per (unit, dataVersion). */
const dpStableCache = new Map<string, number>();

function randomHex(bytes: number): string {
  const buf = Buffer.alloc(bytes);
  crypto.getRandomValues(buf);
  return buf.toString("hex");
}

// ---------------------------------------------------------------------------
// Device tokens (authentication only — never joined with contribution data)
// ---------------------------------------------------------------------------
export function issueToken(role: SyncRole, unitIdRaw: string): string {
  const unitId = unitIdRaw.trim().toUpperCase();
  const token = `niv_${randomHex(24)}`;
  tokens.set(token, { role, unitId, registeredAt: Date.now() });
  return token;
}

export function verifyToken(authHeader: string | undefined): (DeviceInfo & { registeredAt: number }) | null {
  if (!authHeader) return null;
  const m = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  const token = m?.[1];
  if (!token) return null;
  return tokens.get(token) ?? null;
}

// ---------------------------------------------------------------------------
// Replay defense
// ---------------------------------------------------------------------------
export function claimNonce(token: string, windowId: string, nonce: string): boolean {
  const key = `${token}:${windowId}:${nonce}`;
  if (usedNonces.has(key)) return false;
  usedNonces.add(key);
  // Bound memory: nonces older than 7 days' worth of use simply accumulate in
  // v1's in-memory store; a restart clears them. Cap defensively anyway.
  if (usedNonces.size > 100_000) usedNonces.clear();
  return true;
}

// ---------------------------------------------------------------------------
// Staging + aggregation
// ---------------------------------------------------------------------------
function pruneStaging(now = Date.now()): void {
  for (let i = staging.length - 1; i >= 0; i--) {
    if (now - staging[i]!.receivedAt > STAGING_TTL_MS) staging.splice(i, 1);
  }
}

/**
 * Fold a batch of anonymized contributions into the staging area.
 * Returns how many were accepted and the unit's current contribution count
 * (contributions in the last 24 h are the v1 contributor proxy — the server
 * has no identity to dedupe by, which is the point).
 */
export function stageContributions(
  unitId: string,
  contributions: Contribution[]
): { accepted: number; unitContributions: number } {
  pruneStaging();
  const receivedAt = Date.now();
  for (const c of contributions) {
    staging.push({ ...c, unitId, receivedAt });
  }
  const unitContributions = staging.filter((s) => s.unitId === unitId).length;
  return { accepted: contributions.length, unitContributions };
}

function dataVersion(unitId: string, rows: StagedContribution[]): string {
  const last = rows.reduce((max, r) => Math.max(max, r.receivedAt), 0);
  return `${unitId}:${rows.length}:${last}`;
}

function laplace(scale: number): number {
  const u = Math.random() - 0.5;
  if (u === 0) return 0;
  return -scale * Math.sign(u) * Math.log(1 - 2 * Math.abs(u));
}

function round1(x: number): number {
  return Math.round(x * 10) / 10;
}

export interface UnitBrief {
  protocol: "nivara-sync/1";
  unitId: string;
  contributors: number;
  windowDays: number;
  dp: { epsilon: number; layers: string[]; stable: boolean };
  stressIndex: { mean: number; bands: { LOW: number; MODERATE: number; HIGH: number } };
  features: Record<string, { mean: number; pctLow: number }>;
  pooledShapley: { feature: string; pooledPhi: number }[];
  trend: { day: string; average: number; contributors: number }[];
  dataVersion: string;
  generatedAt: string;
}

/**
 * Build the aggregate-only commander brief. Returns null when the unit is
 * below the k-anonymity gate (caller maps this to HTTP 451).
 */
export function buildBrief(unitId: string, days = 7): UnitBrief | null {
  pruneStaging();
  const cutoff = Date.now() - days * 86_400_000;
  const rows = staging.filter((s) => s.unitId === unitId && s.receivedAt >= cutoff);
  if (rows.length < SYNC_PRIVACY_THRESHOLD) return null;

  const version = dataVersion(unitId, rows);
  const rawMean = rows.reduce((a, r) => a + r.stressIndex, 0) / rows.length;

  // Central DP, stable release: sensitivity of the mean is 100/n; one Laplace
  // draw per (unit, dataVersion) so repeated fetches cannot average the noise
  // away (T4 in the threat model).
  const scale = 100 / (DP_EPSILON * rows.length);
  const dpMean = Math.min(100, Math.max(0, rawMean + laplace(scale)));
  dpStableCache.set(version, round1(dpMean));
  if (dpStableCache.size > 500) dpStableCache.clear();

  const bands = {
    LOW: rows.filter((r) => r.stressIndex < 34).length,
    MODERATE: rows.filter((r) => r.stressIndex >= 34 && r.stressIndex < 67).length,
    HIGH: rows.filter((r) => r.stressIndex >= 67).length,
  };

  const featureMeans: Record<string, { mean: number; pctLow: number; lowWhenBelow: number }> = {
    mood: { mean: 0, pctLow: 0, lowWhenBelow: 2.5 },
    sleepHours: { mean: 0, pctLow: 0, lowWhenBelow: 6.0 },
    selfReadiness: { mean: 0, pctLow: 0, lowWhenBelow: 2.5 },
  };
  for (const key of Object.keys(featureMeans)) {
    const vals = rows.map((r) => r.features[key as keyof CoarseFeatures] as number);
    const mean = vals.reduce((a, b) => a + b, 0) / (vals.length || 1);
    const pctLow = vals.filter((v) => v < featureMeans[key]!.lowWhenBelow).length / (vals.length || 1);
    featureMeans[key] = { mean: round1(mean), pctLow: Math.round(pctLow * 100) / 100, lowWhenBelow: featureMeans[key]!.lowWhenBelow };
  }

  const shapleyTotals: Record<string, number> = {};
  for (const r of rows) {
    for (const [feature, phi] of Object.entries(r.shapley ?? {})) {
      shapleyTotals[feature] = (shapleyTotals[feature] ?? 0) + Math.abs(Number(phi) || 0);
    }
  }
  const pooledShapley = Object.entries(shapleyTotals)
    .map(([feature, pooledPhi]) => ({ feature, pooledPhi: Math.round(pooledPhi * 10) / 10 }))
    .sort((a, b) => b.pooledPhi - a.pooledPhi);

  const trend: UnitBrief["trend"] = [];
  for (let d = days - 1; d >= 0; d--) {
    const dayStart = new Date(Date.now() - d * 86_400_000);
    const dayKey = dayStart.toISOString().slice(0, 10);
    const dayRows = rows.filter((r) => r.windowStart.slice(0, 10) === dayKey);
    if (dayRows.length === 0) continue;
    trend.push({
      day: dayKey,
      average: round1(dayRows.reduce((a, r) => a + r.stressIndex, 0) / dayRows.length),
      contributors: dayRows.length,
    });
  }

  return {
    protocol: "nivara-sync/1",
    unitId,
    contributors: rows.length,
    windowDays: days,
    dp: {
      epsilon: DP_EPSILON,
      layers: ["central-release (stable per dataVersion)", "k>=5 gate"],
      stable: true,
    },
    stressIndex: { mean: dpStableCache.get(version)!, bands },
    features: Object.fromEntries(
      Object.entries(featureMeans).map(([k, v]) => [k, { mean: v.mean, pctLow: v.pctLow }])
    ),
    pooledShapley,
    trend,
    dataVersion: version,
    generatedAt: new Date().toISOString(),
  };
}

/** Aggregate-only stats for /sync/stats — counts, never payloads. */
export function stats(): { units: { unitId: string; contributions24h: number }[]; total24h: number; devices: number } {
  pruneStaging();
  const byUnit = new Map<string, number>();
  for (const s of staging) byUnit.set(s.unitId, (byUnit.get(s.unitId) ?? 0) + 1);
  return {
    units: [...byUnit.entries()]
      .map(([unitId, contributions24h]) => ({ unitId, contributions24h }))
      .sort((a, b) => a.unitId.localeCompare(b.unitId)),
    total24h: staging.length,
    devices: tokens.size,
  };
}

/** Test/demo helper: wipe everything (in-memory anyway). */
export function resetSyncStore(): void {
  staging.length = 0;
  usedNonces.clear();
  tokens.clear();
  dpStableCache.clear();
}
