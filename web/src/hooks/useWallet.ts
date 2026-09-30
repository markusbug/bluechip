import { useAccount, useBalance, useReadContracts } from "wagmi";
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
  /** For minting through the zap. */
  eth: bigint;
  usdc: bigint;
  usdcAllowance: bigint;
  weth: bigint;
  wethAllowance: bigint;
  refetch: () => void;
};

/** The connected wallet's stocks, allowances to the fund, BLUE and CHIP, and its ETH, USDC and WETH for the zap. */
export function useWallet(): WalletState {
  const { address, chainId } = useAccount();
  const d = deployment;
  const n = d?.tokens.length ?? 0;
  const chip = siteConfig.chipAddress;
  // What the zap takes besides ETH: a balance and an allowance to the zap for each.
  const zapTokens = d?.zap ? [d.usdc, d.weth].filter((t): t is Address => !!t) : [];

  const contracts =
    d && address
      ? [
          { address: d.fund, abi: erc20Abi, functionName: "balanceOf", args: [address] },
          ...(chip ? [{ address: chip, abi: erc20Abi, functionName: "balanceOf", args: [address] }] : []),
          ...d.tokens.map((t) => ({ address: t, abi: erc20Abi, functionName: "balanceOf", args: [address] })),
          ...d.tokens.map((t) => ({ address: t, abi: erc20Abi, functionName: "allowance", args: [address, d.fund] })),
          ...zapTokens.flatMap((t) => [
            { address: t, abi: erc20Abi, functionName: "balanceOf", args: [address] },
            { address: t, abi: erc20Abi, functionName: "allowance", args: [address, d.zap] },
          ]),
        ]
      : [];

  const q = useReadContracts({
    contracts: contracts as never,
    query: { enabled: contracts.length > 0, refetchInterval: 10_000 },
  });
  const r = (q.data ?? []) as { status: string; result?: unknown }[];
  const val = (i: number) => (r[i]?.status === "success" ? (r[i].result as bigint) : 0n);
  const o = chip ? 2 : 1;
  const zapRead = (token: Address | undefined, k: 0 | 1) => {
    const j = token ? zapTokens.indexOf(token) : -1;
    return j < 0 ? 0n : val(o + 2 * n + 2 * j + k);
  };
  const eth = useBalance({ address, chainId: siteConfig.chain.id, query: { enabled: !!address, refetchInterval: 10_000 } });

  return {
    address,
    onChain: chainId === siteConfig.chain.id,
    blue: val(0),
    chip: chip ? val(1) : 0n,
    balances: Array.from({ length: n }, (_, i) => val(o + i)),
    allowances: Array.from({ length: n }, (_, i) => val(o + n + i)),
    eth: eth.data?.value ?? 0n,
    usdc: zapRead(d?.usdc, 0),
    usdcAllowance: zapRead(d?.usdc, 1),
    weth: zapRead(d?.weth, 0),
    wethAllowance: zapRead(d?.weth, 1),
    refetch: () => {
      void q.refetch();
      void eth.refetch();
    },
  };
}
