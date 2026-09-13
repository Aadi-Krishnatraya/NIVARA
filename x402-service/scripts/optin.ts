/**
 * USDC opt-in for the NIVARA x402 demo accounts.
 *
 * Algorand requires an account to opt in to an ASA before it can hold it:
 *   - the CLIENT must opt in to pay (USDC axfer),
 *   - the PAYEE must opt in to receive the settlement.
 *
 * Requires ALGO in each account for the opt-in transaction fee.
 * Run:  npm run optin
 */
import { config } from "dotenv";
config({ override: true });

import { readFileSync, existsSync } from "node:fs";
import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { mnemonicFromSeed } from "@algorandfoundation/algokit-utils/algo25";
import { ed25519Generator } from "@algorandfoundation/algokit-utils/crypto";
import { ALGOD_TESTNET_URL, USDC_TESTNET_ASA_ID } from "../config/network.js";

const ENV_PATH = new URL("../.env", import.meta.url).pathname;

function readEnv(): Record<string, string> {
  if (!existsSync(ENV_PATH)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(ENV_PATH, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]!] = m[2]!.replace(/^["']|["']$/g, "");
  }
  return out;
}

/** Rebuild the 25-word mnemonic from the stored base64 64-byte key (seed part). */
function mnemonicFromBase64Key(b64: string): string {
  const secretKey = Buffer.from(b64, "base64");
  if (secretKey.length !== 64) throw new Error(`key must be 64 bytes, got ${secretKey.length}`);
  return mnemonicFromSeed(secretKey.slice(0, 32));
}

/** Check USDC opt-in status directly via algod REST (stable raw JSON shape). */
async function isOptedIn(address: string): Promise<boolean> {
  const res = await fetch(`${ALGOD_TESTNET_URL}/v2/accounts/${address}`);
  if (res.status === 404) return false; // account not on-chain yet
  if (!res.ok) throw new Error(`algod ${res.status}`);
  const j = (await res.json()) as { assets?: { "asset-id": number; amount: number }[] };
  return j.assets?.some((a) => a["asset-id"] === Number(USDC_TESTNET_ASA_ID)) ?? false;
}

async function main() {
  const env = readEnv();
  const clientKey = env.CLIENT_AVM_PRIVATE_KEY;
  const payeeKey = env.AVM_SECRET_KEY;

  if (!clientKey || !payeeKey) {
    console.error(
      "❌ Missing key(s) in .env — the opt-in script needs to SIGN for both accounts:\n" +
        "  - CLIENT_AVM_PRIVATE_KEY (present: " + !!clientKey + ")\n" +
        "  - AVM_SECRET_KEY (present: " + !!payeeKey + ")\n" +
        "If AVM_SECRET_KEY is missing, delete .env and re-run `npm run setup` (new accounts will be generated)."
    );
    process.exit(1);
  }

  const algorand = AlgorandClient.testNet();
  const usdc = BigInt(USDC_TESTNET_ASA_ID); // assetId params take bigint

  for (const [label, key, addrVar] of [
    ["CLIENT", clientKey, "CLIENT_AVM_ADDRESS"],
    ["PAYEE", payeeKey, "AVM_ADDRESS"],
  ] as const) {
    const mnemonic = mnemonicFromBase64Key(key);
    const account = algorand.account.fromMnemonic(mnemonic);
    const address = account.addr.toString();

    console.log(`\n── ${label} ${address} ──`);
    if (await isOptedIn(address)) {
      console.log("   ✅ already opted in to USDC");
      continue;
    }

    try {
      console.log("   submitting USDC opt-in (0-amount axfer to self)…");
      await algorand.send.assetOptIn({ sender: address, assetId: usdc });
      console.log("   ✅ opt-in confirmed");
    } catch (err) {
      const msg = String((err as Error)?.message ?? err);
      if (/overspend|below min|funded/i.test(msg)) {
        console.error(`   ⛔ not funded yet — fund ${address} with ~0.3 ALGO at https://dispenser.testnet.algorand.network/ then re-run npm run optin`);
      } else {
        throw err;
      }
    }
  }

  console.log("\n✅ opt-in pass complete — run `npm run client:triple` once both accounts hold funds");
}

main().catch((err) => {
  console.error("optin failed:", err);
  process.exit(1);
});
