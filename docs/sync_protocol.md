# NIVARA Sync Protocol — Design Document

**Status:** Design (v1, pre-implementation)
**Scope:** The *internal* (free) data path between soldier devices, the NIVARA sync
service, and commander devices. The *external* paid path (x402 Wellness Intelligence
API, Algorand USDC via GoPlausible facilitator) is specified separately and consumes
only the aggregates this protocol produces.

---

## 1. Why this exists

NIVARA is offline-first: every soldier's check-ins, Edge-AI stress scores, and Shapley
attributions live in the local encrypted vault (`database_helper.dart` explicitly notes
"All data stays on-device until an explicit sync phase"). That sync phase is this
document.

The commander must be able to answer *"how is my unit actually doing?"* — which is
impossible if every phone is an island. But the answer must never cost a soldier their
privacy. This protocol is the narrow, consent-based bridge between those two
requirements.

**The one-sentence rule:** the soldier's *phone* computes everything; the *server*
aggregates anonymized numbers; the *commander* sees only differentially-private
aggregates — and every external re-use of those aggregates is a paid, on-chain x402
event.

---

## 2. Actors and trust boundaries

```
┌──────────────────────┐          ┌──────────────────────┐
│ SOLDIER DEVICE       │          │ COMMANDER DEVICE     │
│  offline always      │          │  same Flutter app,   │
│  Edge-AI + Shapley   │          │  commander role      │
│  local vault         │          │  local audit log     │
└─────────┬────────────┘          └──────────▲───────────┘
          │ (1) opt-in sync window           │ (3) fetch aggregate brief
          │     TLS + device token           │     TLS + device token
          ▼                                  │
┌────────────────────────────────────────────┴───────────┐
│ NIVARA SYNC SERVICE (extension of x402-service)        │
│  • accepts anonymized feature vectors only             │
│  • folds them into per-unit daily aggregates           │
│  • discards per-contribution rows after aggregation    │
│  • NO raw payload logging, NO IP retention             │
└────────────────────────────────────────────────────────┘
          │ (4) aggregates feed…
          ▼
┌────────────────────────────────────────────────────────┐
│ x402 WELLNESS INTELLIGENCE API (already built)         │
│  paid endpoints → GoPlausible facilitator → Algorand   │
└────────────────────────────────────────────────────────┘
```

| Actor | Trusted with | NOT trusted with |
|---|---|---|
| Soldier device | Its own vault, keys, opt-in choice | — |
| Sync service | Anonymized vectors, unit bucketing | Identity, raw longitudinal history, exact timestamps |
| Commander device | Aggregates, its own audit log | Any soldier-level row, ever |
| External consumers (x402) | Cohort-level DP aggregates only | Unit-level operational data, any soldier data |

---

## 3. Threat model (what we defend against)

| # | Adversary / attack | Defense in this protocol |
|---|---|---|
| T1 | **Curious server operator** reads who reported what | No identity in payload; rotating `contributionId` per window; unit binding only; server discards per-contribution rows ≤24 h after aggregation |
| T2 | **Soldier re-identification by linkage** (server correlates contributions across windows into a personal profile) | New random `contributionId` every sync; coarsened timestamps (day granularity); feature coarsening (§5.3); no device fingerprint in payload |
| T3 | **Curious commander** wants an individual's data | Server API has *no* per-soldier endpoint by construction; app-side k-anonymity block (unit < 5 contributors ⇒ suppressed) — same threshold the commander UI already enforces |
| T4 | **Differencing / averaging attack** (query the same aggregate many times, average away the noise) | **Stable DP releases** — mirrors `DatabaseHelper`'s existing design: one noise draw per (unit, data-version), reused until data changes; documented per-release ε and a daily ε budget per unit |
| T5 | **Network observer** | TLS only; no per-soldier long-lived identifiers on the wire; sync is a short batch, not a stream |
| T6 | **Replay / injection** of fake contributions | Device token + monotonic window counter; server rejects stale/duplicated window nonces |
| T7 | **Server breach** | Nothing worth stealing: anonymized vectors expire in 24 h; aggregates are DP-noised already; no keys, no passcodes, no PII |
| T8 | **Timing correlation** (upload moment ≈ who's on shift) | Sync windows are user-triggered, batched (all unsynced rows in one request), never automatic on check-in |

Explicit non-goals (documented so nobody assumes them): no anonymity-network cover
traffic, no defense against a compromised soldier device, no protection of
*aggregate-level* operational secrecy (the unit's average stress is, by design,
something the commander is supposed to know).

---

## 4. What never leaves the phone

1. **Identity in any form** — `userId`, name, passcode material, vault keys.
2. **Per-person longitudinal history** — the server must never be able to reconstruct
   one soldier's check-in sequence (see T2 defenses).
3. **Exact timestamps** — only a coarse window label (`windowStart`/`windowEnd` at day
   granularity) is sent.
4. **Free-form context / notes** — nothing of the kind exists in the app, and nothing
   of the kind may be added to the sync payload.
5. **Attribution beyond the aggregate use** — Shapley maps are uploaded *per contribution*
   but consumed only as pooled sums (identity-free by construction, as the app's
   `buildCommanderAttributionSummary` already guarantees on-device).

## 5. What DOES leave the phone (the contribution payload)

### 5.1 Source data — exactly what the app already computes

Everything in the payload already exists on-device at check-in time:

- **Stress index** — the TFLite Edge-AI output (0–100).
- **Feature vector** — the 6 canonical features from `stressFeatures()`:
  `mood`, `sleepHours`, `selfReadiness`, `nightPatrolStreak`, `deploymentDays`,
  `cancelledLeave` (0/1).
- **Shapley attribution** — the per-check-in `Map<String, double>` (feature → points of
  stress) computed by `exactShapleyValues`.
- **Operational context** — the same three numbers the soldier self-declares and that
  are *already* inputs to the model.

No new data is invented for sync. The payload is a projection of what the phone knows.

### 5.2 Payload shape

```jsonc
POST /sync/contribute            // internal, FREE — no x402 payment
{
  "protocol": "nivara-sync/1",
  "unitId": "ALPHA-1",           // required for bucketing; the one non-anonymous field
  "deviceToken": "<opaque, issued at registration>",   // auth only, never stored with data
  "windowId": "2026-09-13",      // day-granularity bucket the batch belongs to
  "windowNonce": "a41f...",      // replay protection (T6)
  "contributions": [
    {
      "contributionId": "c_9f2c81a0e4",     // fresh random per check-in — never reused
      "stressIndex": 62.0,                   // locally DP-noised (§5.4)
      "features": {
        "mood": 2.0,
        "sleepHours": 5.5,
        "selfReadiness": 3.0,
        "nightPatrolStreak": 4,
        "deploymentDays": 120,
        "cancelledLeave": 1
      },
      "shapley": { "sleepHours": 12.5, "mood": -8.0, "cancelledLeave": 3.0 },
      "windowStart": "2026-09-12T00:00:00Z", // coarsened: day granularity only
      "windowEnd":   "2026-09-12T23:59:59Z"
    }
    // …all unsynced check-ins since the last successful sync, batched
  ]
}
```

Design decisions:

- **Batched, user-triggered.** One request carries every `check_ins` row with
  `synced = 0` (the column already exists, schema v1, never set). Sync is a discrete
  event the soldier starts — never an automatic background push the moment a check-in
  lands (T8).
- **`contributionId` rotation.** Server cannot join two windows' contributions into a
  trajectory (T2). The `synced` flag is set on success so a retry re-sends only failed
  rows; a retried row keeps its original `contributionId` for exactly one retry window,
  then the device regenerates it.
- **`deviceToken` is authentication only.** The server validates it, then it must not
  be persisted alongside contribution data (no join key between the auth table and the
  aggregate store).

### 5.3 Feature coarsening (before serialization, on-device)

Raw slider precision is a linkage aid (a lone soldier with `sleepHours = 5.73` is
identifiable across windows). Coarsen on-device, before upload:

| Feature | Uploaded precision |
|---|---|
| `mood` | 0.5 steps |
| `sleepHours` | 0.5 h steps |
| `selfReadiness` | 0.5 steps |
| `nightPatrolStreak` | integer (already) |
| `deploymentDays` | nearest 5 days |
| `cancelledLeave` | 0/1 (already) |

### 5.4 Two-layer differential privacy

The app already ships a Laplace mechanism (`differentiallyPrivateAverage`,
`laplaceNoise`, ε = 1.5, bounded [0, 100] stress index). The protocol keeps the noise
**local** and adds a **central** layer:

1. **Local DP (device, per contribution):** the uploaded `stressIndex` gets one Laplace
   draw (ε = 1.5, sensitivity 100) applied *by the phone*. The server never sees an
   exact per-soldier index — even a malicious server can't leak it.
2. **Central DP (server, per release):** every aggregate released to a commander (or
   the x402 exchange) applies the stable-release rule (§T4): one noise draw per
   `(unitId, data-version)`, cached and reused; fresh draw only when new contributions
   change the underlying data. Averaging repeated fetches recovers *the noisy release*,
   never the raw mean.

Both layers use the same parameters as the app today (ε = 1.5), so the judge-facing
claim is simple: *"the same DP math that runs in the commander dashboard is applied
twice — once on the phone, once at the release point."*

### 5.5 The k-anonymity gate

The server refuses to maintain (and the commander app refuses to display) any unit
aggregate with **fewer than 5 contributors in the window** — the same
`squadPrivacyThreshold = 5` the commander UI and the paid briefings already use. A
lone soldier's upload sits in the store until the unit crosses the threshold; nothing
is ever released about a unit of 1–4.

---

## 6. Server-side rules (the sync service)

1. **Stateless per-contribution handling.** On receipt: validate token + nonce +
   schema → fold each contribution into `unit_daily_aggregate[windowId][unitId]`
   (running sums/counters for each feature, stress index, and pooled Shapley) → mark
   the batch accepted. Per-contribution rows live in a short-lived staging table with a
   **24 h TTL** and are never queried again after folding.
2. **No payload logging.** Request logs record endpoint, size, and status only. No IPs
   at rest. `deviceToken` appears in logs only as a salted hash, never joined to data.
3. **Aggregate-only read path.** The read API (§7) has no route that can express
   "give me soldier X" or "give me one contribution". The staging table is not exposed.
4. **Replay defense.** `(deviceToken, windowNonce)` must be unique; stale windows
   (older than 7 days) are rejected outright.
5. **Aggregates are the x402 exchange's raw material.** The paid cohort briefings
   eventually switch from the current seeded generator (`handlers/cohort.ts`) to these
   real aggregates, with unit names never leaving the service boundary — external
   consumers get cohort-level data with rotating cohort ids, exactly as the existing
   `privacy` block in the briefing responses already promises.

---

## 7. Commander fetch (read path)

```jsonc
GET /sync/unit/ALPHA-1/brief?days=7      // internal, FREE — commander app only
Authorization: Bearer <commander device token>

200 OK
{
  "protocol": "nivara-sync/1",
  "unitId": "ALPHA-1",
  "contributors": 12,                     // if < 5 → 451 Unavailable (see below)
  "windowDays": 7,
  "dp": { "epsilon": 1.5, "layers": ["local-device", "central-release"], "stable": true },
  "stressIndex": { "mean": 58.3, "bands": { "LOW": 5, "MODERATE": 5, "HIGH": 2 } },
  "features": {
    "mood": { "mean": 2.4, "pctLow": 0.25 },
    "sleepHours": { "mean": 5.6, "pctLow": 0.33 },
    "selfReadiness": { "mean": 2.9, "pctLow": 0.17 }
  },
  "pooledShapley": [ { "feature": "sleepHours", "pooledPhi": 41.2 }, … ],
  "trend": [ { "day": -1, "dpAverage": 57.1, "contributors": 12 }, … ],
  "generatedAt": "2026-09-13T08:30:00Z",
  "dataVersion": "u1:2026-09-13:04"       // ties the stable DP release to the data
}

451 Unavailable For Legal Reasons (privacy threshold)
{ "error": "PRIVACY_THRESHOLD", "requiredContributors": 5, "currentContributors": 3 }
```

Guarantees:

- **No per-soldier field exists in the response** — the commander app renders exactly
  what it renders today (`CommanderOverviewCard`, trend, pooled Shapley), fed by this
  payload instead of local SQLite when synced data is newer.
- **Staleness is explicit.** The payload carries `generatedAt` and per-window
  contributor counts; the commander UI labels synced data as "as of …" — honesty about
  offline reality is a feature, not a bug.
- **Every fetch is audit-logged on the commander's device** — the existing append-only
  `audit_log` entry pattern (`actor_id`, `COMMANDER_VIEW_SYNCED`, unit, dataVersion)
  extends what `CommanderScreen` already does for local views, preserving the app's
  "every access is logged" invariant.
- **Suppression is graceful.** The 451 path maps to the existing
  `CommanderPrivacyBlocked` widget — small units simply show the privacy block, same as
  today's local behavior.

---

## 8. Identity-free authentication (device tokens)

Minimal scheme, sufficient for the demo and honest about its limits:

- At registration, each device generates an Ed25519 keypair locally (same crypto stack
  the x402 client uses). The public key registers with the sync service; the server
  returns an opaque `deviceToken` bound to `role` (soldier/commander) and `unitId`.
- Requests carry the token; contributions additionally carry a signature over
  `(windowId, windowNonce, payload hash)` so a stolen token can't rewrite history.
- **Limitation (documented):** tokens are pseudonymous, not anonymous — the server can
  see *that* a device synced. It cannot see *what* beyond the anonymized payload, and
  tokens are stored hashed, never joined to contribution data. Full metadata-anonymity
  (mix networks etc.) is out of scope and listed in §9.

---

## 9. Consent UX (soldier side)

Sync is opt-in and legible, or it isn't shipped:

- A **"Wellness Exchange & Sync"** section with a master toggle (off by default) and a
  plain-language explainer: *"Your score and check-in numbers can be shared — without
  your name, account, or device — so your commander sees the whole unit's wellbeing.
  Raw data always stays on this phone."*
- **Per-sync confirmation** on the soldier's first upload (and optionally every N
  uploads): shows exactly which fields will be sent, with the anonymization summary.
- **Payment history / contribution ledger** in the same screen, shared with the x402
  exchange work: the soldier can see (a) what they've contributed (anonymized), and —
  once the revenue-share roadmap item lands — (b) micropayments their anonymized
  contributions earned via x402.

---

## 10. Demo flow this enables (two devices)

```
SOLDIER PHONE                                  COMMANDER PHONE
─────────────                                  ───────────────
1. Register (role: soldier, unit ALPHA-1)      1. Register (role: commander, ALPHA-1)
2. Daily check-in → Edge-AI score + Shapley
   stored in vault, synced = 0
3. Wi-Fi at base camp → "Sync now"
   │  payload per §5.2 (anonymized, batched,
   │  DP-noised, fresh contributionId)
   ▼
                                    ┌─ NIVARA sync service folds into
                                    │  ALPHA-1 aggregates (k ≥ 5 gate)
                                    ▼
                                               2. Commander portal → "Refresh"
                                                  GET /sync/unit/ALPHA-1/brief
                                                  → unit overview, trend, pooled
                                                    Shapley — "as of 08:30"
                                               3. Every view audit-logged locally;
                                                  if the unit later feeds the paid
                                                  exchange → x402 USDC settlement
                                                  visible on lora.algokit.io
```

---

## 11. Implementation checklist (maps to existing code)

| Step | Touches | Notes |
|---|---|---|
| Sync payload model + coarsening + local DP on device | `lib/core/sync/*` (new), reads `check_ins`, `stressFeatures()` | Sets `synced = 1` on success |
| `POST /sync/contribute` + staging + aggregation | `x402-service/` new `sync/` module (Hono routes, no x402 middleware) | 24 h TTL, no payload logs, nonce store |
| `GET /sync/unit/:id/brief` + stable central DP release | same module; reuse ε/params from `briefings.ts` | k ≥ 5 gate → 451 |
| Device token registration | `x402-service/` `auth/` module; Ed25519 via existing crypto deps | Hashed at rest |
| Commander brief rendering + "as of" + 451 → privacy block | `features/commander/*` | Reuses `CommanderPrivacyBlocked` |
| Opt-in toggle + explainer + first-sync confirmation | new `features/exchange/` (shared with x402 exchange screen) | Off by default |
| Local audit entries for sync events | `database_helper.logAudit` | `SYNC_UP`, `COMMANDER_VIEW_SYNCED` |
| Swap `cohort.ts` seeded generator → real aggregates (phase 2) | `handlers/briefings.ts` | Keep seeded mode as `?demo=1` for judges |

---

## 12. Roadmap honesty (what we are NOT building)

- **Mix-network metadata protection** — out of scope; documented as future work.
- **Secure aggregation (crypto) instead of trust-the-server aggregation** — a v2
  candidate; the 24 h TTL + central DP + k-gate is the v1 stance.
- **Revenue share to soldiers** — x402 makes it trivial later (per-call USDC splits);
  protocol reserve: aggregates carry `dataVersion` so provenance ("this briefing
  included ALPHA-1 contributions") is traceable for payouts without identities.
- **Multi-server federation** — single sync service for the demo; the API is
  deliberately stateless-ish so a second region is config, not redesign.
