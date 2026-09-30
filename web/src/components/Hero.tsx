import { useState } from "react";
import { formatUnits } from "viem";
import type { FundState } from "../hooks/useFund";
import { compactUsd, pct, usd } from "../lib/format";
import { PokerChip } from "./PokerChip";
import { Stat } from "./ui";

export function Hero({ fund }: { fund: FundState }) {
  const [active, setActive] = useState<string | null>(null);
  const segs = fund.constituents.map((c) => ({ key: c.symbol, label: `${c.ticker} ${pct(c.weight)}`, weight: c.weight || 1 }));
  const a = fund.constituents.find((c) => c.symbol === active);
  const supply = Number(formatUnits(fund.totalSupply, 18));
  const cap = Number(formatUnits(fund.supplyCap, 18));
  const names = new Intl.ListFormat("en", { type: "conjunction" }).format(
    fund.constituents.map((c) => c.name.replace(/( Platforms Inc\.?|\.com Inc\.?| Inc\.?| Corporation)$/, "")),
  );

  return (
    <section id="top" className="grid items-center gap-10 py-12 sm:py-16 lg:grid-cols-[1.1fr_1fr] lg:gap-16">
      <div className="min-w-0">
        <h1 className="font-display text-4xl font-bold leading-[1.05] tracking-tight sm:text-5xl lg:text-6xl">
          Seven blue chips in one token.
        </h1>
        <p className="mt-6 max-w-xl text-lg leading-relaxed text-muted">
          $BLUE holds real tokenized shares of {names} on Base, weighted by market cap. Mint it by depositing the
          stocks and redeem it for them whenever you like. Every mint pays {(fund.mintFeeBps / 100).toFixed(2)}% into
          $CHIP.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <a href="#trade" className="inline-flex h-12 items-center rounded-full bg-blue px-6 font-semibold text-white hover:brightness-110">
            Mint $BLUE
          </a>
          <a href="#chip" className="inline-flex h-12 items-center rounded-full border border-line px-6 font-semibold hover:border-blue hover:text-blue">
            Get $CHIP
          </a>
        </div>
        <div className="mt-12 grid grid-cols-2 gap-6 border-t border-line pt-6 sm:grid-cols-3">
          <Stat label="Value of 1 BLUE" value={usd(fund.navPerBlue)} sub={priceNote(fund)} />
          <Stat label="Fund size" value={fund.deployed ? compactUsd(fund.aum) : "Not live yet"} />
          <Stat
            label="BLUE in circulation"
            value={fund.deployed ? supply.toLocaleString("en-US", { maximumFractionDigits: 2 }) : "–"}
            sub={fund.deployed && cap ? `Cap ${cap.toLocaleString("en-US")}` : undefined}
          />
        </div>
      </div>

      <div className="mx-auto w-full min-w-0 max-w-[420px]">
        <PokerChip segments={segs} active={active} onActive={setActive}>
          {a ? (
            <div>
              <div className="font-display text-3xl font-bold">{a.ticker}</div>
              <div className="mt-1 text-sm opacity-80">{a.name}</div>
              <div className="mt-2 font-display text-lg">{pct(a.weight)}</div>
            </div>
          ) : (
            <div>
              <div className="text-sm opacity-80">1 BLUE</div>
              <div className="font-display text-3xl font-bold">{usd(fund.navPerBlue)}</div>
              <div className="mt-1 text-sm opacity-80">{fund.constituents.length} stocks</div>
            </div>
          )}
        </PokerChip>
      </div>
    </section>
  );
}

function priceNote(fund: FundState) {
  if (!fund.constituents.every((c) => c.priceIsLive)) return "Snapshot prices, test network";
  const oldest = Math.min(...fund.constituents.map((c) => c.priceUpdatedAt ?? 0));
  const mins = Math.round((Date.now() / 1000 - oldest) / 60);
  return mins < 90 ? "Live Chainlink prices" : "Last Chainlink price, market closed";
}
