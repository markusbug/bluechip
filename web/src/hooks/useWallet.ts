import { useAccount, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { erc20Abi } from "viem";
import { deployment, siteConfig } from "../config";

export type WalletState = {
  address: Address | undefined;
  onChain: boolean;
  /** Per constituent, same order as the fund. */
  balances: bigint[];
  allowances: bigint[];
  blue: bigint;
  chip: bigint;
  refetch: () => void;
};

/** The connected wallet's stocks, allowances to the fund, BLUE and CHIP. */
export function useWallet(): WalletState {
  const { address, chainId } = useAccount();
  const d = deployment;
  const n = d?.tokens.length ?? 0;
  const chip = siteConfig.chipAddress;

  const contracts =
    d && address
      ? [
          { address: d.fund, abi: erc20Abi, functionName: "balanceOf", args: [address] },
          ...(chip ? [{ address: chip, abi: erc20Abi, functionName: "balanceOf", args: [address] }] : []),
          ...d.tokens.map((t) => ({ address: t, abi: erc20Abi, functionName: "balanceOf", args: [address] })),
          ...d.tokens.map((t) => ({ address: t, abi: erc20Abi, functionName: "allowance", args: [address, d.fund] })),
        ]
      : [];

  const q = useReadContracts({
    contracts: contracts as never,
    query: { enabled: contracts.length > 0, refetchInterval: 10_000 },
  });
  const r = (q.data ?? []) as { status: string; result?: unknown }[];
  const val = (i: number) => (r[i]?.status === "success" ? (r[i].result as bigint) : 0n);
  const o = chip ? 2 : 1;

  return {
    address,
    onChain: chainId === siteConfig.chain.id,
    blue: val(0),
    chip: chip ? val(1) : 0n,
    balances: Array.from({ length: n }, (_, i) => val(o + i)),
    allowances: Array.from({ length: n }, (_, i) => val(o + n + i)),
    refetch: () => void q.refetch(),
  };
}
