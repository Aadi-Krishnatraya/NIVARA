/**
 * Settlement verifier — proves the x402 payments are REAL on-chain transactions.
 *
 * Reads the payee account's recent transactions from the Algorand Indexer,
 * filters USDC (ASA 10458941) transfers received, and prints LoRA explorer
 * links for each settlement.
 *
 * Run:  npm run verify
 */
import { config } from "dotenv";
config();

import { INDEXER_TESTNET_URL, USDC_TESTNET_ASA_ID } from "../config/network.js";

const payee = process.env.AVM_ADDRESS;
if (!payee) {
  console.error("❌ AVM_ADDRESS missing in .env — run npm run setup first");
  process.exit(1);
}

interface IndexerTxn {
  id: string;
  "round-time": number;
  "asset-transfer-transaction"?: { amount: number; "asset-id": number; receiver: string; sender: string };
  "payment-transaction"?: { amount: number; receiver: string };
}

async function main() {
  const url =
    `${INDEXER_TESTNET_URL}/v2/accounts/${encodeURIComponent(payee!)}/transactions?limit=25` +
    `&asset-id=${USDC_TESTNET_ASA_ID}`;
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) {
    console.error(`❌ indexer request failed: ${res.status} ${await res.text()}`);
    process.exit(1);
  }
  const j = (await res.json()) as { transactions?: IndexerTxn[] };
  const txns = j.transactions ?? [];

  const received = txns.filter(
    (t) =>
      t["asset-transfer-transaction"] &&
      t["asset-transfer-transaction"]!["asset-id"] === Number(USDC_TESTNET_ASA_ID) &&
      t["asset-transfer-transaction"]!.receiver === payee &&
      t["asset-transfer-transaction"]!.amount > 0
  );

  console.log("════════════════════════════════════════════════════");
  console.log(" NIVARA x402 settlement ledger (Algorand Testnet)");
  console.log("════════════════════════════════════════════════════");
  console.log(` payee: ${payee}`);
  if (received.length === 0) {
    console.log("\n(no USDC settlements found yet — run npm run client:triple first)");
    return;
  }
  let total = 0;
  for (const t of received) {
    const amt = t["asset-transfer-transaction"]!.amount / 1e6;
    total += amt;
    const when = new Date((t["round-time"] ?? 0) * 1000).toISOString();
    console.log(`\n  ${when}  ${amt.toFixed(4)} USDC   from ${t["asset-transfer-transaction"]!.sender}`);
    console.log(`  tx ${t.id}`);
    console.log(`  🔗 https://lora.algokit.io/testnet/transaction/${t.id}`);
  }
  console.log(`\n  TOTAL received: ${total.toFixed(4)} USDC across ${received.length} x402 settlement(s)`);
}

main().catch((err) => {
  console.error("verify failed:", err);
  process.exit(1);
});
