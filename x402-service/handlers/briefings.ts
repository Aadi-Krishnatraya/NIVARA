/**
 * NIVARA Wellness Intelligence API — paid briefing handlers.
 *
 * These handlers run ONLY after the x402 middleware has verified (and the
 * facilitator has settled) an Algorand USDC payment for the request.
 */
import type { Context } from "hono";
import { generateCohort, type StressFeatureVector } from "./cohort.js";
import { PRICES } from "../config/network.js";

function mean(xs: number[]): number {
  if (xs.length === 0) return 0;
  return xs.reduce((a, b) => a + b, 0) / xs.length;
}

function round(x: number, digits = 1): number {
  const f = 10 ** digits;
  return Math.round(x * f) / f;
}

/** Laplace mechanism — mirrors DatabaseHelper.differentiallyPrivateAverage in the app. */
export function laplaceAverage(values: number[], epsilon = 1.5): number {
  if (values.length === 0) return 0;
  const sensitivity = 100 / values.length; // stress index bounded to [0, 100]
  const scale = sensitivity / epsilon;
  const u = Math.random() - 0.5;
  return round(mean(values) - scale * Math.sign(u) * Math.log(1 - 2 * Math.abs(u)));
}

/** Rank pooled Shapley risk drivers (anonymized, summed |phi| per feature). */
function pooledDrivers(members: StressFeatureVector[]): { feature: string; pooledPhi: number; direction: string }[] {
  const totals: Record<string, number> = {};
  for (const m of members) {
    for (const [feature, phi] of Object.entries(m.shapley)) {
      totals[feature] = (totals[feature] ?? 0) + Math.abs(phi);
    }
  }
  const direction = (feature: string): string =>
    ["sleepHours", "mood", "selfReadiness"].includes(feature) ? "protective-when-positive" : "risk-when-positive";
  return Object.entries(totals)
    .map(([feature, phi]) => ({ feature, pooledPhi: round(phi, 2), direction: direction(feature) }))
    .sort((a, b) => b.pooledPhi - a.pooledPhi);
}

/** Data-driven action playbook — recommendation follows the dominant driver. */
function playbook(drivers: { feature: string; pooledPhi: number }[]): { driver: string; recommendation: string } {
  const top = drivers[0]?.feature ?? "mood";
  const map: Record<string, string> = {
    mood: "Schedule unit morale activity and peer-support check-ins this week",
    sleepHours: "Rebalance night-patrol roster to protect consecutive sleep windows",
    selfReadiness: "Offer readiness counselling and workload review for flagged cohort",
    nightPatrolStreak: "Cap consecutive night patrols at 3 before mandatory rest day",
    deploymentDays: "Review mid-deployment rotation and rest opportunities",
    cancelledLeave: "Restore cancelled leave for high-accumulation personnel",
  };
  return { driver: top, recommendation: map[top] ?? "Continue routine monitoring" };
}

/**
 * GET /api/nivara/stress-briefing?cohort=<seed>&size=<n>&days=<d>
 * Anonymous Edge-AI stress index distribution + per-feature Shapley drivers.
 */
export function handleStressBriefing(c: Context) {
  const cohort = c.req.query("cohort") || "alpha-bravo";
  const size = Math.min(Math.max(parseInt(c.req.query("size") || "24", 10) || 24, 5), 200);
  const days = Math.min(Math.max(parseInt(c.req.query("days") || "7", 10) || 7, 1), 30);

  const members = generateCohort(cohort, size, days);
  const indices = members.map((m) => m.stressIndex);
  const drivers = pooledDrivers(members);

  const bands = {
    LOW: members.filter((m) => m.severity === "LOW").length,
    MODERATE: members.filter((m) => m.severity === "MODERATE").length,
    HIGH: members.filter((m) => m.severity === "HIGH").length,
  };

  return c.json({
    service: "NIVARA Wellness Intelligence",
    endpoint: "stress-briefing",
    privacy: {
      rawCheckinsExposed: false,
      identityExposure: "none — rotating anonymous cohort ids only",
      method: "on-device Edge-AI evaluation; only anonymized feature vectors leave the phone",
    },
    cohort: { seed: cohort, contributors: size, windowDays: days },
    stressIndex: {
      mean: round(mean(indices)),
      min: Math.min(...indices),
      max: Math.max(...indices),
      bands,
    },
    explainableRiskDrivers: drivers,
    topDriver: drivers[0] ?? null,
    price: `${PRICES.stressBriefing} USDC (x402, Algorand Testnet)`,
    generatedAt: new Date().toISOString(),
  });
}

/**
 * GET /api/nivara/unit-briefing?cohort=<seed>&size=<n>&days=<d>
 * Differentially-private aggregate + 7-day trend + action playbook.
 */
export function handleUnitBriefing(c: Context) {
  const cohort = c.req.query("cohort") || "alpha-bravo";
  const size = Math.min(Math.max(parseInt(c.req.query("size") || "24", 10) || 24, 5), 200);
  const days = Math.min(Math.max(parseInt(c.req.query("days") || "7", 10) || 7, 1), 30);

  const members = generateCohort(cohort, size, days);
  const byDay: { day: number; dpAverage: number; contributors: number }[] = [];
  for (let d = 0; d < days; d++) {
    const dayMembers = members.filter((m) => m.evaluatedAt >= Date.now() - (d + 1) * 86_400_000 && m.evaluatedAt < Date.now() - d * 86_400_000);
    byDay.push({
      day: -d,
      dpAverage: laplaceAverage(dayMembers.map((m) => m.stressIndex)),
      contributors: dayMembers.length,
    });
  }

  const drivers = pooledDrivers(members);
  const epsilon = 1.5;

  return c.json({
    service: "NIVARA Wellness Intelligence",
    endpoint: "unit-briefing",
    privacy: {
      differentialPrivacy: { epsilon, mechanism: "Laplace on bounded [0,100] index" },
      squadPrivacyThreshold: 5,
      identityExposure: "none — aggregates are DP-noised and pooled Shapley is identity-free",
    },
    cohort: { seed: cohort, contributors: size, windowDays: days },
    dpAverageStressIndex: laplaceAverage(members.map((m) => m.stressIndex), epsilon),
    trend7d: byDay,
    explainableRiskDrivers: drivers,
    playbook: playbook(drivers),
    auditNote: "Every paid view is settled on-chain via x402 — a verifiable audit trail of command access",
    price: `${PRICES.unitBriefing} USDC (x402, Algorand Testnet)`,
    generatedAt: new Date().toISOString(),
  });
}
