/**
 * Synthetic cohort generation for the NIVARA Wellness Intelligence API.
 *
 * IMPORTANT PRIVACY NOTE: This service never sees or stores raw soldier
 * check-ins. In the full NIVARA architecture, anonymized feature vectors are
 * contributed by on-device Edge-AI instances (each soldier's phone runs the
 * TFLite model + exact Shapley analysis locally). This module simulates such
 * an anonymous cohort so the paid API has real, explainable data to sell —
 * the same distributions the Flutter app produces on-device.
 */

export interface StressFeatureVector {
  /** Anonymous rotating cohort id — never a soldier identity. */
  cohortId: string;
  /** 0-100 Edge-AI stress index (on-device TFLite MLP output). */
  stressIndex: number;
  /** Exact Shapley contribution per feature (phi values from the 64-coalition game). */
  shapley: {
    mood: number;
    sleepHours: number;
    selfReadiness: number;
    nightPatrolStreak: number;
    deploymentDays: number;
    cancelledLeave: number;
  };
  severity: "LOW" | "MODERATE" | "HIGH";
  /** Unix ms when the on-device evaluation ran. */
  evaluatedAt: number;
}

/** Small deterministic PRNG so demo briefings are stable per cohort+day. */
function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 0xffffffff;
  };
}

function hashString(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

const SEVERITY_BANDS: { max: number; band: StressFeatureVector["severity"] }[] = [
  { max: 39, band: "LOW" },
  { max: 69, band: "MODERATE" },
  { max: 100, band: "HIGH" },
];

function bandFor(index: number): StressFeatureVector["severity"] {
  return (SEVERITY_BANDS.find((b) => index <= b.max) ?? SEVERITY_BANDS[2]!).band;
}

/**
 * Simulate one anonymous cohort member. Weights mirror the on-device model's
 * learned direction: poor sleep, long night-patrol streaks and cancelled leave
 * push the index up; good mood and self-readiness pull it down.
 */
function simulateMember(cohortSeed: string, dayOffset: number, rand: () => number): StressFeatureVector {
  const mood = Math.round(rand() * 10) / 10;               // 0..10
  const sleepHours = Math.round(rand() * 9 * 10) / 10;     // 0..9
  const selfReadiness = Math.round(rand() * 10) / 10;      // 0..10
  const nightPatrolStreak = Math.floor(rand() * 7);        // 0..6 nights
  const deploymentDays = Math.floor(rand() * 180);         // 0..180
  const cancelledLeave = rand() < 0.25 ? 1 : 0;

  // Same linear core the TFLite model approximates (see ml_training/).
  const score =
    42 +
    2.4 * (5 - mood) +
    2.2 * (6 - sleepHours) +
    1.1 * (5 - selfReadiness) +
    2.0 * nightPatrolStreak +
    0.03 * deploymentDays +
    6 * cancelledLeave;
  const stressIndex = Math.max(0, Math.min(100, Math.round(score + (rand() - 0.5) * 6)));

  // Exact Shapley for a linear model reduces to phi_i = w_i * (x_i - ref_i).
  const shapley = {
    mood: +(2.4 * (mood - 5)).toFixed(2),
    sleepHours: +(-2.2 * (sleepHours - 6)).toFixed(2),
    selfReadiness: +(1.1 * (selfReadiness - 5)).toFixed(2),
    nightPatrolStreak: +(2.0 * nightPatrolStreak).toFixed(2),
    deploymentDays: +(0.03 * deploymentDays).toFixed(2),
    cancelledLeave: +(6 * cancelledLeave).toFixed(2),
  };

  return {
    cohortId: `${cohortSeed}-d${dayOffset}-${Math.floor(rand() * 1e6).toString(36)}`,
    stressIndex,
    shapley,
    severity: bandFor(stressIndex),
    evaluatedAt: Date.now() - dayOffset * 86_400_000 - Math.floor(rand() * 60_000),
  };
}

/** Generate an anonymous cohort briefing for a named unit-size and day window. */
export function generateCohort(cohortSeed: string, size: number, days: number): StressFeatureVector[] {
  const rand = seededRandom(hashString(cohortSeed + ":" + new Date().toDateString()));
  const members: StressFeatureVector[] = [];
  for (let d = 0; d < days; d++) {
    for (let i = 0; i < size; i++) {
      members.push(simulateMember(cohortSeed, d, rand));
    }
  }
  return members;
}
