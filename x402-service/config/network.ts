/**
 * Algorand (AVM) network constants for the NIVARA x402 service.
 *
 * All values follow the x402-avm protocol documentation:
 *  - Testnet CAIP-2 identifier uses the genesis hash
 *  - USDC testnet ASA id is 10458941 (6 decimals)
 *  - Default public endpoints are AlgoNode (free, no token needed)
 */

/** CAIP-2 network identifier for Algorand Testnet (x402 V2). */
export const ALGORAND_TESTNET_CAIP2 =
  "algorand:SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=";

/** USDC (Algorand Standard Asset) id on Algorand Testnet. */
export const USDC_TESTNET_ASA_ID = "10458941";

/** USDC has 6 decimal places on Algorand. */
export const USDC_DECIMALS = 6;

/** Public GoPlausible x402 facilitator (verifies + settles payments on-chain). */
export const GOPLAUSIBLE_FACILITATOR_URL = "https://facilitator.goplausible.xyz";

/** Default AlgoNode public algod endpoint for Testnet. */
export const ALGOD_TESTNET_URL = "https://testnet-api.algonode.cloud";

/** Default AlgoNode public indexer endpoint for Testnet (settlement verification). */
export const INDEXER_TESTNET_URL = "https://testnet-idx.algonode.cloud";

/**
 * Convert a human USDC amount (e.g. "0.01") to atomic units (string).
 * USDC on Algorand uses 6 decimals, so 0.01 USDC -> "10000".
 */
export function usdcToAtomicUnits(amount: string | number): string {
  const value = typeof amount === "number" ? amount.toFixed(6) : amount;
  const [whole = "0", frac = ""] = String(value).split(".");
  const frac6 = (frac + "000000").slice(0, USDC_DECIMALS);
  // Strip leading zeros but keep at least one digit.
  const atomic = `${whole}${frac6}`.replace(/^0+(?=\d)/, "");
  return atomic === "" ? "0" : atomic;
}

/** Price list (USDC) for the NIVARA Wellness Intelligence API. */
export const PRICES = {
  stressBriefing: "0.01",
  unitBriefing: "0.05",
} as const;
