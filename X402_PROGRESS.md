# NIVARA × x402 on Algorand — session handoff

## Where we are

**Done and verified:**

- `nivara_app/x402-service/` — complete TypeScript backend implementing x402 on **Algorand Testnet** via the **GoPlausible facilitator**
  - `index.ts` — Hono server with `paymentMiddleware` from `@x402-avm/hono`, `x402ResourceServer` from `@x402-avm/core/server`, `ExactAvmScheme` (AVM exact scheme) from `@x402-avm/avm/exact/server`
  - Endpoints: `GET /api/nivara/stress-briefing` ($0.01) and `GET /api/nivara/unit-briefing` ($0.05), plus public `/health` and `/info`
  - `npm install` done, `tsc --noEmit` passes clean
  - 402 flow **tested live** against the real facilitator — correct `amount: "10000"` (0.01 USDC), `asset: 10458941`, `feePayer` present in `extra` (gasless flow works)
  - `scripts/setup.ts` — generates payee + client testnet accounts into `.env`
  - `scripts/optin.ts` — USDC opt-in for both accounts (run after funding)
  - `scripts/verify_settlement.ts` — reads testnet indexer, prints LoRA links for each settlement
  - `client/client.ts` — full x402 agent client (`wrapFetchWithPayment`) that does 402 → build axfer → sign → retry

**Two testnet accounts are generated and sitting in `nivara_app/x402-service/.env` (DO NOT commit):**

| Role | Address | Needs |
|---|---|---|
| Payee (receives USDC) | `LB6PLNZMVD67EEQYHOH4O6L6XJY425VI6Z2HZNYJYS626YDWC6VJUW64PA` | ~0.3 ALGO |
| Client (pays) | `ITILCUE5ZUQYRGCXKTPNXJQOKUEGWB6UHBCIRDRU3LQ3TQ3WYUMMJUOVYQ` | ~0.3 ALGO + ~0.1 testnet USDC |

👉 **You need to fund these from https://dispenser.testnet.algorand.network/ (needs GitHub login).** ALGO first, then USDC on the client.

**Bugs found and fixed during live testing (note for write-up):**
- Price must be passed as a dollar string (`"$0.01"`), not pre-converted atomic units — the AVM scheme re-parses it and 10000 atomic → $10,000 otherwise.
- `PORT=0` leaked from the ambient shell env and dotenv didn't override; fixed with `config({ override: true })`.

## Remaining work

1. **Fund the two testnet accounts** (only manual step, needs your GitHub login).
2. `npm run optin` in `x402-service/` (after funding).
3. `npm start` + `npm run client:triple` — capture LoRA tx links as evidence.
4. **Flutter side (not started):**
   - `pubspec.yaml` already has `http`, `pointycastle`, `convert` added and `pub get` done
   - Write Dart x402 client: canonical msgpack encoder → axfer tx builder → Ed25519 signer → 402 parser → X-PAYMENT retry
   - `DatabaseHelper` migration v5: `payments` table + `key_value` settings table
   - "Wellness Exchange" screen in the app with payment history + LoRA links
   - Unit tests against golden vectors generated via algokit-utils (node)
5. Final README for judges: architecture diagram, demo script, LoRA evidence links.

## Quick reference

- Facilitator: `https://facilitator.goplausible.xyz` (verified live, Algorand testnet "up")
- USDC testnet ASA: `10458941` (6 decimals)
- Algorand testnet CAIP-2: `algorand:SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=`
- LoRA explorer: `https://lora.algokit.io/testnet`
- Run server: `cd nivara_app/x402-service && npm start` → `curl localhost:4021/api/nivara/stress-briefing` should give 402
