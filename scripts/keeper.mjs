#!/usr/bin/env node
// Keeper: keeps the fund on its index. Each run it
//   1. activates a proposed index once its 7-day delay has passed, and
//   2. makes the best rebalancing trade, if there is one.
// The contracts decide everything (what, how much, minimum output); anyone can run this, and all it
// needs is gas money. One trade per run: the rebalancer's cooldown spaces them anyway.
// On a testnet mock deployment it also keeps the mock price feeds fresh during the session (real
// Chainlink feeds update themselves; the mocks only move when someone pokes them).
// If the deployment has a CHIP burner, it also burns the fee BLUE once it is worth MIN_BURN_USD
// ($25; $1 on testnets): it quotes the burn by simulating it, then sends it with a minimum CHIP
// out of the quote minus BURN_SLIPPAGE_BPS (2%). The burner only accepts burns from its keeper.
//
//   KEEPER_KEY=0x... node scripts/keeper.mjs [--chain 8453] [--rpc URL] [--loop SECONDS] [--dry-run]
//
// Without KEEPER_KEY it only reports what it would do.
import { burnerAbi, connect, feedAbi, fundAbi, log, option, short, stockAbi } from "./lib/chain.mjs";

const { account, client, deployment, read, send, write } = connect("KEEPER_KEY");
const minBurnUsd = Number(process.env.MIN_BURN_USD || (deployment.mock ? 1 : 25));
const burnSlippageBps = BigInt(process.env.BURN_SLIPPAGE_BPS || 200);
const hasBurner = deployment.burner && !/^0x0+$/.test(deployment.burner);
const loopSeconds = Number(option("loop", 0));
const symbols = deployment.symbols;

async function tick() {
  const now = (await client.getBlock()).timestamp;

  const eta = await read("pendingIndexEta");
  if (eta !== 0n) {
    if (now >= eta) await send("activateIndex");
    else log(`index update pending, activates at ${new Date(Number(eta) * 1000).toISOString()}`);
  }

  if (deployment.mock && (await read("marketOpen"))) await pokeMockFeeds(now);

  let plan;
  try {
    plan = await read("plan");
  } catch (err) {
    // Stale prices: the market is closed or a feed has not updated yet today.
    log(`no prices to trade on: ${short(err)}`);
    return;
  }
  const [ok, sell, buy, valueUsd] = plan;
  const usd = (Number(valueUsd) / 1e18).toFixed(2);
  if (hasBurner && (await read("marketOpen"))) {
    try {
      await burn();
    } catch (err) {
      log(`burn failed: ${short(err)}`);
      process.exitCode = 1;
    }
  }
  if (!ok) {
    const reason = !(await read("marketOpen"))
      ? "market closed"
      : now < (await read("lastTradeAt")) + (await read("cooldown"))
        ? "cooling down"
        : "on target";
    log(`nothing to do (${reason}; best trade $${usd})`);
    return;
  }
  log(`rebalance: sell $${usd} of ${symbols[sell]} for ${symbols[buy]}`);
  await send("rebalance", [sell, buy]);
}

/** Burn the fee BLUE into CHIP once it is worth enough. Runs in the session only. */
async function burn() {
  const pending = await client.readContract({ address: deployment.burner, abi: burnerAbi, functionName: "pendingBlue" });
  if (pending === 0n) return;
  const [, amounts] = await client.readContract({
    address: deployment.fund,
    abi: fundAbi,
    functionName: "previewRedeem",
    args: [pending],
  });
  let usd = 0;
  for (const [i, feed] of deployment.feeds.entries()) {
    const [, answer] = await client.readContract({ address: feed, abi: feedAbi, functionName: "latestRoundData" });
    const decimals = await client.readContract({ address: deployment.tokens[i], abi: stockAbi, functionName: "decimals" });
    usd += (Number(amounts[i]) / 10 ** decimals) * (Number(answer) / 1e8);
  }
  if (usd < minBurnUsd) {
    log(`burner: $${usd.toFixed(2)} of fees waiting, burns at $${minBurnUsd}`);
    return;
  }
  // Quote by simulating the burn as the keeper, then require all but the slippage allowance.
  const keeper = await client.readContract({ address: deployment.burner, abi: burnerAbi, functionName: "keeper" });
  const { result: quote } = await client.simulateContract({
    address: deployment.burner,
    abi: burnerAbi,
    functionName: "burn",
    args: [pending, 0n, []],
    account: account ?? keeper,
  });
  const minOut = (quote * (10_000n - burnSlippageBps)) / 10_000n;
  log(`burner: $${usd.toFixed(2)} of fees buys ~${(Number(quote) / 1e18).toFixed(0)} CHIP to burn`);
  await write(deployment.burner, burnerAbi, "burn", [pending, minOut, []]);
}

/** Re-post each mock feed's price once it is within 2 hours of going stale. */
async function pokeMockFeeds(now) {
  const maxAge = await read("maxFeedAge");
  for (const feed of await read("feeds")) {
    const [, answer, , updatedAt] = await client.readContract({
      address: feed,
      abi: feedAbi,
      functionName: "latestRoundData",
    });
    if (now - updatedAt > maxAge - 7200n) await write(feed, feedAbi, "setPrice", [answer]);
  }
}

do {
  try {
    await tick();
  } catch (err) {
    log(`error: ${short(err)}`);
    if (!loopSeconds) process.exitCode = 1;
  }
  if (loopSeconds) await new Promise((r) => setTimeout(r, loopSeconds * 1000));
} while (loopSeconds);
