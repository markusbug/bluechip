import type { Abi, Address, Hash } from "viem";
import { getCapabilities, sendCalls, waitForCallsStatus, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { wagmiConfig } from "../wagmi";
import { siteConfig } from "../config";

export type Call = { address: Address; abi: Abi; functionName: string; args: readonly unknown[]; label: string };

export type Progress = { label: string; step: number; total: number; stage: "sign" | "wallet" | "pending" };

/**
 * Does the connected wallet execute several calls atomically (EIP-5792)? True for Base Account,
 * Ambire and MetaMask smart accounts; false for a plain EOA in MetaMask or Rabby.
 */
export async function canBatch(account: Address): Promise<boolean> {
  try {
    const caps = await getCapabilities(wagmiConfig, { account, chainId: siteConfig.chain.id });
    const status = (caps as { atomic?: { status?: string } }).atomic?.status;
    return status === "supported" || status === "ready";
  } catch {
    return false;
  }
}

/**
 * Run calls in order. One atomic batch when the wallet supports it, otherwise one transaction at a
 * time, waiting for each so later calls see earlier state (an approval before a mint).
 */
export async function runCalls(account: Address, calls: Call[], onProgress: (p: Progress) => void): Promise<Hash> {
  if (calls.length > 1 && (await canBatch(account))) {
    onProgress({ label: calls.map((c) => c.label).join(" + "), step: 1, total: 1, stage: "wallet" });
    const { id } = await sendCalls(wagmiConfig, {
      account,
      forceAtomic: true,
      calls: calls.map(({ address, abi, functionName, args }) => ({ to: address, abi, functionName, args })),
    });
    onProgress({ label: "Batch", step: 1, total: 1, stage: "pending" });
    const result = await waitForCallsStatus(wagmiConfig, { id, timeout: 120_000 });
    if (result.status !== "success") throw new Error("The batch failed onchain. Nothing was minted.");
    return result.receipts?.at(-1)?.transactionHash ?? ("0x" as Hash);
  }

  let last: Hash = "0x";
  for (const [i, call] of calls.entries()) {
    onProgress({ label: call.label, step: i + 1, total: calls.length, stage: "wallet" });
    const hash = await writeContract(wagmiConfig, {
      account,
      address: call.address,
      abi: call.abi,
      functionName: call.functionName,
      args: call.args,
    } as Parameters<typeof writeContract>[1]);
    onProgress({ label: call.label, step: i + 1, total: calls.length, stage: "pending" });
    const receipt = await waitForTransactionReceipt(wagmiConfig, { hash });
    if (receipt.status !== "success") throw new Error(`${call.label} failed onchain.`);
    last = hash;
  }
  return last;
}
