import { useState } from "react";
import type { FundState } from "../hooks/useFund";
import type { WalletState } from "../hooks/useWallet";
import { deployment } from "../config";
import { MintPanel } from "./MintPanel";
import { RedeemPanel } from "./RedeemPanel";
import { Panel } from "./ui";

export function Trade({ fund, wallet, onDone }: { fund: FundState; wallet: WalletState; onDone: () => void }) {
  const [tab, setTab] = useState<"mint" | "redeem">("mint");
  return (
    <section id="trade" className="grid scroll-mt-24 gap-10 py-12 lg:grid-cols-[1fr_1.15fr]">
      <div className="min-w-0 max-w-md lg:sticky lg:top-28 lg:self-start">
        <h2 className="font-display text-2xl font-bold tracking-tight sm:text-3xl">Mint and redeem</h2>
        <p className="mt-3 text-muted">
          BLUE is created and destroyed in kind. To mint, deposit each stock in the right proportion. To redeem, burn BLUE and
          get your share of every stock back. No oracle, no pricing, no one in the middle.
        </p>
        <p className="mt-3 text-muted">
          {deployment?.zap
            ? "Don't hold the stocks? Pay with USDC, ETH or WETH instead: one transaction buys exactly the stocks your mint deposits on Aerodrome and mints your BLUE."
            : "Short on a stock? Each row links to Bankr, where you can buy it on Base."}
        </p>
        {!fund.deployed && <p className="mt-6 rounded-2xl bg-blue-soft p-4 text-sm">The fund isn&apos;t deployed on this network yet.</p>}
      </div>

      {fund.deployed && (
        <Panel className="min-w-0">
          <div role="tablist" className="mb-6 inline-flex rounded-full border border-line p-1">
            {(["mint", "redeem"] as const).map((t) => (
              <button
                key={t}
                role="tab"
                aria-selected={tab === t}
                onClick={() => setTab(t)}
                className={`h-9 rounded-full px-5 text-sm font-semibold capitalize transition ${tab === t ? "bg-blue text-white" : "text-muted hover:text-ink"}`}
              >
                {t}
              </button>
            ))}
          </div>
          {tab === "mint" ? <MintPanel fund={fund} wallet={wallet} onDone={onDone} /> : <RedeemPanel fund={fund} wallet={wallet} onDone={onDone} />}
        </Panel>
      )}
    </section>
  );
}
