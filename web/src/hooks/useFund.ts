import { useReadContracts } from "wagmi";
import type { Address } from "viem";
import { erc20Abi, parseAbi } from "viem";
import { blueFundAbi, chipBurnerAbi } from "../abi";
import { basket, deployment, siteConfig, stockMeta } from "../config";

const feedAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);
const multiplierAbi = parseAbi(["function multiplier() view returns (uint256)"]);

export type Constituent = {
  address: Address;
  symbol: string;
  ticker: string;
  name: string;
  icon: string | null;
  decimals: number;
  /** Token units behind one whole BLUE. */
  unitsPerBlue: bigint;
  holdings: bigint;
  /** WAD; dividends and splits move this, not balances. */
  multiplier: bigint;
  /** USD per raw token (total-return feed, multiplier already included). */
  price: number | undefined;
  priceIsLive: boolean;
  priceUpdatedAt: number | undefined;
  /** Share of NAV. */
  weight: number;
};

export type FundState = {
  deployed: boolean;
  seeded: boolean;
  constituents: Constituent[];
  totalSupply: bigint;
  supplyCap: bigint;
  mintFeeBps: number;
  navPerBlue: number | undefined;
  aum: number | undefined;
  /** Fee BLUE waiting in the CHIP burner. */
  pendingFees: bigint;
  /** CHIP the burner has bought and burned so far. */
  chipBurned: bigint;
  chipSupply: bigint;
  isLoading: boolean;
  refetch: () => void;
};

const snapshotPrice = (symbol: string) => basket.tokens.find((t) => t.symbol === symbol)?.price;

/**
 * Everything public about the fund, read in one multicall and refreshed every 15s.
 * Before deployment it shows the planned basket from contracts/basket/mag7.json.
 */
export function useFund(): FundState {
  const d = deployment;
  const n = d?.tokens.length ?? 0;
  const fund = d ? { address: d.fund, abi: blueFundAbi } : undefined;
  const hasFeeds = !!d && d.feeds.length === n && n > 0;
  // A fund can go live before CHIP: then there is no burner yet and these reads come back empty.
  const burner = (d?.burner ?? "0x0000000000000000000000000000000000000000") as Address;
  const hasBurner = !/^0x0+$/.test(burner);

  const contracts = d
    ? [
        { ...fund!, functionName: "totalSupply" },
        { ...fund!, functionName: "supplyCap" },
        { ...fund!, functionName: "mintFeeBps" },
        { ...fund!, functionName: "seeded" },
        { ...fund!, functionName: "unitsPerShare" },
        { ...fund!, functionName: "balanceOf", args: [burner] },
        { address: siteConfig.chipAddress ?? d.chip, abi: erc20Abi, functionName: "totalSupply" },
        { address: burner, abi: chipBurnerAbi, functionName: "totalBurned" },
        ...d.tokens.map((t) => ({ ...fund!, functionName: "holdings", args: [t] })),
        ...d.tokens.map((t) => ({ address: t, abi: erc20Abi, functionName: "decimals" })),
        ...d.tokens.map((t) => ({ address: t, abi: multiplierAbi, functionName: "multiplier" })),
        ...(hasFeeds ? d.feeds.map((f) => ({ address: f, abi: feedAbi, functionName: "latestRoundData" })) : []),
        { ...fund!, functionName: "seedUnits" },
      ]
    : siteConfig.isMainnet
      ? basket.tokens.map((t) => ({ address: t.feed as Address, abi: feedAbi, functionName: "latestRoundData" }))
      : [];

  const q = useReadContracts({
    contracts: contracts as never,
    query: { enabled: contracts.length > 0, refetchInterval: 15_000 },
  });
  const r = (q.data ?? []) as { status: "success" | "failure"; result?: unknown }[];
  const ok = <T,>(i: number, fallback: T): T => (r[i]?.status === "success" ? (r[i].result as T) : fallback);

  if (!d) {
    // Planned basket, before the fund exists on this chain. Live feed prices on mainnet.
    const constituents: Constituent[] = basket.tokens.map((t, i) => {
      const feed = ok<readonly [bigint, bigint, bigint, bigint, bigint] | null>(i, null);
      return {
        address: t.address as Address,
        symbol: t.symbol,
        ...meta(t.symbol),
        decimals: t.decimals,
        unitsPerBlue: BigInt(t.units),
        holdings: 0n,
        multiplier: BigInt(Math.round(t.multiplier * 1e6)) * 10n ** 12n,
        price: feed ? Number(feed[1]) / 1e8 : t.price,
        priceIsLive: !!feed,
        priceUpdatedAt: feed ? Number(feed[3]) : undefined,
        weight: 0,
      };
    });
    const nav = navAndWeights(constituents);
    return {
      deployed: false,
      seeded: false,
      constituents,
      totalSupply: 0n,
      supplyCap: 0n,
      mintFeeBps: 30,
      navPerBlue: nav,
      aum: undefined,
      pendingFees: 0n,
      chipBurned: 0n,
      chipSupply: 0n,
      isLoading: false,
      refetch: () => {},
    };
  }

  const totalSupply = ok<bigint>(0, 0n);
  const base = 8;
  // Before the first mint the fund holds nothing and unitsPerShare is all zeros: show the fixed
  // seed ratio the first mint will deposit instead.
  const seedUnits = ok<readonly bigint[]>(base + 3 * n + (hasFeeds ? n : 0), []);
  const units = totalSupply === 0n ? seedUnits : ok<readonly [readonly Address[], readonly bigint[]]>(4, [[], []])[1];
  const constituents: Constituent[] = d.tokens.map((address, i) => {
    const symbol = d.symbols[i];
    const decimals = ok<number>(base + n + i, 8);
    const feed = hasFeeds ? ok<readonly [bigint, bigint, bigint, bigint, bigint] | null>(base + 3 * n + i, null) : null;
    return {
      address,
      symbol,
      ...meta(symbol),
      decimals,
      unitsPerBlue: units[i] ?? 0n,
      holdings: ok<bigint>(base + i, 0n),
      multiplier: ok<bigint>(base + 2 * n + i, 10n ** 18n),
      price: feed ? Number(feed[1]) / 1e8 : snapshotPrice(symbol),
      priceIsLive: !!feed,
      priceUpdatedAt: feed ? Number(feed[3]) : undefined,
      weight: 0,
    };
  });

  const navPerBlue = navAndWeights(constituents);

  return {
    deployed: true,
    seeded: ok<boolean>(3, false),
    constituents,
    totalSupply,
    supplyCap: ok<bigint>(1, 0n),
    mintFeeBps: Number(ok<number | bigint>(2, 0)),
    navPerBlue,
    aum: navPerBlue === undefined ? undefined : navPerBlue * (Number(totalSupply) / 1e18),
    pendingFees: hasBurner ? ok<bigint>(5, 0n) : 0n,
    chipSupply: ok<bigint>(6, 0n),
    chipBurned: hasBurner ? ok<bigint>(7, 0n) : 0n,
    isLoading: q.isLoading,
    refetch: () => void q.refetch(),
  };
}

/** NAV of one BLUE in USD; fills in each constituent's weight as a side effect. */
function navAndWeights(constituents: Constituent[]): number | undefined {
  const values = constituents.map((c) => (c.price === undefined ? undefined : (Number(c.unitsPerBlue) / 10 ** c.decimals) * c.price));
  if (!values.every((v) => v !== undefined)) return undefined;
  const nav = values.reduce((s, v) => s + v!, 0);
  if (!(nav > 0)) return undefined;
  constituents.forEach((c, i) => (c.weight = values[i]! / nav));
  return nav;
}

function meta(symbol: string) {
  const m = stockMeta[symbol];
  return { ticker: m?.ticker ?? symbol.replace(/c$/, ""), name: m?.name ?? symbol, icon: m?.icon ?? null };
}
