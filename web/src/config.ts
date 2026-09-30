/**
 * Single config surface: which chain, which contracts, which links.
 * Contract addresses come from contracts/deployments/<chainId>.json, written by the deploy scripts.
 */
import type { Address, Chain } from "viem";
import { base, baseSepolia, foundry } from "viem/chains";
import basketJson from "../../contracts/basket/mag7.json";
import stocksMeta from "./data/stocks.json";

const env = import.meta.env;

export type Deployment = {
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
  /** Mints BLUE for USDC or ETH, buying the stocks on Aerodrome. Absent in deployments made before it existed. */
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

const chains = { base, baseSepolia, anvil: foundry } as const satisfies Record<string, Chain>;
const chainKey = ((env.VITE_CHAIN as string | undefined) ?? "base") as keyof typeof chains;
export const chain: Chain = chains[chainKey] ?? base;

const deployments = import.meta.glob<Deployment>("../../contracts/deployments/*.json", {
  eager: true,
  import: "default",
});
export const deployment: Deployment | null =
  Object.values(deployments).find((d) => d.chainId === chain.id) ?? null;

const chipOverride = env.VITE_CHIP_ADDRESS as Address | undefined;
const chipAddress: Address | null =
  chipOverride && /^0x[0-9a-fA-F]{40}$/.test(chipOverride) ? chipOverride : (deployment?.chip ?? null);

export type StockMeta = { ticker: string; name: string; icon: string | null; feed: string; mainnetAddress: string };
export const stockMeta = stocksMeta as Record<string, StockMeta>;
export const basket = basketJson;

const explorer = chain.blockExplorers?.default.url;

export const siteConfig = {
  name: "Bluechip",
  siteUrl: (env.VITE_SITE_URL as string | undefined) ?? "https://bluechip.markushaas.com",
  githubUrl: (env.VITE_GITHUB_URL as string | undefined) ?? "https://github.com/markusbug/bluechip",
  rpcUrl: env.VITE_RPC_URL as string | undefined,
  chain,
  chainName: chain.id === foundry.id ? "Local test chain" : chain.name,
  isMainnet: chain.id === base.id,
  isLocal: chain.id === foundry.id,
  /** Testnet deployments use mock stocks anyone can mint and a mock CHIP with a faucet. */
  isMock: deployment?.mock ?? false,
  chipAddress,
  bankrTrade: (token: string) => `https://bankr.bot/terminal/trade?out=${token}&chain=base`,
  hasExplorer: !!explorer,
  explorerAddress: (a: string) => (explorer ? `${explorer}/address/${a}` : "#"),
  explorerToken: (a: string) => (explorer ? `${explorer}/token/${a}` : "#"),
  explorerTx: (h: string) => (explorer ? `${explorer}/tx/${h}` : ""),
};
