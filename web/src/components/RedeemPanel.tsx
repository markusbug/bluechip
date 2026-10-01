import { useState } from "react";
import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { formatUnits } from "viem";
import { blueFundAbi } from "../abi";
import { siteConfig } from "../config";
import type { FundState } from "../hooks/useFund";
import type { WalletState } from "../hooks/useWallet";
import { track } from "../lib/analytics";
import { errorKind, explainError } from "../lib/errors";
import { fmt, parseAmount, usd } from "../lib/format";
import { runCalls } from "../lib/tx";
import { progressText } from "./MintPanel";
import { AmountInput, Button, TokenIcon, TxStatus } from "./ui";

export function RedeemPanel({ fund, wallet, onDone }: { fund: FundState; wallet: WalletState; onDone: () => void }) {
  const [amount, setAmount] = useState("");
  const [skip, setSkip] = useState<Address[]>([]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();
  const [hash, setHash] = useState<string>();

  const d = fund.config.deployment!;
  const { symbol } = fund.config;
  const shares = parseAmount(amount, 18);
  const preview = useReadContract({
    address: d.fund,
    abi: blueFundAbi,
    functionName: "previewRedeem",
    args: [shares ?? 0n],
    query: { enabled: !!shares && shares > 0n },
  });
  const out = preview.data?.[1] ?? [];
  const tooMuch = !!shares && shares > wallet.shares;
  const value = shares && fund.navPerBlue ? (Number(shares) / 1e18) * fund.navPerBlue : undefined;

  async function redeem() {
    const account = wallet.address!;
    setBusy(true);
    setError(undefined);
    setHash(undefined);
    track("redeem_start", { fund: symbol });
    try {
      const call =
        skip.length === 0
          ? { address: d.fund, abi: blueFundAbi, functionName: "redeem", args: [shares!, account], label: "Redeem" }
          : { address: d.fund, abi: blueFundAbi, functionName: "redeemExcept", args: [shares!, account, skip], label: "Redeem" };
      const tx = await runCalls(account, [call], (p) => setMessage(progressText(p.label, p.step, p.total, p.stage)));
      setHash(tx);
      setMessage(`Redeemed ${fmt(shares!, 18)} ${symbol} for the stocks.`);
      track("redeem", { fund: symbol, value: value === undefined ? undefined : Math.round(value), currency: "USD" });
      setAmount("");
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
      track("redeem_failed", { fund: symbol, reason: errorKind(e) });
    } finally {
      setBusy(false);
    }
  }

  const connected = !!wallet.address && wallet.onChain;
  return (
    <div>
      <AmountInput
        label={`${symbol} to redeem`}
        value={amount}
        onChange={setAmount}
        unit={symbol}
        onMax={connected ? () => setAmount(formatUnits(wallet.shares, 18)) : undefined}
      />
      <p className="mt-2 text-sm text-muted">
        {connected ? `You hold ${fmt(wallet.shares, 18)} ${symbol}. ` : ""}Redeeming is free and can never be paused.
        {value !== undefined && ` About ${usd(value)} of stock.`}
      </p>

      <h3 className="mt-6 text-sm font-semibold">You receive</h3>
      <ul className="mt-2 divide-y divide-line">
        {fund.constituents.map((c, i) => {
          const skipped = skip.includes(c.address);
          return (
            <li key={c.symbol} className={`flex items-center gap-3 py-2.5 text-sm ${skipped ? "text-muted line-through" : ""}`}>
              <TokenIcon icon={c.icon} ticker={c.ticker} size={24} />
              <span className="w-14 font-semibold">{c.ticker}</span>
              <span className="grow">{fmt(out[i], c.decimals, 6)}</span>
            </li>
          );
        })}
      </ul>

      <details className="mt-4 text-sm">
        <summary className="cursor-pointer font-medium text-muted hover:text-ink">A stock can&apos;t be transferred right now?</summary>
        <p className="mt-2 text-muted">
          Issuers can pause a token. If one is paused, a normal redeem fails. Tick it to leave your share of that stock in the fund
          (it goes to the remaining holders) and take everything else.
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          {fund.constituents.map((c) => {
            const on = skip.includes(c.address);
            return (
              <label key={c.symbol} className={`flex cursor-pointer items-center gap-1.5 rounded-full border px-3 py-1 ${on ? "border-warn text-warn" : "border-line"}`}>
                <input
                  type="checkbox"
                  className="accent-[var(--warn)]"
                  checked={on}
                  onChange={() => setSkip(on ? skip.filter((a) => a !== c.address) : [...skip, c.address])}
                />
                {c.ticker}
              </label>
            );
          })}
        </div>
      </details>

      <Button size="lg" className="mt-6 w-full" disabled={!connected || busy || !shares || shares === 0n || tooMuch} onClick={redeem}>
        {!connected ? "Connect a wallet to redeem" : tooMuch ? "More than you hold" : skip.length ? `Redeem without ${skip.length} forfeited` : "Redeem"}
      </Button>
      <TxStatus busy={busy} message={message} error={error} hash={hash} explorerTx={siteConfig.explorerTx} />
    </div>
  );
}
