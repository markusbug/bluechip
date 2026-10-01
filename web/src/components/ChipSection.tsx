import { useState } from "react";
import { mockChipAbi } from "../abi";
import { siteConfig } from "../config";
import type { FundState } from "../hooks/useFund";
import type { WalletState } from "../hooks/useWallet";
import { explainError } from "../lib/errors";
import { fmt, usd } from "../lib/format";
import { runCalls } from "../lib/tx";
import { progressText } from "./MintPanel";
import { Button, CopyButton, LinkButton, TxStatus } from "./ui";

const INITIAL_SUPPLY = 100_000_000_000n * 10n ** 18n;

/** Each fund has its own burner; the stats add them up. */
export function ChipSection({ funds, wallet, onDone }: { funds: FundState[]; wallet: WalletState; onDone: () => void }) {
  const chip = siteConfig.chipAddress;
  const withBurner = funds.flatMap((f) => {
    const burner = f.config.deployment?.burner;
    return burner && !/^0x0+$/.test(burner) ? [{ fund: f, burner }] : [];
  });
  const chipBurned = withBurner.reduce((s, b) => s + b.fund.chipBurned, 0n);
  const burnedPct = Number((chipBurned * 1_000_000n) / INITIAL_SUPPLY) / 10_000;
  const pendingValues = withBurner.map(({ fund }) => (fund.navPerBlue !== undefined ? (Number(fund.pendingFees) / 1e18) * fund.navPerBlue : undefined));
  const pendingUsd = pendingValues.every((v) => v !== undefined) ? pendingValues.reduce((s, v) => s! + v!, 0) : undefined;
  const symbols = new Intl.ListFormat("en", { type: "disjunction" }).format(funds.map((f) => f.config.symbol));
  const mintFeeBps = funds[0].mintFeeBps;

  return (
    <section id="chip" className="scroll-mt-16 bg-blue-deep text-white">
      <div className="mx-auto max-w-6xl px-4 py-16 sm:px-6">
        <div className="grid gap-10 lg:grid-cols-[1fr_1.15fr]">
          <div className="min-w-0">
            <h2 className="font-display text-3xl font-bold tracking-tight sm:text-4xl">Every mint burns $CHIP.</h2>
            <p className="mt-4 max-w-lg text-white/75">
              Every {symbols} minted pays {(mintFeeBps / 100).toFixed(2)}% to a CHIP burner. It redeems those fees for the stocks,
              sells them for USDC, buys CHIP in its trading pool and burns it. Burned CHIP is gone for good, so the supply only
              shrinks as the fund grows.
            </p>
            {chip && (
              <div className="mt-8 flex flex-wrap items-center gap-2 text-sm">
                <span className="text-white/65">CHIP</span>
                <code className="min-w-0 break-all rounded-2xl bg-white/10 px-3 py-1.5 font-medium">{chip}</code>
                <span className="[&_button]:border-white/25 [&_button]:text-white">
                  <CopyButton text={chip} />
                </span>
              </div>
            )}
          </div>

          <div className="min-w-0 rounded-[20px] bg-white p-5 text-ink sm:p-7 dark:bg-surface">
            {withBurner.length > 0 ? (
              <>
                <dl className="grid grid-cols-2 gap-6">
                  <div>
                    <dt className="text-sm text-muted">CHIP burned</dt>
                    <dd className="mt-1 font-display text-2xl">{fmt(chipBurned, 18, 0)}</dd>
                    <dd className="text-xs text-muted">{burnedPct.toFixed(4)}% of the 100B supply</dd>
                  </div>
                  <div>
                    <dt className="text-sm text-muted">Fees waiting to burn</dt>
                    {withBurner.length === 1 ? (
                      <dd className="mt-1 font-display text-2xl">
                        {fmt(withBurner[0].fund.pendingFees, 18, 6)} {withBurner[0].fund.config.symbol}
                      </dd>
                    ) : (
                      <dd className="mt-1 font-display text-2xl">{pendingUsd !== undefined ? usd(pendingUsd) : "–"}</dd>
                    )}
                    <dd className="text-xs text-muted">
                      {withBurner.length === 1
                        ? pendingUsd !== undefined
                          ? usd(pendingUsd)
                          : ""
                        : withBurner.map(({ fund }) => `${fmt(fund.pendingFees, 18, 6)} ${fund.config.symbol}`).join(" + ")}
                    </dd>
                  </div>
                </dl>
                <p className="mt-6 text-sm text-muted">
                  A keeper runs the burn during US market hours once enough fees have built up. It can set the price it accepts
                  but can't send the fees anywhere else.
                </p>
                <div className="mt-4 grid gap-2 [&_a]:w-full">
                  {withBurner.map(({ fund, burner }) => (
                    <LinkButton key={burner} href={siteConfig.explorerAddress(burner)}>
                      {withBurner.length === 1 ? "See the burns on the explorer" : `See ${fund.config.symbol}'s burns on the explorer`}
                    </LinkButton>
                  ))}
                </div>
                {siteConfig.isMock && wallet.address && wallet.onChain && <Faucet wallet={wallet} onDone={onDone} />}
              </>
            ) : (
              <p className="text-muted">The CHIP burner goes live with CHIP.</p>
            )}
          </div>
        </div>

        <Buy />
      </div>
    </section>
  );
}

function Faucet({ wallet, onDone }: { wallet: WalletState; onDone: () => void }) {
  const chip = siteConfig.chipAddress!;
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();

  async function faucet() {
    setBusy(true);
    setError(undefined);
    try {
      await runCalls(wallet.address!, [{ address: chip, abi: mockChipAbi, functionName: "faucet", args: [], label: "Get test CHIP" }], (p) =>
        setMessage(progressText(p.label, p.step, p.total, p.stage)),
      );
      setMessage("1B test CHIP received.");
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <Button variant="outline" className="mt-3 w-full" disabled={busy} onClick={faucet}>
        Get test CHIP
      </Button>
      <TxStatus busy={busy} message={message} error={error} explorerTx={siteConfig.explorerTx} />
    </>
  );
}

/** Buying CHIP happens on Bankr, where it was launched. Embedded, with a new-tab fallback. */
function Buy() {
  const chip = siteConfig.chipAddress;
  if (!siteConfig.isMainnet) return null;
  return (
    <div className="mt-16 border-t border-white/15 pt-10">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h3 className="font-display text-2xl font-bold">Buy $CHIP</h3>
          <p className="mt-2 max-w-lg text-white/75">
            {chip ? "CHIP trades on Base through Bankr. Swap from ETH or USDC right here." : "CHIP launches on Bankr soon. The trade widget appears here once it's live."}
          </p>
        </div>
        {chip && (
          <div className="flex gap-2 [&_a]:border-white/25 [&_a]:text-white">
            <LinkButton href={siteConfig.bankrTrade(chip)}>Open on Bankr</LinkButton>
            <LinkButton href={siteConfig.explorerToken(chip)}>Basescan</LinkButton>
          </div>
        )}
      </div>
      {chip && (
        <>
          <div className="mt-6 overflow-hidden rounded-[20px] bg-white">
            <iframe
              src={siteConfig.bankrTrade(chip)}
              title="Buy $CHIP on Bankr"
              loading="lazy"
              allow="clipboard-write; web-share"
              referrerPolicy="strict-origin-when-cross-origin"
              className="block h-[900px] w-full"
            />
          </div>
          <p className="mt-3 text-sm text-white/65">
            Wallet not connecting inside the frame?{" "}
            <a className="underline" href={siteConfig.bankrTrade(chip)} target="_blank" rel="noreferrer">
              Open the trade page in a new tab
            </a>
            .
          </p>
        </>
      )}
    </div>
  );
}
