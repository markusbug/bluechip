import { useState } from "react";
import { useSimulateContract } from "wagmi";
import type { Abi, Address } from "viem";
import { erc20Abi } from "viem";
import { blueFundAbi, mintZapAbi, mockStockAbi } from "../abi";
import { deployment, siteConfig } from "../config";
import type { WalletState } from "../hooks/useWallet";
import { explainError } from "../lib/errors";
import { fmt, pct, usd } from "../lib/format";
import { permitDeadline, permitDomain, signPermit } from "../lib/permit";
import { canBatch, runCalls, type Call } from "../lib/tx";
import { progressText } from "./MintPanel";
import { Button, TxStatus } from "./ui";

export type PayToken = "usdc" | "eth" | "weth";

const TOLERANCES = [50, 100, 300] as const;
/** Above this much over the fund's value, say why the price may be off. */
const PREMIUM_WARNING = 0.02;

/** The zap's own errors plus the fund's, so a refusal from either one gets a readable message. */
const zapAbi = [...mintZapAbi, ...blueFundAbi.filter((x) => x.type === "error")] as Abi;

/**
 * Mint with USDC, ETH or WETH: the zap buys exactly the stocks the mint deposits on Aerodrome and
 * mints, in one transaction. The price is `quoteMint` (simulated with eth_call), plus a slippage
 * allowance the contract enforces as a maximum. Approvals and permits are for that maximum only.
 * WETH has no permit, so a plain wallet approves and then mints (two transactions).
 */
export function ZapMint({
  pay,
  shares,
  received,
  value,
  overCap,
  wallet,
  onDone,
}: {
  pay: PayToken;
  shares: bigint | undefined;
  /** BLUE credited to the minter, after the fee. */
  received: bigint;
  /** NAV of the mint in USD at the feed prices. */
  value: number | undefined;
  overCap: boolean;
  wallet: WalletState;
  onDone: () => void;
}) {
  const [toleranceBps, setToleranceBps] = useState<number>(100);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();
  const [hash, setHash] = useState<string>();

  const d = deployment!;
  const zap = d.zap!;
  const usdc = d.usdc!;
  const weth = d.weth;
  const quote = useSimulateContract({
    address: zap,
    abi: mintZapAbi,
    functionName: "quoteMint",
    args: [shares ?? 0n],
    query: { enabled: !!shares && shares > 0n && !overCap, refetchInterval: 15_000 },
  });
  const [usdcIn, ethIn] = quote.data?.result ?? [undefined, undefined];
  const cost = pay === "usdc" ? usdcIn : ethIn;
  const decimals = pay === "usdc" ? 6 : 18;
  const unit = { usdc: "USDC", eth: "ETH", weth: "WETH" }[pay];
  const max = cost === undefined ? undefined : (cost * BigInt(10_000 + toleranceBps)) / 10_000n;
  const balance = { usdc: wallet.usdc, eth: wallet.eth, weth: wallet.weth }[pay];
  // Every stock is bought with USDC on every route, so the USDC quote is the price in dollars.
  // WETH buys that USDC in the same pool ETH does, so it costs the same as ETH.
  const costUsd = usdcIn === undefined ? undefined : Number(usdcIn) / 1e6;
  const premium = costUsd !== undefined && value ? costUsd / value - 1 : undefined;

  const connected = !!wallet.address && wallet.onChain;
  const short = connected && max !== undefined && balance < max;

  async function mint() {
    const account = wallet.address!;
    const deadline = permitDeadline();
    setBusy(true);
    setError(undefined);
    setHash(undefined);
    try {
      const progress = (p: { label: string; step: number; total: number; stage: "sign" | "wallet" | "pending" }) =>
        setMessage(progressText(p.label, p.step, p.total, p.stage));
      let calls: Call[];
      if (pay === "eth") {
        calls = [{ address: zap, abi: zapAbi, functionName: "mintWithEth", args: [shares!, account, deadline], value: max!, label: "Buy and mint" }];
      } else if (pay === "weth") {
        const mintCall: Call = { address: zap, abi: zapAbi, functionName: "mintWithWeth", args: [shares!, account, max!, deadline], label: "Buy and mint" };
        const approve: Call = { address: weth!, abi: erc20Abi, functionName: "approve", args: [zap, max!], label: "Approve WETH" };
        calls = wallet.wethAllowance >= max! ? [mintCall] : [approve, mintCall];
      } else {
        const mintCall: Call = { address: zap, abi: zapAbi, functionName: "mintWithUsdc", args: [shares!, account, max!, deadline], label: "Buy and mint" };
        const approve: Call = { address: usdc, abi: erc20Abi, functionName: "approve", args: [zap, max!], label: "Approve USDC" };
        if (wallet.usdcAllowance >= max!) {
          calls = [mintCall];
        } else if (await canBatch(account)) {
          calls = [approve, mintCall];
        } else {
          // Plain EOA: one gasless USDC permit, then a single transaction.
          const domain = await permitDomain(usdc);
          if (domain) {
            setMessage("Sign: allow the zap to spend this mint's USDC (no gas)");
            const permit = await signPermit({ token: usdc, domain, owner: account, spender: zap, value: max!, deadline });
            calls = [{ ...mintCall, functionName: "mintWithUsdcPermit", args: [shares!, account, max!, deadline, permit] }];
          } else {
            calls = [approve, mintCall];
          }
        }
      }
      setHash(await runCalls(account, calls, progress));
      setMessage(`Minted ${fmt(received, 18)} BLUE.${pay === "eth" ? " Unspent ETH went back to your wallet." : ""}`);
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
    } finally {
      setBusy(false);
    }
  }

  async function faucet() {
    const account = wallet.address!;
    setBusy(true);
    setError(undefined);
    try {
      const tx = await runCalls(
        account,
        [{ address: usdc as Address, abi: mockStockAbi, functionName: "mint", args: [account, max! * 2n], label: "Get test USDC" }],
        (p) => setMessage(progressText(p.label, p.step, p.total, p.stage)),
      );
      setHash(tx);
      setMessage("Test USDC received.");
      onDone();
    } catch (e) {
      setMessage(undefined);
      setError(explainError(e));
    } finally {
      setBusy(false);
    }
  }

  const quoteFailed = quote.isError && !!shares && shares > 0n && !overCap;
  const disabled = !connected || busy || !shares || shares === 0n || overCap || max === undefined || short;

  return (
    <div>
      <dl className="mt-6 divide-y divide-line text-sm">
        <div className="flex justify-between gap-4 py-2.5">
          <dt className="text-muted">You pay</dt>
          <dd className="text-right font-semibold">
            {quoteFailed ? "No quote" : cost === undefined ? "…" : `${fmt(cost, decimals, pay === "usdc" ? 2 : 6)} ${unit}`}
          </dd>
        </div>
        <div className="flex justify-between gap-4 py-2.5">
          <dt className="text-muted">Most you pay</dt>
          <dd className="text-right">{max === undefined ? "–" : `${fmt(max, decimals, pay === "usdc" ? 2 : 6)} ${unit}`}</dd>
        </div>
        <div className="flex items-center justify-between gap-4 py-2.5">
          <dt className="text-muted">Slippage allowed</dt>
          <dd className="inline-flex rounded-full border border-line p-0.5">
            {TOLERANCES.map((bps) => (
              <button
                key={bps}
                type="button"
                aria-pressed={toleranceBps === bps}
                onClick={() => setToleranceBps(bps)}
                className={`h-7 rounded-full px-3 text-xs font-semibold transition ${toleranceBps === bps ? "bg-blue text-white" : "text-muted hover:text-ink"}`}
              >
                {pct(bps / 10_000, bps % 100 === 0 ? 0 : 1)}
              </button>
            ))}
          </dd>
        </div>
        {premium !== undefined && (
          <div className="flex justify-between gap-4 py-2.5">
            <dt className="text-muted">Price vs the fund&apos;s value</dt>
            <dd className={`text-right ${premium > PREMIUM_WARNING ? "font-semibold text-warn" : ""}`}>
              {premium >= 0 ? "+" : ""}
              {pct(premium, 2)} ({usd(costUsd)} for {usd(value)})
            </dd>
          </div>
        )}
      </dl>

      {premium !== undefined && premium > PREMIUM_WARNING && (
        <p className="mt-3 rounded-2xl bg-blue-soft p-3 text-sm">
          The stock pools are pricing this mint {pct(premium, 1)} above the fund&apos;s value at Chainlink prices. Pools are thin, and
          they drift outside US market hours. Try a smaller amount, or wait for the session.
        </p>
      )}
      {quoteFailed && (
        <p className="mt-3 text-sm text-warn">The pools can&apos;t fill this size right now. Try a smaller amount.</p>
      )}

      {connected && short && siteConfig.isMock && pay === "usdc" && (
        <Button variant="outline" className="mt-4" onClick={faucet} disabled={busy}>
          Get test USDC for this mint
        </Button>
      )}

      <Button size="lg" className="mt-6 w-full" disabled={disabled} onClick={mint}>
        {!connected
          ? "Connect a wallet to mint"
          : overCap
            ? "Above the supply cap"
            : short
              ? `Not enough ${unit} (you have ${fmt(balance, decimals, pay === "usdc" ? 2 : 4)})`
              : `Buy the stocks and mint with ${unit}`}
      </Button>
      <p className="mt-2 text-xs text-muted">
        One transaction buys exactly the stocks this mint deposits in their Aerodrome pools and mints your BLUE. You never pay more
        than the maximum{pay === "eth" ? "; whatever it doesn't spend comes straight back" : ""}.
      </p>
      <TxStatus busy={busy} message={message} error={error} hash={hash} explorerTx={siteConfig.explorerTx} />
    </div>
  );
}
