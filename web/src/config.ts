/**
 * Single config surface: which chain, which funds, which links.
 * Each fund's contract addresses come from its file in contracts/deployments/, written by the deploy
 * scripts: <chainId>.json for BLUE, <chainId>-<fund>.json for the others (the rule in
 * scripts/lib/fund.mjs). Its planned basket comes from contracts/basket/.
 */
import type { Address, Chain } from "viem";
import { base, baseSepolia, foundry } from "viem/chains";
import stocksMeta from "./data/stocks.json";
import { FUND_INFO, type FundInfo } from "./funds";

const env = import.meta.env;

export type Deployment = {
  /** The fund id (absent in files written before there was more than one fund: those are BLUE). */
  id?: string;
  /** The fund token's name and symbol (absent in the same older files). */
  name?: string;
  symbol?: string;
  chainId: number;
  startBlock: number;
  mock: boolean;
  fund: Address;
  /** Buys and burns CHIP with the mint fees. Absent until CHIP exists. */
  burner?: Address;
  chip: Address;
  /** Trades the holdings back onto the index. Absent in deployments made before it existed. */
  rebalancer?: Address;
  swapper?: Address;
  /** Mints the fund for USDC or ETH, buying the stocks on Aerodrome. Absent in deployments made before it existed. */
  zap?: Address;
  usdc?: Address;
  /** Absent in deployments made before the zap took WETH. */
  weth?: Address;
  tokens: Address[];
  feeds: Address[];
  symbols: string[];
  /** Testnet only: one-transaction mock basket faucet. */
  faucet?: Address;
};

/** contracts/basket/<basket>.json, written by scripts/basket.mjs: the planned basket at snapshot prices. */
export type BasketFile = {
  name: string;
  tokens: { symbol: string; address: string; feed: string; decimals: number; price: number; multiplier: number; units: string }[];
};

export type FundConfig = FundInfo & {
  /** Null until the fund is deployed on this chain. */
  deployment: Deployment | null;
  basket: BasketFile;
};

const chains = { base, baseSepolia, anvil: foundry } as const satisfies Record<string, Chain>;
const chainKey = ((env.VITE_CHAIN as string | undefined) ?? "base") as keyof typeof chains;
export const chain: Chain = chains[chainKey] ?? base;

const deploymentFiles = import.meta.glob<Deployment>("../../contracts/deployments/*.json", { eager: true, import: "default" });
const basketFiles = import.meta.glob<BasketFile>(["../../contracts/basket/*.json", "!../../contracts/basket/*.config.json"], {
  eager: true,
  import: "default",
});

/** This chain's deployment of a fund, by file name: <chainId>.json is BLUE, <chainId>-<id>.json the others. */
function deploymentOf(id: string): Deployment | null {
  for (const [path, d] of Object.entries(deploymentFiles)) {
    const m = path.match(/\/(\d+)(?:-([a-z0-9]+))?\.json$/);
    if (m && Number(m[1]) === chain.id && (m[2] ?? "blue") === id && d.chainId === chain.id) return d;
  }
  return null;
}

/**
 * The funds this site offers, in display order. BLUE always shows (before its deployment, as the
 * planned basket); every other fund appears once it is deployed on this chain.
 */
export const funds: FundConfig[] = FUND_INFO.flatMap((info) => {
  const deployment = deploymentOf(info.id);
  const basket = basketFiles[`../../contracts/basket/${info.basketName}.json`];
  if (!basket || (!deployment && info.id !== "blue")) return [];
  return [{ ...info, deployment, basket }];
});

const chipOverride = env.VITE_CHIP_ADDRESS as Address | undefined;
const chipAddress: Address | null =
  chipOverride && /^0x[0-9a-fA-F]{40}$/.test(chipOverride) ? chipOverride : (funds.find((f) => f.deployment)?.deployment?.chip ?? null);

export type StockMeta = { ticker: string; name: string; icon: string | null; feed: string; mainnetAddress: string };
export const stockMeta = stocksMeta as Record<string, StockMeta>;

const explorer = chain.blockExplorers?.default.url;

export const siteConfig = {
  name: "Bluechip",
  siteUrl: (env.VITE_SITE_URL as string | undefined) ?? "https://onbluechip.com",
  githubUrl: (env.VITE_GITHUB_URL as string | undefined) ?? "https://github.com/markusbug/bluechip",
  rpcUrl: env.VITE_RPC_URL as string | undefined,
  chain,
  chainName: chain.id === foundry.id ? "Local test chain" : chain.name,
  isMainnet: chain.id === base.id,
  isLocal: chain.id === foundry.id,
  /** Testnet deployments use mock stocks anyone can mint and a mock CHIP with a faucet. */
  isMock: funds.some((f) => f.deployment?.mock),
  chipAddress,
  bankrTrade: (token: string) => `https://bankr.bot/terminal/trade?out=${token}&chain=base`,
  hasExplorer: !!explorer,
  explorerAddress: (a: string) => (explorer ? `${explorer}/address/${a}` : "#"),
  explorerToken: (a: string) => (explorer ? `${explorer}/token/${a}` : "#"),
  explorerTx: (h: string) => (explorer ? `${explorer}/tx/${h}` : ""),
};
