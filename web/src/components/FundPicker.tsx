import { useAccount, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { erc20Abi } from "viem";
import { siteConfig } from "../config";
import type { FundState } from "../hooks/useFund";
import { compactUsd, fmt, pct, usd } from "../lib/format";
import { MiniChip } from "./PokerChip";
import { TokenIcon } from "./ui";

/** One card per fund; the chosen one drives the holdings table and the mint and redeem panel below. */
export function FundPicker({ funds, selected, onSelect }: { funds: FundState[]; selected: string; onSelect: (id: string) => void }) {
  const { address, chainId } = useAccount();
  const onChain = !!address && chainId === siteConfig.chain.id;
  const deployed = funds.filter((f) => f.config.deployment);
  const balances = useReadContracts({
    contracts: deployed.map((f) => ({ address: f.config.deployment!.fund, abi: erc20Abi, functionName: "balanceOf", args: [address as Address] })),
    query: { enabled: onChain && deployed.length > 0, refetchInterval: 10_000 },
  });
  const balanceOf = (f: FundState) => {
    const r = balances.data?.[deployed.indexOf(f)];
    return r?.status === "success" ? (r.result as bigint) : undefined;
  };

  return (
    <section id="funds" className="scroll-mt-24 py-12">
      <h2 className="font-display text-2xl font-bold tracking-tight sm:text-3xl">Choose your fund</h2>
      <p className="mt-3 max-w-2xl text-muted">
        Each fund is its own token with its own basket. {funds.length === 2 ? "Both are" : "All are"} weighted the same way and minted,
        redeemed and rebalanced by the same contracts. Pick one to see what it holds and to mint or redeem it.
      </p>

      <div role="radiogroup" aria-label="Fund" className={`mt-8 grid gap-4 md:grid-cols-2 ${funds.length > 2 ? "xl:grid-cols-3" : ""}`}>
        {funds.map((f) => {
          const on = f.config.id === selected;
          const top = [...f.constituents].sort((a, b) => b.weight - a.weight);
          const balance = balanceOf(f);
          return (
            <button
              key={f.config.id}
              type="button"
              role="radio"
              aria-checked={on}
              onClick={() => onSelect(f.config.id)}
              className={`min-w-0 rounded-[20px] border bg-surface p-5 text-left transition sm:p-6 ${
                on ? "border-blue ring-2 ring-blue/25" : "border-line hover:border-blue/50"
              }`}
            >
              <div className="flex items-start gap-4">
                <MiniChip weights={top.map((c) => c.weight || 1)} size={56} />
                <div className="min-w-0 grow">
                  <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span className="font-display text-lg font-bold">{f.config.name}</span>
                    <span className="rounded-full bg-blue-soft px-2 py-0.5 text-xs font-bold text-blue">${f.config.symbol}</span>
                  </div>
                  <p className="mt-1 text-sm text-muted">{f.config.tagline}</p>
                </div>
                <span
                  aria-hidden
                  className={`mt-1 grid h-5 w-5 shrink-0 place-items-center rounded-full border-2 ${on ? "border-blue" : "border-line"}`}
                >
                  {on && <span className="h-2.5 w-2.5 rounded-full bg-blue" />}
                </span>
              </div>

              <div className="mt-5 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
                {top.slice(0, 3).map((c) => (
                  <span key={c.symbol} className="flex items-center gap-1.5">
                    <TokenIcon icon={c.icon} ticker={c.ticker} size={20} />
                    <span className="font-semibold">{c.ticker}</span>
                    <span className="text-muted">{pct(c.weight)}</span>
                  </span>
                ))}
                {top.length > 3 && <span className="text-muted">+{top.length - 3} more</span>}
              </div>

              <dl className="mt-5 grid grid-cols-3 gap-3 border-t border-line pt-4 text-sm">
                <div>
                  <dt className="text-muted">1 {f.config.symbol}</dt>
                  <dd className="mt-0.5 font-semibold">{usd(f.navPerBlue)}</dd>
                </div>
                <div>
                  <dt className="text-muted">Fund size</dt>
                  <dd className="mt-0.5 font-semibold">{f.deployed ? compactUsd(f.aum) : "Not live"}</dd>
                </div>
                <div>
                  <dt className="text-muted">You hold</dt>
                  <dd className="mt-0.5 truncate font-semibold">{balance === undefined ? "–" : fmt(balance, 18)}</dd>
                </div>
              </dl>
            </button>
          );
        })}
      </div>
    </section>
  );
}
