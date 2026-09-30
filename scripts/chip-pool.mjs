#!/usr/bin/env node
// Finds a Bankr-launched token's Uniswap v4 pool key (fee, tick spacing, hook) from the pool's
// Initialize event, and prints it as the environment the CHIP burner deploy wants.
//
//   node scripts/chip-pool.mjs <token address> [--rpc URL]
//
// The pool id comes from GeckoTerminal; the key from the PoolManager's log around the pool's
// creation (the RPC needs logs that far back: mainnet.base.org keeps a few weeks).
import { decodeAbiParameters, getAddress } from "viem";
import { option } from "./lib/chain.mjs";

const POOL_MANAGER = "0x498581fF718922c3f8e6A244956aF099B2652b2b";
const WETH = "0x4200000000000000000000000000000000000006";
// keccak256("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")
const INITIALIZE = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438";

const token = process.argv[2] && getAddress(process.argv[2].toLowerCase());
if (!token) throw new Error("usage: node scripts/chip-pool.mjs <token address>");
const RPC = option("rpc", process.env.RPC_URL || "https://mainnet.base.org");

async function rpc(method, params) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

// The token's WETH pool on Bankr (a v4 pool: its "address" is the 32-byte pool id).
const gecko = await fetch(`https://api.geckoterminal.com/api/v2/networks/base/tokens/${token}/pools?page=1`, {
  headers: { accept: "application/json" },
}).then((r) => r.json());
const pool = (gecko.data ?? []).find(
  (p) => p.attributes.address.length === 66 && p.relationships.quote_token.data.id.toLowerCase() === `base_${WETH.toLowerCase()}`,
) ?? (gecko.data ?? []).find((p) => p.attributes.address.length === 66);
if (!pool) throw new Error(`no v4 pool found for ${token} on GeckoTerminal`);
const poolId = pool.attributes.address;

// Base makes a block every 2 seconds: estimate the creation block, then search around it.
const latest = await rpc("eth_getBlockByNumber", ["latest", false]);
const created = Math.floor(Date.parse(pool.attributes.pool_created_at) / 1000);
const guess = Number(latest.number) - Math.floor((Number(latest.timestamp) - created) / 2);
let log;
for (const span of [200, 2_000]) {
  const logs = await rpc("eth_getLogs", [
    {
      address: POOL_MANAGER,
      topics: [INITIALIZE, poolId],
      fromBlock: `0x${(guess - span).toString(16)}`,
      toBlock: `0x${(guess + span).toString(16)}`,
    },
  ]);
  if (logs.length) {
    log = logs[0];
    break;
  }
}
if (!log) throw new Error(`no Initialize event for pool ${poolId} near block ${guess}`);

const currency0 = getAddress(`0x${log.topics[2].slice(26)}`);
const currency1 = getAddress(`0x${log.topics[3].slice(26)}`);
const [fee, tickSpacing, hooks] = decodeAbiParameters(
  [{ type: "uint24" }, { type: "int24" }, { type: "address" }, { type: "uint160" }, { type: "int24" }],
  log.data,
);
if (![currency0, currency1].includes(token) || ![currency0, currency1].includes(getAddress(WETH))) {
  throw new Error(`pool ${poolId} is ${currency0}/${currency1}, not ${token}/WETH`);
}

console.error(`${pool.attributes.name}: pool ${poolId}, created in block ${Number(log.blockNumber)}`);
console.log(`CHIP_ADDRESS=${token}`);
console.log(`CHIP_POOL_FEE=${fee}`);
console.log(`CHIP_POOL_TICK_SPACING=${tickSpacing}`);
console.log(`CHIP_POOL_HOOKS=${hooks}`);
