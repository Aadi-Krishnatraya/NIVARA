/**
 * NIVARA x402 agent client — demonstrates the complete x402 flow against the
 * NIVARA Wellness Intelligence API:
 *
 *   1. GET briefing                -> 402 Payment Required (payment requirements)
 *   2. Build Algorand USDC axfer   -> sign with client wallet
 *   3. Retry with X-PAYMENT header -> GoPlausible facilitator verifies + settles on-chain
 *   4. 200 OK + paid briefing JSON
 *
 * Usage:
 *   npm run client             # stress briefing (0.01 USDC)
 *   npm run client:unit        # unit briefing   (0.05 USDC)
 *   npm run client:triple      # buy both briefings back-to-back
 */
import { config } from "dotenv";
config();

import { x402Client } from "@x402-avm/core/client";
import { wrapFetchWithPayment } from "@x402-avm/fetch";
import { ExactAvmScheme } from "@x402-avm/avm/exact/client";
import { ALGORAND_TESTNET_CAIP2, toClientAvmSigner } from "@x402-avm/avm";

const RESOURCE_SERVER = process.env.RESOURCE_SERVER_URL || "http://localhost:4021";

function clientSigner() {
  const secret = process.env.CLIENT_AVM_PRIVATE_KEY;
  if (!secret) {
    console.error("❌ Missing CLIENT_AVM_PRIVATE_KEY (base64 64-byte Algorand key). Run: npm run setup");
    process.exit(1);
  }
  return toClientAvmSigner(secret);
}

async function buyBriefing(path: string, label: string): Promise<void> {
  const signer = clientSigner();
  console.log(`\n── ${label} ─────────────────────────────────────────`);
  console.log(`   buyer wallet : ${signer.address}`);
  console.log(`   resource     : ${RESOURCE_SERVER}${path}`);

  const client = new x402Client().register(ALGORAND_TESTNET_CAIP2, new ExactAvmScheme(signer));
  const fetchWithPayment = wrapFetchWithPayment(fetch, client);

  const t0 = Date.now();
  const res = await fetchWithPayment(`${RESOURCE_SERVER}${path}`);
  const elapsed = Date.now() - t0;

  console.log(`   HTTP ${res.status} in ${elapsed}ms`);
  if (!res.ok) {
    console.error("   ❌ payment-protected request failed:", await res.text());
    process.exit(1);
  }
  const body = (await res.json()) as Record<string, unknown>;
  console.log("   ✅ PAID — briefing received:");
  console.log("   " + JSON.stringify(body, null, 2).split("\n").join("\n   "));
}

async function main() {
  const mode = process.argv[2] || "stress";
  if (mode === "stress") await buyBriefing("/api/nivara/stress-briefing", "Stress briefing — 0.01 USDC");
  else if (mode === "unit") await buyBriefing("/api/nivara/unit-briefing", "Unit briefing — 0.05 USDC");
  else if (mode === "triple") {
    await buyBriefing("/api/nivara/stress-briefing", "Purchase 1/2 — stress briefing");
    await buyBriefing("/api/nivara/unit-briefing", "Purchase 2/2 — unit briefing");
  } else {
    console.error("Unknown mode. Use: stress | unit | triple");
    process.exit(1);
  }
  console.log("\n💡 Verify the settlement transaction on LoRA: https://lora.algokit.io/testnet");
  console.log("   (or run: npm run verify)");
}

main().catch((err) => {
  console.error("❌ client failed:", err?.message ?? err);
  process.exit(1);
});
