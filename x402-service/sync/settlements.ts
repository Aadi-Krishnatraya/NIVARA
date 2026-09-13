/**
 * x402 settlement recorder.
 *
 * The @x402-avm resource server settles via the GoPlausible facilitator and
 * exposes settlement info on the response context; we capture what the
 * middleware surfaces onto the Hono context so the Flutter Wellness Exchange
 * can show real Algorand txids with LoRA links — judge-facing proof that the
 * x402 loop is live.
 *
 * Captured entries are aggregate-level metadata only (txid, amounts, asset,
 * payer address) — the sync privacy contract is unaffected. In-memory, capped.
 */
import type { Context } from "hono";

export interface SettlementRecord {
  txId: string | null;
  route: string;
  payer: string | null;
  payee: string | null;
  asset: string | null;
  amountAtomic: string | null;
  network: string;
  settledAt: string;
}

const MAX_RECORDS = 100;
const records: SettlementRecord[] = [];

/**
 * Pull settlement metadata off the Hono context. The x402-avm middleware
 * stores its result under several well-known keys depending on version —
 * we probe them all defensively and normalize whatever is found.
 */
export function captureSettlement(c: Context, route: string): void {
  const source =
    (c.get("x402") as unknown) ??
    (c.get("x402Result") as unknown) ??
    (c.get("paymentResult") as unknown) ??
    null;
  if (!source || typeof source !== "object") return;

  const s = source as Record<string, unknown>;
  const settlement = (s.settlement as Record<string, unknown> | undefined) ?? s;
  const txId =
    (typeof settlement.transaction === "string" && settlement.transaction) ||
    (typeof settlement.txId === "string" && settlement.txId) ||
    (typeof settlement.txid === "string" && settlement.txid) ||
    null;
  if (!txId) return; // verify-only or failed flow — nothing settled on-chain

  records.unshift({
    txId,
    route,
    payer: typeof settlement.payer === "string" ? settlement.payer : null,
    payee: typeof settlement.payee === "string" ? settlement.payee : typeof settlement.recipient === "string" ? settlement.recipient : null,
    asset: typeof settlement.asset === "string" ? settlement.asset : null,
    amountAtomic:
      typeof settlement.amount === "string" || typeof settlement.amount === "number"
        ? String(settlement.amount)
        : null,
    network: typeof settlement.network === "string" ? settlement.network : "algorand-testnet",
    settledAt: new Date().toISOString(),
  });
  if (records.length > MAX_RECORDS) records.length = MAX_RECORDS;
}

export function recentSettlements(): SettlementRecord[] {
  return records;
}

/** LoRA deep link for a testnet transaction — used by the Flutter app and docs. */
export function loraUrl(txId: string): string {
  return `https://lora.algokit.io/testnet/transaction/${txId}`;
}
