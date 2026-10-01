#!/usr/bin/env node
// Index updater: recomputes each company's float shares from its latest SEC filing and, if the
// index moved, proposes it to the rebalancer. The proposal only applies after a 7-day delay, during
// which the owner can cancel it and holders can redeem.
//
//   UPDATER_KEY=0x... SEC_USER_AGENT="Name email" \
//   node scripts/index-update.mjs [--chain 8453] [--rpc URL] [--dry-run] [--force]
//
// Guards: nothing is proposed for changes under MIN_CHANGE, and a change over MAX_CHANGE for any
// company stops the script for a human to look at (--force proposes anyway). A jump that large is
// usually a stock split that EDGAR has not caught up with yet, or bad data.
import { connect, flag, log, stockAbi } from "./lib/chain.mjs";
import { configPath, floatShares, loadConfig } from "./lib/index-data.mjs";

const MIN_CHANGE = 0.005;
const MAX_CHANGE = 0.25;

const { client, deployment, read, send } = connect("UPDATER_KEY");
const cfg = loadConfig();
const fetched = await floatShares(cfg);

// Deployment order is the fund's constituent order; match the config by symbol.
const next = deployment.symbols.map((symbol) => {
  const row = fetched.find((r) => r.symbol === symbol);
  if (!row) throw new Error(`${symbol} is not in ${configPath}`);
  return row;
});
const multipliers = await Promise.all(
  deployment.tokens.map((address) => client.readContract({ address, abi: stockAbi, functionName: "multiplier" })),
);
const floats = next.map((r) => BigInt(r.floatShares));

const [curFloats, curMults, pendingEta, pendingFloats, pendingMults] = await Promise.all([
  read("floatShares"),
  read("multipliers"),
  read("pendingIndexEta"),
  read("pendingFloatShares"),
  read("pendingMultipliers"),
]);

// Compare in tokens (float shares / multiplier), so a split counted on both sides is no change.
const tokens = (f, m) => (Number(f) * 1e18) / Number(m);
let maxChange = 0;
console.log("symbol   float shares      change   source");
for (const [i, r] of next.entries()) {
  const change = tokens(floats[i], multipliers[i]) / tokens(curFloats[i], curMults[i]) - 1;
  maxChange = Math.max(maxChange, Math.abs(change));
  const pct = `${change >= 0 ? "+" : ""}${(change * 100).toFixed(2)}%`;
  console.log(`${r.symbol.padEnd(8)} ${String(r.floatShares).padStart(14)}  ${pct.padStart(8)}   ${r.sharesSource}`);
}

const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
if (pendingEta !== 0n && same(pendingFloats, floats) && same(pendingMults, multipliers)) {
  log(`already proposed, activates at ${new Date(Number(pendingEta) * 1000).toISOString()}`);
} else if (maxChange < MIN_CHANGE) {
  log(`largest change ${(maxChange * 100).toFixed(2)}% is under ${MIN_CHANGE * 100}%: no update`);
} else if (maxChange > MAX_CHANGE && !flag("force")) {
  log(`largest change ${(maxChange * 100).toFixed(1)}% is over ${MAX_CHANGE * 100}%: check it, then rerun with --force`);
  process.exitCode = 2;
} else {
  await send("proposeIndex", [floats, multipliers]);
}
