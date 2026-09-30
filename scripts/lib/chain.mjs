// Shared setup for the automation scripts: flags, the deployment file, viem clients.
import { existsSync, readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia, foundry } from "viem/chains";

const root = new URL("../..", import.meta.url).pathname;
const chains = { [base.id]: base, [baseSepolia.id]: baseSepolia, [foundry.id]: foundry };

export const rebalancerAbi = parseAbi([
  "function plan() view returns (bool ok, uint256 sellIdx, uint256 buyIdx, uint256 valueUsd)",
  "function rebalance(uint256 sellIdx, uint256 buyIdx) returns (uint256 amountIn, uint256 amountOut)",
  "function pendingIndexEta() view returns (uint256)",
  "function activateIndex()",
  "function floatShares() view returns (uint256[])",
  "function multipliers() view returns (uint256[])",
  "function pendingFloatShares() view returns (uint256[])",
  "function pendingMultipliers() view returns (uint256[])",
  "function proposeIndex(uint256[] floatShares, uint256[] multipliers)",
  "function marketOpen() view returns (bool)",
  "function lastTradeAt() view returns (uint256)",
  "function cooldown() view returns (uint256)",
]);
export const stockAbi = parseAbi(["function multiplier() view returns (uint256)"]);

export function flag(name) {
  return process.argv.includes(`--${name}`);
}

export function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
}

/**
 * Clients and the deployment for --chain (default Base). The signer comes from the env var
 * `keyVar`; without one (or with --dry-run) the script only reads and simulates.
 */
export function connect(keyVar) {
  const chainId = Number(option("chain", process.env.CHAIN_ID || base.id));
  const chain = chains[chainId];
  if (!chain) throw new Error(`unknown chain ${chainId}`);
  const rpc = option("rpc", process.env.RPC_URL || chain.rpcUrls.default.http[0]);
  const path = `${root}contracts/deployments/${chainId}.json`;
  if (!existsSync(path)) throw new Error(`no ${path}: deploy first`);
  const deployment = JSON.parse(readFileSync(path, "utf8"));
  if (!deployment.rebalancer || /^0x0+$/.test(deployment.rebalancer)) {
    throw new Error(`${path} has no rebalancer`);
  }

  const transport = http(rpc);
  const client = createPublicClient({ chain, transport });
  const key = process.env[keyVar] || undefined;
  const dryRun = flag("dry-run") || !key;
  const account = key ? privateKeyToAccount(key) : undefined;
  const wallet = account ? createWalletClient({ chain, transport, account }) : undefined;

  /** Simulate, then (unless dry-run) send and wait. Returns the receipt or null. */
  async function send(functionName, args = []) {
    const { request } = await client.simulateContract({
      address: deployment.rebalancer,
      abi: rebalancerAbi,
      functionName,
      args,
      account,
    });
    if (dryRun) {
      log(`dry run: would call ${functionName}(${args.join(", ")})`);
      return null;
    }
    const hash = await wallet.writeContract(request);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
    log(`${functionName}(${args.join(", ")}) ${hash}`);
    return receipt;
  }

  const read = (functionName, args = []) =>
    client.readContract({ address: deployment.rebalancer, abi: rebalancerAbi, functionName, args });

  return { chain, client, deployment, dryRun, send, read };
}

export function log(msg) {
  console.log(`${new Date().toISOString()} ${msg}`);
}

/** A viem error on one line, with the revert reason (viem puts it on the next line). */
export function short(err) {
  return (err.shortMessage ?? err.message ?? String(err))
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .join(" ");
}
