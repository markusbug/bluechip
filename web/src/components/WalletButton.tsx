import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { useState } from "react";
import { siteConfig } from "../config";
import { shortAddress } from "../lib/format";
import { Button } from "./ui";

type Connectors = ReturnType<typeof useConnect>["connectors"];
/** MetaMask, Rabby, Ambire etc. announce themselves (EIP-6963); hide the generic entry when any did. */
const visible = (cs: Connectors) => (cs.some((c) => c.type === "injected" && c.id !== "injected") ? cs.filter((c) => c.id !== "injected") : cs);

const connectorLabel = (name: string) => (name === "Injected" ? "Browser wallet" : name === "Mock Connector" ? "Anvil dev account" : name);

export function WalletButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false);

  if (!isConnected || !address) {
    return (
      <div className="relative">
        <Button size="sm" onClick={() => setOpen((o) => !o)} aria-expanded={open} disabled={isPending}>
          Connect wallet
        </Button>
        {open && (
          <div className="absolute right-0 z-30 mt-2 w-60 rounded-2xl border border-line bg-surface p-2 shadow-lg">
            {visible(connectors).map((c) => (
              <button
                key={c.uid}
                className="block w-full rounded-xl px-3 py-2.5 text-left text-sm font-medium hover:bg-blue-soft"
                onClick={() => {
                  setOpen(false);
                  connect({ connector: c, chainId: siteConfig.chain.id });
                }}
              >
                {connectorLabel(c.name)}
              </button>
            ))}
          </div>
        )}
      </div>
    );
  }

  if (chainId !== siteConfig.chain.id) {
    return (
      <Button size="sm" disabled={switching} onClick={() => switchChain({ chainId: siteConfig.chain.id })}>
        Switch to {siteConfig.chainName}
      </Button>
    );
  }

  return (
    <div className="flex items-center gap-1">
      <span className="rounded-full border border-line bg-surface px-3 py-1.5 text-sm font-medium" title={address}>
        {shortAddress(address)}
      </span>
      <Button variant="quiet" size="sm" onClick={() => disconnect()} aria-label="Disconnect wallet">
        ✕
      </Button>
    </div>
  );
}
