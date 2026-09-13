/**
 * x402 endpoint configuration for the NIVARA Wellness Intelligence API.
 *
 * Each entry is a payment-protected route. The payment middleware reads this
 * map and enforces an x402 payment (Algorand USDC via the GoPlausible
 * facilitator) before the route handler runs.
 */
import { ALGORAND_TESTNET_CAIP2, PRICES, USDC_TESTNET_ASA_ID, usdcToAtomicUnits } from "./network.js";

export interface EndpointDefinition {
  /** Human-readable description returned in the 402 response. */
  description: string;
  /** HTTP method for the route. */
  method: "GET" | "POST";
  /** USDC price as a human string, e.g. "0.01". */
  priceUsd: string;
  /** MIME type of the successful response (used by the x402 bazaar extension). */
  mimeType?: string;
}

export interface EndpointConfig {
  /** x402 "accepts" payment requirements (scheme/network/payTo/price/asset). */
  accepts: {
    scheme: "exact";
    network: string;
    payTo: string;
    price: string;
    asset: string;
  }[];
  description: string;
  mimeType?: string;
}

export const ENDPOINTS: Record<string, EndpointDefinition> = {
  "GET /api/nivara/stress-briefing": {
    description:
      "NIVARA anonymous stress briefing — on-device Edge-AI stress index distribution and per-feature Shapley risk drivers for a cohort",
    method: "GET",
    priceUsd: PRICES.stressBriefing,
    mimeType: "application/json",
  },
  "GET /api/nivara/unit-briefing": {
    description:
      "NIVARA unit wellness briefing — differentially-private aggregate (Laplace eps=1.5), 7-day trend and recommended action playbook",
    method: "GET",
    priceUsd: PRICES.unitBriefing,
    mimeType: "application/json",
  },
};

/**
 * Build the payment config expected by @x402-avm/hono paymentMiddleware.
 * `payTo` is the Algorand address that receives the USDC.
 */
export function createPaymentConfig(payTo: string): Record<string, EndpointConfig> {
  const config: Record<string, EndpointConfig> = {};
  for (const [route, def] of Object.entries(ENDPOINTS)) {
    config[route] = {
      accepts: [
        {
          scheme: "exact",
          network: ALGORAND_TESTNET_CAIP2,
          payTo,
          // NOTE: dollar string — the AVM server scheme (parsePrice) converts to
          // USDC atomic units via the facilitator's `extra` (decimals). Passing
          // pre-converted atomic units would be re-parsed as USD (10,000x bug).
          price: `$${def.priceUsd}`,
          asset: USDC_TESTNET_ASA_ID,
        },
      ],
      description: def.description,
      mimeType: def.mimeType,
    };
  }
  return config;
}
