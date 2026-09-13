/**
 * NIVARA internal sync routes (protocol: nivara-sync/1) — FREE, no x402.
 *
 *   POST /sync/register       -> issue a device token (role + unit binding)
 *   POST /sync/contribute     -> soldier uploads anonymized batch (local-DP'd)
 *   GET  /sync/unit/:id/brief -> commander aggregate-only fetch (k>=5 gate)
 *   GET  /sync/stats          -> aggregate-only operational stats
 *
 * The payload contract is docs/sync_protocol.md §5.2. This module never logs
 * payloads and never persists per-contribution rows beyond the 24 h staging
 * TTL — see sync/store.ts for the full privacy contract.
 */
import { Hono } from "hono";
import type { Context } from "hono";
import {
  claimNonce,
  issueToken,
  stageContributions,
  buildBrief,
  stats,
  verifyToken,
  SYNC_PRIVACY_THRESHOLD,
  type CoarseFeatures,
  type Contribution,
  type SyncRole,
} from "./store.js";

const COARSENED_RANGES: Record<keyof CoarseFeatures, { min: number; max: number }> = {
  mood: { min: 0, max: 5 },
  sleepHours: { min: 0, max: 16 },
  selfReadiness: { min: 0, max: 5 },
  nightPatrolStreak: { min: 0, max: 60 },
  deploymentDays: { min: 0, max: 730 },
  cancelledLeave: { min: 0, max: 1 },
};

function badRequest(c: Context, error: string, hint?: string) {
  return c.json({ error, hint }, 400);
}

function sanitizeFeatures(raw: unknown): CoarseFeatures | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const out = {} as CoarseFeatures;
  for (const key of Object.keys(COARSENED_RANGES) as (keyof CoarseFeatures)[]) {
    const v = Number(r[key]);
    if (!Number.isFinite(v)) return null;
    const { min, max } = COARSENED_RANGES[key];
    out[key] = Math.min(max, Math.max(min, v)) as never;
  }
  return out;
}

function sanitizeContribution(raw: unknown): Contribution | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const contributionId = typeof r.contributionId === "string" ? r.contributionId.slice(0, 64) : null;
  const stressIndex = Number(r.stressIndex);
  const features = sanitizeFeatures(r.features);
  if (!contributionId || !Number.isFinite(stressIndex) || !features) return null;
  const shapley: Record<string, number> = {};
  if (typeof r.shapley === "object" && r.shapley !== null) {
    for (const [k, v] of Object.entries(r.shapley as Record<string, unknown>)) {
      const n = Number(v);
      if (Number.isFinite(n)) shapley[k.slice(0, 32)] = n;
    }
  }
  const windowStart = typeof r.windowStart === "string" ? r.windowStart : new Date().toISOString();
  const windowEnd = typeof r.windowEnd === "string" ? r.windowEnd : windowStart;
  return {
    contributionId,
    stressIndex: Math.min(100, Math.max(0, stressIndex)),
    features,
    shapley,
    windowStart,
    windowEnd,
  };
}

export const syncRoutes = new Hono();

// ── POST /sync/register — device token issuance (auth only, data-free) ──
syncRoutes.post("/register", async (c) => {
  const body = await c.req.json().catch(() => null);
  const role = (body as { role?: unknown } | null)?.role;
  const unitId = String((body as { unitId?: unknown } | null)?.unitId ?? "").trim().toUpperCase();
  if (role !== "soldier" && role !== "commander") {
    return badRequest(c, "role must be 'soldier' or 'commander'");
  }
  if (!unitId || unitId.length > 32) return badRequest(c, "unitId is required (<=32 chars)");
  const deviceToken = issueToken(role as SyncRole, unitId);
  // Token appears here exactly once — it is never logged with payloads.
  return c.json({ protocol: "nivara-sync/1", deviceToken, role, unitId });
});

// ── POST /sync/contribute — soldier batch upload (anonymized, local-DP'd) ──
syncRoutes.post("/contribute", async (c) => {
  const device = verifyToken(c.req.header("authorization"));
  if (!device) return c.json({ error: "UNAUTHORIZED", hint: "POST /sync/register first" }, 401);
  if (device.role !== "soldier") {
    return c.json({ error: "FORBIDDEN", hint: "only soldier devices contribute" }, 403);
  }

  const body = await c.req.json().catch(() => null);
  const b = body as
    | { protocol?: unknown; windowId?: unknown; windowNonce?: unknown; contributions?: unknown }
    | null;
  if (!b || b.protocol !== "nivara-sync/1") return badRequest(c, "protocol must be 'nivara-sync/1'");
  const windowId = typeof b.windowId === "string" ? b.windowId.slice(0, 32) : null;
  const windowNonce = typeof b.windowNonce === "string" ? b.windowNonce.slice(0, 64) : null;
  if (!windowId || !windowNonce) return badRequest(c, "windowId and windowNonce are required");

  // Replay defense (T6): (token, windowId, nonce) is single-use.
  if (!claimNonce(c.req.header("authorization") ?? "", windowId, windowNonce)) {
    return c.json({ error: "REPLAY_DETECTED", hint: "windowNonce already used for this window" }, 409);
  }

  if (!Array.isArray(b.contributions) || b.contributions.length === 0) {
    return badRequest(c, "contributions must be a non-empty array");
  }
  if (b.contributions.length > 100) return badRequest(c, "max 100 contributions per batch");

  const contributions: Contribution[] = [];
  for (const raw of b.contributions) {
    const sanitized = sanitizeContribution(raw);
    if (!sanitized) return badRequest(c, "invalid contribution shape", "see docs/sync_protocol.md §5.2");
    contributions.push(sanitized);
  }

  // NOTE: the token is used for the auth decision above and then dropped —
  // stageContributions binds data to unitId only, never to the token.
  const result = stageContributions(device.unitId, contributions);
  return c.json({
    protocol: "nivara-sync/1",
    accepted: result.accepted,
    unitId: device.unitId,
    unitContributions24h: result.unitContributions,
    // k-gate status is reported so the soldier UI can explain why the unit
    // brief may still be suppressed for the commander.
    privacyGate: {
      threshold: SYNC_PRIVACY_THRESHOLD,
      met: result.unitContributions >= SYNC_PRIVACY_THRESHOLD,
    },
  });
});

// ── GET /sync/unit/:id/brief — commander aggregate-only fetch ──
syncRoutes.get("/unit/:unitId/brief", async (c) => {
  const device = verifyToken(c.req.header("authorization"));
  if (!device) return c.json({ error: "UNAUTHORIZED", hint: "POST /sync/register first" }, 401);
  if (device.role !== "commander") {
    return c.json({ error: "FORBIDDEN", hint: "only commander devices fetch briefs" }, 403);
  }
  const unitId = c.req.param("unitId").trim().toUpperCase();
  const days = Math.min(Math.max(parseInt(c.req.query("days") || "7", 10) || 7, 1), 30);

  const brief = buildBrief(unitId, days);
  if (!brief) {
    // k-anonymity gate: no aggregate exists below 5 contributors (T3).
    return c.json(
      {
        error: "PRIVACY_THRESHOLD",
        requiredContributors: SYNC_PRIVACY_THRESHOLD,
        unitId,
      },
      451
    );
  }
  return c.json(brief);
});

// ── GET /sync/stats — counts only, never payloads ──
syncRoutes.get("/stats", (c) => {
  const device = verifyToken(c.req.header("authorization"));
  if (!device) return c.json({ error: "UNAUTHORIZED" }, 401);
  return c.json({ protocol: "nivara-sync/1", ...stats() });
});
