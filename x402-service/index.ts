/**
 * NIVARA Wellness Intelligence API — x402 resource server.
 *
 * Payment-protected endpoints using the x402 protocol on Algorand Testnet:
 *   - Client requests a briefing                    -> 402 Payment Required
 *   - Client builds + signs an Algorand USDC axfer  -> X-PAYMENT header
 *   - GoPlausible facilitator verifies + settles    -> on-chain USDC transfer
 *   - Server returns the paid briefing              -> 200 OK
 *
 * Wiring follows the x402-avm reference implementation:
 *   @x402-avm/hono paymentMiddleware + @x402-avm/core x402ResourceServer
 *   + @x402-avm/avm ExactAvmScheme (Algorand exact scheme via ASA transfer).
 */
import { config } from "dotenv";
// override: the service's own .env wins over any ambient shell env (e.g. a stray PORT=0)
config({ override: true });

import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { paymentMiddleware } from "@x402-avm/hono";
import { x402ResourceServer, HTTPFacilitatorClient } from "@x402-avm/core/server";
import type { ResourceServerExtension } from "@x402-avm/core/types";
import { ExactAvmScheme } from "@x402-avm/avm/exact/server";
import { ALGORAND_TESTNET_CAIP2 } from "@x402-avm/avm";
import { bazaarResourceServerExtension } from "@x402-avm/extensions";

import { createPaymentConfig, ENDPOINTS } from "./config/endpoints.js";
import { GOPLAUSIBLE_FACILITATOR_URL } from "./config/network.js";
import { handleStressBriefing, handleUnitBriefing } from "./handlers/briefings.js";
import { syncRoutes } from "./sync/routes.js";
import { captureSettlement, loraUrl, recentSettlements } from "./sync/settlements.js";

const avmAddress = process.env.AVM_ADDRESS;
const facilitatorUrl = process.env.FACILITATOR_URL || GOPLAUSIBLE_FACILITATOR_URL;
const port = parseInt(process.env.PORT || "4021", 10);

if (!avmAddress) {
  console.error(
    "❌ Missing required environment variables:\n" +
      "  - AVM_ADDRESS (Algorand address receiving USDC payments)\n" +
      `  - FACILITATOR_URL (optional, defaults to ${GOPLAUSIBLE_FACILITATOR_URL})`
  );
  process.exit(1);
}

console.log("\n" + "═".repeat(64));
console.log("  NIVARA WELLNESS INTELLIGENCE API  —  x402 on Algorand");
console.log("═".repeat(64));
console.log(`  Receiver (payTo) : ${avmAddress}`);
console.log(`  Facilitator      : ${facilitatorUrl}`);  console.log(`  Network          : Algorand Testnet (${ALGORAND_TESTNET_CAIP2})`);
  console.log(`  Sync protocol    : nivara-sync/1 (free internal endpoints at /sync/*)`);
  console.log(`  Port             : ${port}`);
console.log("═".repeat(64) + "\n");

// ── x402 resource server: routes payments through the GoPlausible facilitator ──
const facilitatorClient = new HTTPFacilitatorClient({ url: facilitatorUrl });
const x402Server = new x402ResourceServer(facilitatorClient)
  .register(ALGORAND_TESTNET_CAIP2, new ExactAvmScheme())
  .registerExtension(bazaarResourceServerExtension as unknown as ResourceServerExtension);

const app = new Hono();

// ── CORS: browsers/agents must be able to read x402 headers ──
app.use("*", async (c, next) => {
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS, PUT, DELETE, HEAD",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Expose-Headers": "*",
    "Access-Control-Max-Age": "86400",
  };
  if (c.req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }
  Object.entries(corsHeaders).forEach(([key, value]) => c.header(key, value));
  await next();
});

// ── Request logging ──
app.use("*", async (c, next) => {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${c.req.method} ${c.req.path}${c.req.header("x-payment") ? "  (X-PAYMENT present)" : ""}`);
  await next();
  console.log(`  -> ${c.res.status}`);
});

// ── Settlement capture: record x402 on-chain results for the exchange UI ──
// Runs only on the paid path; stores txid-level metadata (no payloads).
app.use("/api/nivara/*", async (c, next) => {
  await next();
  captureSettlement(c, `${c.req.method} ${c.req.path}`);
});

// ── FREE internal sync endpoints (nivara-sync/1) — mounted BEFORE the x402
//    middleware so no payment requirement can ever attach to them ──
app.route("/sync", syncRoutes);

// ── x402 payment middleware over the configured endpoints ──
const paymentConfig = createPaymentConfig(avmAddress);
console.log("Payment-protected endpoints:");
for (const [route, cfg] of Object.entries(paymentConfig)) {
  console.log(`  ${route}  —  ${cfg.accepts[0]!.price} USDC-atomic  —  ${cfg.description.slice(0, 72)}…`);
}
console.log();
app.use(paymentMiddleware(paymentConfig as never, x402Server));

// ── Paid routes (handlers run only after payment verification) ──
app.get("/api/nivara/stress-briefing", handleStressBriefing);
app.get("/api/nivara/unit-briefing", handleUnitBriefing);

// ── Public endpoints ──
app.get("/health", (c) =>
  c.json({
    status: "ok",
    service: "nivara-wellness-intelligence",
    x402: true,
    sync: "nivara-sync/1",
    chain: "algorand-testnet",
    facilitator: facilitatorUrl,
    uptime: process.uptime(),
  })
);

// ── Public settlement ledger: real Algorand txids + LoRA links (judge proof) ──
app.get("/settlements/recent", (c) =>
  c.json({
    service: "NIVARA Wellness Intelligence API",
    note: "x402 settlements settled on Algorand Testnet via the GoPlausible facilitator",
    explorer: "https://lora.algokit.io/testnet",
    settlements: recentSettlements().map((s) => ({ ...s, loraUrl: loraUrl(s.txId ?? "") })),
  })
);

app.get("/info", (c) =>
  c.json({
    service: "NIVARA Wellness Intelligence API",
    version: "1.0.0",
    protocol: "x402 (exact scheme, Algorand/AVM)",
    network: ALGORAND_TESTNET_CAIP2,
    receiver: avmAddress,
    facilitator: facilitatorUrl,
    endpoints: Object.entries(ENDPOINTS).map(([route, def]) => ({
      route,
      price: `${def.priceUsd} USDC`,
      description: def.description,
    })),
  })
);

app.notFound((c) =>
  c.json({ error: "Endpoint not found", path: c.req.path, hint: "Try GET /health or GET /info" }, 404)
);

serve({ fetch: app.fetch, port }, () => {
  console.log(`✅ NIVARA x402 resource server running on http://localhost:${port}`);
  console.log(`   curl http://localhost:${port}/api/nivara/stress-briefing   # -> 402 Payment Required`);
});
