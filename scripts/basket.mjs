#!/usr/bin/env node
// Turns contracts/basket/mag7.config.json into the seed vector the fund is deployed with.
//
// Float-adjusted cap weighting, the S&P 500 method: hold a number of shares of each company
// proportional to its float shares (see scripts/lib/index-data.mjs), scaled so one BLUE is worth
// `targetUsdPerShare` today. Prices come from the Coinbase Chainlink feeds on Base, which are
// total-return (already include the token multiplier), so
//   units_i = target * floatShares_i / (multiplier_i * totalFloatCap) * 10^decimals
// The same float shares are the rebalancer's initial index, so the fund starts on target.
// Also snapshots names and icons from the Coinbase API (it has no CORS, so the site can't).
//
// Usage: node scripts/basket.mjs [--rpc https://mainnet.base.org]
import { mkdirSync, writeFileSync } from "node:fs";
import { getAddress } from "viem";
import { floatShares, loadConfig } from "./lib/index-data.mjs";

const root = new URL("..", import.meta.url).pathname;
const outPath = `${root}contracts/basket/mag7.json`;
const metaPath = `${root}web/src/data/stocks.json`;
const rpcArg = process.argv.indexOf("--rpc");
const RPC = rpcArg > 0 ? process.argv[rpcArg + 1] : process.env.BASE_RPC_URL ?? "https://mainnet.base.org";

const cfg = loadConfig();
// Published addresses sometimes carry a broken EIP-55 checksum; viem rejects those outright.
for (const c of cfg.constituents) {
  c.address = getAddress(c.address.toLowerCase());
  c.feed = getAddress(c.feed.toLowerCase());
  c.pool = getAddress(c.pool.toLowerCase());
}
const index = await floatShares(cfg);

async function ethCall(to, data) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${to} ${data}: ${json.error.message}`);
  return json.result;
}
const word = (hex, i) => BigInt("0x" + hex.slice(2 + 64 * i, 2 + 64 * (i + 1)));

const SEL = { latestRoundData: "0xfeaf968c", multiplier: "0x1b3ed722", decimals: "0x313ce567" };
const MAX_FEED_AGE_S = 4 * 24 * 3600; // feeds pause off-hours and over weekends

const now = Math.floor(Date.now() / 1000);
const rows = [];
for (const [i, c] of cfg.constituents.entries()) {
  const round = await ethCall(c.feed, SEL.latestRoundData);
  const answer = word(round, 1);
  const price = Number(answer) / 1e8; // feeds use 8 decimals
  const updatedAt = Number(word(round, 3));
  if (now - updatedAt > MAX_FEED_AGE_S) throw new Error(`${c.symbol}: feed stale (${now - updatedAt}s)`);
  const multiplierWad = word(await ethCall(c.address, SEL.multiplier), 0);
  const multiplier = Number(multiplierWad) / 1e18;
  const decimals = Number(word(await ethCall(c.address, SEL.decimals), 0));
  const { floatShares, sharesOutstanding, sharesSource } = index[i];
  rows.push({
    ...c,
    sharesOutstanding,
    sharesSource,
    floatShares,
    answer,
    price,
    multiplier,
    multiplierWad,
    decimals,
    cap: (floatShares * price) / multiplier,
  });
}

const totalCap = rows.reduce((s, r) => s + r.cap, 0);
const tokens = rows.map((r) => {
  const tokensPerBlue = (cfg.targetUsdPerShare * r.floatShares) / (r.multiplier * totalCap);
  const units = BigInt(Math.round(tokensPerBlue * 10 ** r.decimals));
  return {
    symbol: r.symbol,
    address: r.address,
    feed: r.feed,
    pool: r.pool,
    decimals: r.decimals,
    sharesOutstanding: r.sharesOutstanding,
    sharesSource: r.sharesSource,
    listedFraction: r.listedFraction,
    iwf: r.iwf,
    floatShares: r.floatShares,
    priceAnswer: r.answer.toString(),
    price: r.price,
    multiplier: r.multiplier,
    multiplierWad: r.multiplierWad.toString(),
    weight: +(r.cap / totalCap).toFixed(6),
    units: units.toString(),
  };
});

const out = {
  name: cfg.name,
  targetUsdPerShare: cfg.targetUsdPerShare,
  generatedAt: new Date().toISOString(),
  totalFloatCapUsd: Math.round(totalCap),
  usdc: getAddress(cfg.usdc.toLowerCase()),
  // Flat arrays for Foundry's vm.parseJson*Array.
  symbols: tokens.map((t) => t.symbol),
  addresses: tokens.map((t) => t.address),
  feeds: tokens.map((t) => t.feed),
  pools: tokens.map((t) => t.pool),
  decimals: tokens.map((t) => t.decimals),
  floatShares: tokens.map((t) => t.floatShares),
  // WAD token multipliers the float shares were counted at (the rebalancer's index needs both).
  multipliers: tokens.map((t) => t.multiplierWad),
  // Raw 8-decimal feed answers, for the mock feeds on local and test chains.
  prices: tokens.map((t) => t.priceAnswer),
  units: tokens.map((t) => t.units),
  tokens,
};
writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");

// Display metadata for the site, keyed by symbol (mock tokens on testnets reuse the symbols).
const api = await fetch("https://api.coinbase.com/v1/tokenized-stocks").then((r) => r.json());
const meta = {};
// Icons are served by the site itself, so visitors never hit a third-party CDN.
const iconDir = `${root}web/public/icons`;
mkdirSync(iconDir, { recursive: true });
for (const t of tokens) {
  const m = api.tokens.find((x) => x.symbol === t.symbol);
  const ticker = t.symbol.replace(/c$/, "");
  let icon = null;
  if (m?.icon_url) {
    const res = await fetch(m.icon_url);
    const bytes = res.ok ? Buffer.from(await res.arrayBuffer()) : Buffer.alloc(0);
    // The CDN labels them octet-stream; trust the PNG signature instead.
    if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
      writeFileSync(`${iconDir}/${ticker}.png`, bytes);
      icon = `/icons/${ticker}.png`;
    }
  }
  meta[t.symbol] = {
    ticker,
    name: m?.name ?? t.symbol,
    icon,
    isin: m?.isin ?? null,
    feed: t.feed,
    mainnetAddress: t.address,
  };
}
writeFileSync(metaPath, JSON.stringify(meta, null, 2) + "\n");

console.log(`${cfg.name}: 1 BLUE ≈ $${cfg.targetUsdPerShare}, float cap $${(totalCap / 1e12).toFixed(2)}T`);
for (const t of tokens) {
  const per = Number(t.units) / 10 ** t.decimals;
  console.log(`  ${t.symbol.padEnd(7)} ${(t.weight * 100).toFixed(2).padStart(6)}%  ${per.toFixed(8)} per BLUE  ($${(per * t.price).toFixed(2)})`);
}
console.log(`wrote ${outPath}\nwrote ${metaPath}`);
