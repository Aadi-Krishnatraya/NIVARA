/**
 * One-time setup for the NIVARA x402 demo:
 *   - generates payee (server) + client wallets if not present in .env
 *   - writes them back to .env (base64 64-byte Algorand keys)
 *   - prints TestNet funding links (ALGO dispenser + USDC sources)
 *   - checks current balances via AlgoNode
 *
 * Run:  npm run setup
 */
import { config } from "dotenv";
config();

import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { ed25519Generator } from "@algorandfoundation/algokit-utils/crypto";
import { encodeAddress } from "@algorandfoundation/algokit-utils/common";
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

function upsertEnv(entries: Record<string, string>): void {
  const existing = existsSync(ENV_PATH) ? readFileSync(ENV_PATH, "utf8") : "";
  let updated = existing;
  for (const [k, v] of Object.entries(entries)) {
    if (k.startsWith("#")) {
      // comment line — append verbatim (used to store payee secret reference)
      updated += (updated && !updated.endsWith("\n") ? "\n" : "") + `${k}${v ? "=" + v : ""}\n`;
      continue;
    }
    const re = new RegExp(`^\\s*${k}\\s*=.*$`, "m");
    if (re.test(updated)) updated = updated.replace(re, `${k}=${v}`);
    else updated += (updated && !updated.endsWith("\n") ? "\n" : "") + `${k}=${v}\n`;
  }
  writeFileSync(ENV_PATH, updated);
}

/** Generate a fresh Algorand account: returns { address, privateKeyBase64 }. */
function newAccount(): { address: string; privateKeyBase64: string } {
  const seed = randomBytes(32);
  const { ed25519Pubkey, ed25519SecretKey } = ed25519Generator(seed);
  return {
    address: encodeAddress(ed25519Pubkey),
    privateKeyBase64: Buffer.from(ed25519SecretKey).toString("base64"),
  };
}

async function balance(address: string): Promise<{ algo: number; usdc: number }> {
  try {
    const res = await fetch(`${ALGOD_TESTNET_URL}/v2/accounts/${address}`);
    if (res.status === 404) return { algo: 0, usdc: 0 };
    if (!res.ok) throw new Error(`algod ${res.status}`);
    const j = (await res.json()) as { amount: number; assets?: { "asset-id": number; amount: number }[] };
    const usdc = j.assets?.find((a) => a["asset-id"] === Number(USDC_TESTNET_ASA_ID))?.amount ?? 0;
    return { algo: j.amount / 1e6, usdc: usdc / 1e6 };
  } catch {
    return { algo: NaN, usdc: NaN };
  }
}

async function main() {
  const env = readEnv();
  const toCreate: Record<string, string> = {};

  if (!env.AVM_ADDRESS) {
    const payee = newAccount();
    toCreate["AVM_ADDRESS"] = payee.address;
    toCreate["# payee 64-byte secret key base64 (KEEP PRIVATE — receives USDC)"] = "";
    toCreate["# AVM_SECRET_KEY"] = payee.privateKeyBase64;
    console.log("🔑 generated new PAYEE (server receiver) account");
  }
  if (!env.CLIENT_AVM_PRIVATE_KEY) {
    const client = newAccount();
    toCreate["CLIENT_AVM_PRIVATE_KEY"] = client.privateKeyBase64;
    toCreate["CLIENT_AVM_ADDRESS"] = client.address;
    console.log("🔑 generated new CLIENT (buyer) account");
  }
  if (!env.FACILITATOR_URL) toCreate["FACILITATOR_URL"] = "https://facilitator.goplausible.xyz";
  if (!env.PORT) toCreate["PORT"] = "4021";

  if (Object.keys(toCreate).length > 0) {
    upsertEnv(toCreate);
    console.log(`   -> written to ${ENV_PATH}`);
  }

  const env2 = readEnv();
  const payee = env2.AVM_ADDRESS!;
  const client = env2.CLIENT_AVM_ADDRESS!;

  console.log("\n════════════════════════════════════════════════════");
  console.log(" NIVARA x402 accounts (Algorand Testnet)");
  console.log("════════════════════════════════════════════════════");
  console.log(` payee  (receives USDC): ${payee}`);
  console.log(` client (pays)         : ${client}`);

  const [payeeBal, clientBal] = await Promise.all([balance(payee), balance(client)]);
  console.log("\nBalances:");
  console.log(` payee : ${payeeBal.algo} ALGO, ${payeeBal.usdc} USDC`);
  console.log(` client: ${clientBal.algo} ALGO, ${clientBal.usdc} USDC`);

  console.log("\n💰 Fund BOTH accounts:");
  console.log("   1. ALGO dispenser: https://dispenser.testnet.algorand.network/");
  console.log("   2. TestNet USDC  : same dispenser (choose USDC), needs opt-in");
  console.log("      client: USDC >= 0.06 + ~0.2 ALGO  |  payee: ~0.2 ALGO (USDC opt-in happens on first receipt)");
  console.log(`\nℹ️  USDC testnet ASA id: ${USDC_TESTNET_ASA_ID}`);
  console.log("Then: npm start   (server)   +   npm run client:triple   (paid demo)");
}

main().catch((err) => {
  console.error("setup failed:", err);
  process.exit(1);
});
