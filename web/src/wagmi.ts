import { createConfig, http, mock } from "wagmi";
import { baseAccount, injected } from "wagmi/connectors";
import { foundry } from "viem/chains";
import { siteConfig } from "./config";

// anvil's first dev account; only offered when the site points at a local chain.
const ANVIL_ACCOUNT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

const connectors = [
  injected(),
  // No telemetry: the site itself has no analytics and shouldn't ship any through a wallet SDK.
  baseAccount({ appName: siteConfig.name, preference: { telemetry: false } }),
  ...(siteConfig.chain.id === foundry.id ? [mock({ accounts: [ANVIL_ACCOUNT], features: { reconnect: true } })] : []),
];

export const wagmiConfig = createConfig({
  chains: [siteConfig.chain],
  connectors,
  // One HTTP request for everything asked in the same moment (the public Base RPC rate-limits per request).
  transports: { [siteConfig.chain.id]: http(siteConfig.rpcUrl, { batch: { wait: 16 } }) },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
