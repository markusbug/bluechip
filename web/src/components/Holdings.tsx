import { formatUnits } from "viem";
import type { FundState } from "../hooks/useFund";
import { siteConfig } from "../config";
import { pct, usd } from "../lib/format";
import { TokenIcon } from "./ui";

/** Share equivalents: raw token units times the token's multiplier (dividends and splits). */
const shares = (units: bigint, decimals: number, multiplier: bigint) => Number(formatUnits(units, decimals)) * (Number(multiplier) / 1e18);

export function Holdings({ fund }: { fund: FundState }) {
  const rows = [...fund.constituents].sort((a, b) => b.weight - a.weight);
  const { symbol } = fund.config;
  return (
    <section id="fund" className="scroll-mt-24 py-12">
      <div className="max-w-2xl">
        <h2 className="font-display text-2xl font-bold tracking-tight sm:text-3xl">What one {symbol} holds</h2>
        <p className="mt-3 text-muted">
          Shares of each company in proportion to its free float, the way the S&P 500 weights. Price moves keep
          that mix on target by themselves. When share counts change, a new index is posted with 7 days' notice and
          the fund trades back onto it on its own, in small steps during US market hours. Minting and redeeming never
          read a price.
        </p>
      </div>

      <div className="mt-8 overflow-x-auto rounded-[20px] border border-line bg-surface">
        <table className="w-full min-w-[640px] text-left text-sm">
          <thead className="text-muted">
            <tr className="border-b border-line">
              <th className="px-5 py-3 font-medium">Company</th>
              <th className="px-5 py-3 font-medium">Weight</th>
              <th className="px-5 py-3 text-right font-medium">Shares per {symbol}</th>
              <th className="px-5 py-3 text-right font-medium">Price</th>
              <th className="px-5 py-3 text-right font-medium">Fund holds</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((c) => (
              <tr key={c.symbol} className="border-b border-line last:border-0">
                <td className="px-5 py-3.5">
                  <a href={siteConfig.explorerToken(c.address)} target="_blank" rel="noreferrer" className="flex items-center gap-3 hover:text-blue">
                    <TokenIcon icon={c.icon} ticker={c.ticker} />
                    <span>
                      <span className="block font-semibold">{c.ticker}</span>
                      <span className="block text-xs text-muted">{c.name}</span>
                    </span>
                  </a>
                </td>
                <td className="px-5 py-3.5">
                  <div className="flex items-center gap-3">
                    <div className="h-1.5 w-24 overflow-hidden rounded-full bg-blue-soft">
                      <div className="h-full rounded-full bg-blue" style={{ width: pct(Math.min(1, c.weight * 3), 2) }} />
                    </div>
                    <span className="w-12 font-medium">{pct(c.weight)}</span>
                  </div>
                </td>
                <td className="px-5 py-3.5 text-right">{shares(c.unitsPerBlue, c.decimals, c.multiplier).toFixed(5)}</td>
                <td className="px-5 py-3.5 text-right">{usd(c.price)}</td>
                <td className="px-5 py-3.5 text-right">
                  {fund.deployed ? shares(c.holdings, c.decimals, c.multiplier).toLocaleString("en-US", { maximumFractionDigits: 4 }) : "–"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
